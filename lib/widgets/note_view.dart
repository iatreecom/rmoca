import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../markdown/note_document.dart';
import '../markdown/obsidian_syntax.dart';
import '../markdown/html_lite.dart';
import '../models/note.dart';
import 'media_view.dart';
import '../theme.dart';

/// What a [NoteView] can ask its screen to do.
class NoteViewActions {
  const NoteViewActions({
    required this.openPath,
    required this.openTag,
    required this.openMissingWiki,
    this.toggleTask,
    this.editDrawing,
  });

  final void Function(String path) openPath;
  final void Function(String tag) openTag;

  /// `[[target]]` that does not exist yet (offer to create it).
  final void Function(String target) openMissingWiki;

  /// Null for read-only views (embeds).
  final void Function(int line)? toggleTask;
  final void Function(String id, String svg)? editDrawing;
}

/// Renders a markdown note with Obsidian extensions.
class NoteView extends StatelessWidget {
  const NoteView({
    super.key,
    required this.source,
    required this.notePath,
    required this.actions,
    this.headingKeys,
    this.depth = 0,
    this.selectable = true,
  });

  final String source;
  final String notePath;
  final NoteViewActions actions;

  /// Source line of a heading -> key, so an outline can scroll to it.
  final Map<int, GlobalKey>? headingKeys;

  /// Text can be selected (reading); off where a tap means "edit".
  final bool selectable;

  /// Embed nesting level; embeds stop after a couple of levels.
  final int depth;

  @override
  Widget build(BuildContext context) {
    final doc = NoteDocument.parse(source);
    final children = <Widget>[
      if (doc.properties.isNotEmpty && depth == 0)
        _PropertiesCard(doc: doc, onTag: actions.openTag),
      for (final block in doc.blocks) _block(context, doc, block),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  Widget _block(BuildContext context, NoteDocument doc, NoteBlock block) =>
      switch (block) {
        TextBlock b => _markdown(context, doc, b),
        SvgBlock b => _EmbeddedSvg(
          svg: b.svg,
          onEdit: b.id == null || actions.editDrawing == null
              ? null
              : () => actions.editDrawing!(b.id!, b.svg),
        ),
        // Callout bodies can hold any block (math, mermaid, drawings…).
        CalloutBlock b => _Callout(
          block: b,
          child: _blocks(
            context,
            NoteDocument.parse(
              b.body.text,
              frontmatter: false,
              lineMap: b.body.lines,
            ),
          ),
        ),
        EmbedBlock b => _embed(context, b.target),
        MathBlock b => MathBlockView(b.tex),
      };

  Widget _blocks(BuildContext context, NoteDocument doc) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [for (final b in doc.blocks) _block(context, doc, b)],
  );

  Widget _markdown(BuildContext context, NoteDocument doc, TextBlock block) {
    if (block.text.trim().isEmpty) return const SizedBox.shrink();
    // Pasted HTML (<img>, <br>, <p align>…) becomes markdown; line count is
    // kept so checkboxes still map to source lines.
    final text = HtmlLite.toMarkdown(block.text);
    final checkLines = actions.toggleTask == null
        ? null
        : checkboxLines(text, block.lines);
    var checkIndex = 0;
    final blockHeadings = doc.headings
        .where((h) => block.lines.contains(h.line))
        .toList();
    var headingIndex = 0;
    GlobalKey? nextHeadingKey() {
      if (headingIndex >= blockHeadings.length) return null;
      final line = blockHeadings[headingIndex++].line;
      return headingKeys?.putIfAbsent(line, GlobalKey.new);
    }

    final headingBuilder = HeadingBuilder(nextHeadingKey);
    return MarkdownBody(
      data: text,
      selectable: selectable,
      extensionSet: obsidianExtensions,
      inlineSyntaxes: obsidianInlineSyntaxes(),
      styleSheet: noteStyleSheet(context),
      builders: {
        'tag': TagBuilder(actions.openTag),
        'mark': HighlightBuilder(),
        'math': InlineMathBuilder(),
        'pre': CodeBlockBuilder(),
        for (final h in ['h1', 'h2', 'h3', 'h4', 'h5', 'h6']) h: headingBuilder,
        'img': _ImageBuilder(notePath: notePath, onOpen: actions.openPath),
      },
      onTapLink: (text, href, title) => _tapLink(context, href),
      checkboxBuilder: (checked) {
        // MarkdownBody can re-run its builders on its own (e.g. when the
        // text scale changes); every run visits all checkboxes in order.
        final line = checkLines == null || checkLines.isEmpty
            ? null
            : checkLines[checkIndex++ % checkLines.length];
        return _TaskBox(
          key: const ValueKey('task-checkbox'),
          checked: checked,
          onTap: line == null ? null : () => actions.toggleTask!(line),
        );
      },
    );
  }

  String get _dir => Note.parentOf(notePath);

  String? _resolveRelative(String target) {
    if (RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:').hasMatch(target)) return null;
    String decoded;
    try {
      decoded = Uri.decodeFull(target.split('#').first);
    } catch (_) {
      decoded = target;
    }
    final joined = p.posix.normalize(
      p.posix.join(_dir.isEmpty ? '.' : _dir, decoded),
    );
    return joined.startsWith('..') ? null : joined;
  }

  void _tapLink(BuildContext context, String? href) {
    if (href == null) return;
    final app = context.read<AppState>();
    if (href.startsWith(wikiScheme)) {
      final target = Uri.decodeComponent(href.substring(wikiScheme.length));
      final path = app.resolveWiki(target, notePath);
      path == null ? actions.openMissingWiki(target) : actions.openPath(path);
      return;
    }
    final local = _resolveRelative(href);
    if (local != null && Note.isNotePath(local)) {
      if (app.notes.any((n) => n.path == local)) actions.openPath(local);
    }
  }

  Widget _embed(BuildContext context, String target) {
    final app = context.read<AppState>();
    // `![[photo.png|300]]`: the part after | is a size for images.
    final (name, size) = splitSize(target);
    final path = app.resolveWiki(name, notePath);
    if (path == null) return _Missing('![[$name]] 를 찾을 수 없습니다');
    if (Note.isDrawingPath(path) || Note.isAttachmentPath(path)) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: MediaView(
          src: p.posix.relative(path, from: _dir.isEmpty ? '.' : _dir),
          notePath: notePath,
          width: size?.width,
          height: size == null || size.height.isNaN ? null : size.height,
          onOpen: actions.openPath,
        ),
      );
    }
    if (depth >= 2 || path == notePath) {
      return _Missing('[[$target]]'); // Avoid embedding loops.
    }
    return _EmbeddedNote(
      path: path,
      onOpen: () => actions.openPath(path),
      builder: (text) => NoteView(
        source: text,
        notePath: path,
        depth: depth + 1,
        actions: NoteViewActions(
          openPath: actions.openPath,
          openTag: actions.openTag,
          openMissingWiki: actions.openMissingWiki,
        ),
      ),
    );
  }
}

