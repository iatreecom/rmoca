import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../markdown/edit_helpers.dart';
import '../markdown/embedded_drawings.dart';
import '../markdown/link_rewriter.dart';
import '../markdown/note_document.dart';
import '../markdown/md_table.dart';
import '../models/note.dart';
import '../widgets/block_editor.dart';
import '../widgets/block_menu.dart';
import '../widgets/markdown_help.dart';
import '../widgets/note_view.dart';
import '../widgets/table_editor.dart';
import '../widgets/wiki_suggestions.dart';
import '../widgets/sync_indicator.dart';
import 'drawing_screen.dart';
import 'navigation.dart';
import '../theme.dart';

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

/// Reading, easy (block) editing, or plain markdown editing.
enum _Mode { read, easy, markdown }

class _MarkdownScreenState extends State<MarkdownScreen> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  final Map<int, GlobalKey> _headingKeys = {};
  final Map<int, GlobalKey> _blockHeadingKeys = {};
  final _blockKey = GlobalKey<BlockEditorState>();
  late _Mode _mode;
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
    _mode = widget.startEditing ? _editMode : _Mode.read;
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
      if (content.isEmpty && _mode == _Mode.read) _mode = _editMode;
    });
    if (first && widget.openDrawingId != null) {
      _editEmbedded(widget.openDrawingId!, null);
    } else if (_editing) {
      _focus.requestFocus();
    } else if (first && _easy && widget.startEditing) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _blockKey.currentState?.startAtEnd(),
      );
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
    if (_editing) {
      final continued = continueList(previous, _text.value);
      if (continued != null) {
        _text.value = continued;
        return;
      }
    }
    _dirty = true;
    setState(() {}); // Refresh the preview.
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), _save);
    if (_editing && typedSlashAtLineStart(previous, _text.value)) {
      _slashMenu();
    }
  }

  bool get _editing => _mode == _Mode.markdown;
  bool get _easy => _mode == _Mode.easy;
  _Mode get _editMode => _app.easyEditing ? _Mode.easy : _Mode.markdown;

  Future<void> _save() async {
    if (!_dirty) return;
    _dirty = false;
    await _app.saveText(widget.path, _text.text);
  }

  // --- editing helpers -------------------------------------------------------

  void _wrap(String before, [String after = '']) {
    if (_easy) {
      _blockKey.currentState?.wrap(before, after);
      return;
    }
    _text.value = wrapSelection(_text.value, before, after);
    _focus.requestFocus();
  }

  void _linePrefix(String prefix) {
    if (_easy) {
      _blockKey.currentState?.linePrefix(prefix);
      return;
    }
    _text.value = setLinePrefix(_text.value, prefix);
    _focus.requestFocus();
  }

  /// Inserts [block] on its own lines at the cursor; [caretMark] in it marks
  /// where the cursor goes.
  void _insertBlock(String block) {
    final sel = _text.selection;
    final text = _text.text;
    final pos = sel.isValid ? sel.start : text.length;
    final before = text.substring(0, pos);
    final after = text.substring(pos);
    final lead = before.isEmpty || before.endsWith('\n\n')
        ? ''
        : (before.endsWith('\n') ? '\n' : '\n\n');
    final tail = after.isEmpty
        ? '\n'
        : after.startsWith('\n\n')
        ? ''
        : (after.startsWith('\n') ? '\n' : '\n\n');
    final caret = block.indexOf(caretMark);
    final clean = block.replaceFirst(caretMark, '');
    _text.value = TextEditingValue(
      text: before + lead + clean + tail + after,
      selection: TextSelection.collapsed(
        offset: pos + lead.length + (caret < 0 ? clean.length : caret),
      ),
    );
    if (_editing) _focus.requestFocus();
  }

  /// The `/` menu in the markdown editor.
  Future<void> _slashMenu() async {
    final t = await showBlockMenu(context);
    if (t == null || !mounted) return;
    final v = _text.value;
    final pos = v.selection.start;
    if (pos > 0 && v.text[pos - 1] == '/') {
      _text.value = TextEditingValue(
        text: v.text.substring(0, pos - 1) + v.text.substring(pos),
        selection: TextSelection.collapsed(offset: pos - 1),
      );
    }
    await _applyTemplate(t);
  }

  Future<void> _applyTemplate(BlockTemplate t) async {
    switch (t.action) {
      case BlockAction.image:
      case BlockAction.camera:
        final md = await _pickImage(camera: t.action == BlockAction.camera);
        if (md != null && mounted) _insertBlock(md);
      case BlockAction.drawing:
        await _insertDrawing();
      case BlockAction.table:
        await _insertTable();
      case BlockAction.date:
      case BlockAction.time:
        _text.value = insertSnippet(_text.value, t.resolve(DateTime.now()));
        _focus.requestFocus();
      case BlockAction.text:
        if (t.blockLevel) {
          _insertBlock(t.snippet);
        } else {
          _text.value = insertSnippet(_text.value, t.snippet);
          _focus.requestFocus();
        }
    }
  }

  Future<void> _insertTable() async {
    final table = await showTableEditor(context, MdTable.blank(3, 2));
    if (table == null || table.rows.isEmpty && table.columns == 1 || !mounted) {
      return;
    }
    _insertBlock(table.encode());
  }

  Future<void> _showHelp() async {
    final syntax = await showMarkdownHelp(context, widget.path);
    if (syntax == null || !mounted) return;
    if (_easy) {
      _blockKey.currentState?.insertText(syntax);
    } else {
      _insertBlock(syntax);
    }
  }

  // --- images ----------------------------------------------------------------

  /// Picks a photo (or takes one), stores it in `attachments/` and returns
  /// a markdown image link to it.
  Future<String?> _pickImage({required bool camera}) async {
    XFile? file;
    try {
      file = await ImagePicker().pickImage(
        source: camera ? ImageSource.camera : ImageSource.gallery,
        maxWidth: 2400,
        maxHeight: 2400,
        imageQuality: 85,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              camera ? '이 기기에서는 카메라를 사용할 수 없습니다' : '이미지를 가져올 수 없습니다: $e',
            ),
          ),
        );
      }
      return null;
    }
    if (file == null) return null;
    final bytes = await file.readAsBytes();
    var ext = p.extension(file.name).toLowerCase();
    if (!Note.attachmentExtensions.contains(ext)) ext = '.jpg';
    final stamp = DateFormat('yyyyMMdd-HHmmss').format(DateTime.now());
    final path = await _app.saveAttachment(
      '${camera ? 'photo' : 'image'}-$stamp$ext',
      bytes,
    );
    final rel = p.posix.relative(path, from: _noteDir.isEmpty ? '.' : _noteDir);
    return '![${p.posix.basenameWithoutExtension(path)}](${LinkRewriter.format(rel)})';
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
    _insertBlock('![$name](${LinkRewriter.format(rel)})');
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
      setState(() => _mode = _Mode.read);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final keys = _easy ? _blockHeadingKeys : _headingKeys;
      final ctx = keys[line]?.currentContext;
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
    final query = wikiQueryOf(_text.value);
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
            _Tool(Icons.table_chart_outlined, '표', _insertTable),
            _Tool(Icons.functions_rounded, '수식', () => _wrap(r'$', r'$')),
            _Tool(Icons.image_outlined, '사진', () async {
              final md = await _pickImage(camera: false);
              if (md != null && mounted) _insertBlock(md);
            }),
            _Tool(Icons.draw_rounded, '그림 삽입', _insertDrawing),
            null,
            _Tool(Icons.add_box_outlined, '블록 넣기 (/)', () async {
              final t = await showBlockMenu(context);
              if (t != null && mounted) await _applyTemplate(t);
            }),
            _Tool(Icons.help_outline_rounded, '마크다운 문법', _showHelp),
          ],
        ),
        if (query != null)
          WikiSuggestions(
            query: query,
            notes: _app.notes,
            currentPath: widget.path,
            onPick: (name) {
              _text.value = completeWiki(_text.value, name);
              _focus.requestFocus();
            },
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
              fontFamily: monoFont,
              fontFamilyFallback: monoFallback,
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

  void _setMode(_Mode mode) {
    if (mode == _mode) return;
    _blockKey.currentState?.finish();
    setState(() => _mode = mode);
    if (mode != _Mode.read) _app.setEasyEditing(mode == _Mode.easy);
    if (mode == _Mode.markdown) _focus.requestFocus();
    _save();
  }

  void _toggleMode() => _setMode(_mode == _Mode.read ? _editMode : _Mode.read);

  Widget _blockEditor() => BlockEditor(
    key: _blockKey,
    source: _text.text,
    notePath: widget.path,
    actions: _actions,
    headingKeys: _blockHeadingKeys,
    scrollController: _scroll,
    onChanged: (source) => _text.text = source,
    onPickImage: _pickImage,
    onInsertDrawing: (offset) async {
      _text.selection = TextSelection.collapsed(offset: offset);
      await _insertDrawing();
    },
  );

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
            body = switch (_mode) {
              _Mode.read => _preview(),
              _Mode.easy => _blockEditor(),
              _Mode.markdown => _editor(),
            };
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
                if (_mode != _Mode.read)
                  IconButton(
                    tooltip: '마크다운 문법',
                    icon: const Icon(Icons.help_outline_rounded),
                    onPressed: _showHelp,
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: SegmentedButton<_Mode>(
                    showSelectedIcon: false,
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                    ),
                    segments: const [
                      ButtonSegment(
                        value: _Mode.read,
                        icon: Icon(Icons.chrome_reader_mode_outlined, size: 18),
                        tooltip: '읽기 (Ctrl+E)',
                      ),
                      ButtonSegment(
                        value: _Mode.easy,
                        icon: Icon(Icons.view_agenda_outlined, size: 18),
                        tooltip: '쉬운 편집 (블록)',
                      ),
                      ButtonSegment(
                        value: _Mode.markdown,
                        icon: Icon(Icons.code_rounded, size: 18),
                        tooltip: '마크다운 편집',
                      ),
                    ],
                    selected: {_mode},
                    onSelectionChanged: (s) => _setMode(s.first),
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
