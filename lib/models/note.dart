import 'package:path/path.dart' as p;

import '../markdown/note_links.dart';

enum NoteKind { markdown, drawing }

/// A memo stored as a single file: `.md` for text, `.svg` for drawings.
class Note {
  Note({
    required this.path,
    required this.modified,
    this.preview = '',
    this.embeddedSvg,
    this.body = '',
    NoteLinks? links,
  }) : links = links ?? NoteLinks.empty;

  /// The same note showing [preview] instead (e.g. a search snippet).
  Note withPreview(String preview) => Note(
    path: path,
    modified: modified,
    preview: preview,
    embeddedSvg: embeddedSvg,
    body: body,
    links: links,
  );

  /// Path relative to the notes root, always using `/` separators.
  final String path;
  final DateTime modified;

  /// First meaningful line of a markdown note (empty for drawings).
  final String preview;

  /// First drawing embedded in a markdown note, used as its thumbnail.
  final String? embeddedSvg;

  /// Text of a markdown note without embedded drawings (for search).
  final String body;

  /// Tags and outgoing links (markdown notes only).
  final NoteLinks links;

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

  /// Synced settings (favorites, folder colors).
  static const metaPath = '.rmoca/meta.json';

  /// Deleted notes keep their path under this folder (Obsidian's `.trash`).
  static const trashFolder = '.trash';

  /// Images notes can show (`![](a.png)`, `![[a.png]]`); synced as-is.
  static const attachmentExtensions = {
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.webp',
    '.bmp',
  };

  static bool isAttachmentPath(String path) =>
      attachmentExtensions.contains(p.posix.extension(path).toLowerCase());

  /// Files the sync engine mirrors: notes, attachments, folder markers and
  /// settings.
  static bool isSyncedPath(String path) =>
      isNotePath(path) ||
      isAttachmentPath(path) ||
      p.posix.basename(path) == folderMarker ||
      path == metaPath;

  /// In a dot-folder (`.trash`, `.rmoca`, `.obsidian`…): not shown as notes.
  static bool isHidden(String path) =>
      path.split('/').any((s) => s.startsWith('.') && s != folderMarker);

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
