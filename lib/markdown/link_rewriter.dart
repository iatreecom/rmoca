import 'package:path/path.dart' as p;

import '../models/note.dart';

/// Keeps relative links and images in markdown pointing at the right files
/// after notes or folders move.
class LinkRewriter {
  // [text](target "title") and ![alt](<target with spaces>)
  static final _link = RegExp(
    r'(!?\[[^\]\n]*\]\()(<[^>\n]+>|[^)\s]+)((?:\s+"[^"\n]*")?\))',
  );

  /// Rewrites links in a note that moved from [oldPath] to [newPath] (the
  /// same path if it did not move), given every moved file in [moves]
  /// (old path -> new path). Returns [content] unchanged if nothing changes.
  static String rewrite(
    String content, {
    required String oldPath,
    required String newPath,
    required Map<String, String> moves,
  }) {
    final oldDir = Note.parentOf(oldPath);
    final newDir = Note.parentOf(newPath);
    return content.replaceAllMapped(_link, (m) {
      final raw = m.group(2)!;
      final angled = raw.startsWith('<');
      final encoded = angled ? raw.substring(1, raw.length - 1) : raw;
      if (encoded.startsWith('#') ||
          encoded.startsWith('/') ||
          RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:').hasMatch(encoded)) {
        return m.group(0)!; // Anchors, absolute paths and URLs stay.
      }
      final hash = encoded.indexOf('#');
      final fragment = hash < 0 ? '' : encoded.substring(hash);
      final target = _decode(hash < 0 ? encoded : encoded.substring(0, hash));

      final resolved = p.posix.normalize(p.posix.join(oldDir, target));
      if (resolved.startsWith('..')) return m.group(0)!;
      final moved = _movedPath(resolved, moves);
      if (moved == resolved && oldDir == newDir) return m.group(0)!;

      final rel = p.posix.relative(moved, from: newDir.isEmpty ? '.' : newDir);
      if (rel == target) return m.group(0)!;
      return '${m.group(1)}${format(rel)}$fragment${m.group(3)}';
    });
  }

  /// Formats a relative path for a link, using `<...>` when it contains
  /// characters that would end a plain link target.
  static String format(String rel) =>
      RegExp(r'[\s()<>]').hasMatch(rel) ? '<$rel>' : rel;

  static String _movedPath(String path, Map<String, String> moves) {
    final direct = moves[path];
    if (direct != null) return direct;
    // A link to a folder that moved as a whole.
    for (final e in moves.entries) {
      if (path.startsWith('${e.key}/')) {
        return '${e.value}${path.substring(e.key.length)}';
      }
    }
    return path;
  }

  static String _decode(String s) {
    try {
      return Uri.decodeFull(s);
    } on ArgumentError {
      return s;
    }
  }
}
