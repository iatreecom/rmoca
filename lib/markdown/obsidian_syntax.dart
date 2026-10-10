import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:re_highlight/languages/all.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/github.dart';

/// Link scheme for `[[wikilinks]]`; the rest is the encoded target.
const wikiScheme = 'rmoca-wiki:';

/// `[[target]]`, `[[target|alias]]`, `[[target#heading]]`.
class WikiLinkSyntax extends md.InlineSyntax {
  WikiLinkSyntax() : super(r'\[\[([^\[\]\n|]+)(?:\|([^\[\]\n]+))?\]\]');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final target = match[1]!.trim();
    final alias = match[2]?.trim();
    final display = alias ?? target.replaceFirst('#', ' › ');
    parser.addNode(
      md.Element('a', [md.Text(display)])
        ..attributes['href'] = '$wikiScheme${Uri.encodeComponent(target)}',
    );
    return true;
  }
}

/// `#tag` and `#nested/tag` (not headings, not pure numbers).
class TagSyntax extends md.InlineSyntax {
  TagSyntax()
    : super(
        r'#([^\s#\[\]\(\)\{\}<>!,.;:?"\x27`*~=|\\]+)',
        startCharacter: 0x23,
      );

  @override
  bool tryMatch(md.InlineParser parser, [int? startMatchPos]) {
    final pos = startMatchPos ?? parser.pos;
    // A tag starts a word.
    if (pos > 0 && !RegExp(r'\s').hasMatch(parser.source[pos - 1])) {
      return false;
    }
    return super.tryMatch(parser, startMatchPos);
  }

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final tag = match[1]!;
    if (RegExp(r'^[0-9/]+$').hasMatch(tag)) {
      parser.addNode(md.Text(match[0]!));
      return true;
    }
    parser.addNode(md.Element.text('tag', tag));
    return true;
  }
}

/// `$inline math$` (not `$$`).
class InlineMathSyntax extends md.InlineSyntax {
  InlineMathSyntax()
    : super(r'\$(?!\$)([^\$\n]+?)\$(?![\$\d])', startCharacter: 0x24);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.text('math', match[1]!));
    return true;
  }
}

/// `==highlight==`.
md.InlineSyntax highlightSyntax() => md.DelimiterSyntax(
  '=+',
  requiresDelimiterRun: true,
  allowIntraWord: true,
  tags: [md.DelimiterTag('mark', 2)],
);

List<md.InlineSyntax> obsidianInlineSyntaxes() => [
  WikiLinkSyntax(),
  InlineMathSyntax(),
  TagSyntax(),
  highlightSyntax(),
];

final md.ExtensionSet obsidianExtensions = md.ExtensionSet.gitHubFlavored;

class TagBuilder extends MarkdownElementBuilder {
  TagBuilder(this.onTap);

  final void Function(String tag) onTap;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final tag = element.textContent;
    return Text.rich(
      TextSpan(
        text: '#$tag',
        style: (parentStyle ?? const TextStyle()).copyWith(
          color: scheme.primary,
          backgroundColor: scheme.primaryContainer.withValues(alpha: 0.45),
          fontWeight: FontWeight.w500,
        ),
        recognizer: TapGestureRecognizer()..onTap = () => onTap(tag),
      ),
    );
  }
}

class HighlightBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Text.rich(
      TextSpan(
        text: element.textContent,
        style: (parentStyle ?? const TextStyle()).copyWith(
          backgroundColor: dark
              ? const Color(0x66B8860B)
              : const Color(0xFFFFF3A3),
        ),
      ),
    );
  }
}

class InlineMathBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) => Text.rich(
    WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Math.tex(
        element.textContent,
        mathStyle: MathStyle.text,
        // Math defaults to black; follow the theme's text color.
        textStyle: (parentStyle ?? const TextStyle()).copyWith(
          color: parentStyle?.color ?? Theme.of(context).colorScheme.onSurface,
        ),
        onErrorFallback: (e) =>
            Text('\$${element.textContent}\$', style: parentStyle),
      ),
    ),
  );
}

/// Display math block widget.
class MathBlockView extends StatelessWidget {
  const MathBlockView(this.tex, {super.key});

  final String tex;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Center(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Math.tex(
          tex,
          mathStyle: MathStyle.display,
          textStyle: Theme.of(context).textTheme.bodyLarge
              ?.copyWith(color: Theme.of(context).colorScheme.onSurface),
          onErrorFallback: (e) => Text(
            tex,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      ),
    ),
  );
}

