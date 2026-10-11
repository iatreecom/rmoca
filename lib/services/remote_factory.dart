import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../git/git_http_remote.dart';
import '../git/objects.dart';
import '../models/sync_settings.dart';
import 'github_remote.dart';
import 'remote.dart';

/// Builds the remote for [settings]. Git over HTTPS keeps its object cache
/// under [cacheRoot], one folder per repository, so later syncs only
/// download what changed.
NoteRemote remoteFor(SyncSettings settings, Directory cacheRoot) =>
    switch (settings.kind) {
      RemoteKind.github => GitHubRemote(settings),
      RemoteKind.git => gitRemoteFor(settings, cacheRoot),
    };

GitHttpRemote gitRemoteFor(SyncSettings s, Directory cacheRoot) {
  final url = SyncSettings.normalizeGitUrl(s.gitUrl);
  final key = sha1.convert(utf8.encode(url)).toString().substring(0, 16);
  return GitHttpRemote(
    url: url,
    branch: s.branch,
    folder: s.folder,
    username: s.username,
    password: s.token,
    store: ObjectStore(Directory(p.join(cacheRoot.path, 'git', key))),
    authorName: s.effectiveAuthorName,
    authorEmail: s.effectiveAuthorEmail,
    allowSelfSigned: s.allowSelfSigned,
  );
}

/// Checks the connection; returns a short human-readable summary.
Future<String> testRemote(SyncSettings s, Directory cacheRoot) =>
    switch (s.kind) {
      RemoteKind.github => GitHubRemote(s).testConnection(),
      RemoteKind.git => gitRemoteFor(s, cacheRoot).testConnection(),
    };
