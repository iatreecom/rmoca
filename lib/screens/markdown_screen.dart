import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../markdown/embedded_drawings.dart';
import '../markdown/link_rewriter.dart';
import '../markdown/note_document.dart';
import '../models/note.dart';
import '../widgets/note_view.dart';
import '../widgets/sync_indicator.dart';
import 'drawing_screen.dart';
import 'navigation.dart';

/// Markdown editor with a rendered preview; saves automatically.
class MarkdownScreen extends StatefulWidget {
  const MarkdownScreen({
    super.key,
    required this.path,
    this.startEditing = false,
    this.openDrawingId,
  });

  final String path;
  final bool startEditing;

  /// Opens the embedded-drawing editor for this `data-id` right away (used
  /// when a drawing is created as a new memo).
  final String? openDrawingId;

  @override
  State<MarkdownScreen> createState() => _MarkdownScreenState();
}

class _MarkdownScreenState extends State<MarkdownScreen> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  final Map<int, GlobalKey> _headingKeys = {};
  late bool _editing = widget.startEditing;
  bool _loading = true;
  bool _dirty = false;
  String _lastText = '';
  Timer? _saveTimer;
  StreamSubscription<Set<String>>? _externalSub;
  late final AppState _app;

  @override
  void initState() {
    super.initState();
    _app = context.read<AppState>();
    _load();
    _text.addListener(_onChanged);
    _externalSub = _app.externalChanges.listen((paths) {
      if (paths.contains(widget.path) && !_dirty) _load();
    });
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _externalSub?.cancel();
    if (_dirty) _save();
    _text.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // --- load / save -----------------------------------------------------------

  Future<void> _load() async {
    final store = _app.store;
    final content = await store.exists(widget.path)
        ? await store.readText(widget.path)
        : '';
    if (!mounted) return;
    _text.removeListener(_onChanged);
    final selection = _text.selection;
    _text.text = content;
    _lastText = content;
    if (selection.isValid && selection.end <= content.length) {
      _text.selection = selection;
    }
    _text.addListener(_onChanged);
    final first = _loading;
    setState(() {
      _loading = false;
      if (content.isEmpty) _editing = true;
    });
    if (first && widget.openDrawingId != null) {
      _editEmbedded(widget.openDrawingId!, null);
    } else if (_editing) {
      _focus.requestFocus();
    }
  }

  void _onChanged() {
    final text = _text.text;
    if (text == _lastText) {
      // Cursor moves still matter for [[ suggestions.
      if (_editing) setState(() {});
      return;
    }
    final previous = _lastText;
    _lastText = text;
    if (_continueList(previous)) return;
    _dirty = true;
    setState(() {}); // Refresh the preview.
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), _save);
  }

  Future<void> _save() async {
    if (!_dirty) return;
    _dirty = false;
    await _app.saveText(widget.path, _text.text);
  }

  // --- editing helpers -------------------------------------------------------

  static final _listItem = RegExp(
    r'^(\s*)([-*+]|(\d+)([.)]))(\s+\[[ xX]\])?\s+(.*)$',
  );

  /// After Enter on a list item, starts the next item (or ends the list
  /// when the item was empty), like Obsidian.
  bool _continueList(String previous) {
    final text = _text.text;
    final sel = _text.selection;
    if (!sel.isCollapsed || text.length != previous.length + 1) return false;
    final pos = sel.start;
    if (pos < 1 || text[pos - 1] != '\n') return false;
    if (text.substring(0, pos - 1) != previous.substring(0, pos - 1)) {
      return false;
    }
    final lineStart = text.lastIndexOf('\n', pos - 2) + 1;
    final line = text.substring(lineStart, pos - 1);
    final m = _listItem.firstMatch(line);
    if (m == null) return false;

    if (m[6]!.trim().isEmpty) {
      // Empty item: remove its bullet instead of adding another.
      _text.value = TextEditingValue(
        text: text.substring(0, lineStart) + text.substring(pos),
        selection: TextSelection.collapsed(offset: lineStart),
      );
      return true;
    }
    final number = m[3] == null ? null : int.parse(m[3]!) + 1;
    final bullet = number == null ? m[2]! : '$number${m[4]}';
    final task = m[5] == null ? '' : ' [ ]';
    final prefix = '${m[1]}$bullet$task ';
    _text.value = TextEditingValue(
      text: text.substring(0, pos) + prefix + text.substring(pos),
      selection: TextSelection.collapsed(offset: pos + prefix.length),
    );
    return true;
  }

  void _wrap(String before, [String after = '']) {
    final sel = _text.selection;
    final text = _text.text;
    if (!sel.isValid) {
      _text.text = '$text$before$after';
      return;
    }
    final selected = sel.textInside(text);
    _text.value = TextEditingValue(
      text:
          sel.textBefore(text) +
          before +
          selected +
          after +
          sel.textAfter(text),
      selection: TextSelection.collapsed(
        offset:
            sel.start +
            before.length +
            selected.length +
            (selected.isEmpty ? 0 : after.length),
      ),
    );
    _focus.requestFocus();
  }

  void _linePrefix(String prefix) {
    final sel = _text.selection;
    final text = _text.text;
    final pos = sel.isValid ? sel.start : text.length;
    final lineStart = text.lastIndexOf('\n', pos == 0 ? 0 : pos - 1) + 1;
    _text.value = TextEditingValue(
      text: text.substring(0, lineStart) + prefix + text.substring(lineStart),
      selection: TextSelection.collapsed(offset: pos + prefix.length),
    );
    _focus.requestFocus();
  }

  void _insertBlock(String block) {
    final sel = _text.selection;
    final text = _text.text;
    final pos = sel.isValid ? sel.start : text.length;
    final before = text.substring(0, pos);
    final lead = before.isEmpty || before.endsWith('\n\n')
        ? ''
        : (before.endsWith('\n') ? '\n' : '\n\n');
    final inserted = '$lead$block\n';
    _text.value = TextEditingValue(
      text: before + inserted + text.substring(pos),
      selection: TextSelection.collapsed(offset: pos + inserted.length),
    );
    _focus.requestFocus();
  }

  /// `[[partial` right before the cursor, if any.
  String? get _wikiQuery {
    final sel = _text.selection;
    if (!_editing || !sel.isValid || !sel.isCollapsed) return null;
    final before = _text.text.substring(0, sel.start);
    return RegExp(r'\[\[([^\[\]\n|#]*)$').firstMatch(before)?[1];
  }

  void _completeWiki(String name) {
    final sel = _text.selection;
    final text = _text.text;
    final query = _wikiQuery ?? '';
    final start = sel.start - query.length;
    final after = text.substring(sel.start);
    final close = after.startsWith(']]') ? '' : ']]';
    _text.value = TextEditingValue(
      text: text.substring(0, start) + name + close + after,
      selection: TextSelection.collapsed(
        offset: start + name.length + (close.isEmpty ? 2 : close.length),
      ),
    );
    _focus.requestFocus();
  }

  // --- drawings --------------------------------------------------------------

  Future<void> _insertDrawing() async {
    final drawings = _app.notes
        .where((n) => n.kind == NoteKind.drawing)
        .toList();
    final choice = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.7,
          ),
          child: ListView(
            shrinkWrap: true,
            children: [
              const _SheetHeader('새 그림'),
              ListTile(
                leading: const Icon(Icons.code_rounded),
                title: const Text('메모 안에 넣기'),
                subtitle: const Text('<svg> 코드를 이 .md 파일에 직접 넣습니다'),
                onTap: () => Navigator.pop(context, ':embedded'),
              ),
              ListTile(
                leading: const Icon(Icons.insert_drive_file_outlined),
                title: const Text('SVG 파일로 저장'),
                subtitle: const Text('별도 .svg 파일을 만들고 링크합니다'),
                onTap: () => Navigator.pop(context, ':file'),
              ),
              if (drawings.isNotEmpty) ...[
                const Divider(),
                const _SheetHeader('기존 SVG 파일 링크'),
                for (final d in drawings)
                  ListTile(
                    leading: const Icon(Icons.draw_outlined),
                    title: Text(d.title),
                    subtitle: d.folder.isEmpty ? null : Text(d.folder),
                    onTap: () => Navigator.pop(context, d.path),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == ':embedded') {
      _app.setDrawingMode(DrawingMode.embedded);
      await _editEmbedded(EmbeddedDrawings.newId(), null);
      return;
    }
    var path = choice;
    if (choice == ':file') {
      _app.setDrawingMode(DrawingMode.file);
      path = await _app.newNotePath(
        '${p.posix.basenameWithoutExtension(widget.path)} 그림',
        'svg',
        folder: _noteDir,
      );
      if (!mounted) return;
      await Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => DrawingScreen(path: path)));
      if (!await _app.store.exists(path)) return;
    }
    final rel = p.posix.relative(path, from: _noteDir.isEmpty ? '.' : _noteDir);
    final name = p.posix.basenameWithoutExtension(path);
    _wrap('![$name](${LinkRewriter.format(rel)})\n');
  }

  /// Opens the editor for the embedded drawing [id]; [svg] is its current
  /// code, or null for a new drawing that is inserted at the cursor once
  /// something is drawn.
  Future<void> _editEmbedded(String id, String? svg) async {
    final insertAt = _text.selection.isValid
        ? _text.selection.start
        : _text.text.length;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DrawingScreen.embedded(
          embedId: id,
          title: p.posix.basenameWithoutExtension(widget.path),
          initialSvg: svg,
          // The final save can come while the editor route is being torn
          // down; apply it once the current frame is done.
          onSave: (newSvg) => Future.microtask(() {
            if (mounted) _putEmbedded(id, newSvg, insertAt);
          }),
        ),
      ),
    );
  }

  void _putEmbedded(String id, String svg, int insertAt) {
    final text = _text.text;
    final exists = EmbeddedDrawings.split(text)
        .any((s) => s.isSvg && s.id == id);
    if (exists) {
      _text.text = EmbeddedDrawings.replace(text, id, svg);
      return;
    }
    // New drawing: put it on its own lines after the cursor's line.
    final lineEnd = text.indexOf('\n', insertAt.clamp(0, text.length));
    final pos = lineEnd < 0 ? text.length : lineEnd;
    final before = text.substring(0, pos);
    final lead = before.isEmpty || before.endsWith('\n\n')
        ? ''
        : (before.endsWith('\n') ? '\n' : '\n\n');
    final block = '$lead$svg\n';
    _text.value = TextEditingValue(
      text: before + block + text.substring(pos),
      selection: TextSelection.collapsed(offset: pos + block.length),
    );
  }

  String get _noteDir => Note.parentOf(widget.path);

  // --- outline ---------------------------------------------------------------

  Future<void> _showOutline() async {
    final headings = NoteDocument.parse(_text.text).headings;
    final line = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: headings.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(32),
                child: Text('제목(#)이 없습니다'),
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  const _SheetHeader('목차'),
                  for (final h in headings)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.only(
                        left: 16.0 + (h.level - 1) * 18,
                        right: 16,
                      ),
                      leading: Text(
                        'H${h.level}',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.outline,
                          fontSize: 12,
                        ),
                      ),
                      title: Text(h.text),
                      onTap: () => Navigator.pop(context, h.line),
                    ),
                ],
              ),
      ),
    );
    if (line == null || !mounted) return;
    if (_editing && MediaQuery.sizeOf(context).width < 900) {
      setState(() => _editing = false);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _headingKeys[line]?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  // --- build -----------------------------------------------------------------

  NoteViewActions get _actions => NoteViewActions(
    openPath: (path) => openNote(context, path),
    openTag: (tag) => openTag(context, tag),
    openMissingWiki: (target) => createFromWiki(context, target, widget.path),
    toggleTask: (line) {
      _text.text = NoteDocument.toggleTask(_text.text, line);
    },
    editDrawing: _editEmbedded,
  );

  Widget _preview() {
    final backlinks = context.watch<AppState>().backlinksTo(widget.path);
    return SingleChildScrollView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 80),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 780),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              NoteView(
                source: _text.text,
                notePath: widget.path,
                actions: _actions,
                headingKeys: _headingKeys,
              ),
              if (backlinks.isNotEmpty) _Backlinks(notes: backlinks),
            ],
          ),
        ),
      ),
    );
  }

  Widget _editor() {
    final scheme = Theme.of(context).colorScheme;
    final query = _wikiQuery;
    final suggestions = query == null
        ? const <Note>[]
        : _app.notes
              .where(
                (n) =>
                    n.path != widget.path &&
                    n.title.toLowerCase().contains(query.toLowerCase()),
              )
              .take(8)
              .toList();
    final words = EmbeddedDrawings.textOnly(_text.text);
    final wordCount = RegExp(r'\S+').allMatches(words).length;
    return Column(
      children: [
        _Toolbar(
          items: [
            _Tool(Icons.title_rounded, '제목', () => _linePrefix('## ')),
            _Tool(Icons.format_bold_rounded, '굵게', () => _wrap('**', '**')),
            _Tool(Icons.format_italic_rounded, '기울임', () => _wrap('*', '*')),
            _Tool(
              Icons.format_strikethrough_rounded,
              '취소선',
              () => _wrap('~~', '~~'),
            ),
            _Tool(Icons.border_color_rounded, '형광펜', () => _wrap('==', '==')),
            null,
            _Tool(
              Icons.format_list_bulleted_rounded,
              '목록',
              () => _linePrefix('- '),
            ),
            _Tool(
              Icons.format_list_numbered_rounded,
              '번호 목록',
              () => _linePrefix('1. '),
            ),
            _Tool(
              Icons.check_box_outlined,
              '체크리스트',
              () => _linePrefix('- [ ] '),
            ),
            _Tool(Icons.format_quote_rounded, '인용', () => _linePrefix('> ')),
            null,
            _Tool(Icons.link_rounded, '메모 링크 [[ ]]', () => _wrap('[[', ']]')),
            _Tool(Icons.tag_rounded, '태그', () => _wrap('#')),
            _Tool(Icons.code_rounded, '코드', () => _wrap('`', '`')),
            _Tool(
              Icons.lightbulb_outline_rounded,
              '콜아웃',
              () => _insertBlock('> [!note] 제목\n> 내용'),
            ),
            _Tool(
              Icons.table_chart_outlined,
              '표',
              () => _insertBlock('| 항목 | 내용 |\n| --- | --- |\n|  |  |'),
            ),
            _Tool(Icons.functions_rounded, '수식', () => _wrap(r'$', r'$')),
            _Tool(Icons.draw_rounded, '그림 삽입', _insertDrawing),
          ],
        ),
        if (suggestions.isNotEmpty || (query?.isNotEmpty ?? false))
          Container(
            height: 48,
            color: scheme.surfaceContainerLow,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              children: [
                for (final n in suggestions)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ActionChip(
                      avatar: Icon(
                        n.kind == NoteKind.drawing
                            ? Icons.draw_outlined
                            : Icons.description_outlined,
                        size: 16,
                      ),
                      label: Text(n.title),
                      onPressed: () => _completeWiki(
                        n.kind == NoteKind.drawing
                            ? p.posix.basename(n.path)
                            : n.title,
                      ),
                    ),
                  ),
                if (query != null &&
                    query.isNotEmpty &&
                    !suggestions.any((n) => n.title == query))
                  ActionChip(
                    avatar: const Icon(Icons.add_rounded, size: 16),
                    label: Text("새 메모 '$query'"),
                    onPressed: () => _completeWiki(query),
                  ),
              ],
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: TextField(
            controller: _text,
            focusNode: _focus,
            maxLines: null,
            expands: true,
            keyboardType: TextInputType.multiline,
            textAlignVertical: TextAlignVertical.top,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontFamilyFallback: ['Menlo', 'Consolas', 'Roboto Mono'],
              fontSize: 15,
              height: 1.6,
            ),
            decoration: const InputDecoration(
              // A plain page, not the app's filled text-field style.
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: EdgeInsets.fromLTRB(24, 20, 24, 20),
              hintText:
                  '# 제목\n\n마크다운으로 메모를 작성하세요…\n[[다른 메모]] 로 연결하고 #태그 를 붙일 수 있습니다',
            ),
          ),
        ),
        Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          alignment: Alignment.centerRight,
          color: scheme.surfaceContainerLow,
          child: Text(
            '단어 $wordCount · 글자 ${words.replaceAll(RegExp(r'\s'), '').length}',
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: scheme.outline),
          ),
        ),
      ],
    );
  }

  void _toggleMode() {
    setState(() => _editing = !_editing);
    if (_editing) _focus.requestFocus();
    _save();
  }

  @override
  Widget build(BuildContext context) {
    final title = p.posix.basenameWithoutExtension(widget.path);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyE, control: true):
            _toggleMode,
        const SingleActivator(LogicalKeyboardKey.keyE, meta: true): _toggleMode,
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
            showQuickSwitcher(context),
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () =>
            showQuickSwitcher(context),
        const SingleActivator(LogicalKeyboardKey.keyB, control: true): () =>
            _wrap('**', '**'),
        const SingleActivator(LogicalKeyboardKey.keyB, meta: true): () =>
            _wrap('**', '**'),
        const SingleActivator(LogicalKeyboardKey.keyI, control: true): () =>
            _wrap('*', '*'),
        const SingleActivator(LogicalKeyboardKey.keyI, meta: true): () =>
            _wrap('*', '*'),
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 900;
          Widget body;
          if (_loading) {
            body = const Center(child: CircularProgressIndicator());
          } else if (wide && _editing) {
            body = Row(
              children: [
                Expanded(child: _editor()),
                const VerticalDivider(width: 1),
                Expanded(child: _preview()),
              ],
            );
          } else {
            body = _editing ? _editor() : _preview();
          }
          return Scaffold(
            appBar: AppBar(
              titleSpacing: 0,
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  if (_noteDir.isNotEmpty)
                    Text(
                      _noteDir,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                ],
              ),
              actions: [
                IconButton(
                  tooltip: '목차',
                  icon: const Icon(Icons.toc_rounded),
                  onPressed: _showOutline,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: SegmentedButton<bool>(
                    showSelectedIcon: false,
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                    ),
                    segments: const [
                      ButtonSegment(
                        value: false,
                        icon: Icon(Icons.chrome_reader_mode_outlined, size: 18),
                        tooltip: '읽기 (Ctrl+E)',
                      ),
                      ButtonSegment(
                        value: true,
                        icon: Icon(Icons.edit_outlined, size: 18),
                        tooltip: '편집 (Ctrl+E)',
                      ),
                    ],
                    selected: {_editing},
                    onSelectionChanged: (s) {
                      if (s.first != _editing) _toggleMode();
                    },
                  ),
                ),
                const SyncIndicator(),
                const SizedBox(width: 4),
              ],
            ),
            body: SafeArea(top: false, child: body),
          );
        },
      ),
    );
  }
}

