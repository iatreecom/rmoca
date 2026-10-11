import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../markdown/embedded_drawings.dart';
import '../markdown/note_links.dart';
import '../models/note.dart';
import '../models/note_meta.dart';
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

  /// Notes outside hidden folders; with [trash], only the ones in `.trash`.
  Future<List<Note>> listNotes({bool trash = false}) async {
    final notes = <Note>[];
    await for (final entity in notesDir.list(recursive: true)) {
      if (entity is! File) continue;
      final rel = _relative(entity.path);
      if (!Note.isNotePath(rel)) continue;
      final inTrash = Note.isWithin(Note.trashFolder, rel);
      if (trash ? !inTrash : Note.isHidden(rel)) continue;
      final stat = await entity.stat();
      if (Note.isDrawingPath(rel)) {
        notes.add(Note(path: rel, modified: stat.modified));
        continue;
      }
      final text = await _readTextOrEmpty(entity);
      notes.add(
        Note(
          path: rel,
          modified: stat.modified,
          preview: _preview(
            EmbeddedDrawings.textOnly(text),
            p.basenameWithoutExtension(entity.path),
          ),
          embeddedSvg: EmbeddedDrawings.firstSvg(text),
          body: EmbeddedDrawings.textOnly(text),
          links: NoteLinks.extract(rel, text),
        ),
      );
    }
    notes.sort((a, b) => b.modified.compareTo(a.modified));
    return notes;
  }

  /// Image attachments outside hidden folders.
  Future<List<String>> listAttachments() async {
    final result = <String>[];
    await for (final entity in notesDir.list(recursive: true)) {
      if (entity is! File) continue;
      final rel = _relative(entity.path);
      if (Note.isAttachmentPath(rel) && !Note.isHidden(rel)) result.add(rel);
    }
    return result..sort();
  }

  /// Where copies of remote images are kept for offline use.
  /// App data outside the notes (caches such as git objects).
  Directory get dataDir => _root;

  Directory get mediaDir => Directory(p.join(_root.path, 'media'));

  /// Every folder under the notes root ('a', 'a/b', ...), sorted.
  Future<List<String>> listFolders() async {
    final folders = <String>[];
    await for (final entity in notesDir.list(recursive: true)) {
      if (entity is! Directory) continue;
      final rel = _relative(entity.path);
      if (!Note.isHidden(rel)) folders.add(rel);
    }
    return folders..sort(_compareNames);
  }

  /// Creates a folder that syncs even while empty (via a `.gitkeep`).
  Future<void> createFolder(String folder) => lock.run(() async {
    final dir = dirFor(folder);
    if (await dir.exists()) {
      throw FileSystemException(
        'A folder with this name already exists',
        folder,
      );
    }
    await writeBytesUnlocked(Note.join(folder, Note.folderMarker), const []);
  });

  /// Deletes a folder and everything in it.
  Future<void> deleteFolder(String folder) => lock.run(() async {
    final dir = dirFor(folder);
    if (await dir.exists()) await dir.delete(recursive: true);
    await _pruneEmptyDirs(dir.parent);
  });

  /// Moves a folder; returns the old -> new path of every synced file in it.
  Future<Map<String, String>> moveFolder(String from, String to) => lock.run(
    () async {
      if (Note.isWithin(from, to)) {
        throw FileSystemException('Cannot move a folder into itself', to);
      }
      final source = dirFor(from);
      final target = dirFor(to);
      if (await target.exists()) {
        throw FileSystemException('A folder with this name already exists', to);
      }
      final moves = <String, String>{};
      await for (final entity in source.list(recursive: true)) {
        if (entity is! File) continue;
        final rel = _relative(entity.path);
        if (Note.isSyncedPath(rel)) {
          moves[rel] = '$to${rel.substring(from.length)}';
        }
      }
      await target.parent.create(recursive: true);
      await source.rename(target.path);
      await _pruneEmptyDirs(source.parent);
      return moves;
    },
  );

  // --- trash -----------------------------------------------------------------

  /// Moves a note or folder into `.trash`, keeping its path so it can be
  /// restored. Returns the path inside the trash.
  Future<String> moveToTrash(String path, {bool folder = false}) =>
      lock.run(() async {
        var target = Note.join(Note.trashFolder, path);
        if (folder) {
          for (var i = 2; await dirFor(target).exists(); i++) {
            target = Note.join(Note.trashFolder, '$path $i');
          }
          final dir = dirFor(path);
          await dirFor(target).parent.create(recursive: true);
          // Mark the deletion time for the 30-day purge.
          await for (final f in dir.list(recursive: true)) {
            if (f is File) await f.setLastModified(DateTime.now());
          }
          await dir.rename(dirFor(target).path);
          await _pruneEmptyDirs(dir.parent);
        } else {
          target = await _uniqueUnlocked(target);
          final file = fileFor(path);
          await fileFor(target).parent.create(recursive: true);
          await file.setLastModified(DateTime.now());
          await file.rename(fileFor(target).path);
          await _pruneEmptyDirs(file.parent);
        }
        return target;
      });

  /// Moves a trashed note back to where it was; returns its new path.
  Future<String> restoreFromTrash(String trashPath) => lock.run(() async {
    final original = trashPath.substring(Note.trashFolder.length + 1);
    final target = await _uniqueUnlocked(original);
    final file = fileFor(trashPath);
    await fileFor(target).parent.create(recursive: true);
    await file.rename(fileFor(target).path);
    await _pruneEmptyDirs(file.parent);
    return target;
  });

  /// Permanently deletes trashed notes older than [maxAge].
  Future<int> purgeTrash(Duration maxAge) => lock.run(() async {
    final dir = dirFor(Note.trashFolder);
    if (!await dir.exists()) return 0;
    var count = 0;
    final cutoff = DateTime.now().subtract(maxAge);
    await for (final f in dir.list(recursive: true)) {
      if (f is File && (await f.lastModified()).isBefore(cutoff)) {
        await f.delete();
        await _pruneEmptyDirs(f.parent);
        count++;
      }
    }
    return count;
  });

  Future<String> _uniqueUnlocked(String path) async {
    if (!await fileFor(path).exists()) return path;
    final dir = Note.parentOf(path);
    final base = p.posix.basenameWithoutExtension(path);
    final ext = p.posix.extension(path);
    for (var i = 2; ; i++) {
      final candidate = Note.join(dir, '$base $i$ext');
      if (!await fileFor(candidate).exists()) return candidate;
    }
  }

  // --- synced settings -------------------------------------------------------

  Future<NoteMeta> readMeta() async {
    final file = fileFor(Note.metaPath);
    return await file.exists()
        ? NoteMeta.decode(await file.readAsBytes())
        : NoteMeta();
  }

  Future<void> writeMeta(NoteMeta meta) =>
      lock.run(() => writeBytesUnlocked(Note.metaPath, meta.encode()));

  Directory dirFor(String folder) {
    _checkPath(folder);
    return Directory(p.joinAll([notesDir.path, ...folder.split('/')]));
  }

  static int _compareNames(String a, String b) =>
      a.toLowerCase().compareTo(b.toLowerCase());

  /// Git blob SHA for every note file, used by the sync engine.
  Future<Map<String, String>> hashes() async {
    final result = <String, String>{};
    await for (final entity in notesDir.list(recursive: true)) {
      if (entity is! File) continue;
      final rel = _relative(entity.path);
      if (!Note.isSyncedPath(rel)) continue;
      result[rel] = gitBlobSha(await entity.readAsBytes());
    }
    return result;
  }

  Future<bool> exists(String path) => fileFor(path).exists();

  Future<String> readText(String path) => fileFor(path).readAsString();

  Future<Uint8List> readBytes(String path) => fileFor(path).readAsBytes();

  /// Saves user edits; waits for any running sync to finish first.
  /// [keepVersion] always keeps the old text in the history (otherwise at
  /// most every few minutes while typing).
  Future<void> writeText(
    String path,
    String content, {
    bool keepVersion = false,
  }) => lock.run(
    () => writeBytesUnlocked(
      path,
      utf8.encode(content),
      keepVersion: keepVersion,
    ),
  );

  Future<void> delete(String path) => lock.run(() => deleteUnlocked(path));

  Future<void> rename(String from, String to) => lock.run(() async {
    final target = fileFor(to);
    if (await target.exists()) {
      throw FileSystemException('A note with this name already exists', to);
    }
    await target.parent.create(recursive: true);
    await fileFor(from).rename(target.path);
    await _pruneEmptyDirs(fileFor(from).parent);
    await _moveHistory(from, to);
  });

  Future<void> writeBytes(String path, List<int> bytes) =>
      lock.run(() => writeBytesUnlocked(path, bytes));

  /// Writes without taking [lock]; only for callers already holding it.
  /// The previous text of a markdown note is kept as a version (always
  /// when [keepVersion], e.g. when a sync replaces it).
  Future<void> writeBytesUnlocked(
    String path,
    List<int> bytes, {
    bool keepVersion = false,
  }) async {
    await _keepVersion(path, bytes, force: keepVersion);
    final file = fileFor(path);
    await file.parent.create(recursive: true);
    // Write to a temp file and rename so a crash never leaves half a note.
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
  }

  // --- version history -------------------------------------------------------

  /// Local snapshots of earlier versions of each note (not synced).
  Directory get historyDir => Directory(p.join(_root.path, 'history'));

  static const maxVersions = 50;
  static const versionInterval = Duration(minutes: 5);

  Directory _historyFor(String path) => Directory(
    p.join(
      historyDir.path,
      sha1.convert(utf8.encode(path)).toString().substring(0, 24),
    ),
  );

  /// Earlier versions of [path], newest first.
  Future<List<NoteVersion>> versions(String path) async {
    final dir = _historyFor(path);
    if (!await dir.exists()) return const [];
    final result = <NoteVersion>[];
    await for (final f in dir.list()) {
      if (f is! File || !f.path.endsWith('.md')) continue;
      final ms = int.tryParse(p.basenameWithoutExtension(f.path));
      if (ms == null) continue;
      result.add(NoteVersion(DateTime.fromMillisecondsSinceEpoch(ms), f));
    }
    return result..sort((a, b) => b.time.compareTo(a.time));
  }

  Future<void> _keepVersion(
    String path,
    List<int> next, {
    required bool force,
  }) async {
    if (!path.toLowerCase().endsWith('.md') || Note.isHidden(path)) return;
    final file = fileFor(path);
    if (!await file.exists()) return;
    final current = await file.readAsBytes();
    if (current.isEmpty || _same(current, next)) return;
    final existing = await versions(path);
    final now = DateTime.now();
    if (existing.isNotEmpty) {
      if (!force && now.difference(existing.first.time) < versionInterval) {
        return;
      }
      if (_same(await existing.first.file.readAsBytes(), current)) return;
    }
    final dir = _historyFor(path);
    await dir.create(recursive: true);
    await File(p.join(dir.path, '${now.millisecondsSinceEpoch}.md'))
        .writeAsBytes(current, flush: true);
    for (final old in existing.skip(maxVersions - 1)) {
      await old.file.delete();
    }
  }

  /// Keeps a note's history when it is renamed.
  Future<void> _moveHistory(String from, String to) async {
    final src = _historyFor(from);
    if (!await src.exists()) return;
    final dst = _historyFor(to);
    if (await dst.exists()) await dst.delete(recursive: true);
    await dst.parent.create(recursive: true);
    await src.rename(dst.path);
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
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

  static Future<String> _readTextOrEmpty(File file) async {
    try {
      return await file.readAsString();
    } on FileSystemException {
      return ''; // Unreadable or not UTF-8; show no preview.
    }
  }

  /// A few lines of plain text for list cards: markdown syntax removed,
  /// code and table rules skipped, a heading repeating the name dropped.
  static String _preview(String text, String title) {
    // Skip YAML frontmatter.
    text = text.replaceFirst(RegExp(r'^---\n[\s\S]*?\n---\n?'), '');
    final parts = <String>[];
    var length = 0;
    var inFence = false;
    for (final line in const LineSplitter().convert(text)) {
      if (RegExp(r'^\s*(```|~~~)').hasMatch(line)) {
        inFence = !inFence;
        continue;
      }
      if (inFence || RegExp(r'^\s*\|?\s*:?-{2,}').hasMatch(line)) continue;
      final plain = plainText(line);
      if (plain.replaceAll(RegExp(r'[·\s]'), '').isEmpty) continue;
      // A heading that just repeats the file name adds nothing.
      if (line.startsWith('#') && plain == title) continue;
      parts.add(plain);
      length += plain.length;
      if (length > 160 || parts.length >= 4) break;
    }
    final joined = parts.join('\n');
    return joined.length > 200 ? '${joined.substring(0, 200)}…' : joined;
  }

  /// One markdown line as plain text.
  static String plainText(String line) => line
      .replaceFirst(RegExp(r'^\s*(#{1,6}\s+|>\s*(\[![^\]]*\][+-]?\s*)?)'), '')
      .replaceFirst(RegExp(r'^\s*([-*+]|\d+[.)])\s+(\[[ xX]\]\s*)?'), '')
      .replaceAll(RegExp(r'!\[\[[^\]]*\]\]|!\[[^\]]*\]\([^)]*\)'), '')
      .replaceAllMapped(
        RegExp(r'\[\[([^\]|#]+)(?:#[^\]|]*)?(?:\|([^\]]+))?\]\]'),
        (m) => m[2] ?? m[1]!,
      )
      .replaceAllMapped(RegExp(r'\[([^\]]*)\]\([^)]*\)'), (m) => m[1]!)
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll(RegExp(r'(\*\*|__|~~|==|`)'), '')
      .replaceAllMapped(
        RegExp(r'(?<![\w*])[*_]([^*_\s][^*_]*?)[*_](?![\w*])'),
        (m) => m[1]!,
      )
      .replaceAll(RegExp(r'%%.*?%%'), '')
      .replaceAll(RegExp(r'\s*\|\s*'), ' · ')
      .replaceAll(RegExp(r'^ · | · $'), '')
      .trim();

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

/// An earlier version of a note, kept on this device.
class NoteVersion {
  NoteVersion(this.time, this.file);

  final DateTime time;
  final File file;

  Future<String> read() => file.readAsString();
}
