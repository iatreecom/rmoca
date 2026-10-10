import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/note.dart';
import '../widgets/sync_indicator.dart';
import 'drawing_screen.dart';

/// Markdown editor with live preview; saves automatically.
class MarkdownScreen extends StatefulWidget {
  const MarkdownScreen({super.key, required this.path, this.startEditing = false});

  final String path;
  final bool startEditing;

  @override
  State<MarkdownScreen> createState() => _MarkdownScreenState();
}

class _MarkdownScreenState extends State<MarkdownScreen> {
  final _text = TextEditingController();
  final _focus = FocusNode();
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
    super.dispose();
  }

  Future<void> _load() async {
    final store = _app.store;
    final content =
        await store.exists(widget.path) ? await store.readText(widget.path) : '';
    if (!mounted) return;
    _text.removeListener(_onChanged);
    final selection = _text.selection;
    _text.text = content;
    _lastText = content;
    if (selection.isValid && selection.end <= content.length) _text.selection = selection;
    _text.addListener(_onChanged);
    setState(() {
      _loading = false;
      if (content.isEmpty) _editing = true;
    });
    if (_editing) _focus.requestFocus();
  }

  void _onChanged() {
    // The listener also fires for cursor moves; only real edits count.
    if (_text.text == _lastText) return;
    _lastText = _text.text;
    _dirty = true;
    setState(() {}); // Refresh the live preview.
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), _save);
  }

  Future<void> _save() async {
    if (!_dirty) return;
    _dirty = false;
    await _app.saveText(widget.path, _text.text);
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
      text: sel.textBefore(text) + before + selected + after + sel.textAfter(text),
      selection: TextSelection.collapsed(
          offset: sel.start + before.length + selected.length + (selected.isEmpty ? 0 : after.length)),
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

  Future<void> _insertDrawing() async {
    final drawings = _app.notes.where((n) => n.kind == NoteKind.drawing).toList();
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('새 그림 그리기'),
            onTap: () => Navigator.pop(context, ''),
          ),
          for (final d in drawings)
            ListTile(
              leading: const Icon(Icons.brush_outlined),
              title: Text(d.title),
              subtitle: d.folder.isEmpty ? null : Text(d.folder),
              onTap: () => Navigator.pop(context, d.path),
            ),
        ]),
      ),
    );
    if (choice == null || !mounted) return;
    var path = choice;
    if (path.isEmpty) {
      path = await _app.newNotePath('${p.posix.basenameWithoutExtension(widget.path)} 그림', 'svg');
      if (!mounted) return;
      await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => DrawingScreen(path: path)));
      if (!await _app.store.exists(path)) return;
    }
    final rel = p.posix.relative(path, from: _noteDir);
    _wrap('![${p.posix.basenameWithoutExtension(path)}](${Uri.encodeFull(rel)})\n');
  }

  String get _noteDir {
    final d = p.posix.dirname(widget.path);
    return d == '.' ? '' : d;
  }

  /// Resolves a link inside the note to a note path, if it points to one.
  String? _resolveLocal(Uri uri) {
    if (uri.hasScheme) return null;
    final joined = p.posix.normalize(p.posix.join(_noteDir.isEmpty ? '.' : _noteDir, Uri.decodeFull(uri.path)));
    if (joined.startsWith('..')) return null;
    return joined;
  }

  Widget _image(Uri uri, String? title, String? alt) {
    final local = _resolveLocal(uri);
    if (local != null) {
      final file = _app.store.fileFor(local);
      if (!file.existsSync()) return Text('[그림 없음: ${alt ?? local}]');
      final child = local.toLowerCase().endsWith('.svg')
          ? SvgPicture.file(file, fit: BoxFit.contain)
          : Image.file(file);
      return GestureDetector(
        onTap: local.toLowerCase().endsWith('.svg')
            ? () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => DrawingScreen(path: local)))
            : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 480),
          child: child,
        ),
      );
    }
    return Image.network(uri.toString(),
        errorBuilder: (_, _, _) => Text('[이미지: ${alt ?? uri}]'));
  }

  void _openLink(String text, String? href, String title) {
    if (href == null) return;
    final local = _resolveLocal(Uri.parse(href));
    if (local == null || !Note.isNotePath(local)) return;
    if (!File(_app.store.fileFor(local).path).existsSync()) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Note.isDrawingPath(local)
          ? DrawingScreen(path: local)
          : MarkdownScreen(path: local),
    ));
  }

  Widget _preview() => Markdown(
        data: _text.text,
        selectable: true,
        padding: const EdgeInsets.all(20),
        imageBuilder: _image,
        onTapLink: _openLink,
      );

  Widget _editor() => Column(children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            IconButton(tooltip: '제목', icon: const Icon(Icons.title), onPressed: () => _linePrefix('## ')),
            IconButton(tooltip: '굵게', icon: const Icon(Icons.format_bold), onPressed: () => _wrap('**', '**')),
            IconButton(tooltip: '기울임', icon: const Icon(Icons.format_italic), onPressed: () => _wrap('_', '_')),
            IconButton(tooltip: '목록', icon: const Icon(Icons.format_list_bulleted), onPressed: () => _linePrefix('- ')),
            IconButton(tooltip: '체크리스트', icon: const Icon(Icons.check_box_outlined), onPressed: () => _linePrefix('- [ ] ')),
            IconButton(tooltip: '코드', icon: const Icon(Icons.code), onPressed: () => _wrap('`', '`')),
            IconButton(tooltip: '그림 삽입', icon: const Icon(Icons.brush_outlined), onPressed: _insertDrawing),
          ]),
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
            style: const TextStyle(fontFamily: 'monospace', fontFamilyFallback: ['Menlo', 'Consolas', 'Roboto Mono'], height: 1.5),
            decoration: const InputDecoration(
              border: InputBorder.none,
              contentPadding: EdgeInsets.all(20),
              hintText: '# 제목\n\n마크다운으로 메모를 작성하세요…',
            ),
          ),
        ),
      ]);

  @override
  Widget build(BuildContext context) {
    final title = p.posix.basenameWithoutExtension(widget.path);
    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= 900;
      Widget body;
      if (_loading) {
        body = const Center(child: CircularProgressIndicator());
      } else if (wide && _editing) {
        body = Row(children: [
          Expanded(child: _editor()),
          const VerticalDivider(width: 1),
          Expanded(child: _preview()),
        ]);
      } else {
        body = _editing ? _editor() : _preview();
      }
      return Scaffold(
        appBar: AppBar(
          title: Text(title),
          actions: [
            IconButton(
              tooltip: _editing ? '읽기' : '편집',
              icon: Icon(_editing ? Icons.visibility_outlined : Icons.edit_outlined),
              onPressed: () {
                setState(() => _editing = !_editing);
                if (_editing) _focus.requestFocus();
                _save();
              },
            ),
            const SyncIndicator(),
          ],
        ),
        body: SafeArea(top: false, child: body),
      );
    });
  }
}