class _Tool {
  const _Tool(this.icon, this.tooltip, this.onPressed);

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
}

/// Formatting buttons; null entries are separators.
class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.items});

  final List<_Tool?> items;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          for (final item in items)
            if (item == null)
              VerticalDivider(
                indent: 12,
                endIndent: 12,
                width: 12,
                color: scheme.outlineVariant,
              )
            else
              IconButton(
                tooltip: item.tooltip,
                icon: Icon(item.icon, size: 20),
                visualDensity: VisualDensity.compact,
                onPressed: item.onPressed,
              ),
        ],
      ),
    );
  }
}

class _SheetHeader extends StatelessWidget {
  const _SheetHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleMedium
          ?.copyWith(fontWeight: FontWeight.w700),
    ),
  );
}

class _Backlinks extends StatelessWidget {
  const _Backlinks({required this.notes});

  final List<Note> notes;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 32),
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.call_received_rounded,
                    size: 16,
                    color: scheme.outline,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '백링크 ${notes.length}',
                    style: Theme.of(context).textTheme.labelLarge
                        ?.copyWith(color: scheme.outline),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              for (final n in notes)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    Icons.description_outlined,
                    color: scheme.primary,
                  ),
                  title: Text(n.title),
                  subtitle: n.preview.isEmpty
                      ? null
                      : Text(
                          n.preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                  onTap: () => openNote(context, n.path),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
