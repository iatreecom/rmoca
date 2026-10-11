import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../models/note.dart';
import '../services/remote.dart';
import 'objects.dart';
import 'pack.dart';

/// Syncs with any git server over HTTPS (GitHub, GitLab, Gitea/Forgejo,
/// Bitbucket, Azure DevOps, a self-hosted `git http-backend`…) by speaking
/// git's smart HTTP protocol directly — no git installation needed, so it
/// works the same on every platform.
///
/// Each sync fetches only the latest commit (shallow) plus objects that
/// changed since the last one, and pushes one new commit; the server
/// rejects the push if the branch moved meanwhile, which the sync engine
/// handles by syncing again.
class GitHttpRemote implements NoteRemote {
  GitHttpRemote({
    required this.url,
    required this.branch,
    required this.folder,
    required this.username,
    required this.password,
    required this.store,
    required this.authorName,
    required this.authorEmail,
    bool allowSelfSigned = false,
    http.Client? client,
  }) : _client = client ?? _makeClient(allowSelfSigned);

  /// Repository URL, e.g. `https://git.example.com/me/notes.git`.
  final String url;
  final String branch;
  final String folder;
  final String username;
  final String password;
  final ObjectStore store;
  final String authorName;
  final String authorEmail;
  final http.Client _client;

  String get _ref => 'refs/heads/$branch';
  String get _prefix => folder.isEmpty ? '' : '$folder/';
  String get _base => url.replaceAll(RegExp(r'/+$'), '');

  static const _zero = '0000000000000000000000000000000000000000';
  static const _agent = 'git/2.43.0-rmoca';

  static http.Client _makeClient(bool allowSelfSigned) {
    final io = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    if (allowSelfSigned) io.badCertificateCallback = (_, _, _) => true;
    return IOClient(io);
  }

  Map<String, String> get _headers => {
    'User-Agent': _agent,
    if (username.isNotEmpty || password.isNotEmpty)
      'Authorization':
          'Basic ${base64Encode(utf8.encode('${username.isEmpty ? 'git' : username}:$password'))}',
  };

  /// Checks credentials and the branch; returns a short summary.
  Future<String> testConnection() async {
    final refs = await _refs('git-upload-pack');
    final head = refs[_ref];
    final snap = await snapshot();
    return head == null
        ? '연결됨 · 빈 저장소 또는 새 브랜치 ($branch)'
        : '연결됨 · $branch · 메모 ${snap.files.keys.where(Note.isNotePath).length}개';
  }

  // --- protocol --------------------------------------------------------------

  Future<Map<String, String>> _refs(String service) async {
    final response = await _send(
      http.Request('GET', Uri.parse('$_base/info/refs?service=$service')),
    );
    final refs = <String, String>{};
    for (final pkt in readPkts(response)) {
      if (pkt.isFlush) continue;
      var line = pkt.text;
      if (line.startsWith('#')) continue;
      final nul = line.indexOf('\u0000');
      if (nul >= 0) line = line.substring(0, nul);
      final parts = line.trim().split(' ');
      if (parts.length == 2 && parts[0] != _zero) refs[parts[1]] = parts[0];
    }
    return refs;
  }

  Future<Uint8List> _send(http.BaseRequest request) async {
    request.headers.addAll(_headers);
    final http.StreamedResponse streamed;
    try {
      streamed = await _client
          .send(request)
          .timeout(const Duration(seconds: 60));
    } on HandshakeException {
      throw RemoteException(
        '보안 연결(인증서)을 확인할 수 없습니다. 사설 서버라면 설정에서 "자체 서명 인증서 허용"을 켜 주세요.',
      );
    }
    final body = await streamed.stream.toBytes();
    final code = streamed.statusCode;
    if (code == 401 || code == 403) {
      throw RemoteException(
        '인증에 실패했습니다. 사용자 이름과 토큰(비밀번호)을 확인하세요.',
        statusCode: code,
      );
    }
    if (code == 404) {
      throw RemoteException('저장소를 찾을 수 없습니다. 주소를 확인하세요.', statusCode: 404);
    }
    if (code >= 400) {
      throw RemoteException('git 서버 오류 $code', statusCode: code);
    }
    final type = streamed.headers['content-type'] ?? '';
    if (request.method == 'GET' && !type.contains('application/x-git-')) {
      // A login page or a "dumb" server rather than git.
      throw RemoteException(
        'git 저장소 주소가 아닌 것 같습니다 (응답: ${type.isEmpty ? '알 수 없음' : type}).',
      );
    }
    return body;
  }

