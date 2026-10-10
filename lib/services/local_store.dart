import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/note.dart';
import 'git_hash.dart';

/// Serializes async sections so a sync never interleaves with a save.
class Mutex {
  Future<void> _last = Future.value();

  Future<T> run<T>(Future<T> Function() action) {
    final result = _last.then((_) => action());
    _last = result.then((_) {}, onError: (_) {});
    return result;
  }
}

/// The last state both sides agreed on, keyed by note path.
///
/// Storing the git blob SHA of every file at the last successful sync lets
/// the sync engine do a three-way comparison (local / remote / base) and
/// tell edits, deletions and conflicts apart while working offline.
class SyncState {
  SyncState({required this.targetKey, required this.base, this.lastSync});

  final String targetKey;
  final Map<String, String> base;
  final DateTime? lastSync;

  factory SyncState.empty(String targetKey) =>
      SyncState(targetKey: targetKey, base: {});

  Map<String, Object?> toJson() => {
    'targetKey': targetKey,
    'base': base,
    'lastSync': lastSync?.toIso8601String(),
  };

  factory SyncState.fromJson(Map<String, Object?> json) => SyncState(
    targetKey: json['targetKey'] as String? ?? '',
    base: Map<String, String>.from(json['base'] as Map? ?? const {}),
    lastSync: json['lastSync'] == null
        ? null
        : DateTime.tryParse(json['lastSync'] as String),
  );
}

/// Notes live as plain `.md` / `.svg` files in the app support directory, so
/// everything works offline; the sync engine mirrors them to git.
class LocalStore {
  LocalStore._(this._root);

  final Directory _root;
  final Mutex lock = Mutex();

  Directory get notesDir => Directory(p.join(_root.path, 'notes'));
  File get _stateFile => File(p.join(_root.path, 'sync_state.json'));

  static Future<LocalStore> open() async {
    final support = await getApplicationSupportDirectory();
    final root = Directory(p.join(support.path, 'rmoca'));
    final store = LocalStore._(root);
    await store.notesDir.create(recursive: true);
    return store;
  }

  /// For tests: a store rooted at an arbitrary directory.
  static Future<LocalStore> openAt(Directory root) async {
    final store = LocalStore._(root);
    await store.notesDir.create(recursive: true);
    return store;
  }

  File fileFor(String path) {
    _checkPath(path);
    return File(p.joinAll([notesDir.path, ...path.split('/')]));
  }

  Future<List<Note>> listNotes() async {
    final notes = <Note>[];
    await for (final entity in notesDir.list(recursive: true)) {
      if (entity is! File) continue;
      final rel = _relative(entity.path);
      if (!Note.isNotePath(rel)) continue;
      final stat = await entity.stat();
      final preview = Note.isDrawingPath(rel)
          ? ''
          : await _preview(entity, p.basenameWithoutExtension(entity.path));
      notes.add(Note(path: rel, modified: stat.modified, preview: preview));
    }
    notes.sort((a, b) => b.modified.compareTo(a.modified));
    return notes;
  }

  /// Git blob SHA for every note file, used by the sync engine.
  Future<Map<String, String>> hashes() async {
    final result = <String, String>{};
    await for (final entity in notesDir.list(recursive: true)) {
      if (entity is! File) continue;
      final rel = _relative(entity.path);
      if (!Note.isNotePath(rel)) continue;
      result[rel] = gitBlobSha(await entity.readAsBytes());
    }
    return result;
  }

  Future<bool> exists(String path) => fileFor(path).exists();

  Future<String> readText(String path) => fileFor(path).readAsString();

  Future<Uint8List> readBytes(String path) => fileFor(path).readAsBytes();

  /// Saves user edits; waits for any running sync to finish first.
  Future<void> writeText(String path, String content) =>
      lock.run(() => writeBytesUnlocked(path, utf8.encode(content)));

  Future<void> delete(String path) => lock.run(() => deleteUnlocked(path));

  Future<void> rename(String from, String to) => lock.run(() async {
    final target = fileFor(to);
    if (await target.exists()) {
      throw FileSystemException('A note with this name already exists', to);
    }
    await target.parent.create(recursive: true);
    await fileFor(from).rename(target.path);
    await _pruneEmptyDirs(fileFor(from).parent);
  });

  /// Writes without taking [lock]; only for callers already holding it.
  Future<void> writeBytesUnlocked(String path, List<int> bytes) async {
    final file = fileFor(path);
    await file.parent.create(recursive: true);
    // Write to a temp file and rename so a crash never leaves half a note.
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
  }

  Future<void> deleteUnlocked(String path) async {
    final file = fileFor(path);
    if (await file.exists()) await file.delete();
    await _pruneEmptyDirs(file.parent);
  }

  Future<SyncState?> loadState() async {
    if (!await _stateFile.exists()) return null;
    try {
      final json = jsonDecode(await _stateFile.readAsString());
      return SyncState.fromJson(Map<String, Object?>.from(json as Map));
    } on FormatException {
      return null;
    }
  }

  Future<void> saveState(SyncState state) async {
    final tmp = File('${_stateFile.path}.tmp');
    await tmp.writeAsString(jsonEncode(state.toJson()), flush: true);
    await tmp.rename(_stateFile.path);
  }

  /// Returns a path like `name 2.md` that does not exist yet.
  Future<String> uniquePath(String path) async {
    if (!await exists(path)) return path;
    final dir = p.posix.dirname(path);
    final base = p.posix.basenameWithoutExtension(path);
    final ext = p.posix.extension(path);
    for (var i = 2; ; i++) {
      final candidate = p.posix.join(dir, '$base $i$ext');
      final normalized = candidate.startsWith('./')
          ? candidate.substring(2)
          : candidate;
      if (!await exists(normalized)) return normalized;
    }
  }

  String _relative(String absolute) =>
      p.split(p.relative(absolute, from: notesDir.path)).join('/');

  Future<void> _pruneEmptyDirs(Directory dir) async {
    var current = dir;
    while (p.isWithin(notesDir.path, current.path) &&
        await current.exists() &&
        await current.list().isEmpty) {
      await current.delete();
      current = current.parent;
    }
  }

  static Future<String> _preview(File file, String title) async {
    try {
      final text = await file.readAsString();
      for (final line in const LineSplitter().convert(text)) {
        final trimmed = line
            .replaceFirst(RegExp(r'^[#>\-*+\s]+(\[[ xX]\]\s*)?'), '')
            .trim();
        // A heading that just repeats the file name adds nothing.
        if (trimmed.isNotEmpty && !(line.startsWith('#') && trimmed == title)) {
          return trimmed.length > 120
              ? '${trimmed.substring(0, 120)}…'
              : trimmed;
        }
      }
    } on FileSystemException {
      // Unreadable or not UTF-8; show no preview.
    } on FormatException {
      // Not UTF-8.
    }
    return '';
  }

  static void _checkPath(String path) {
    final parts = path.split('/');
    if (path.isEmpty ||
        path.startsWith('/') ||
        path.contains('\\') ||
        parts.any((s) => s.isEmpty || s == '.' || s == '..')) {
      throw ArgumentError.value(path, 'path', 'Invalid note path');
    }
  }
}
