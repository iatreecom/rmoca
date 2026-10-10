import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rmoca/models/note.dart';
import 'package:rmoca/models/note_meta.dart';
import 'package:rmoca/services/git_hash.dart';
import 'package:rmoca/services/local_store.dart';
import 'package:rmoca/services/remote.dart';
import 'package:rmoca/services/sync_engine.dart';

/// In-memory remote that behaves like a branch with linear history.
class FakeRemote implements NoteRemote {
  final Map<String, Uint8List> blobs = {};
  Map<String, String> files = {};
  int head = 0;
  int commits = 0;

  /// Simulates another device pushing between snapshot and commit.
  void Function()? beforeCommit;

  void put(String path, String text) {
    final bytes = Uint8List.fromList(utf8.encode(text));
    final sha = gitBlobSha(bytes);
    blobs[sha] = bytes;
    files = {...files, path: sha};
    head++;
  }

  void remove(String path) {
    files = {...files}..remove(path);
    head++;
  }

  String? text(String path) {
    final sha = files[path];
    return sha == null ? null : utf8.decode(blobs[sha]!);
  }

  @override
  Future<RemoteSnapshot> snapshot() async =>
      RemoteSnapshot(headCommit: '$head', files: Map.of(files));

  @override
  Future<Uint8List> download(String blobSha) async => blobs[blobSha]!;

  @override
  Future<void> commit({
    required String? parentCommit,
    required List<RemoteChange> changes,
    required String message,
  }) async {
    final hook = beforeCommit;
    beforeCommit = null;
    hook?.call();
    if (parentCommit != '$head') throw RemoteConflictException();
    for (final c in changes) {
      if (c.content == null) {
        files.remove(c.path);
      } else {
        final sha = gitBlobSha(c.content!);
        blobs[sha] = c.content!;
        files[c.path] = sha;
      }
    }
    head++;
    commits++;
  }
}

