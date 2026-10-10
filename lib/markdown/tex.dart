/// Rewrites common LaTeX that the math renderer does not support into
/// equivalents it does (Obsidian/MathJax users write `align`, `\tag`,
/// `\newcommand`… freely).
class TexNormalizer {
  /// Returns the renderable TeX and any `\tag{…}` labels to show beside it.
  static ({String tex, List<String> tags}) normalize(String input) {
    var tex = input.trim();
    final tags = <String>[];

    // Comments (unescaped %) to end of line.
    tex = tex.replaceAll(RegExp(r'(?<!\\)%[^\n]*'), '');

    tex = _expandMacros(tex);

    // Equation numbers and labels.
    tex = tex.replaceAllMapped(RegExp(r'\\tag\*?\{([^{}]*)\}'), (m) {
      tags.add(m[1]!);
      return '';
    });
    tex = tex.replaceAll(RegExp(r'\\label\{[^{}]*\}'), '');
    tex = tex.replaceAll(RegExp(r'\\(nonumber|notag)\b'), '');

    // Environments -> supported ones.
    const toAligned = ['align', 'eqnarray', 'flalign', 'alignat', 'split'];
    const toGathered = ['gather', 'multline'];
    const unwrap = ['equation', 'displaymath', 'math'];
    tex = tex.replaceAllMapped(
      RegExp(r'\\(begin|end)\{(\w+)(\*?)\}(\{\d+\})?'),
      (m) {
        final env = m[2]!;
        final begin = m[1] == 'begin';
        if (toAligned.contains(env)) return '\\${m[1]}{aligned}';
        // Centered lines; the renderer has no `gathered`.
        if (toGathered.contains(env) || env == 'gathered') {
          return '\\${m[1]}{matrix}';
        }
        if (unwrap.contains(env)) return begin ? '{' : '}';
        return m[0]!;
      },
    );

    tex = _mhchem(tex);

    // Rare commands with harmless substitutes.
    tex = tex
        .replaceAll(r'\dfrac', r'\frac')
        .replaceAll(r'\bm{', r'\boldsymbol{')
        .replaceAll(r'\pmb{', r'\boldsymbol{');

    return (tex: tex.trim(), tags: tags);
  }

  /// `\newcommand{\X}[n]{body}`, `\renewcommand`, `\def\X{body}`.
  static String _expandMacros(String tex) {
    final macros = <String, ({int args, String body})>{};
    final def = RegExp(
      r'\\(?:re)?newcommand\*?\s*\{?\\([A-Za-z]+)\}?\s*(?:\[(\d)\])?\s*\{',
    );
    final plainDef = RegExp(r'\\def\s*\\([A-Za-z]+)\s*\{');
    for (final pattern in [def, plainDef]) {
      while (true) {
        final m = pattern.firstMatch(tex);
        if (m == null) break;
        final bodyStart = m.end;
        final bodyEnd = _matchingBrace(tex, bodyStart - 1);
        if (bodyEnd < 0) break;
        final args = pattern == def ? int.tryParse(m[2] ?? '') ?? 0 : 0;
        macros[m[1]!] = (args: args, body: tex.substring(bodyStart, bodyEnd));
        tex = tex.substring(0, m.start) + tex.substring(bodyEnd + 1);
      }
    }
    if (macros.isEmpty) return tex;
    // Expand repeatedly so macros may use other macros (bounded).
    for (var round = 0; round < 8; round++) {
      var changed = false;
      for (final e in macros.entries) {
        final name = RegExp('\\\\${e.key}(?![A-Za-z])');
        while (true) {
          final m = name.firstMatch(tex);
          if (m == null) break;
          var end = m.end;
          var body = e.value.body;
          for (var i = 1; i <= e.value.args; i++) {
            while (end < tex.length && tex[end] == ' ') {
              end++;
            }
            String arg;
            if (end < tex.length && tex[end] == '{') {
              final close = _matchingBrace(tex, end);
              if (close < 0) break;
              arg = tex.substring(end + 1, close);
              end = close + 1;
            } else if (end < tex.length) {
              arg = tex[end];
              end++;
            } else {
              arg = '';
            }
            body = body.replaceAll('#$i', arg);
          }
          tex = '${tex.substring(0, m.start)}{$body}${tex.substring(end)}';
          changed = true;
        }
      }
      if (!changed) break;
    }
    return tex;
  }

  static int _matchingBrace(String s, int open) {
    var depth = 0;
    for (var i = open; i < s.length; i++) {
      if (s[i] == '\\') {
        i++;
        continue;
      }
      if (s[i] == '{') depth++;
      if (s[i] == '}' && --depth == 0) return i;
    }
    return -1;
  }

  /// Minimal mhchem: `\ce{H2SO4 -> 2H+ + SO4^2-}`.
  static String _mhchem(String tex) {
    return tex.replaceAllMapped(RegExp(r'\\ce\{([^{}]*)\}'), (m) {
      var s = m[1]!;
      s = s
          .replaceAll('<=>', r' \rightleftharpoons ')
          .replaceAll('<->', r' \leftrightarrow ')
          .replaceAll('->', r' \rightarrow ')
          .replaceAll('<-', r' \leftarrow ');
      final out = StringBuffer();
      final tokens = RegExp(
        r'(\\[a-z]+)|(\d+)|([A-Z][a-z]?)|(\^[\d]*[+-])|([+-])|(\s+)|(.)',
      );
      String? prev;
      for (final t in tokens.allMatches(s)) {
        if (t[1] != null) {
          out.write(t[1]);
        } else if (t[2] != null) {
          // Digits after an element or ')' are subscripts; else coefficients.
          final sub = prev != null && RegExp(r'[A-Za-z)\]]$').hasMatch(prev);
          out.write(sub ? '_{${t[2]}}' : t[2]);
        } else if (t[3] != null) {
          out.write('\\mathrm{${t[3]}}');
        } else if (t[4] != null) {
          out.write('^{${t[4]!.substring(1)}}');
        } else if (t[5] != null) {
          // A charge right after an element, else a plus sign.
          final charge = prev != null && RegExp(r'[A-Za-z)\]]$').hasMatch(prev);
          out.write(charge ? '^{${t[5]}}' : ' ${t[5]} ');
        } else if (t[6] != null) {
          out.write(r'\ ');
        } else {
          out.write(t[7]);
        }
        prev = t[0];
      }
      return '{$out}';
    });
  }
}