/// Typography for rendered notes.
MarkdownStyleSheet noteStyleSheet(BuildContext context) {
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;
  final t = theme.textTheme;
  final body = t.bodyLarge!.copyWith(height: 1.7, fontSize: 16);
  return MarkdownStyleSheet.fromTheme(theme).copyWith(
    p: body,
    listBullet: body,
    h1: t.headlineMedium!.copyWith(fontWeight: FontWeight.w800, height: 1.3),
    h2: t.headlineSmall!.copyWith(fontWeight: FontWeight.w700, height: 1.35),
    h3: t.titleLarge!.copyWith(fontWeight: FontWeight.w700),
    h4: t.titleMedium!.copyWith(fontWeight: FontWeight.w700),
    h1Padding: const EdgeInsets.only(top: 12, bottom: 4),
    h2Padding: const EdgeInsets.only(top: 10, bottom: 2),
    blockSpacing: 12,
    a: body.copyWith(
      color: scheme.primary,
      decoration: TextDecoration.underline,
      decorationColor: scheme.primary.withValues(alpha: 0.4),
    ),
    code: t.bodyMedium!.copyWith(
      fontFamily: monoFont,
      fontFamilyFallback: monoFallback,
      backgroundColor: scheme.surfaceContainerHighest,
      color: scheme.tertiary,
    ),
    blockquote: body.copyWith(color: scheme.onSurfaceVariant),
    blockquotePadding: const EdgeInsets.fromLTRB(16, 6, 12, 6),
    blockquoteDecoration: BoxDecoration(
      border: Border(left: BorderSide(color: scheme.primary, width: 3)),
      color: scheme.surfaceContainerLow,
    ),
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: scheme.outlineVariant)),
    ),
    tableBorder: TableBorder.all(color: scheme.outlineVariant, width: 1),
    tableHead: body.copyWith(fontWeight: FontWeight.w700),
    tableBody: body,
    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    tableHeadAlign: TextAlign.left,
    del: body.copyWith(
      decoration: TextDecoration.lineThrough,
      color: scheme.outline,
    ),
  );
}

class _TaskBox extends StatelessWidget {
  const _TaskBox({super.key, required this.checked, this.onTap});

  final bool checked;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 6, top: 3),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: checked ? scheme.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: checked ? scheme.primary : scheme.outline,
              width: 1.6,
            ),
          ),
          child: checked
              ? Icon(Icons.check_rounded, size: 15, color: scheme.onPrimary)
              : null,
        ),
      ),
    );
  }
}

