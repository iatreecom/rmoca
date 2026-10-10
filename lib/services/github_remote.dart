import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/note.dart';
import '../models/sync_settings.dart';
import 'remote.dart';

/// Syncs through the GitHub Git Data API, which works the same on every
/// platform (no native git needed) and lets one sync become one commit.
class GitHubRemote implements NoteRemote {
  GitHubRemote(this.settings, {http.Client? client})
    : _client = client ?? http.Client();

  final SyncSettings settings;
  final http.Client _client;

  String get _repoUrl {
    final base = settings.apiBaseUrl.replaceAll(RegExp(r'/+$'), '');
    return '$base/repos/${settings.owner}/${settings.repo}';
  }

  String get _prefix => settings.folder.isEmpty ? '' : '${settings.folder}/';

  /// Checks the token and repository, returning a human readable summary.
  Future<String> testConnection() async {
    final repo = await _request('GET', '');
    final perms = repo['permissions'] as Map?;
    if (perms != null && perms['push'] != true) {
      throw RemoteException('토큰에 저장소 쓰기(push) 권한이 없습니다.');
    }
    final snap = await snapshot();
    return '${repo['full_name']} 연결됨 · 메모 ${snap.files.length}개';
  }

  @override
  Future<RemoteSnapshot> snapshot() async {
    final head = await _headCommit();
    if (head == null) return RemoteSnapshot(headCommit: null, files: {});
    final commit = await _request('GET', '/git/commits/$head');
    final treeSha = (commit['tree'] as Map)['sha'] as String;
    final tree = await _request('GET', '/git/trees/$treeSha?recursive=1');
    if (tree['truncated'] == true) {
      throw RemoteException(
        '저장소가 너무 커서 전체 목록을 가져올 수 없습니다. '
        '더 작은 폴더를 지정해 주세요.',
      );
    }
    final files = <String, String>{};
    for (final entry in (tree['tree'] as List).cast<Map>()) {
      if (entry['type'] != 'blob') continue;
      final path = entry['path'] as String;
      if (!path.startsWith(_prefix)) continue;
      final rel = path.substring(_prefix.length);
      if (Note.isNotePath(rel)) files[rel] = entry['sha'] as String;
    }
    return RemoteSnapshot(headCommit: head, files: files);
  }

  @override
  Future<Uint8List> download(String blobSha) async {
    final blob = await _request('GET', '/git/blobs/$blobSha');
    final content = (blob['content'] as String).replaceAll(RegExp(r'\s'), '');
    return base64Decode(content);
  }

  @override
  Future<void> commit({
    required String? parentCommit,
    required List<RemoteChange> changes,
    required String message,
  }) async {
    if (changes.isEmpty) return;
    if (parentCommit == null) {
      // The Git Data API refuses to work on an empty repository, so create
      // the first file through the contents API, then continue normally.
      final first = changes.firstWhere(
        (c) => c.content != null,
        orElse: () => throw RemoteException('빈 저장소에서는 삭제할 파일이 없습니다.'),
      );
      await _request(
        'PUT',
        '/contents/${_encodePath('$_prefix${first.path}')}',
        body: {
          'message': message,
          'content': base64Encode(first.content!),
          'branch': settings.branch,
        },
      );
      final rest = changes.where((c) => c != first).toList();
      if (rest.isEmpty) return;
      return commit(
        parentCommit: await _headCommit(),
        changes: rest,
        message: message,
      );
    }

    final parent = await _request('GET', '/git/commits/$parentCommit');
    final baseTree = (parent['tree'] as Map)['sha'] as String;

    final entries = <Map<String, Object?>>[];
    for (final change in changes) {
      final path = '$_prefix${change.path}';
      if (change.content == null) {
        entries.add({
          'path': path,
          'mode': '100644',
          'type': 'blob',
          'sha': null,
        });
      } else {
        final blob = await _request(
          'POST',
          '/git/blobs',
          body: {
            'content': base64Encode(change.content!),
            'encoding': 'base64',
          },
        );
        entries.add({
          'path': path,
          'mode': '100644',
          'type': 'blob',
          'sha': blob['sha'],
        });
      }
    }

    final tree = await _request(
      'POST',
      '/git/trees',
      body: {'base_tree': baseTree, 'tree': entries},
    );
    final newCommit = await _request(
      'POST',
      '/git/commits',
      body: {
        'message': message,
        'tree': tree['sha'],
        'parents': [parentCommit],
      },
    );
    try {
      await _request(
        'PATCH',
        '/git/refs/heads/${settings.branch}',
        body: {'sha': newCommit['sha'], 'force': false},
      );
    } on RemoteException catch (e) {
      // 422 = not a fast-forward: someone pushed in the meantime.
      if (e.statusCode == 422 || e.statusCode == 409) {
        throw RemoteConflictException();
      }
      rethrow;
    }
  }

  Future<String?> _headCommit() async {
    try {
      final ref = await _request('GET', '/git/ref/heads/${settings.branch}');
      return (ref['object'] as Map)['sha'] as String;
    } on RemoteException catch (e) {
      // 409: repository is empty. 404: branch does not exist yet.
      if (e.statusCode == 409) return null;
      if (e.statusCode == 404) {
        await _request(
          'GET',
          '',
        ); // Throws a clearer error if the repo is missing.
        throw RemoteException(
          "'${settings.branch}' 브랜치를 찾을 수 없습니다.",
          statusCode: 404,
        );
      }
      rethrow;
    }
  }

  Future<Map<String, Object?>> _request(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async {
    final request = http.Request(method, Uri.parse('$_repoUrl$path'))
      ..headers.addAll({
        'Accept': 'application/vnd.github+json',
        'Authorization': 'Bearer ${settings.token}',
        'X-GitHub-Api-Version': '2022-11-28',
        if (body != null) 'Content-Type': 'application/json',
      });
    if (body != null) request.body = jsonEncode(body);

    final response = await http.Response.fromStream(
      await _client.send(request).timeout(const Duration(seconds: 30)),
    );
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return Map<String, Object?>.from(jsonDecode(response.body) as Map);
    }

    String detail = response.reasonPhrase ?? '';
    try {
      detail =
          (jsonDecode(response.body) as Map)['message'] as String? ?? detail;
    } catch (_) {
      // Non-JSON error body; keep the reason phrase.
    }
    final message = switch (response.statusCode) {
      401 => '토큰이 올바르지 않거나 만료되었습니다.',
      403 => '권한이 없거나 요청 한도를 초과했습니다: $detail',
      404 => '저장소를 찾을 수 없습니다. 이름과 토큰 권한을 확인하세요.',
      _ => 'GitHub 오류 ${response.statusCode}: $detail',
    };
    throw RemoteException(message, statusCode: response.statusCode);
  }

  static String _encodePath(String path) =>
      path.split('/').map(Uri.encodeComponent).join('/');
}
