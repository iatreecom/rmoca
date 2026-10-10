import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rmoca/models/sync_settings.dart';
import 'package:rmoca/services/github_remote.dart';
import 'package:rmoca/services/remote.dart';

void main() {
  const settings = SyncSettings(
    owner: 'me',
    repo: 'notes',
    branch: 'main',
    folder: 'memo',
    token: 't',
  );

  test('snapshot lists only notes inside the folder', () async {
    final client = MockClient((req) async {
      expect(req.headers['Authorization'], 'Bearer t');
      final path = req.url.path;
      if (path.endsWith('/git/ref/heads/main')) {
        return http.Response(
          jsonEncode({
            'object': {'sha': 'c1'},
          }),
          200,
        );
      }
      if (path.endsWith('/git/commits/c1')) {
        return http.Response(
          jsonEncode({
            'tree': {'sha': 't1'},
          }),
          200,
        );
      }
      if (path.endsWith('/git/trees/t1')) {
        expect(req.url.queryParameters['recursive'], '1');
        return http.Response(
          jsonEncode({
            'truncated': false,
            'tree': [
              {'path': 'memo', 'type': 'tree', 'sha': 'x'},
              {'path': 'memo/a.md', 'type': 'blob', 'sha': 's1'},
              {'path': 'memo/sub/b.svg', 'type': 'blob', 'sha': 's2'},
              {'path': 'memo/c.txt', 'type': 'blob', 'sha': 's3'},
              {'path': 'memos/d.md', 'type': 'blob', 'sha': 's4'},
              {'path': 'README.md', 'type': 'blob', 'sha': 's5'},
            ],
          }),
          200,
        );
      }
      return http.Response('not found', 404);
    });

    final snap = await GitHubRemote(settings, client: client).snapshot();
    expect(snap.headCommit, 'c1');
    expect(snap.files, {'a.md': 's1', 'sub/b.svg': 's2'});
  });

  test(
    'commit creates blobs, tree, commit and fast-forwards the ref',
    () async {
      final calls = <String>[];
      Map<String, Object?>? treeBody;
      Map<String, Object?>? refBody;
      final client = MockClient((req) async {
        calls.add(
          '${req.method} ${req.url.path.split('/repos/me/notes').last}',
        );
        final body = req.body.isEmpty
            ? null
            : jsonDecode(req.body) as Map<String, Object?>;
        return switch (calls.last) {
          'GET /git/commits/c1' => http.Response(
            jsonEncode({
              'tree': {'sha': 't1'},
            }),
            200,
          ),
          'POST /git/blobs' => http.Response(jsonEncode({'sha': 'b1'}), 201),
          'POST /git/trees' => () {
            treeBody = body;
            return http.Response(jsonEncode({'sha': 't2'}), 201);
          }(),
          'POST /git/commits' => http.Response(jsonEncode({'sha': 'c2'}), 201),
          'PATCH /git/refs/heads/main' => () {
            refBody = body;
            return http.Response(jsonEncode({}), 200);
          }(),
          _ => http.Response('unexpected', 500),
        };
      });

      await GitHubRemote(settings, client: client).commit(
        parentCommit: 'c1',
        changes: [
          RemoteChange.put('a.md', utf8.encode('hi')),
          RemoteChange.delete('old.md'),
        ],
        message: 'm',
      );

      expect(treeBody!['base_tree'], 't1');
      expect(treeBody!['tree'], [
        {'path': 'memo/a.md', 'mode': '100644', 'type': 'blob', 'sha': 'b1'},
        {'path': 'memo/old.md', 'mode': '100644', 'type': 'blob', 'sha': null},
      ]);
      expect(refBody, {'sha': 'c2', 'force': false});
    },
  );

  test('non fast-forward ref update reports a conflict', () async {
    final client = MockClient((req) async {
      final p = req.url.path;
      if (p.endsWith('/git/commits/c1')) {
        return http.Response(
          jsonEncode({
            'tree': {'sha': 't1'},
          }),
          200,
        );
      }
      if (p.endsWith('/git/blobs')) {
        return http.Response(jsonEncode({'sha': 'b'}), 201);
      }
      if (p.endsWith('/git/trees')) {
        return http.Response(jsonEncode({'sha': 't'}), 201);
      }
      if (p.endsWith('/git/commits')) {
        return http.Response(jsonEncode({'sha': 'c'}), 201);
      }
      return http.Response(
        jsonEncode({'message': 'Update is not a fast forward'}),
        422,
      );
    });
    expect(
      GitHubRemote(settings, client: client).commit(
        parentCommit: 'c1',
        changes: [RemoteChange.put('a.md', utf8.encode('x'))],
        message: 'm',
      ),
      throwsA(isA<RemoteConflictException>()),
    );
  });
}
