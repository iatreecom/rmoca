import 'package:path/path.dart' as p;

enum NoteKind { markdown, drawing }

/// A memo stored as a single file: `.md` for text, `.svg` for drawings.
class Note {
  Note({
    required this.path,
    required this.modified,
    this.preview = '',
    this.embeddedSvg,
  });

  /// Path relative to the notes root, always using `/` separators.
  final String path;
  final DateTime modified;

  /// First meaningful line of a markdown note (empty for drawings).
  final String preview;

  /// First drawing embedded in a markdown note, used as its thumbnail.
  final String? embeddedSvg;

  NoteKind get kind =>
      isDrawingPath(path) ? NoteKind.drawing : NoteKind.markdown;

  String get title => p.posix.basenameWithoutExtension(path);

  String get folder => parentOf(path);

  static bool isNotePath(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.md') || lower.endsWith('.svg');
  }

  static bool isDrawingPath(String path) => path.toLowerCase().endsWith('.svg');

  /// Marker file that keeps an otherwise empty folder in git.
  static const folderMarker = '.gitkeep';

  /// Files the sync engine mirrors: notes plus folder markers.
  static bool isSyncedPath(String path) =>
      isNotePath(path) || p.posix.basename(path) == folderMarker;

  /// Parent folder of [path], '' for the root.
  static String parentOf(String path) {
    final dir = p.posix.dirname(path);
    return dir == '.' ? '' : dir;
  }

  /// Joins a folder ('' = root) and a name.
  static String join(String folder, String name) =>
      folder.isEmpty ? name : '$folder/$name';

  /// Whether [path] is [folder] itself or inside it.
  static bool isWithin(String folder, String path) =>
      folder.isEmpty || path == folder || path.startsWith('$folder/');
}