/// Fenced code with syntax highlighting.
class CodeBlockBuilder extends MarkdownElementBuilder {
  static final Highlight _highlight = Highlight()
    ..registerLanguages(builtinAllLanguages);

  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final code = element.textContent.replaceFirst(RegExp(r'\n$'), '');
    final codeEl = element.children?.whereType<md.Element>().firstOrNull;
    final language = (codeEl?.attributes['class'] ?? '').replaceFirst(
      'language-',
      '',
    );
    final dark = Theme.of(context).brightness == Brightness.dark;
    final base = TextStyle(
      fontFamily: 'monospace',
      fontFamilyFallback: const ['Menlo', 'Consolas', 'Roboto Mono'],
      fontSize: 13.5,
      height: 1.5,
      color: dark ? const Color(0xFFABB2BF) : const Color(0xFF24292E),
    );
    TextSpan span = TextSpan(text: code, style: base);
    if (language.isNotEmpty && builtinAllLanguages.containsKey(language)) {
      try {
        final result = _highlight.highlight(code: code, language: language);
        final renderer = TextSpanRenderer(
          base,
          dark ? atomOneDarkTheme : githubTheme,
        );
        result.render(renderer);
        span = renderer.span ?? span;
      } catch (_) {
        // Fall back to plain text.
      }
    }
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF282C34) : const Color(0xFFF6F8FA),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Stack(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: SelectableText.rich(span),
          ),
          if (language.isNotEmpty)
            Positioned(
              right: 10,
              top: 6,
              child: Text(
                language,
                style: TextStyle(fontSize: 11, color: scheme.outline),
              ),
            ),
        ],
      ),
    );
  }
}

/// Headings with keys so the outline can scroll to them.
class HeadingBuilder extends MarkdownElementBuilder {
  HeadingBuilder(this.nextKey);

  /// Returns the key for the next heading in document order.
  final GlobalKey? Function() nextKey;

  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) => Padding(
    key: nextKey(),
    padding: const EdgeInsets.only(top: 6),
    child: Text(element.textContent, style: preferredStyle),
  );
}

/// Maps the renderer's checkbox order to source lines.
///
/// The renderer builds a task's checkbox when its list item closes, i.e. in
/// post-order, so nested tasks would otherwise be matched to the wrong line.
List<int>? checkboxLines(String text, List<int> lines) {
  final taskLines = <int>[];
  String? fence;
  final src = text.split('\n');
  for (var i = 0; i < src.length; i++) {
    final f = RegExp(r'^\s{0,3}(`{3,}|~{3,})').firstMatch(src[i]);
    if (fence != null) {
      if (f != null && f[1]!.startsWith(fence)) fence = null;
      continue;
    }
    if (f != null) {
      fence = f[1]!.substring(0, 3);
      continue;
    }
    if (RegExp(r'^\s*(?:[-*+]|\d+[.)])\s+\[[ xX]\]').hasMatch(src[i])) {
      taskLines.add(lines[i]);
    }
  }
  if (taskLines.isEmpty) return const [];

  final doc = md.Document(
    extensionSet: obsidianExtensions,
    inlineSyntaxes: obsidianInlineSyntaxes(),
  );
  final pre = <md.Element>[];
  final post = <md.Element>[];
  void walk(md.Node n) {
    if (n is! md.Element) return;
    final isTask =
        n.tag == 'li' &&
        (n.children?.firstOrNull is md.Element) &&
        (n.children!.first as md.Element).attributes['type'] == 'checkbox';
    if (isTask) pre.add(n);
    for (final c in n.children ?? const <md.Node>[]) {
      walk(c);
    }
    if (isTask) post.add(n);
  }

  for (final n in doc.parseLines(src)) {
    walk(n);
  }
  if (pre.length != taskLines.length) return null; // Unexpected shape.
  return [for (final e in post) taskLines[pre.indexOf(e)]];
}

/// Obsidian callout look: color and icon per type.
({Color color, IconData icon}) calloutStyle(String type) => switch (type) {
  'abstract' ||
  'summary' ||
  'tldr' => (color: const Color(0xFF00B8D4), icon: Icons.content_paste_rounded),
  'info' => (color: const Color(0xFF2979FF), icon: Icons.info_outline_rounded),
  'todo' => (
    color: const Color(0xFF2979FF),
    icon: Icons.check_circle_outline_rounded,
  ),
  'tip' || 'hint' || 'important' => (
    color: const Color(0xFF00BFA5),
    icon: Icons.local_fire_department_outlined,
  ),
  'success' ||
  'check' ||
  'done' => (color: const Color(0xFF00C853), icon: Icons.check_rounded),
  'question' ||
  'help' ||
  'faq' => (color: const Color(0xFFFF9100), icon: Icons.help_outline_rounded),
  'warning' || 'caution' || 'attention' => (
    color: const Color(0xFFFF9100),
    icon: Icons.warning_amber_rounded,
  ),
  'failure' ||
  'fail' ||
  'missing' => (color: const Color(0xFFFF5252), icon: Icons.close_rounded),
  'danger' ||
  'error' => (color: const Color(0xFFFF1744), icon: Icons.bolt_rounded),
  'bug' => (color: const Color(0xFFF50057), icon: Icons.bug_report_outlined),
  'example' => (color: const Color(0xFF7C4DFF), icon: Icons.list_rounded),
  'quote' ||
  'cite' => (color: const Color(0xFF9E9E9E), icon: Icons.format_quote_rounded),
  _ => (color: const Color(0xFF448AFF), icon: Icons.edit_note_rounded),
};
