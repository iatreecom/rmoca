import 'package:yaml/yaml.dart';

/// A note's markdown split into blocks the preview renders differently.
///
/// Text blocks remember which source line each of their lines came from so
/// the preview can edit the source (e.g. tick a task checkbox).
sealed class NoteBlock {
  const NoteBlock();
}

class TextBlock extends NoteBlock {
  TextBlock(this.text, this.lines);

  final String text;

  /// Source line index for each line of [text].
  final List<int> lines;
}

class SvgBlock extends NoteBlock {
  SvgBlock(this.svg, this.id);

  final String svg;

  /// `data-id` of an rmoca drawing; null for SVG from elsewhere.
  final String? id;
}

/// Obsidian callout: `> [!type]± Title` followed by `>` lines.
class CalloutBlock extends NoteBlock {
  CalloutBlock({
    required this.type,
    required this.title,
    required this.foldable,
    required this.initiallyOpen,
    required this.body,
  });

  final String type;
  final String title;
  final bool foldable;
  final bool initiallyOpen;
  final TextBlock body;
}

/// `![[target]]` on its own line: another note, drawing or image.
class EmbedBlock extends NoteBlock {
  EmbedBlock(this.target);

  final String target;
}

/// `$$ ... $$` display math.
class MathBlock extends NoteBlock {
  MathBlock(this.tex);

  final String tex;
}

class Heading {
  Heading(this.level, this.text, this.line);

  final int level;
  final String text;
  final int line;
}

class NoteDocument {
  NoteDocument({
    required this.properties,
    required this.blocks,
    required this.headings,
    required this.bodyStartLine,
  });

  /// YAML frontmatter (Obsidian "properties").
  final Map<String, Object?> properties;
  final List<NoteBlock> blocks;
  final List<Heading> headings;

  /// First source line after the frontmatter.
  final int bodyStartLine;

  /// Tags from the frontmatter `tags:` / `tag:` property.
  List<String> get propertyTags {
    final raw = properties['tags'] ?? properties['tag'];
    final list = raw is List
        ? raw.map((e) => '$e')
        : raw is String
        ? raw.split(RegExp(r'[,\s]+'))
        : const <String>[];
    return list
        .map((t) => t.trim().replaceFirst(RegExp('^#'), ''))
        .where((t) => t.isNotEmpty)
        .toList();
  }

  static final _fence = RegExp(r'^\s{0,3}(`{3,}|~{3,})');
  static final _callout = RegExp(r'^>\s*\[!([\w-]+)\]([+-]?)\s*(.*)$');
  static final _embed = RegExp(r'^!\[\[([^\[\]\n]+)\]\]\s*$');
  static final _heading = RegExp(r'^(#{1,6})\s+(.+?)\s*#*\s*$');
  static final _svgId = RegExp(r'''data-id=["']([^"']+)["']''');