class _Missing extends StatelessWidget {
  const _Missing(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Text(
      text,
      style: TextStyle(color: Theme.of(context).colorScheme.outline),
    ),
  );
}

class _PropertiesCard extends StatelessWidget {
  const _PropertiesCard({required this.doc, required this.onTag});

  final NoteDocument doc;
  final void Function(String) onTag;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final tags = doc.propertyTags;
    final entries = doc.properties.entries
        .where((e) => e.key != 'tags' && e.key != 'tag')
        .toList();
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.tune_rounded, size: 16, color: scheme.outline),
              const SizedBox(width: 6),
              Text('속성', style: t.labelLarge?.copyWith(color: scheme.outline)),
            ],
          ),
          const SizedBox(height: 8),
          for (final e in entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 110,
                    child: Text(
                      e.key,
                      style: t.bodyMedium?.copyWith(color: scheme.outline),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      e.value is List
                          ? (e.value as List).join(', ')
                          : '${e.value ?? ''}',
                      style: t.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
          if (tags.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final tag in tags)
                    ActionChip(
                      label: Text('#$tag'),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => onTag(tag),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Callout extends StatefulWidget {
  const _Callout({required this.block, required this.child});

  final CalloutBlock block;
  final Widget child;

  @override
  State<_Callout> createState() => _CalloutState();
}

class _CalloutState extends State<_Callout> {
  late bool _open = widget.block.initiallyOpen;

  @override
  Widget build(BuildContext context) {
    final b = widget.block;
    final style = calloutStyle(b.type);
    final hasBody = b.body.text.trim().isNotEmpty;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: style.color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border(left: BorderSide(color: style.color, width: 4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: b.foldable ? () => setState(() => _open = !_open) : null,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Row(
                children: [
                  Icon(style.icon, size: 20, color: style.color),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      b.title,
                      style: TextStyle(
                        color: style.color,
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                  ),
                  if (b.foldable)
                    AnimatedRotation(
                      turns: _open ? 0.25 : 0,
                      duration: const Duration(milliseconds: 150),
                      child: Icon(
                        Icons.chevron_right_rounded,
                        color: style.color,
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (hasBody && _open)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: widget.child,
            ),
        ],
      ),
    );
  }
}

class _EmbeddedSvg extends StatelessWidget {
  const _EmbeddedSvg({required this.svg, this.onEdit});

  final String svg;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onEdit,
          child: Stack(
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 480),
                // heightFactor: shrink to the SVG instead of the max height.
                child: Center(heightFactor: 1, child: SvgView(svg)),
              ),
              if (onEdit != null)
                Positioned(
                  right: 8,
                  top: 8,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.edit_rounded,
                      size: 16,
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmbeddedNote extends StatelessWidget {
  const _EmbeddedNote({
    required this.path,
    required this.onOpen,
    required this.builder,
  });

  final String path;
  final VoidCallback onOpen;
  final Widget Function(String text) builder;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            dense: true,
            leading: Icon(Icons.link_rounded, color: scheme.primary),
            title: Text(
              p.posix.basenameWithoutExtension(path),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            trailing: const Icon(Icons.open_in_new_rounded, size: 18),
            onTap: onOpen,
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(14),
            child: FutureBuilder<String>(
              future: app.store.readText(path),
              builder: (context, snap) => snap.hasData
                  ? builder(snap.data!)
                  : const SizedBox(height: 24),
            ),
          ),
        ],
      ),
    );
  }
}

/// `name|300` or `name|300x200` (Obsidian image sizes) -> name and size.
(String, Size?) splitSize(String s) {
  final bar = s.lastIndexOf('|');
  if (bar < 0) return (s.trim(), null);
  final m = RegExp(r'^\s*(\d+)(?:\s*x\s*(\d+))?\s*$')
      .firstMatch(s.substring(bar + 1));
  if (m == null) return (s.substring(0, bar).trim(), null);
  final w = double.parse(m[1]!);
  final h = m[2] == null ? null : double.parse(m[2]!);
  return (s.substring(0, bar).trim(), Size(w, h ?? double.nan));
}

/// Markdown images (`![alt|300](src)`) of every kind go through MediaView.
class _ImageBuilder extends MarkdownElementBuilder {
  _ImageBuilder({required this.notePath, required this.onOpen});

  final String notePath;
  final void Function(String path) onOpen;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final (alt, size) = splitSize(element.attributes['alt'] ?? '');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: MediaView(
        src: element.attributes['src'] ?? '',
        notePath: notePath,
        alt: alt,
        width: size?.width,
        height: size == null || size.height.isNaN ? null : size.height,
        onOpen: onOpen,
      ),
    );
  }
}
