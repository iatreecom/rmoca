import 'dart:typed_data';

/// A snapshot of the remote folder at one commit.
class RemoteSnapshot {
  RemoteSnapshot({required this.headCommit, required this.files});

  /// Commit SHA of the branch head, or null if the repository is empty.
  final String? headCommit;

  /// Note path (relative to the synced folder) -> git blob SHA.
  final Map<String, String> files;
}

/// One file change in a commit. [content] null means delete.
class RemoteChange {
  RemoteChange.put(this.path, Uint8List this.content);
  RemoteChange.delete(this.path) : content = null;

  final String path;
  final Uint8List? content;
}

/// The branch moved while we were syncing; fetch again and retry.
class RemoteConflictException implements Exception {
  @override
  String toString() => 'The remote branch changed during sync';
}

class RemoteException implements Exception {
  RemoteException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  bool get isAuthError => statusCode == 401 || statusCode == 403;

  @override
  String toString() => message;
}

/// Storage backend the sync engine talks to. Paths are relative to the
/// configured folder; implementations add the folder prefix.
abstract class NoteRemote {
  Future<RemoteSnapshot> snapshot();

  Future<Uint8List> download(String blobSha);

  /// Commits [changes] on top of [parentCommit] in a single commit and moves
  /// the branch, failing with [RemoteConflictException] if it moved.
  Future<void> commit({
    required String? parentCommit,
    required List<RemoteChange> changes,
    required String message,
  });
}
