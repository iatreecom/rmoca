import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';

import 'models/note.dart';
import 'models/sync_settings.dart';
import 'services/github_remote.dart';
import 'services/local_store.dart';
import 'services/remote.dart';
import 'services/settings_repository.dart';
import 'services/sync_engine.dart';

enum SyncStatus { notConfigured, idle, syncing, offline, error }

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
  SyncStatus status = SyncStatus.notConfigured;
  String? lastError;
  DateTime? lastSync;

  /// Fires with the paths a sync changed on disk so open editors can reload.
  final StreamController<Set<String>> _externalChanges =
      StreamController.broadcast();
  Stream<Set<String>> get externalChanges => _externalChanges.stream;

  Timer? _debounce;
  Timer? _periodic;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  AppLifecycleListener? _lifecycle;
  bool _online = true;
  bool _syncAgain = false;
  Future<void>? _running;

  Future<void> init() async {
    settings = await _settingsRepo.load();
    lastSync = (await store.loadState())?.lastSync;
    await refreshNotes();
    _updateIdleStatus();

    try {
      final initial = await Connectivity().checkConnectivity();
      _online = !initial.contains(ConnectivityResult.none);
    } catch (_) {
      _online = true;
    }
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final online = !results.contains(ConnectivityResult.none);
      final cameOnline = online && !_online;
      _online = online;
      if (!online && status != SyncStatus.syncing) {
        status = settings.isConfigured ? SyncStatus.offline : status;
        notifyListeners();
      }
      if (cameOnline) syncNow(auto: true);
    });
    _lifecycle = AppLifecycleListener(onResume: () => syncNow(auto: true));
    _periodic = Timer.periodic(
        const Duration(minutes: 3), (_) => syncNow(auto: true));

    syncNow(auto: true);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _periodic?.cancel();
    _connectivitySub?.cancel();
    _lifecycle?.dispose();
    _externalChanges.close();
    super.dispose();
  }

  Future<void> refreshNotes() async {
    notes = await store.listNotes();
    notifyListeners();
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

  Future<void> renameNote(String from, String to) async {
    await store.rename(from, to);
    await refreshNotes();
    _scheduleSync();
  }

  Future<String> newNotePath(String name, String extension, {String folder = ''}) {
    final safe = name
        .trim()
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'^\.+'), '');
    final file = '${safe.isEmpty ? '메모' : safe}.$extension';
    return store.uniquePath(folder.isEmpty ? file : '$folder/$file');
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
      }
    } on RemoteException catch (e) {
      lastError = e.message;
      status = SyncStatus.error;
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