  @override
  Future<RemoteSnapshot> snapshot() async {
    final head = (await _refs('git-upload-pack'))[_ref];
    if (head == null) return RemoteSnapshot(headCommit: null, files: {});
    if (!store.has(head)) await _fetch(head);
    final commit = Commit.parse(store.get(head)!.data);
    final files = <String, String>{};
    _walk(commit.tree, '', files);
    return RemoteSnapshot(
      headCommit: head,
      files: {
        for (final e in files.entries)
          if (e.key.startsWith(_prefix) &&
              Note.isSyncedPath(e.key.substring(_prefix.length)))
            e.key.substring(_prefix.length): e.value,
      },
    );
  }

  void _walk(String treeSha, String path, Map<String, String> out) {
    final tree = store.get(treeSha);
    if (tree == null) {
      throw RemoteException('저장소 데이터가 불완전합니다 (tree $treeSha).');
    }
    for (final e in parseTree(tree.data)) {
      final full = '$path${e.name}';
      if (e.isTree) {
        // Only descend where the synced folder can be.
        if (_prefix.isEmpty ||
            _prefix.startsWith('$full/') ||
            full.startsWith(_prefix)) {
          _walk(e.sha, '$full/', out);
        }
      } else if (e.mode != '160000') {
        out[full] = e.sha;
      }
    }
  }

  /// Shallow-fetches [want] and stores the objects. Commits we already
  /// have are sent as `have`, so only new objects come back.
  Future<void> _fetch(String want) async {
    final body = BytesBuilder(copy: false)
      ..add(
        pktLine(
          'want $want ofs-delta side-band-64k thin-pack shallow no-progress agent=$_agent\n',
        ),
      )
      ..add(pktLine('deepen 1\n'))
      ..add(flushPkt);
    for (final have in _knownHeads()) {
      body.add(pktLine('have $have\n'));
    }
    body.add(pktLine('done\n'));
    final request = http.Request('POST', Uri.parse('$_base/git-upload-pack'))
      ..headers['Content-Type'] = 'application/x-git-upload-pack-request'
      ..headers['Accept'] = 'application/x-git-upload-pack-result'
      ..bodyBytes = body.takeBytes();
    final response = await _send(request);

    final pack = BytesBuilder(copy: false);
    for (final pkt in readPkts(response)) {
      if (pkt.isFlush || pkt.data!.isEmpty) continue;
      final band = pkt.data![0];
      if (band == 1) {
        pack.add(Uint8List.sublistView(pkt.data!, 1));
      } else if (band == 3) {
        throw RemoteException(
          'git 서버 오류: ${utf8.decode(pkt.data!.sublist(1), allowMalformed: true).trim()}',
        );
      }
      // 2 = progress; text lines (shallow/ACK/NAK) are protocol chatter.
    }
    final bytes = pack.takeBytes();
    if (bytes.isEmpty) {
      throw RemoteException('git 서버가 데이터를 보내지 않았습니다.');
    }
    for (final obj in parsePack(bytes, store)) {
      store.put(obj);
    }
    _rememberHead(want);
  }

  // Heads we fetched before, for `have` negotiation.
  File get _headsFile => File('${store.dir.path}/rmoca-heads');

  List<String> _knownHeads() {
    if (!_headsFile.existsSync()) return [];
    return _headsFile
        .readAsLinesSync()
        .where((s) => s.length == 40 && store.has(s))
        .take(8)
        .toList();
  }

  void _rememberHead(String sha) {
    final heads = [sha, ..._knownHeads().where((s) => s != sha)].take(8);
    _headsFile.parent.createSync(recursive: true);
    _headsFile.writeAsStringSync('${heads.join('\n')}\n');
  }

  @override
  Future<Uint8List> download(String blobSha) async {
    final obj = store.get(blobSha);
    if (obj == null) throw RemoteException('파일을 찾을 수 없습니다 ($blobSha).');
    return obj.data;
  }