  static NoteDocument parse(String source) {
    final lines = _stripComments(source).split('\n');
    final blocks = <NoteBlock>[];
    final headings = <Heading>[];
    var properties = <String, Object?>{};

    var i = 0;
    // Frontmatter: '---' on the first line up to the next '---'.
    if (lines.isNotEmpty && lines.first.trim() == '---') {
      final end = lines.indexWhere((l) => l.trim() == '---', 1);
      if (end > 0) {
        properties = _parseYaml(lines.sublist(1, end).join('\n'));
        i = end + 1;
      }
    }
    final bodyStart = i;

    final text = <String>[];
    final textLines = <int>[];
    void flush() {
      if (text.isEmpty) return;
      blocks.add(TextBlock(text.join('\n'), List.of(textLines)));
      text.clear();
      textLines.clear();
    }

    String? fence;
    for (; i < lines.length; i++) {
      final line = lines[i];
      final fenceMatch = _fence.firstMatch(line);
      if (fence != null) {
        if (fenceMatch != null && fenceMatch.group(1)!.startsWith(fence)) {
          fence = null;
        }
        text.add(line);
        textLines.add(i);
        continue;
      }
      if (fenceMatch != null) {
        fence = fenceMatch.group(1)!.substring(0, 3);
        text.add(line);
        textLines.add(i);
        continue;
      }

      // Embedded drawing.
      if (line.trimLeft().startsWith('<svg')) {
        final end = _indexFrom(lines, i, (l) => l.contains('</svg>'));
        if (end != null) {
          flush();
          blocks.add(
            SvgBlock(
              lines.sublist(i, end + 1).join('\n'),
              _svgId.firstMatch(line)?.group(1),
            ),
          );
          i = end;
          continue;
        }
      }

      // Callout.
      final callout = _callout.firstMatch(line);
      if (callout != null) {
        flush();
        final body = <String>[];
        final bodyLines = <int>[];
        var j = i + 1;
        while (j < lines.length && lines[j].startsWith('>')) {
          body.add(lines[j].replaceFirst(RegExp(r'^> ?'), ''));
          bodyLines.add(j);
          j++;
        }
        final type = callout.group(1)!.toLowerCase();
        final title = callout.group(3)!.trim();
        blocks.add(
          CalloutBlock(
            type: type,
            title: title.isEmpty ? _titleCase(type) : title,
            foldable: callout.group(2)!.isNotEmpty,
            initiallyOpen: callout.group(2) != '-',
            body: TextBlock(body.join('\n'), bodyLines),
          ),
        );
        i = j - 1;
        continue;
      }

      // Whole-line embed.
      final embed = _embed.firstMatch(line.trim());
      if (embed != null) {
        flush();
        blocks.add(EmbedBlock(embed.group(1)!.trim()));
        continue;
      }

      // Display math.
      final trimmed = line.trim();
      if (trimmed.startsWith(r'$$')) {
        if (trimmed.length > 4 && trimmed.endsWith(r'$$')) {
          flush();
          blocks.add(
            MathBlock(trimmed.substring(2, trimmed.length - 2).trim()),
          );
          continue;
        }
        if (trimmed == r'$$') {
          final end = _indexFrom(lines, i + 1, (l) => l.trim() == r'$$');
          if (end != null) {
            flush();
            blocks.add(MathBlock(lines.sublist(i + 1, end).join('\n').trim()));
            i = end;
            continue;
          }
        }
      }

      final heading = _heading.firstMatch(line);
      if (heading != null) {
        headings.add(Heading(heading.group(1)!.length, heading.group(2)!, i));
      }
      text.add(line);
      textLines.add(i);
    }
    flush();
    return NoteDocument(
      properties: properties,
      blocks: blocks,
      headings: headings,
      bodyStartLine: bodyStart,
    );
  }

  /// Removes Obsidian `%%comments%%`, keeping line breaks so line numbers
  /// still match the source.
  static String _stripComments(String s) => s.contains('%%')
      ? s.replaceAllMapped(
          RegExp(r'%%[\s\S]*?%%'),
          (m) => '\n' * '\n'.allMatches(m.group(0)!).length,
        )
      : s;

  static int? _indexFrom(
    List<String> lines,
    int from,
    bool Function(String) test,
  ) {
    for (var j = from; j < lines.length; j++) {
      if (test(lines[j])) return j;
    }
    return null;
  }

  static Map<String, Object?> _parseYaml(String yaml) {
    try {
      final doc = loadYaml(yaml);
      if (doc is Map) {
        return {for (final e in doc.entries) '${e.key}': _plain(e.value)};
      }
    } catch (_) {
      // Invalid frontmatter is shown as nothing rather than failing.
    }
    return {};
  }

  static Object? _plain(Object? v) => switch (v) {
    YamlList l => l.map(_plain).toList(),
    YamlMap m => {for (final e in m.entries) '${e.key}': _plain(e.value)},
    _ => v,
  };

  static String _titleCase(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  /// Tasks: `- [ ] x`, `* [x] y`, `1. [ ] z`.
  static final task = RegExp(r'^(\s*(?:[-*+]|\d+[.)])\s+\[)([ xX])(\])');

  /// Toggles the task checkbox on [line] of [source].
  static String toggleTask(String source, int line) {
    final lines = source.split('\n');
    if (line < 0 || line >= lines.length) return source;
    lines[line] = lines[line].replaceFirstMapped(
      task,
      (m) => '${m[1]}${m[2] == ' ' ? 'x' : ' '}${m[3]}',
    );
    return lines.join('\n');
  }
}
