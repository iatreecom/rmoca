import '../models/note.dart';

class SearchHit {
  SearchHit(this.note, this.snippet, this.score);

  final Note note;

  /// Text around the first match in the body (or the note's preview).
  final String snippet;
  final int score;
}

/// Full-text search: every term must appear in the title, path, body or
/// tags. `#tag` matches tags (and nested tags), `"two words"` a phrase.
/// Results are ranked with title matches first.
List<SearchHit> searchNotes(Iterable<Note> notes, String query) {
  final terms = parseQuery(query);
  if (terms.isEmpty) return const [];
  final hits = <SearchHit>[];
  for (final note in notes) {
    final title = note.title.toLowerCase();
    final path = note.path.toLowerCase();
    final body = note.body.toLowerCase();
    var score = 0;
    var firstAt = -1;
    var firstLen = 0;
    var ok = true;
    for (final t in terms) {
      if (t.startsWith('#') && t.length > 1) {
        final tag = t.substring(1);
        final has = note.links.tags.any(
          (x) => x.toLowerCase() == tag || x.toLowerCase().startsWith('$tag/'),
        );
        if (!has) {
          ok = false;
          break;
        }
        score += 5;
        continue;
      }
      final inTitle = title.contains(t);
      final at = body.indexOf(t);
      if (!inTitle && at < 0 && !path.contains(t)) {
        ok = false;
        break;
      }
      if (inTitle) score += title == t ? 30 : 10;
      if (at >= 0) {
        score += 1 + _count(body, t).clamp(0, 9);
        if (firstAt < 0 || at < firstAt) {
          firstAt = at;
          firstLen = t.length;
        }
      }
    }
    if (!ok) continue;
    hits.add(
      SearchHit(
        note,
        firstAt < 0 ? note.preview : snippetAt(note.body, firstAt, firstLen),
        score,
      ),
    );
  }
  hits.sort((a, b) {
    final s = b.score.compareTo(a.score);
    return s != 0 ? s : b.note.modified.compareTo(a.note.modified);
  });
  return hits;
}

/// Lower-cased terms; quoted phrases stay together.
List<String> parseQuery(String query) => [
  for (final m in RegExp(r'"([^"]+)"|(\S+)').allMatches(query))
    (m[1] ?? m[2]!).toLowerCase(),
];

int _count(String text, String term) {
  var n = 0;
  for (var i = text.indexOf(term); i >= 0; i = text.indexOf(term, i + 1)) {
    n++;
  }
  return n;
}

/// One line of context around [at].
String snippetAt(String text, int at, int length) {
  const before = 40, after = 90;
  final start = (at - before).clamp(0, text.length);
  final end = (at + length + after).clamp(0, text.length);
  final core = text
      .substring(start, end)
      .replaceAll(RegExp(r'[#>*_`=~\[\]|]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return '${start > 0 ? '… ' : ''}$core${end < text.length ? ' …' : ''}';
}
