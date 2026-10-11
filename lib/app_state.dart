import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/widgets.dart';

import 'package:path/path.dart' as p;

import 'markdown/link_rewriter.dart';
import 'markdown/note_links.dart';
import 'models/note.dart';
import 'models/note_meta.dart';
import 'models/sync_settings.dart';
import 'services/conflicts.dart';
import 'services/local_store.dart';
import 'services/note_crypto.dart';
import 'services/media_cache.dart';
import 'services/remote.dart';
import 'services/remote_factory.dart';
import 'services/settings_repository.dart';
import 'services/sync_engine.dart';

enum SyncStatus { notConfigured, idle, syncing, offline, error }

/// Order of notes in lists (favorites always come first).
enum SortMode {
  modifiedDesc('최근 수정 순'),
  modifiedAsc('오래된 순'),
  nameAsc('이름 순 (가나다)'),
  nameDesc('이름 역순');

  const SortMode(this.label);

  final String label;
}

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

  /// Edit notes block by block (true) or as plain markdown.
  bool easyEditing = true;

  /// Text size of notes (reading and editing), 1.0 = default.
  double noteScale = 1.0;
  SortMode sortMode = SortMode.modifiedDesc;
  ThemeMode themeMode = ThemeMode.system;
  Color accent = accentColors.first;

  static const accentColors = [
    Color(0xFF4F5BD5),
    Color(0xFF0F9D8A),
    Color(0xFFE0663E),
    Color(0xFFC2185B),
    Color(0xFF7E57C2),
    Color(0xFF546E7A),
  ];

  /// Synced favorites and folder colors.
  NoteMeta meta = NoteMeta();

  /// Image attachments synced with the notes.
  List<String> attachments = [];

  /// Offline copies of remote images used by notes.
  late final MediaCache media = MediaCache(store.mediaDir);

  /// Deleted notes, with paths inside `.trash`.
  List<Note> trash = [];

  static const trashRetention = Duration(days: 30);
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
    easyEditing = await _settingsRepo.loadEasyEditing();
    noteScale = await _settingsRepo.loadNoteScale();
    sortMode = await _settingsRepo.loadSortMode();
    final (mode, color) = await _settingsRepo.loadAppearance(accent);
    themeMode = mode;
    accent = color;
    await store.purgeTrash(trashRetention);
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
    unawaited(prefetchMedia());
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
    if (cameOnline) {
      syncNow(auto: true);
      unawaited(prefetchMedia());
    }
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
    meta = await store.readMeta();
    notes = _sorted(await store.listNotes());
    folders = await store.listFolders();
    trash = await store.listNotes(trash: true);
    attachments = await store.listAttachments();
    notifyListeners();
  }

  List<Note> _sorted(List<Note> list) {
    int byMode(Note a, Note b) => switch (sortMode) {
      SortMode.modifiedDesc => b.modified.compareTo(a.modified),
      SortMode.modifiedAsc => a.modified.compareTo(b.modified),
      SortMode.nameAsc => a.title.toLowerCase().compareTo(
        b.title.toLowerCase(),
      ),
      SortMode.nameDesc => b.title.toLowerCase().compareTo(
        a.title.toLowerCase(),
      ),
    };
    return list..sort((a, b) {
      final fa = meta.isFavorite(a.path), fb = meta.isFavorite(b.path);
      if (fa != fb) return fa ? -1 : 1;
      return byMode(a, b);
    });
  }

  Future<void> setAppearance({ThemeMode? mode, Color? accent}) async {
    themeMode = mode ?? themeMode;
    this.accent = accent ?? this.accent;
    notifyListeners();
    await _settingsRepo.saveAppearance(themeMode, this.accent);
  }

  Future<void> setSortMode(SortMode mode) async {
    sortMode = mode;
    notes = _sorted(notes);
    notifyListeners();
    await _settingsRepo.saveSortMode(mode);
  }

  // --- favorites and colors --------------------------------------------------

  bool isFavorite(String path) => meta.isFavorite(path);

  List<Note> get favorites =>
      notes.where((n) => meta.isFavorite(n.path)).toList();

  Future<void> setFavorite(Iterable<String> paths, bool value) async {
    for (final path in paths) {
      meta.setFavorite(path, value, DateTime.now());
    }
    await _saveMeta();
  }

  Color? folderColor(String folder) {
    final c = meta.folderColor(folder);
    return c == null ? null : Color(0xFF000000 | c);
  }

  Future<void> setFolderColor(String folder, Color? color) async {
    meta.setFolderColor(
      folder,
      color == null ? null : color.toARGB32() & 0xFFFFFF,
      DateTime.now(),
    );
    await _saveMeta();
  }

  Future<void> _saveMeta() async {
    await store.writeMeta(meta);
    notes = _sorted(notes);
    notifyListeners();
    _scheduleSync();
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

  static const noteScales = (min: 0.8, max: 1.6);

  Future<void> setNoteScale(double value) async {
    final v = double.parse(
      value.clamp(noteScales.min, noteScales.max).toStringAsFixed(2),
    );
    if (v == noteScale) return;
    noteScale = v;
    notifyListeners();
    await _settingsRepo.saveNoteScale(v);
  }

  Future<void> setEasyEditing(bool value) async {
    if (easyEditing == value) return;
    easyEditing = value;
    notifyListeners();
    await _settingsRepo.saveEasyEditing(value);
  }

  static const attachmentsFolder = 'attachments';

  /// Stores [bytes] as a new file in `attachments/` named after [name]
  /// (made unique); returns its path. Synced like notes.
  Future<String> saveAttachment(String name, List<int> bytes) async {
    final path = await store.uniquePath(
      Note.join(attachmentsFolder, sanitizeName(name)),
    );
    await store.writeBytes(path, bytes);
    await refreshNotes();
    _scheduleSync();
    return path;
  }

  /// Puts an earlier version back; the text it replaces stays in history.
  Future<void> restoreVersion(String path, String content) async {
    await store.writeText(path, content, keepVersion: true);
    _externalChanges.add({path});
    await refreshNotes();
    _scheduleSync();
  }

  Future<void> saveText(String path, String content) async {
    await store.writeText(path, content);
    await refreshNotes();
    _scheduleSync();
  }

  /// Moves a note to the trash (restorable for 30 days).
  Future<void> deleteNote(String path) async {
    await store.moveToTrash(path);
    await refreshNotes();
    _scheduleSync();
  }

  /// Keys of locked notes unlocked in this session (memory only).
  final Map<String, NoteKey> unlockedKeys = {};

  /// Conflict copies left by syncs, with the notes they belong to.
  List<ConflictPair> get conflicts => findConflicts(notes);

  /// Resolves [c] with this device's version: it replaces the note (the
  /// replaced text stays in version history) and the copy goes to the trash.
  Future<void> resolveWithCopy(ConflictPair c) async {
    final bytes = await store.readBytes(c.copy.path);
    if (await store.exists(c.original)) {
      if (Note.isDrawingPath(c.original)) {
        await store.writeBytes(c.original, bytes);
      } else {
        await store.writeText(
          c.original,
          await store.readText(c.copy.path),
          keepVersion: true,
        );
      }
    } else {
      await store.writeBytes(c.original, bytes);
    }
    await store.moveToTrash(c.copy.path);
    _externalChanges.add({c.original});
    await refreshNotes();
    _scheduleSync();
  }

  /// Resolves [c] with the other device's version: the copy goes to trash.
  Future<void> resolveWithOriginal(ConflictPair c) => deleteNote(c.copy.path);

  Future<void> deleteNotes(Iterable<String> paths) async {
    for (final path in paths) {
      await store.moveToTrash(path);
    }
    await refreshNotes();
    _scheduleSync();
  }

  Future<String> restoreNote(String trashPath) async {
    final path = await store.restoreFromTrash(trashPath);
    await refreshNotes();
    _scheduleSync();
    return path;
  }

  Future<void> deleteForever(Iterable<String> trashPaths) async {
    for (final path in trashPaths) {
      await store.delete(path);
    }
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

  /// Moves a folder with everything in it to the trash.
  Future<void> deleteFolder(String folder) async {
    await store.moveToTrash(folder, folder: true);
    await refreshNotes();
    _scheduleSync();
  }

  /// Renames or moves a folder with everything in it, fixing links.
  Future<void> moveFolder(String from, String to) async {
    if (from == to) return;
    final moves = await store.moveFolder(from, to);
    await _afterMove(moves);
  }

  // --- links and tags --------------------------------------------------------

  /// Note path a `[[target]]` in [fromPath] points to, if it exists.
  String? resolveWiki(String target, String fromPath) => resolveWikiTarget(
    target,
    fromPath,
    [...notes.map((n) => n.path), ...attachments],
  );

  /// Downloads remote images used anywhere in the notes that are not yet
  /// stored, so they show offline later.
  Future<void> prefetchMedia() async {
    final urls = {for (final n in notes) ...n.links.remoteMedia};
    if (urls.isEmpty) return;
    final count = await media.prefetch(urls);
    if (count > 0) debugPrint('cached $count remote images for offline use');
  }

  /// Notes that link to [path] with a wikilink or a relative link.
  /// Outgoing links of every note to other existing notes.
  Map<String, Set<String>> get linkGraph {
    final existing = {for (final n in notes) n.path};
    return {
      for (final n in notes)
        n.path: {
          ...n.links.paths.where(existing.contains),
          for (final t in n.links.wikiTargets)
            if (resolveWiki(t, n.path) case final String r
                when existing.contains(r))
              r,
        }..remove(n.path),
    };
  }

  List<Note> backlinksTo(String path) => notes
      .where(
        (n) =>
            n.path != path &&
            (n.links.paths.contains(path) ||
                n.links.wikiTargets.any((t) => resolveWiki(t, n.path) == path)),
      )
      .toList();

  /// Every tag with its note count; `a/b` also counts towards `a`.
  Map<String, int> get tagCounts {
    final counts = <String, int>{};
    for (final n in notes) {
      final all = <String>{};
      for (final t in n.links.tags) {
        final parts = t.split('/');
        for (var i = 1; i <= parts.length; i++) {
          all.add(parts.sublist(0, i).join('/'));
        }
      }
      for (final t in all) {
        counts[t] = (counts[t] ?? 0) + 1;
      }
    }
    return Map.fromEntries(
      counts.entries.toList()
        ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase())),
    );
  }

  /// Notes tagged [tag] or a nested tag under it.
  List<Note> notesWithTag(String tag) {
    final lower = tag.toLowerCase();
    return notes
        .where(
          (n) => n.links.tags.any((t) {
            final l = t.toLowerCase();
            return l == lower || l.startsWith('$lower/');
          }),
        )
        .toList();
  }

  /// Notes directly inside [folder] ('' = root).
  List<Note> notesIn(String folder) =>
      notes.where((n) => n.folder == folder).toList();

  /// Folders directly inside [folder] ('' = root).
  List<String> subfolders(String folder) =>
      folders.where((f) => Note.parentOf(f) == folder).toList();

  /// Number of images anywhere under [folder].
  int attachmentsUnder(String folder) =>
      attachments.where((a) => Note.isWithin(folder, a)).length;

  /// Number of notes anywhere under [folder].
  int countUnder(String folder) =>
      notes.where((n) => Note.isWithin(folder, n.path)).length;

  /// Rewrites relative links in every markdown note after [moves]
  /// (old path -> new path) so images and links keep working.
  Future<void> _afterMove(Map<String, String> moves) async {
    // Favorites and colors follow the files.
    meta = await store.readMeta();
    meta.applyMoves(moves, DateTime.now());
    final folderMoves = {
      for (final e in moves.entries)
        if (Note.parentOf(e.key) != Note.parentOf(e.value))
          Note.parentOf(e.key): Note.parentOf(e.value),
    }..remove('');
    meta.applyMoves(folderMoves, DateTime.now());
    await store.writeMeta(meta);
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
    final remote = remoteFor(settings, store.dataDir);
    final engine = SyncEngine(
      store: store,
      remote: remote,
      targetKey: settings.targetKey,
      deviceName: settings.deviceName,
      mergers: const {Note.metaPath: NoteMeta.merge},
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
      // New notes from other devices may use images not stored here yet.
      unawaited(refreshNotes().then((_) => prefetchMedia()));
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