void main() {
  late Directory dir;
  late LocalStore store;
  late FakeRemote remote;
  late SyncEngine engine;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('rmoca_test');
    store = await LocalStore.openAt(dir);
    remote = FakeRemote();
    engine = SyncEngine(
      store: store,
      remote: remote,
      targetKey: 'test',
      deviceName: 'mac',
      mergers: const {Note.metaPath: NoteMeta.merge},
      clock: () => DateTime(2026, 10, 10, 9, 30),
    );
  });

  tearDown(() => dir.delete(recursive: true));

  test('git blob sha matches git hash-object', () {
    // `printf 'hello\n' | git hash-object --stdin`
    expect(
      gitBlobSha(Uint8List.fromList(utf8.encode('hello\n'))),
      'ce013625030ba8dba906f756967f9e9ca394464a',
    );
  });

  test('uploads new local notes and downloads new remote ones', () async {
    await store.writeText('local.md', '# local');
    remote.put('remote.md', '# remote');
    remote.put('sub/drawing.svg', '<svg/>');

    final r = await engine.sync();

    expect(r.uploaded, ['local.md']);
    expect(r.downloaded, containsAll(['remote.md', 'sub/drawing.svg']));
    expect(remote.text('local.md'), '# local');
    expect(await store.readText('remote.md'), '# remote');
    expect(await store.readText('sub/drawing.svg'), '<svg/>');
    expect(remote.commits, 1);

    // Nothing to do on the next run.
    final again = await engine.sync();
    expect(again.hasChanges, isFalse);
    expect(remote.commits, 1);
  });

  test('offline edits are pushed on the next sync', () async {
    remote.put('a.md', 'v1');
    await engine.sync();

    await store.writeText('a.md', 'v2 offline');
    await store.writeText('b.md', 'new offline');
    final r = await engine.sync();

    expect(r.uploaded, ['a.md', 'b.md']);
    expect(remote.text('a.md'), 'v2 offline');
    expect(remote.text('b.md'), 'new offline');
  });

  test('deletions propagate in both directions', () async {
    remote.put('a.md', 'a');
    remote.put('b.md', 'b');
    await engine.sync();

    await store.delete('a.md');
    remote.remove('b.md');
    final r = await engine.sync();

    expect(r.deletedRemotely, ['a.md']);
    expect(r.deletedLocally, ['b.md']);
    expect(remote.files, isEmpty);
    expect(await store.exists('b.md'), isFalse);
  });

  test('concurrent edits keep both versions', () async {
    remote.put('a.md', 'base');
    await engine.sync();

    await store.writeText('a.md', 'mine');
    remote.put('a.md', 'theirs');
    final r = await engine.sync();

    const copy = 'a (충돌 mac 2026-10-10 09.30).md';
    expect(r.conflicts, [copy]);
    expect(await store.readText('a.md'), 'theirs');
    expect(await store.readText(copy), 'mine');
    expect(remote.text('a.md'), 'theirs');
    expect(remote.text(copy), 'mine');

    expect((await engine.sync()).hasChanges, isFalse);
  });

  test('edit wins over a delete on the other side', () async {
    remote.put('a.md', 'base');
    remote.put('b.md', 'base');
    await engine.sync();

    await store.delete('a.md');
    remote.put('a.md', 'edited remotely');
    await store.writeText('b.md', 'edited locally');
    remote.remove('b.md');
    await engine.sync();

    expect(await store.readText('a.md'), 'edited remotely');
    expect(remote.text('b.md'), 'edited locally');
  });

  test('retries when the branch moves during sync', () async {
    await store.writeText('a.md', 'mine');
    remote.beforeCommit = () => remote.put('other.md', 'pushed meanwhile');

    await engine.sync();

    expect(remote.text('a.md'), 'mine');
    expect(await store.readText('other.md'), 'pushed meanwhile');
  });

  test(
    'identical content on both sides without history is not a conflict',
    () async {
      await store.writeText('a.md', 'same');
      remote.put('a.md', 'same');
      final r = await engine.sync();
      expect(r.hasChanges, isFalse);
      expect(r.conflicts, isEmpty);
    },
  );

  test('ignores non-note files', () async {
    remote.put('a.md', 'x');
    await File('${store.notesDir.path}/readme.txt').writeAsString('ignored');
    final r = await engine.sync();
    expect(r.uploaded, isEmpty);
  });

  test('empty folders sync through .gitkeep', () async {
    await store.createFolder('work/ideas');
    final r = await engine.sync();
    expect(r.uploaded, ['work/ideas/.gitkeep']);
    expect(remote.files.keys, contains('work/ideas/.gitkeep'));

    await store.deleteFolder('work');
    final r2 = await engine.sync();
    expect(r2.deletedRemotely, ['work/ideas/.gitkeep']);
  });

  test('moving a folder syncs as delete + add', () async {
    await store.writeText('a/note.md', 'x');
    await engine.sync();
    final moves = await store.moveFolder('a', 'b/a');
    expect(moves, {'a/note.md': 'b/a/note.md'});
    await engine.sync();
    expect(remote.files.keys, ['b/a/note.md']);
    expect(await store.listFolders(), ['b', 'b/a']);
  });

  test('favorites changed on two devices are merged, not conflicted', () async {
    final t0 = DateTime.utc(2026, 1, 1);
    final base = NoteMeta()..setFavorite('a.md', true, t0);
    await store.writeMeta(base);
    await engine.sync();

    final local = await store.readMeta()
      ..setFavorite('b.md', true, t0.add(const Duration(minutes: 1)));
    await store.writeMeta(local);
    final other = NoteMeta.decode(utf8.encode(remote.text(Note.metaPath)!))
      ..setFavorite('a.md', false, t0.add(const Duration(minutes: 2)))
      ..setFolderColor('work', 0xFF0000, t0);
    remote.put(Note.metaPath, utf8.decode(other.encode()));

    final r = await engine.sync();
    expect(r.conflicts, isEmpty);
    final merged = await store.readMeta();
    expect(merged.isFavorite('a.md'), isFalse);
    expect(merged.isFavorite('b.md'), isTrue);
    expect(merged.folderColor('work'), 0xFF0000);
    expect(remote.text(Note.metaPath), utf8.decode(merged.encode()));
  });

  test('trash keeps paths, restores and hides trashed notes', () async {
    await store.writeText('work/a.md', 'x');
    final trashed = await store.moveToTrash('work/a.md');
    expect(trashed, '.trash/work/a.md');
    expect(await store.listNotes(), isEmpty);
    expect(
      (await store.listNotes(trash: true)).single.path,
      '.trash/work/a.md',
    );
    expect(await store.listFolders(), isEmpty);

    // Trash syncs like any folder, so other devices see the deletion.
    await engine.sync();
    expect(remote.files.keys, ['.trash/work/a.md']);

    expect(await store.restoreFromTrash(trashed), 'work/a.md');
    expect(await store.readText('work/a.md'), 'x');
    expect(await store.listNotes(trash: true), isEmpty);
  });
}
