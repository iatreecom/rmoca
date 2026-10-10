import 'dart:math';

/// A piece of a markdown note: either markdown text or an inline `<svg>`.
class MdSegment {
  MdSegment.text(this.text) : svg = null, id = null;
  MdSegment.svg(String this.svg, this.id) : text = null;

  final String? text;
  final String? svg;

  /// `data-id` of an rmoca drawing; null for SVG from elsewhere.
  final String? id;

  bool get isSvg => svg != null;
}

/// Finds drawings embedded in markdown as raw `<svg>…</svg>` blocks.
///
/// A block starts with a line beginning `<svg` and ends with the line that
/// closes it; blocks inside fenced code are left alone so SVG examples in
/// code stay text.
class EmbeddedDrawings {
  static final _fence = RegExp(r'^\s{0,3}(`{3,}|~{3,})');
  static final _id = RegExp(r'''data-id=["']([^"']+)["']''');

  static List<MdSegment> split(String markdown) {
    final lines = markdown.split('\n');
    final segments = <MdSegment>[];
    final text = <String>[];
    String? fence;

    void flushText() {
      if (text.isEmpty) return;
      segments.add(MdSegment.text(text.join('\n')));
      text.clear();
    }

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final fenceMatch = _fence.firstMatch(line);
      if (fence != null) {
        if (fenceMatch != null && fenceMatch.group(1)!.startsWith(fence)) {
          fence = null;
        }
        text.add(line);
        continue;
      }
      if (fenceMatch != null) {
        fence = fenceMatch.group(1)!.substring(0, 3);
        text.add(line);
        continue;
      }
      if (line.trimLeft().startsWith('<svg')) {
        final end = _closingLine(lines, i);
        if (end != null) {
          flushText();
          final svg = lines.sublist(i, end + 1).join('\n');
          segments.add(MdSegment.svg(svg, _id.firstMatch(lines[i])?.group(1)));
          i = end;
          continue;
        }
      }
      text.add(line);
    }
    flushText();
    return segments;
  }

  static int? _closingLine(List<String> lines, int start) {
    for (var j = start; j < lines.length; j++) {
      if (lines[j].contains('</svg>')) return j;
    }
    return null;
  }

  /// Markdown without embedded drawings (for previews and search).
  static String textOnly(String markdown) =>
      split(markdown).where((s) => !s.isSvg).map((s) => s.text).join('\n');

  static String? firstSvg(String markdown) {
    for (final s in split(markdown)) {
      if (s.isSvg) return s.svg;
    }
    return null;
  }

  /// Replaces the drawing with `data-id` [id] by [svg]; appends it if absent.
  static String replace(String markdown, String id, String svg) {
    var found = false;
    final out = split(markdown)
        .map((s) {
          if (s.isSvg && s.id == id) {
            found = true;
            return svg;
          }
          return s.svg ?? s.text!;
        })
        .join('\n');
    if (found) return out;
    final sep = markdown.isEmpty || markdown.endsWith('\n\n')
        ? ''
        : (markdown.endsWith('\n') ? '\n' : '\n\n');
    return '$markdown$sep$svg\n';
  }

  static String newId() {
    final r = Random.secure();
    return List.generate(8, (_) => r.nextInt(36).toRadixString(36)).join();
  }
}
