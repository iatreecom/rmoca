/// Converts the HTML people commonly paste into markdown (GitHub READMEs,
/// web clippings) into markdown the renderer understands, instead of
/// showing raw tags. Code fences and `inline code` are left untouched.
class HtmlLite {
  static final _fence = RegExp(r'^\s{0,3}(`{3,}|~{3,})');
  static final _attr = RegExp(
    r'''([\w-]+)\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))''',
  );

  static String toMarkdown(String text) {
    if (!text.contains('<')) return text;
    final lines = text.split('\n');
    String? fence;
    for (var i = 0; i < lines.length; i++) {
      final f = _fence.firstMatch(lines[i]);
      if (fence != null) {
        if (f != null && f[1]!.startsWith(fence)) fence = null;
        continue;
      }
      if (f != null) {
        fence = f[1]!.substring(0, 3);
        continue;
      }
      if (!lines[i].contains('<')) continue;
      // Leave `inline code` alone: convert only the parts between backticks.
      final parts = lines[i].split('`');
      for (var p = 0; p < parts.length; p += 2) {
        parts[p] = _convert(parts[p]);
      }
      lines[i] = parts.join('`');
    }
    return lines.join('\n');
  }

  static Map<String, String> attributes(String tag) => {
    for (final m in _attr.allMatches(tag))
      m[1]!.toLowerCase(): m[3] ?? m[4] ?? m[5] ?? '',
  };

  static String _convert(String s) {
    // <img src=… alt=… width=…> -> ![alt|width](<src>)
    s = s.replaceAllMapped(
      RegExp(r'''<img\b(?:[^>"']|"[^"]*"|'[^']*')*>''', caseSensitive: false),
      (m) {
        final a = attributes(m[0]!);
        var src = a['src'];
        if (src == null || src.isEmpty) return '';
        // Raw `<svg …>` data URIs: escape what would end the link.
        src = src
            .replaceAll('<', '%3C')
            .replaceAll('>', '%3E')
            .replaceAll(' ', '%20')
            .replaceAll('\n', '');
        final width = a['width']?.replaceAll('px', '');
        final height = a['height']?.replaceAll('px', '');
        var alt = (a['alt'] ?? '').replaceAll(RegExp(r'[\[\]|]'), ' ');
        if (width != null && double.tryParse(width) != null) {
          alt =
              '$alt|$width${height != null && double.tryParse(height) != null ? 'x$height' : ''}';
        }
        return '![$alt](<$src>)';
      },
    );
    // <a href=…>text</a> -> [text](<href>)
    s = s.replaceAllMapped(
      RegExp(r'<a\b([^>]*)>(.*?)</a>', caseSensitive: false),
      (m) {
        final href = attributes(m[1]!)['href'];
        return href == null ? m[2]! : '[${m[2]}](<$href>)';
      },
    );
    // Keep the line count (checkboxes map to source lines): a line break
    // becomes U+2028, which text layout breaks on.
    s = s.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\u2028');
    if (RegExp(r'^\s*<hr\s*/?>\s*$', caseSensitive: false).hasMatch(s)) {
      return '---';
    }
    s = s.replaceAll(RegExp(r'<hr\s*/?>', caseSensitive: false), '');
    const inline = {
      'b': '**',
      'strong': '**',
      'i': '*',
      'em': '*',
      'mark': '==',
      's': '~~',
      'del': '~~',
      'strike': '~~',
      'kbd': '`',
      'code': '`',
    };
    for (final e in inline.entries) {
      s = s.replaceAllMapped(
        RegExp('<${e.key}\\b[^>]*>(.*?)</${e.key}>', caseSensitive: false),
        (m) => '${e.value}${m[1]}${e.value}',
      );
    }
    // <summary> becomes a bold line; wrappers keep only their content.
    s = s.replaceAllMapped(
      RegExp(r'<summary\b[^>]*>(.*?)</summary>', caseSensitive: false),
      (m) => '**${m[1]}**',
    );
    s = s.replaceAll(
      RegExp(
        r'</?(p|div|center|span|details|section|article|figure|figcaption|u|sup|sub|small|big|font|picture|source)\b[^>]*>',
        caseSensitive: false,
      ),
      '',
    );
    return s;
  }
}
