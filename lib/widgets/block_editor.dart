import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../markdown/blocks.dart';
import '../markdown/edit_helpers.dart';
import '../markdown/md_table.dart';
import '../markdown/note_document.dart';
import 'block_menu.dart';
import 'note_view.dart';
import 'table_editor.dart';
import 'wiki_suggestions.dart';
import '../theme.dart';

/// "Easy editing": the note stays rendered, and tapping a block opens just
/// that block's markdown with formatting buttons. New blocks come from a
/// menu (or typing `/`), tables are edited as a grid.
class BlockEditor extends StatefulWidget {
  const BlockEditor({
    super.key,
    required this.source,
    required this.notePath,
    required this.actions,
    required this.onChanged,
    required this.onInsertDrawing,
    required this.onPickImage,
    this.headingKeys,
    this.scrollController,
  });

  final String source;
  final String notePath;
  final NoteViewActions actions;
  final ValueChanged<String> onChanged;

  /// Starts a new drawing to be placed at [offset] of the source.
  final Future<void> Function(int offset) onInsertDrawing;

  /// Picks or takes a photo, stores it, and returns markdown for it.
  final Future<String?> Function({required bool camera}) onPickImage;
  final Map<int, GlobalKey>? headingKeys;
  final ScrollController? scrollController;

  @override
  State<BlockEditor> createState() => BlockEditorState();
}

class _Session {
  _Session({
    required this.index,
    required this.isNew,
    required this.prefix,
    required this.suffix,
    required this.original,
    this.block,
  });

  /// Position in the block list (for a new block: where it is inserted).
  final int index;
  final bool isNew;
  final String prefix;
  final String suffix;
  final String original;
  final MdBlock? block;

  String sourceFor(String text) {
    if (text.trim().isNotEmpty) return prefix + text + suffix;
    return isNew ? original : replaceBlock(original, block!, '');
  }

  bool get splittable => switch (block?.kind) {
    BlockKind.code ||
    BlockKind.math ||
    BlockKind.mermaid ||
    BlockKind.frontmatter ||
    BlockKind.drawing ||
    BlockKind.table => false,
    _ => true,
  };
}

class BlockEditorState extends State<BlockEditor> {
  late String _source = widget.source;

  /// What the parent currently has (changes while typing).
  late String _current = widget.source;
  late List<MdBlock> _blocks = splitBlocks(_source);
  _Session? _session;
  final _ctl = TextEditingController();
  final _focus = FocusNode();

  /// Keeps the text field's state (and keyboard focus) when the editor
  /// moves to another block.
  final _editorKey = GlobalKey();
  String _prevText = '';
  int? _hover;

  bool get isEditing => _session != null;

  @override
  void initState() {
    super.initState();
    _ctl.addListener(_onText);
  }

