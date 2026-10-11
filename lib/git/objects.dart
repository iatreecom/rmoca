import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

enum GitType {
  commit(1),
  tree(2),
  blob(3),
  tag(4);

  const GitType(this.code);

  final int code;

  static GitType byCode(int code) =>
      GitType.values.firstWhere((t) => t.code == code);

  static GitType byName(String name) =>
      GitType.values.firstWhere((t) => t.name == name);
}

class GitObject {
  GitObject(this.type, this.data);

  final GitType type;
  final Uint8List data;

  late final String sha = hashObject(type, data);

  static String hashObject(GitType type, List<int> data) {
    final header = utf8.encode('${type.name} ${data.length}\u0000');
    return sha1.convert([...header, ...data]).toString();
  }
}

/// Git objects kept on disk as loose objects (`objects/ab/cdef…`, zlib),
/// the same layout git uses, so fetches only need what is new.
class ObjectStore {
  ObjectStore(this.dir);

  final Directory dir;
  final Map<String, GitObject> _memory = {};

  File _file(String sha) =>
      File(p.join(dir.path, sha.substring(0, 2), sha.substring(2)));

  bool has(String sha) => _memory.containsKey(sha) || _file(sha).existsSync();

  GitObject? get(String sha) {
    final cached = _memory[sha];
    if (cached != null) return cached;
    final file = _file(sha);
    if (!file.existsSync()) return null;
    final raw = zlib.decode(file.readAsBytesSync());
    final nul = raw.indexOf(0);
    final header = latin1.decode(raw.sublist(0, nul));
    final type = GitType.byName(header.split(' ').first);
    final obj = GitObject(type, Uint8List.fromList(raw.sublist(nul + 1)));
    _remember(sha, obj);
    return obj;
  }

  String put(GitObject obj) {
    final sha = obj.sha;
    final file = _file(sha);
    if (!file.existsSync()) {
      file.parent.createSync(recursive: true);
      final header = utf8.encode('${obj.type.name} ${obj.data.length}\u0000');
      final tmp = File('${file.path}.tmp');
      tmp.writeAsBytesSync(zlib.encode([...header, ...obj.data]), flush: true);
      tmp.renameSync(file.path);
    }
    _remember(sha, obj);
    return sha;
  }

  void _remember(String sha, GitObject obj) {
    // Small cache: trees and commits are read repeatedly during a sync.
    if (_memory.length > 2000) _memory.clear();
    _memory[sha] = obj;
  }
}

class TreeEntry {
  TreeEntry(this.mode, this.name, this.sha);

  final String mode;
  final String name;
  final String sha;

  bool get isTree => mode == '40000' || mode == '040000';
}

List<TreeEntry> parseTree(Uint8List data) {
  final entries = <TreeEntry>[];
  var i = 0;
  while (i < data.length) {
    final space = data.indexOf(0x20, i);
    final nul = data.indexOf(0, space);
    final mode = latin1.decode(data.sublist(i, space));
    final name = utf8.decode(data.sublist(space + 1, nul));
    final sha = _hex(data.sublist(nul + 1, nul + 21));
    entries.add(TreeEntry(mode, name, sha));
    i = nul + 21;
  }
  return entries;
}

/// Serializes entries in git's order (trees compare as `name/`).
Uint8List serializeTree(List<TreeEntry> entries) {
  final sorted = [...entries]
    ..sort((a, b) {
      final ka = utf8.encode(a.isTree ? '${a.name}/' : a.name);
      final kb = utf8.encode(b.isTree ? '${b.name}/' : b.name);
      for (var i = 0; i < ka.length && i < kb.length; i++) {
        if (ka[i] != kb[i]) return ka[i] - kb[i];
      }
      return ka.length - kb.length;
    });
  final out = BytesBuilder(copy: false);
  for (final e in sorted) {
    out
      ..add(utf8.encode('${e.isTree ? '40000' : e.mode} ${e.name}'))
      ..addByte(0)
      ..add(unhex(e.sha));
  }
  return out.takeBytes();
}

class Commit {
  Commit({
    required this.tree,
    required this.parents,
    required this.author,
    required this.message,
  });

  final String tree;
  final List<String> parents;

  /// `Name <email> 1700000000 +0900`
  final String author;
  final String message;

  static Commit parse(Uint8List data) {
    final text = utf8.decode(data, allowMalformed: true);
    final split = text.indexOf('\n\n');
    final header = split < 0 ? text : text.substring(0, split);
    String tree = '';
    final parents = <String>[];
    String author = '';
    for (final line in header.split('\n')) {
      if (line.startsWith('tree ')) tree = line.substring(5).trim();
      if (line.startsWith('parent ')) parents.add(line.substring(7).trim());
      if (line.startsWith('author ')) author = line.substring(7);
    }
    return Commit(
      tree: tree,
      parents: parents,
      author: author,
      message: split < 0 ? '' : text.substring(split + 2),
    );
  }

  Uint8List serialize() => Uint8List.fromList(
    utf8.encode(
      'tree $tree\n'
      '${parents.map((p) => 'parent $p\n').join()}'
      'author $author\n'
      'committer $author\n'
      '\n$message${message.endsWith('\n') ? '' : '\n'}',
    ),
  );

  /// `Name <email> <unix seconds> <+hhmm>` for [now].
  static String signature(String name, String email, DateTime now) {
    final offset = now.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final mins = offset.inMinutes.abs();
    final tz =
        '$sign${(mins ~/ 60).toString().padLeft(2, '0')}${(mins % 60).toString().padLeft(2, '0')}';
    final clean = name.replaceAll(RegExp(r'[<>\n]'), '');
    return '$clean <${email.replaceAll(RegExp(r'[<>\n]'), '')}> '
        '${now.millisecondsSinceEpoch ~/ 1000} $tz';
  }
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List unhex(String hex) => Uint8List.fromList([
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
]);

String hexOf(List<int> bytes) => _hex(bytes);
