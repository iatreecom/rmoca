import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import 'markdown/link_rewriter.dart';
import 'models/note.dart';
import 'models/sync_settings.dart';
import 'services/github_remote.dart';
import 'services/local_store.dart';
import 'services/remote.dart';
import 'services/settings_repository.dart';
import 'services/sync_engine.dart';

enum SyncStatus { notConfigured, idle, syncing, offline, error }

/// How a new drawing is stored.
enum DrawingMode {
  /// Its own `.svg` file (linked from memos with `![](x.svg)`).
  file,

  /// Inline `<svg>` code inside a markdown memo.
  embedded,
}

/// App-wide state: the note list, settings and background sync.
///
/// Edits are always saved locally first; sync runs after edits (debounced),
/// when the network comes back, when the app resumes and periodically.
class AppState extends ChangeNotifier {
  AppState(this.store, this._settingsRepo);

  final LocalStore store;
  final SettingsRepository _settingsRepo;

  SyncSettings settings = const SyncSettings();
  List<Note> notes = [];

  /// Every folder, including empty ones ('a', 'a/b', ...).
  List<String> folders = [];
  DrawingMode drawingMode = DrawingMode.file;
  SyncStatus status = SyncStatus.notConfigured;
  String? lastError;
  DateTime? lastSync;

  /// Fires with the paths a sync changed on disk so open editors can reload.
  final StreamController<Set<String>> _externalChanges =
      StreamController.broadcast();
  Stream<Set<String>> get externalChanges => _externalChanges.stream;

  /// Things the user should notice (conflicts, auth problems), shown once.
  final StreamController<String> _messages = StreamController.broadcast();
  Stream<String> get messages => _messages.stream;

  Timer? _debounce;
  Timer? _periodic;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  AppLifecycleListener? _lifecycle;
  bool _online = true;
  bool _syncAgain = false;
  Future<void>? _running;

  Future<void> init() async {
    settings = await _settingsRepo.load();
    drawingMode = await _settingsRepo.loadDrawingMode();
    lastSync = (await store.loadState())?.lastSync;
    await refreshNotes();
    _updateIdleStatus();

    _watchConnectivity();
    _lifecycle = AppLifecycleListener(onResume: () => syncNow(auto: true));
    _periodic = Timer.periodic(
      const Duration(minutes: 3),
      (_) => syncNow(auto: true),
    );

    syncNow(auto: true);
  }

  /// Tracks network changes to sync as soon as we're back online.
  ///
  /// Connectivity is only a hint: if the platform service is missing or
  /// misbehaves we assume online and let failed syncs report offline. The
  /// plugin can throw from internal streams, hence the guarded zone.
  void _watchConnectivity() {
    runZonedGuarded(() async {
      final connectivity = Connectivity();
      try {
        final initial = await connectivity.checkConnectivity().timeout(
          const Duration(seconds: 3),
        );
        _online = !initial.contains(ConnectivityResult.none);
        _updateIdleStatus();
        notifyListeners();
      } catch (_) {
        // Keep assuming online.
      }
      _connectivitySub = connectivity.onConnectivityChanged.listen(
        _onConnectivity,
        onError: (Object _) {},
      );
    }, (error, _) => debugPrint('connectivity unavailable: $error'));
  }

  void _onConnectivity(List<ConnectivityResult> results) {
    final online = !results.contains(ConnectivityResult.none);
    final cameOnline = online && !_online;
    _online = online;
    if (!online && status != SyncStatus.syncing) {
      status = settings.isConfigured ? SyncStatus.offline : status;
      notifyListeners();
    }
    if (cameOnline) syncNow(auto: true);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _periodic?.cancel();
    _connectivitySub?.cancel();
    _lifecycle?.dispose();
    _externalChanges.close();
    _messages.close();
    super.dispose();
  }

  Future<void> refreshNotes() async {
    notes = await store.listNotes();
    folders = await store.listFolders();
    notifyListeners();
  }

  Future<void> setDrawingMode(DrawingMode mode) async {
    drawingMode = mode;
    notifyListeners();
    await _settingsRepo.saveDrawingMode(mode);
  }

  Future<void> updateSettings(SyncSettings next) async {
    settings = next;
    await _settingsRepo.save(next);
    _updateIdleStatus();
    notifyListeners();
    syncNow(auto: true);
  }

  // --- note operations -----------------------------------------------------

  Future<void> saveText(String path, String content) async {
    await store.writeText(path, content);
    await refreshNotes();
    _scheduleSync();
  }

  Future<void> deleteNote(String path) async {
    await store.delete(path);
    await refreshNotes();
    _scheduleSync();
  }

  /// Renames or moves a note, fixing links to and from it.
  Future<void> renameNote(String from, String to) async {
    if (from == to) return;
    await store.rename(from, to);
    await _afterMove({from: to});
  }

  // --- folders -------------------------------------------------------------

  Future<String> createFolder(String parent, String name) async {
    final path = Note.join(parent, sanitizeName(name, fallback: '새 폴더'));
    await store.createFolder(path);
    await refreshNotes();
    _scheduleSync();
    return path;
  }