  @override
  void didUpdateWidget(BlockEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.source == _current) return;
    // Changed elsewhere (sync, drawing editor, task toggle).
    _session = null;
    _current = _source = widget.source;
    _blocks = splitBlocks(_source);
  }

  @override
  void dispose() {
    _ctl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _emit(String source) {
    if (source == _current) return;
    _current = source;
    widget.onChanged(source);
  }

  // --- sessions --------------------------------------------------------------

  void _start(int index, {bool isNew = false, String? initial}) {
    finish();
    if (!isNew && _blocks[index].kind == BlockKind.table) {
      _editTable(index);
      return;
    }
    final String prefix, suffix, text;
    MdBlock? block;
    if (isNew) {
      (prefix, suffix) = insertionContext(_source, _blocks, index);
      text = initial ?? '';
    } else {
      block = _blocks[index];
      prefix = _source.substring(0, block.start);
      suffix = _source.substring(block.end);
      text = block.text;
    }
    final caret = text.indexOf(caretMark);
    final clean = text.replaceFirst(caretMark, '');
    _session = _Session(
      index: index,
      isNew: isNew,
      prefix: prefix,
      suffix: suffix,
      original: _source,
      block: block,
    );
    _prevText = clean;
    _ctl.value = TextEditingValue(
      text: clean,
      selection: TextSelection.collapsed(
        offset: caret < 0 ? clean.length : caret,
      ),
    );
    if (isNew && clean.isNotEmpty) _emit(_session!.sourceFor(clean));
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  /// Starts typing a new block at the end of the note.
  void startAtEnd() => _start(_blocks.length, isNew: true);

  /// Ends block editing, keeping what was typed.
  void finish() {
    final s = _session;
    if (s == null) return;
    final result = s.sourceFor(_ctl.text);
    _session = null;
    _source = result;
    _blocks = splitBlocks(result);
    _emit(result);
    if (mounted) setState(() {});
  }

  void _onText() {
    final s = _session;
    if (s == null) return;
    final value = _ctl.value;
    if (value.text == _prevText) {
      setState(() {}); // Cursor moved: refresh [[ suggestions.
      return;
    }
    final previous = _prevText;
    _prevText = value.text;

    final continued = continueList(previous, value);
    if (continued != null) {
      _prevText = continued.text;
      _ctl.value = continued;
      _emit(s.sourceFor(continued.text));
      return;
    }
    // Enter on an empty line ends the block and starts a new one.
    final text = value.text;
    if (s.splittable &&
        value.selection.isCollapsed &&
        value.selection.start == text.length &&
        text.endsWith('\n\n') &&
        text.trim().isNotEmpty) {
      final kept = text.trimRight();
      _prevText = kept;
      _ctl.text = kept;
      final end = s.prefix.length + kept.length;
      finish();
      final next = _blocks.where((b) => b.start < end).length;
      _start(next, isNew: true);
      return;
    }
    _emit(s.sourceFor(text));
    setState(() {});
    if (typedSlashAtLineStart(previous, value)) _slashMenu();
  }

  // --- inserting -------------------------------------------------------------

  Future<void> _slashMenu() async {
    final t = await showBlockMenu(context);
    if (!mounted || _session == null) return;
    // Drop the typed '/'.
    final v = _ctl.value;
    final pos = v.selection.start;
    if (pos > 0 && v.text[pos - 1] == '/') {
      _ctl.value = TextEditingValue(
        text: v.text.substring(0, pos - 1) + v.text.substring(pos),
        selection: TextSelection.collapsed(offset: pos - 1),
      );
    }
    if (t != null) await _insertInSession(t);
    _focus.requestFocus();
  }

  /// Opens the block menu and adds the chosen block at [index].
  Future<void> addBlockAt(int index) async {
    finish();
    final t = await showBlockMenu(context);
    if (t == null || !mounted) return;
    final snippet = await _snippetFor(t, offset: _offsetFor(index));
    if (snippet == null || !mounted) return;
    if (snippet.contains(caretMark) || t.action == BlockAction.text) {
      _start(index, isNew: true, initial: snippet);
    } else {
      final (src, _) = insertBlock(_source, _blocks, index, snippet);
      _source = src;
      _blocks = splitBlocks(src);
      _emit(src);
      setState(() {});
    }
  }

  /// Where content inserted before `blocks[index]` goes: right after the
  /// previous block.
  int _offsetFor(int index) =>
      index == 0 || _blocks.isEmpty ? 0 : _blocks[index - 1].end;

  /// Inserts [text] at the cursor of the block being edited, or as a new
  /// block at the end.
  void insertText(String text) {
    if (_session == null) {
      final (src, _) = insertBlock(_source, _blocks, _blocks.length, text);
      _source = src;
      _blocks = splitBlocks(src);
      _emit(src);
      setState(() {});
      return;
    }
    _ctl.value = insertSnippet(_ctl.value, text);
    _focus.requestFocus();
  }

  /// Inserts [t] at the cursor of the block being edited.
  Future<void> _insertInSession(BlockTemplate t) async {
    final s = _session!;
    final snippet = await _snippetFor(
      t,
      offset: s.prefix.length + _ctl.text.trimRight().length,
    );
    if (snippet == null || !mounted || _session != s) return;
    final v = _ctl.value;
    final blank = v.text.trim().isEmpty;
    if (blank) {
      _ctl.value = insertSnippet(TextEditingValue.empty, snippet);
      // A finished block (table, picture, divider): show it rendered.
      if (!snippet.contains(caretMark) && t.blockLevel) finish();
      return;
    }
    var insert = snippet;
    if (t.blockLevel) {
      final pos = v.selection.isValid ? v.selection.start : v.text.length;
      final before = v.text.substring(0, pos);
      final after = v.text.substring(pos);
      final lead = before.isEmpty || before.endsWith('\n\n')
          ? ''
          : before.endsWith('\n')
          ? '\n'
          : '\n\n';
      final tail = after.isEmpty || after.startsWith('\n\n') ? '' : '\n\n';
      insert = '$lead$snippet$tail';
    }
    _ctl.value = insertSnippet(v, insert);
  }

  /// The markdown for [t], running its action (pick a photo, draw…);
  /// null when cancelled or handled elsewhere.
  Future<String?> _snippetFor(BlockTemplate t, {required int offset}) async {
    switch (t.action) {
      case BlockAction.image:
      case BlockAction.camera:
        return widget.onPickImage(camera: t.action == BlockAction.camera);
      case BlockAction.drawing:
        finish();
        await widget.onInsertDrawing(offset.clamp(0, _source.length));
        return null;
      case BlockAction.table:
        final table = await showTableEditor(context, MdTable.blank(3, 2));
        if (table == null || _isDeleted(table)) return null;
        return table.encode();
      case BlockAction.date:
      case BlockAction.time:
        return t.resolve(DateTime.now());
      case BlockAction.text:
        return t.snippet;
    }
  }

  bool _isDeleted(MdTable t) =>
      t.rows.isEmpty && t.header.every((h) => h.trim().isEmpty);

  Future<void> _editTable(int index) async {
    final block = _blocks[index];
    final table = MdTable.parse(block.text);
    if (table == null) {
      // Not a table we understand: edit the text instead.
      _editTableSource(index);
      return;
    }
    final edited = await showTableEditor(context, table);
    if (edited == null || !mounted) return;
    final text = _isDeleted(edited) ? '' : edited.encode();
    final src = replaceBlock(_source, block, text);
    _source = src;
    _blocks = splitBlocks(src);
    _emit(src);
    setState(() {});
  }

  // --- formatting (also used by keyboard shortcuts) --------------------------

  void wrap(String before, [String after = '']) {
    if (_session == null) return;
    _ctl.value = wrapSelection(_ctl.value, before, after);
    _focus.requestFocus();
  }

  void linePrefix(String prefix) {
    if (_session == null) return;
    _ctl.value = setLinePrefix(_ctl.value, prefix);
    _focus.requestFocus();
  }

  // --- block menu ------------------------------------------------------------

  Future<void> _blockActions(int index) async {
    finish();
    if (index >= _blocks.length) return;
    final block = _blocks[index];
    final scheme = Theme.of(context).colorScheme;
    final canMove = block.kind != BlockKind.frontmatter;
    final first = _blocks.first.kind == BlockKind.frontmatter ? 1 : 0;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: Text(block.kind == BlockKind.table ? '표 편집' : '편집'),
                onTap: () => Navigator.pop(context, 'edit'),
              ),
              if (block.kind == BlockKind.table)
                ListTile(
                  leading: const Icon(Icons.code_rounded),
                  title: const Text('마크다운으로 편집'),
                  onTap: () => Navigator.pop(context, 'source'),
                ),
              ListTile(
                leading: const Icon(Icons.vertical_align_top_rounded),
                title: const Text('위에 블록 추가'),
                onTap: () => Navigator.pop(context, 'above'),
              ),
              ListTile(
                leading: const Icon(Icons.vertical_align_bottom_rounded),
                title: const Text('아래에 블록 추가'),
                onTap: () => Navigator.pop(context, 'below'),
              ),
              if (canMove && index > first)
                ListTile(
                  leading: const Icon(Icons.arrow_upward_rounded),
                  title: const Text('위로 이동'),
                  onTap: () => Navigator.pop(context, 'up'),
                ),
              if (canMove && index < _blocks.length - 1)
                ListTile(
                  leading: const Icon(Icons.arrow_downward_rounded),
                  title: const Text('아래로 이동'),
                  onTap: () => Navigator.pop(context, 'down'),
                ),
              ListTile(
                leading: const Icon(Icons.copy_rounded),
                title: const Text('복제'),
                onTap: () => Navigator.pop(context, 'dup'),
              ),
              if (_convertible(block.kind))
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final (label, prefix) in _conversions)
                        ActionChip(
                          label: Text(label),
                          onPressed: () => Navigator.pop(context, 'to:$prefix'),
                        ),
                    ],
                  ),
                ),
              ListTile(
                leading: Icon(
                  Icons.delete_outline_rounded,
                  color: scheme.error,
                ),
                title: Text('삭제', style: TextStyle(color: scheme.error)),
                onTap: () => Navigator.pop(context, 'delete'),
              ),
            ],
          ),
        ),
      ),
    );
    if (choice == null || !mounted) return;
    String? src;
    switch (choice) {
      case 'edit':
        _start(index);
      case 'source':
        _editTableSource(index);
      case 'above':
        await addBlockAt(index);
      case 'below':
        await addBlockAt(index + 1);
      case 'up':
        src = moveBlock(_source, _blocks, index, index - 1);
      case 'down':
        src = moveBlock(_source, _blocks, index, index + 1);
      case 'dup':
        src = insertBlock(_source, _blocks, index + 1, block.text).$1;
      case 'delete':
        src = replaceBlock(_source, block, '');
      default:
        if (choice.startsWith('to:')) {
          src = replaceBlock(
            _source,
            block,
            convertBlock(block.text, choice.substring(3)),
          );
        }
    }
    if (src != null) {
      _source = src;
      _blocks = splitBlocks(src);
      _emit(src);
      setState(() {});
    }
  }

  void _editTableSource(int index) {
    final block = _blocks[index];
    _session = _Session(
      index: index,
      isNew: false,
      prefix: _source.substring(0, block.start),
      suffix: _source.substring(block.end),
      original: _source,
      block: block,
    );
    _prevText = block.text;
    _ctl.text = block.text;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  static const _conversions = [
    ('텍스트', ''),
    ('제목 1', '# '),
    ('제목 2', '## '),
    ('제목 3', '### '),
    ('목록', '- '),
    ('번호', '1. '),
    ('체크리스트', '- [ ] '),
    ('인용', '> '),
  ];

  bool _convertible(BlockKind k) => switch (k) {
    BlockKind.paragraph ||
    BlockKind.heading ||
    BlockKind.list ||
    BlockKind.tasks ||
    BlockKind.quote => true,
    _ => false,
  };

  // --- build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = _session;
    final children = <Widget>[];
    for (var i = 0; i < _blocks.length; i++) {
      if (s != null && s.isNew && s.index == i) children.add(_editor(s));
      if (s != null && !s.isNew && s.index == i) {
        children.add(_editor(s));
      } else {
        children.add(_blockView(i));
      }
    }
    if (s != null && s.isNew && s.index >= _blocks.length) {
      children.add(_editor(s));
    }
    children.add(_addRow(scheme));

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: finish,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): finish,
          const SingleActivator(LogicalKeyboardKey.enter, control: true):
              finish,
          const SingleActivator(LogicalKeyboardKey.enter, meta: true): finish,
        },
        child: ListView(
          controller: widget.scrollController,
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 120),
          children: [
            for (final c in children)
              Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 820),
                  child: c,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _blockView(int i) {
    final b = _blocks[i];
    final scheme = Theme.of(context).colorScheme;
    final hovered = _hover == i;
    final view = NoteView(
      source: b.text,
      notePath: widget.notePath,
      selectable: false,
      actions: NoteViewActions(
        openPath: widget.actions.openPath,
        openTag: widget.actions.openTag,
        openMissingWiki: widget.actions.openMissingWiki,
        editDrawing: widget.actions.editDrawing,
        toggleTask: (line) {
          if (_session != null) {
            finish();
            return;
          }
          final src = NoteDocument.toggleTask(_source, b.firstLine + line);
          _source = src;
          _blocks = splitBlocks(src);
          _emit(src);
          setState(() {});
        },
      ),
    );
    Widget content = MouseRegion(
      onEnter: (_) => setState(() => _hover = i),
      onExit: (_) {
        if (_hover == i) setState(() => _hover = null);
      },
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 32,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 120),
              opacity: hovered ? 1 : 0,
              child: IconButton(
                tooltip: '블록 메뉴',
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                icon: Icon(Icons.drag_indicator_rounded, color: scheme.outline),
                onPressed: () => _blockActions(i),
              ),
            ),
          ),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _start(i),
              onLongPress: () => _blockActions(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: hovered
                      ? scheme.surfaceContainerHighest.withValues(alpha: 0.5)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: view,
              ),
            ),
          ),
        ],
      ),
    );
    if (b.kind == BlockKind.heading && widget.headingKeys != null) {
      content = KeyedSubtree(
        key: widget.headingKeys!.putIfAbsent(b.firstLine, GlobalKey.new),
        child: content,
      );
    }
    return content;
  }

  Widget _addRow(ColorScheme scheme) => Padding(
    padding: const EdgeInsets.fromLTRB(32, 12, 0, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () {
              finish();
              _start(_blocks.length, isNew: true);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              child: Row(
                children: [
                  Icon(Icons.edit_note_rounded, color: scheme.outline),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '여기를 눌러 이어 쓰기',
                      style: TextStyle(color: scheme.outline),
                    ),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: () => addBlockAt(_blocks.length),
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('블록'),
                  ),
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            '블록을 누르면 편집 · 길게 누르면 이동/복제/삭제 · 빈 줄에서 / 를 입력하면 블록 메뉴',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: scheme.outline),
          ),
        ),
      ],
    ),
  );

  Widget _editor(_Session s) {
    final scheme = Theme.of(context).colorScheme;
    final (label, icon) = _kindLabel(s.block?.kind);
    final query = wikiQueryOf(_ctl.value);
    final mono = switch (s.block?.kind) {
      BlockKind.code ||
      BlockKind.math ||
      BlockKind.mermaid ||
      BlockKind.table ||
      BlockKind.frontmatter ||
      BlockKind.drawing => true,
      _ => false,
    };
    return Padding(
      key: _editorKey,
      padding: const EdgeInsets.only(left: 32, top: 4, bottom: 4),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: scheme.primary, width: 1.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 6, 0),
              child: Row(
                children: [
                  Icon(icon, size: 16, color: scheme.primary),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: Theme.of(context).textTheme.labelMedium
                        ?.copyWith(color: scheme.primary),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: finish,
                    icon: const Icon(Icons.check_rounded, size: 18),
                    label: const Text('완료'),
                  ),
                ],
              ),
            ),
            TextField(
              controller: _ctl,
              focusNode: _focus,
              maxLines: null,
              minLines: 1,
              keyboardType: TextInputType.multiline,
              style: TextStyle(
                fontSize: mono ? 14 : 16,
                height: 1.5,
                fontFamily: mono ? monoFont : null,
                fontFamilyFallback: mono ? monoFallback : null,
              ),
              decoration: const InputDecoration(
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.fromLTRB(14, 6, 14, 10),
                hintText: '내용 입력 · 빈 줄에서 / 를 누르면 블록 메뉴',
              ),
            ),
            if (query != null)
              WikiSuggestions(
                query: query,
                notes: context.read<AppState>().notes,
                currentPath: widget.notePath,
                onPick: (name) {
                  _ctl.value = completeWiki(_ctl.value, name);
                  _focus.requestFocus();
                },
              ),
            Divider(height: 1, color: scheme.outlineVariant),
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                children: [
                  // The block menu first: always visible on narrow phones.
                  _btn(Icons.add_box_outlined, '블록 넣기 (/)', () async {
                    final t = await showBlockMenu(context);
                    if (t != null && mounted && _session != null) {
                      await _insertInSession(t);
                      _focus.requestFocus();
                    }
                  }),
                  _sep(scheme),
                  _btn(Icons.format_bold_rounded, '굵게', () => wrap('**', '**')),
                  _btn(
                    Icons.format_italic_rounded,
                    '기울임',
                    () => wrap('*', '*'),
                  ),
                  _btn(
                    Icons.format_strikethrough_rounded,
                    '취소선',
                    () => wrap('~~', '~~'),
                  ),
                  _btn(
                    Icons.border_color_rounded,
                    '형광펜',
                    () => wrap('==', '=='),
                  ),
                  _btn(Icons.code_rounded, '코드', () => wrap('`', '`')),
                  _btn(Icons.functions_rounded, '수식', () => wrap(r'$', r'$')),
                  _btn(Icons.link_rounded, '메모 링크', () => wrap('[[', ']]')),
                  _sep(scheme),
                  _btn(Icons.title_rounded, '제목', () => linePrefix('## ')),
                  _btn(
                    Icons.format_list_bulleted_rounded,
                    '목록',
                    () => linePrefix('- '),
                  ),
                  _btn(
                    Icons.check_box_outlined,
                    '체크리스트',
                    () => linePrefix('- [ ] '),
                  ),
                  _btn(
                    Icons.format_quote_rounded,
                    '인용',
                    () => linePrefix('> '),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _btn(IconData icon, String tip, VoidCallback onPressed) => IconButton(
    tooltip: tip,
    visualDensity: VisualDensity.compact,
    iconSize: 20,
    icon: Icon(icon),
    onPressed: onPressed,
  );

  Widget _sep(ColorScheme scheme) => VerticalDivider(
    indent: 12,
    endIndent: 12,
    width: 12,
    color: scheme.outlineVariant,
  );

  static (String, IconData) _kindLabel(BlockKind? kind) => switch (kind) {
    null => ('새 블록', Icons.add_rounded),
    BlockKind.frontmatter => ('속성', Icons.tune_rounded),
    BlockKind.heading => ('제목', Icons.title_rounded),
    BlockKind.paragraph => ('문단', Icons.notes_rounded),
    BlockKind.list => ('목록', Icons.format_list_bulleted_rounded),
    BlockKind.tasks => ('체크리스트', Icons.check_box_outlined),
    BlockKind.quote => ('인용', Icons.format_quote_rounded),
    BlockKind.callout => ('콜아웃', Icons.lightbulb_outline_rounded),
    BlockKind.code => ('코드', Icons.code_rounded),
    BlockKind.math => ('수식', Icons.functions_rounded),
    BlockKind.mermaid => ('다이어그램', Icons.account_tree_outlined),
    BlockKind.table => ('표', Icons.table_chart_outlined),
    BlockKind.rule => ('구분선', Icons.horizontal_rule_rounded),
    BlockKind.drawing => ('그림 코드', Icons.draw_outlined),
    BlockKind.embed => ('이미지 · 임베드', Icons.image_outlined),
  };
}

/// Turns a block into a heading / list / quote / plain text.
String convertBlock(String text, String prefix) {
  final marker = RegExp(
    r'^\s*(#{1,6}\s+|>\s?|(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?)',
  );
  final lines = [for (final l in text.split('\n')) l.replaceFirst(marker, '')];
  if (prefix.startsWith('#')) return '$prefix${lines.join(' ')}';
  if (prefix == '1. ') {
    return [for (var i = 0; i < lines.length; i++) '${i + 1}. ${lines[i]}']
        .join('\n');
  }
  return [for (final l in lines) '$prefix$l'].join('\n');
}
