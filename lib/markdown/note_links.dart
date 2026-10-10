import 'package:path/path.dart' as p;

import '../models/note.dart';
import 'note_document.dart';

/// Tags and outgoing links found in a markdown note.
class NoteLinks {
  NoteLinks({
    required this.tags,
    required this.wikiTargets,
    required this.paths,
    this.remoteMedia = const [],
  });

  static final empty = NoteLinks(tags: {}, wikiTargets: [], paths: []);

  /// http(s) images the note shows; kept offline by the media cache.
  final List<String> remoteMedia;

  static final _remoteImage = RegExp(
    r'''!\[[^\]\n]*\]\(<?(https?://[^)\s>]+)>?|<img\b[^>]*\bsrc\s*=\s*["']?(https?://[^"'\s>]+)''',
    caseSensitive: false,
  );

  final Set<String> tags;

  /// `[[target]]` / `![[target]]` targets without `#heading` or `|alias`.
  final List<String> wikiTargets;

  /// Relative markdown links/images, resolved to note paths.
  final List<String> paths;

  static final _code = RegExp(
    r'(^\s{0,3}(`{3,}|~{3,})[\s\S]*?^\s{0,3}\2)|(`[^`\n]*`)',
    multiLine: true,
  );
  static final _wiki = RegExp(
    r'\[\[([^\[\]\n|#]+)(?:#[^\[\]\n|]*)?(?:\|[^\[\]\n]*)?\]\]',
  );
  static final _tag = RegExp(
    r'(?:^|\s)#([^\s#\[\]\(\)\{\}<>!,.;:?"\x27`*~=|\\]+)',
    multiLine: true,
  );
  static final _mdLink = RegExp(r'\]\((<[^>\n]+>|[^)\s]+)');
  static final _svg = RegExp(r'^<svg[\s\S]*?</svg>', multiLine: true);

  static NoteLinks extract(String notePath, String source) {
    final doc = NoteDocument.parse(source);
    final text = source
        .replaceAll(_svg, '')
        .replaceAll(_code, '')
        .replaceAll(RegExp(r'%%[\s\S]*?%%'), '');
    final tags = <String>{...doc.propertyTags};
    for (final m in _tag.allMatches(text)) {
      final t = m[1]!;
      if (!RegExp(r'^[0-9/]+$').hasMatch(t)) tags.add(t);
    }
    final dir = Note.parentOf(notePath);
    final paths = <String>[];
    for (final m in _mdLink.allMatches(text)) {
      var target = m[1]!;
      if (target.startsWith('<')) {
        target = target.substring(1, target.length - 1);
      }
      if (RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:').hasMatch(target) ||
          target.startsWith('#')) {
        continue;
      }
      try {
        target = Uri.decodeFull(target.split('#').first);
      } catch (_) {}
      final resolved = p.posix.normalize(
        p.posix.join(dir.isEmpty ? '.' : dir, target),
      );
      if (!resolved.startsWith('..')) paths.add(resolved);
    }
    return NoteLinks(
      remoteMedia: [
        for (final m in _remoteImage.allMatches(text)) (m[1] ?? m[2])!,
      ],
      tags: tags,
      wikiTargets: [for (final m in _wiki.allMatches(text)) m[1]!.trim()],
      paths: paths,
    );
  }
}

/// Resolves `[[target]]` like Obsidian: exact path, then relative to the
/// linking note, then by file name anywhere (closest path wins).
String? resolveWikiTarget(
  String target,
  String fromPath,
  Iterable<String> notePaths,
) {
  var t = target.split('#').first.split('|').first.trim();
  if (t.isEmpty) return null;
  if (t.startsWith('/')) t = t.substring(1);
  final candidates = Note.isNotePath(t) ? [t] : ['$t.md', '$t.svg', t];
  final all = notePaths.toSet();
  for (final c in candidates) {
    if (all.contains(c)) return c;
    final rel = p.posix.normalize(Note.join(Note.parentOf(fromPath), c));
    if (all.contains(rel)) return rel;
  }
  for (final c in candidates) {
    final matches = all.where((n) => n == c || n.endsWith('/$c')).toList()
      ..sort((a, b) => a.length.compareTo(b.length));
    if (matches.isNotEmpty) return matches.first;
  }
  return null;
}
