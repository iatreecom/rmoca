import 'package:path/path.dart' as p;

enum NoteKind { markdown, drawing }

/// A memo stored as a single file: `.md` for text, `.svg` for drawings.
class Note {
  Note({required this.path, required this.modified, this.preview = ''});

  /// Path relative to the notes root, always using `/` separators.
  final String path;
  final DateTime modified;

  /// First meaningful line of a markdown note (empty for drawings).
  final String preview;

  NoteKind get kind => isDrawingPath(path) ? NoteKind.drawing : NoteKind.markdown;

  String get title => p.posix.basenameWithoutExtension(path);

  String get folder {
    final dir = p.posix.dirname(path);
    return dir == '.' ? '' : dir;
  }

  static bool isNotePath(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.md') || lower.endsWith('.svg');
  }

  static bool isDrawingPath(String path) => path.toLowerCase().endsWith('.svg');
}