  @override
  Future<void> commit({
    required String? parentCommit,
    required List<RemoteChange> changes,
    required String message,
  }) async {
    if (changes.isEmpty) return;
    final newObjects = <GitObject>[];
    String put(GitObject o) {
      newObjects.add(o);
      return store.put(o);
    }

    // Path -> new blob sha (null = delete), under the synced folder.
    final edits = <String, String?>{};
    for (final c in changes) {
      edits['$_prefix${c.path}'] = c.content == null
          ? null
          : put(GitObject(GitType.blob, c.content!));
    }
    final baseTree = parentCommit == null
        ? null
        : Commit.parse(store.get(parentCommit)!.data).tree;
    final tree =
        _buildTree(baseTree, edits, put) ??
        put(GitObject(GitType.tree, Uint8List(0)));
    final now = DateTime.now();
    final commitSha = put(
      GitObject(
        GitType.commit,
        Commit(
          tree: tree,
          parents: [?parentCommit],
          author: Commit.signature(authorName, authorEmail, now),
          message: message,
        ).serialize(),
      ),
    );

    // Unique objects only, in a stable order.
    final seen = <String>{};
    final pack = writePack([
      for (final o in newObjects)
        if (seen.add(o.sha)) o,
    ]);
    final body = BytesBuilder(copy: false)
      ..add(
        pktLine(
          '${parentCommit ?? _zero} $commitSha $_ref\u0000 report-status agent=$_agent\n',
        ),
      )
      ..add(flushPkt)
      ..add(pack);
    final request = http.Request('POST', Uri.parse('$_base/git-receive-pack'))
      ..headers['Content-Type'] = 'application/x-git-receive-pack-request'
      ..headers['Accept'] = 'application/x-git-receive-pack-result'
      ..bodyBytes = body.takeBytes();
    final response = await _send(request);

    final lines = readPkts(response)
        .where((p) => !p.isFlush)
        .map((p) => p.text.trim())
        .toList();
    final unpack = lines.firstWhere(
      (l) => l.startsWith('unpack'),
      orElse: () => '',
    );
    if (unpack.isNotEmpty && unpack != 'unpack ok') {
      throw RemoteException('git 서버가 데이터를 거부했습니다: $unpack');
    }
    final status = lines.firstWhere(
      (l) => l.startsWith('ok ') || l.startsWith('ng '),
      orElse: () => '',
    );
    if (status.startsWith('ng ')) {
      // The branch moved (another device pushed) or the server refused.
      final head = (await _refs('git-upload-pack'))[_ref];
      if (head != parentCommit) throw RemoteConflictException();
      throw RemoteException('푸시가 거부되었습니다: ${status.substring(3)}');
    }
    if (status.isEmpty && lines.isNotEmpty) {
      throw RemoteException('git 서버 응답을 이해할 수 없습니다: ${lines.join(' / ')}');
    }
    _rememberHead(commitSha);
  }

  /// Rebuilds the tree [base] with [edits] (full paths), writing new trees.
  /// Returns null when the result is empty.
  String? _buildTree(
    String? base,
    Map<String, String?> edits,
    String Function(GitObject) put,
  ) {
    final entries = <String, TreeEntry>{
      if (base != null)
        for (final e in parseTree(store.get(base)!.data)) e.name: e,
    };
    final byChild = <String, Map<String, String?>>{};
    for (final e in edits.entries) {
      final slash = e.key.indexOf('/');
      if (slash < 0) {
        if (e.value == null) {
          entries.remove(e.key);
        } else {
          final old = entries[e.key];
          entries[e.key] = TreeEntry(
            old != null && !old.isTree ? old.mode : '100644',
            e.key,
            e.value!,
          );
        }
      } else {
        (byChild[e.key.substring(0, slash)] ??= {})[e.key.substring(
              slash + 1,
            )] =
            e.value;
      }
    }
    for (final e in byChild.entries) {
      final old = entries[e.key];
      final sub = _buildTree(
        old != null && old.isTree ? old.sha : null,
        e.value,
        put,
      );
      if (sub == null) {
        entries.remove(e.key);
      } else {
        entries[e.key] = TreeEntry('40000', e.key, sub);
      }
    }
    if (entries.isEmpty) return null;
    return put(GitObject(GitType.tree, serializeTree(entries.values.toList())));
  }
}