  Future<void> deleteFolder(String folder) async {
    await store.deleteFolder(folder);
    await refreshNotes();
    _scheduleSync();
  }

  /// Renames or moves a folder with everything in it, fixing links.
  Future<void> moveFolder(String from, String to) async {
    if (from == to) return;
    final moves = await store.moveFolder(from, to);
    await _afterMove(moves);
  }

  /// Notes directly inside [folder] ('' = root).
  List<Note> notesIn(String folder) =>
      notes.where((n) => n.folder == folder).toList();

  /// Folders directly inside [folder] ('' = root).
  List<String> subfolders(String folder) =>
      folders.where((f) => Note.parentOf(f) == folder).toList();

  /// Number of notes anywhere under [folder].
  int countUnder(String folder) =>
      notes.where((n) => Note.isWithin(folder, n.path)).length;

  /// Rewrites relative links in every markdown note after [moves]
  /// (old path -> new path) so images and links keep working.
  Future<void> _afterMove(Map<String, String> moves) async {
    final reverse = {for (final e in moves.entries) e.value: e.key};
    for (final note in await store.listNotes()) {
      if (note.kind != NoteKind.markdown) continue;
      final content = await store.readText(note.path);
      final updated = LinkRewriter.rewrite(
        content,
        oldPath: reverse[note.path] ?? note.path,
        newPath: note.path,
        moves: moves,
      );
      if (updated != content) await store.writeText(note.path, updated);
    }
    await refreshNotes();
    _scheduleSync();
  }

  static String sanitizeName(String name, {String fallback = '메모'}) {
    final safe = name
        .trim()
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'^\.+'), '');
    return safe.isEmpty ? fallback : safe;
  }

  Future<String> newNotePath(
    String name,
    String extension, {
    String folder = '',
  }) {
    final file = '${sanitizeName(name)}.$extension';
    return store.uniquePath(Note.join(folder, file));
  }

  // --- sync ----------------------------------------------------------------

  void _scheduleSync() {
    if (!settings.isConfigured || !settings.autoSync) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 4), () => syncNow(auto: true));
  }

  /// Runs a sync now. With [auto], silently skips when sync is off/offline.
  Future<void> syncNow({bool auto = false}) {
    if (!settings.isConfigured) return Future.value();
    if (auto && (!settings.autoSync || !_online)) {
      _updateIdleStatus();
      notifyListeners();
      return Future.value();
    }
    if (_running != null) {
      // A sync is in flight; run once more afterwards to pick up new edits.
      _syncAgain = true;
      return _running!;
    }
    _debounce?.cancel();
    return _running = _runSync().whenComplete(() {
      _running = null;
      if (_syncAgain) {
        _syncAgain = false;
        syncNow(auto: true);
      }
    });
  }

  Future<void> _runSync() async {
    status = SyncStatus.syncing;
    notifyListeners();
    final remote = GitHubRemote(settings);
    final engine = SyncEngine(
      store: store,
      remote: remote,
      targetKey: settings.targetKey,
      deviceName: settings.deviceName,
    );
    final previousError = lastError;
    try {
      final result = await engine.sync();
      lastSync = DateTime.now();
      lastError = null;
      status = SyncStatus.idle;
      _online = true;
      if (result.changedLocally.isNotEmpty) {
        _externalChanges.add(result.changedLocally);
      }
      if (result.conflicts.isNotEmpty) {
        lastError = '충돌 ${result.conflicts.length}건: 로컬 수정본을 별도 메모로 저장했습니다.';
        final names = result.conflicts
            .map((c) => p.posix.basenameWithoutExtension(c))
            .join(', ');
        _messages.add('다른 기기에서도 수정된 메모가 있어 이 기기의 내용을 따로 저장했습니다: $names');
      }
    } on RemoteException catch (e) {
      lastError = e.message;
      status = SyncStatus.error;
      // Auto sync retries often; only surface a problem when it changes.
      if (e.message != previousError) _messages.add('동기화 오류: ${e.message}');
    } on RemoteConflictException {
      lastError = '다른 기기와 동시에 저장되었습니다. 잠시 후 다시 시도합니다.';
      status = SyncStatus.error;
      _scheduleSync();
    } catch (e) {
      // Network failures (SocketException, TimeoutException, ...) land here:
      // everything stays saved locally and syncs once we're back online.
      lastError = '오프라인: 로컬에 저장되었으며 연결되면 동기화됩니다.';
      status = SyncStatus.offline;
      debugPrint('sync failed: $e');
    } finally {
      await refreshNotes();
    }
  }

  void _updateIdleStatus() {
    if (status == SyncStatus.syncing) return;
    if (!settings.isConfigured) {
      status = SyncStatus.notConfigured;
    } else if (!_online) {
      status = SyncStatus.offline;
    } else if (status == SyncStatus.notConfigured) {
      status = SyncStatus.idle;
    }
  }
}
