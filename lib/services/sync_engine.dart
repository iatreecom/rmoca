import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

import 'git_hash.dart';
import 'local_store.dart';
import 'remote.dart';

class SyncResult {
  final List<String> downloaded = [];
  final List<String> uploaded = [];
  final List<String> deletedLocally = [];
  final List<String> deletedRemotely = [];

  /// Conflict copies created from local edits that clashed with remote ones.
  final List<String> conflicts = [];

  /// Paths whose local file changed, so open editors can reload.
  Set<String> get changedLocally => {...downloaded, ...deletedLocally};

  bool get hasChanges =>
      downloaded.isNotEmpty ||
      uploaded.isNotEmpty ||
      deletedLocally.isNotEmpty ||
      deletedRemotely.isNotEmpty;
}

/// Three-way sync between the local notes folder and a [NoteRemote].
///
/// For every path we compare the local blob SHA, the remote blob SHA and the
/// SHA recorded at the last successful sync (the base):
///
/// * local == remote            -> already in sync
/// * only local changed         -> upload (or delete remotely)
/// * only remote changed        -> download (or delete locally)
/// * both changed differently   -> keep the remote version under the original
///   name and save the local version as a conflict copy, so nothing is lost.
class SyncEngine {
  SyncEngine({
    required this.store,
    required this.remote,
    required this.targetKey,
    required this.deviceName,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final LocalStore store;
  final NoteRemote remote;
  final String targetKey;
  final String deviceName;
  final DateTime Function() _clock;

  static const _maxAttempts = 3;

  Future<SyncResult> sync() => store.lock.run(() async {
        for (var attempt = 1;; attempt++) {
          try {
            return await _syncOnce();
          } on RemoteConflictException {
            // Someone else pushed between our snapshot and commit. Downloads
            // already written match the remote, so simply run again.
            if (attempt >= _maxAttempts) rethrow;
          }
        }
      });

  Future<SyncResult> _syncOnce() async {
    final result = SyncResult();
    final saved = await store.loadState();
    // A different repo/folder means the old base is meaningless.
    final base = saved != null && saved.targetKey == targetKey
        ? Map<String, String>.from(saved.base)
        : <String, String>{};

    final local = await store.hashes();
    final snapshot = await remote.snapshot();
    final remoteFiles = snapshot.files;

    final newBase = <String, String>{};
    final changes = <RemoteChange>[];
    final paths = {...local.keys, ...remoteFiles.keys, ...base.keys}.toList()
      ..sort();

    for (final path in paths) {
      final l = local[path];
      final r = remoteFiles[path];
      final b = base[path];

      if (l == r) {
        if (l != null) newBase[path] = l;
        continue;
      }

      if (l == b) {
        // Only the remote changed.
        if (r == null) {
          await store.deleteUnlocked(path);
          result.deletedLocally.add(path);
        } else {
          await _download(path, r);
          newBase[path] = r;
          result.downloaded.add(path);
        }
        continue;
      }

      if (r == b) {
        // Only the local copy changed.
        if (l == null) {
          changes.add(RemoteChange.delete(path));
          result.deletedRemotely.add(path);
        } else {
          changes.add(RemoteChange.put(path, await store.readBytes(path)));
          newBase[path] = l;
          result.uploaded.add(path);
        }
        continue;
      }

      // Both sides changed in different ways.
      if (l == null) {
        // Deleted here, edited elsewhere: keep the edit.
        await _download(path, r!);
        newBase[path] = r;
        result.downloaded.add(path);
      } else if (r == null) {
        // Edited here, deleted elsewhere: keep the edit.
        changes.add(RemoteChange.put(path, await store.readBytes(path)));
        newBase[path] = l;
        result.uploaded.add(path);
      } else {
        final localBytes = await store.readBytes(path);
        final copy = await _conflictPath(path, {...local.keys, ...remoteFiles.keys});
        await store.writeBytesUnlocked(copy, localBytes);
        await _download(path, r);
        changes.add(RemoteChange.put(copy, localBytes));
        newBase[path] = r;
        newBase[copy] = l;
        result.downloaded.add(path);
        result.uploaded.add(copy);
        result.conflicts.add(copy);
      }
    }

    if (changes.isNotEmpty) {
      await remote.commit(
        parentCommit: snapshot.headCommit,
        changes: changes,
        message: _commitMessage(result),
      );
    }

    await store.saveState(
        SyncState(targetKey: targetKey, base: newBase, lastSync: _clock()));
    return result;
  }

  Future<void> _download(String path, String sha) async {
    final bytes = await remote.download(sha);
    if (gitBlobSha(Uint8List.fromList(bytes)) != sha) {
      throw RemoteException('다운로드한 파일이 손상되었습니다: $path');
    }
    await store.writeBytesUnlocked(path, bytes);
  }

  Future<String> _conflictPath(String path, Set<String> taken) async {
    final dir = p.posix.dirname(path);
    final name = p.posix.basenameWithoutExtension(path);
    final ext = p.posix.extension(path);
    final stamp = DateFormat('yyyy-MM-dd HH.mm').format(_clock());
    final device = deviceName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    for (var i = 1;; i++) {
      final suffix = i == 1 ? '' : ' $i';
      final file = '$name (충돌 $device $stamp$suffix)$ext';
      final candidate = dir == '.' ? file : '$dir/$file';
      if (!taken.contains(candidate) && !await store.exists(candidate)) {
        return candidate;
      }
    }
  }

  String _commitMessage(SyncResult r) {
    final parts = <String>[
      if (r.uploaded.isNotEmpty) '${r.uploaded.length}개 수정',
      if (r.deletedRemotely.isNotEmpty) '${r.deletedRemotely.length}개 삭제',
    ];
    final files = [...r.uploaded, ...r.deletedRemotely];
    final listing = files.take(20).map((f) => '- $f').join('\n');
    final more = files.length > 20 ? '\n- … 외 ${files.length - 20}개' : '';
    return 'rmoca: ${parts.join(', ')} ($deviceName)\n\n$listing$more';
  }
}
