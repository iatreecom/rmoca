import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rmoca/git/git_http_remote.dart';
import 'package:rmoca/git/objects.dart';
import 'package:rmoca/services/local_store.dart';
import 'package:rmoca/services/remote.dart';
import 'package:rmoca/services/sync_engine.dart';

/// End-to-end tests against `git http-backend` (git's own smart-HTTP
/// server), using the real git CLI as "another device".
void main() {
  final hasGit = Process.runSync('which', ['git']).exitCode == 0;
  late Directory root;
  late Process server;
  late int port;
  late Directory work;

  Future<ProcessResult> git(List<String> args, {String? dir}) async {
    final r = await Process.run('git', [
      '-c',
      'user.name=Phone',
      '-c',
      'user.email=phone@x',
      '-c',
      'core.quotepath=off',
      ...args,
    ], workingDirectory: dir ?? work.path);
    if (r.exitCode != 0) fail('git ${args.join(' ')}: ${r.stderr}');
    return r;
  }

  String bare() => '${root.path}/notes.git';
  String url() => 'http://127.0.0.1:$port/notes.git';
  String authed() => 'http://u:pw@127.0.0.1:$port/notes.git';

  GitHttpRemote remote({String folder = 'memo', String password = 'pw'}) =>
      GitHttpRemote(
        url: url(),
        branch: 'main',
        folder: folder,
        username: 'u',
        password: password,
        store: ObjectStore(Directory('${work.path}/objects-$folder')),
        authorName: 'Tablet',
        authorEmail: 'tablet@rmoca',
      );

  setUp(() async {
    if (!hasGit) return;
    root = await Directory.systemTemp.createTemp('gitroot');
    work = await Directory.systemTemp.createTemp('gitwork');
    await Process.run('git', ['init', '-q', '--bare', '-b', 'main', bare()]);
    final socket = await ServerSocket.bind('127.0.0.1', 0);
    port = socket.port;
    await socket.close();
    server = await Process.start('python3', [
      '-I',
      'test/support/git_http_server.py',
      '$port',
      root.path,
      'u:pw',
    ]);
    // Wait until it answers.
    for (var i = 0; i < 50; i++) {
      try {
        final s = await Socket.connect('127.0.0.1', port);
        s.destroy();
        break;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  tearDown(() async {
    if (!hasGit) return;
    server.kill();
    await root.delete(recursive: true);
    await work.delete(recursive: true);
  });

  Future<String> show(String path) async =>
      (await git(['--git-dir', bare(), 'show', 'main:$path'])).stdout as String;

  Future<void> clonePushAs(
    void Function(String dir) edit,
    String message,
  ) async {
    final dir = '${work.path}/phone';
    if (!Directory(dir).existsSync()) {
      await git(['clone', '-q', authed(), dir]);
      await git(['checkout', '-q', '-B', 'main'], dir: dir);
    } else {
      await git(['pull', '-q', '--rebase', 'origin', 'main'], dir: dir);
    }
    edit(dir);
    await git(['add', '-A'], dir: dir);
    await git(['commit', '-qm', message], dir: dir);
    await git(['push', '-q', 'origin', 'HEAD:main'], dir: dir);
  }

  test('first push into an empty repository', () async {
    final r = remote();
    final snap = await r.snapshot();
    expect(snap.headCommit, isNull);
    await r.commit(
      parentCommit: null,
      changes: [
        RemoteChange.put('hello.md', utf8.encode('# 안녕\n')),
        RemoteChange.put('sub/deep/a.svg', utf8.encode('<svg/>')),
      ],
      message: 'first',
    );
    expect(await show('memo/hello.md'), '# 안녕\n');
    expect(await show('memo/sub/deep/a.svg'), '<svg/>');
    final log = await git([
      '--git-dir',
      bare(),
      'log',
      '--format=%an %s',
      'main',
    ]);
    expect((log.stdout as String).trim(), 'Tablet first');
    // git itself agrees the repository is consistent.
    await git(['--git-dir', bare(), 'fsck', '--strict']);
  }, skip: !hasGit);

  test('reads changes pushed by real git, incl. deltas', () async {
    final big = List.generate(400, (i) => 'line $i of a long note').join('\n');
    await clonePushAs((d) {
      Directory('$d/memo/folder').createSync(recursive: true);
      File('$d/memo/a.md').writeAsStringSync(big);
      File('$d/memo/folder/b.md').writeAsStringSync('b');
      File('$d/other/x.md')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('outside the synced folder');
    }, 'phone 1');

    final r = remote();
    var snap = await r.snapshot();
    expect(snap.files.keys.toSet(), {'a.md', 'folder/b.md'});

    // A small edit to a big file: git sends it as a delta against the
    // blob we already have (thin pack).
    await clonePushAs((d) {
      File('$d/memo/a.md').writeAsStringSync('$big\nedited on phone');
      File('$d/memo/folder/b.md').deleteSync();
      File('$d/memo/c.md').writeAsStringSync('new');
    }, 'phone 2');
    await git(['--git-dir', bare(), 'gc', '-q', '--aggressive']);

    snap = await r.snapshot();
    expect(snap.files.keys.toSet(), {'a.md', 'c.md'});
    final a = utf8.decode(await r.download(snap.files['a.md']!));
    expect(a, endsWith('edited on phone'));
    expect(utf8.decode(await r.download(snap.files['c.md']!)), 'new');
  }, skip: !hasGit);

  test('a stale push is rejected as a conflict', () async {
    await clonePushAs((d) {
      File('$d/memo/a.md')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('v1');
    }, 'base');
    final r = remote();
    final snap = await r.snapshot();
    await clonePushAs(
      (d) => File('$d/memo/a.md').writeAsStringSync('v2'),
      'meanwhile',
    );
    await expectLater(
      r.commit(
        parentCommit: snap.headCommit,
        changes: [RemoteChange.put('b.md', utf8.encode('x'))],
        message: 'late',
      ),
      throwsA(isA<RemoteConflictException>()),
    );
    expect(await show('memo/a.md'), 'v2');
  }, skip: !hasGit);

  test('full sync round trip with the sync engine', () async {
    final storeDir = await Directory.systemTemp.createTemp('store');
    addTearDown(() => storeDir.delete(recursive: true));
    final store = await LocalStore.openAt(storeDir);
    final engine = SyncEngine(
      store: store,
      remote: remote(),
      targetKey: 'git',
      deviceName: 'tablet',
    );
    await store.writeText('오늘.md', '# 오늘\n- [ ] 장보기');
    await store.writeBytesUnlocked(
      'img/p.png',
      Uint8List.fromList([137, 80, 78, 71, 0, 1]),
    );
    await engine.sync();
    expect(await show('memo/오늘.md'), '# 오늘\n- [ ] 장보기');

    await clonePushAs((d) {
      File('$d/memo/오늘.md').writeAsStringSync('# 오늘\n- [x] 장보기');
      File('$d/memo/폰.md').writeAsStringSync('from phone');
    }, 'phone edit');
    final r = await engine.sync();
    expect(r.downloaded.toSet(), {'오늘.md', '폰.md'});
    expect(await store.readText('오늘.md'), '# 오늘\n- [x] 장보기');

    await store.delete('폰.md');
    await engine.sync();
    final ls = await git([
      '--git-dir',
      bare(),
      'ls-tree',
      '-r',
      '--name-only',
      'main',
    ]);
    expect((ls.stdout as String).trim().split('\n').toSet(), {
      'memo/img/p.png',
      'memo/오늘.md',
    });
    await git(['--git-dir', bare(), 'fsck', '--strict']);
  }, skip: !hasGit);

  test('wrong password is reported as an auth error', () async {
    await expectLater(
      remote(password: 'nope').snapshot(),
      throwsA(
        isA<RemoteException>().having((e) => e.isAuthError, 'auth', isTrue),
      ),
    );
  }, skip: !hasGit);
}
