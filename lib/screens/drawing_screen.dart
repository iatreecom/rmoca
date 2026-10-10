import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../drawing/drawing_canvas.dart';
import '../drawing/svg_codec.dart';
import '../widgets/sync_indicator.dart';

const _palette = [
  Color(0xFF1F1F1F),
  Color(0xFF1E5EFF),
  Color(0xFFE5383B),
  Color(0xFF2B9348),
  Color(0xFFF59F00),
  Color(0xFF7B2CBF),
  Color(0x66FFE14D), // highlighter
];

/// Pen drawing editor that saves automatically, either to its own `.svg`
/// file or, for a drawing embedded in a memo, back into that memo.
class DrawingScreen extends StatefulWidget {
  /// Edits the `.svg` note at [path].
  const DrawingScreen({super.key, required String this.path})
    : embedId = null,
      initialSvg = null,
      onEmbeddedSave = null,
      embeddedTitle = null;

  /// Edits a drawing embedded in a memo; [onSave] receives the new `<svg>`.
  const DrawingScreen.embedded({
    super.key,
    required String this.embedId,
    required String title,
    required this.initialSvg,
    required void Function(String svg) onSave,
  }) : path = null,
       embeddedTitle = title,
       onEmbeddedSave = onSave;

  final String? path;
  final String? embedId;
  final String? initialSvg;
  final String? embeddedTitle;
  final void Function(String svg)? onEmbeddedSave;

  String get title =>
      embeddedTitle ?? path!.split('/').last.replaceAll(RegExp(r'\.svg$'), '');

  @override
  State<DrawingScreen> createState() => _DrawingScreenState();
}

class _DrawingScreenState extends State<DrawingScreen> {
  DrawingController? _controller;
  String? _foreignSvg;
  bool _loading = true;
  bool _dirty = false;
  Timer? _saveTimer;
  StreamSubscription<Set<String>>? _externalSub;
  late final AppState _app;

  @override
  void initState() {
    super.initState();
    _app = context.read<AppState>();
    _load();
    if (widget.path != null) {
      _externalSub = _app.externalChanges.listen((paths) {
        if (paths.contains(widget.path) && !_dirty) _load();
      });
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _externalSub?.cancel();
    if (_dirty) _save();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final store = _app.store;
    Drawing drawing = Drawing(strokes: []);
    String? foreign;
    final path = widget.path;
    final svg = path == null
        ? widget.initialSvg
        : (await store.exists(path) ? await store.readText(path) : null);
    if (svg != null && svg.trim().isNotEmpty) {
      final decoded = SvgCodec.decode(svg);
      if (decoded == null) {
        foreign = svg;
      } else {
        drawing = decoded;
      }
    }
    if (!mounted) return;
    setState(() {
      _foreignSvg = foreign;
      if (_controller == null) {
        _controller = DrawingController(drawing);
      } else {
        _controller!.replace(drawing);
      }
      _loading = false;
    });
  }

  void _onCommitted() {
    _dirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 1200), _save);
  }

  Future<void> _save() async {
    final c = _controller;
    if (c == null || !_dirty) return;
    _dirty = false;
    final path = widget.path;
    if (path == null) {
      widget.onEmbeddedSave!(
        SvgCodec.encode(c.drawing, embedId: widget.embedId),
      );
    } else {
      await _app.saveText(path, SvgCodec.encode(c.drawing));
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.title;
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(title)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_foreignSvg != null) {
      return Scaffold(
        appBar: AppBar(title: Text(title), actions: const [SyncIndicator()]),
        body: Column(
          children: [
            const MaterialBanner(
              content: Text('다른 프로그램에서 만든 SVG라 보기만 가능합니다.'),
              actions: [SizedBox.shrink()],
            ),
            Expanded(
              child: InteractiveViewer(
                maxScale: 8,
                child: Center(child: SvgPicture.string(_foreignSvg!)),
              ),
            ),
          ],
        ),
      );
    }

    final c = _controller!;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): c.undo,
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): c.undo,
        const SingleActivator(
          LogicalKeyboardKey.keyZ,
          control: true,
          shift: true,
        ): c.redo,
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true):
            c.redo,
      },
      child: PopScope(
        // Save as soon as the user leaves, before the screen is disposed.
        onPopInvokedWithResult: (didPop, _) {
          if (didPop && _dirty) {
            _saveTimer?.cancel();
            _save();
          }
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            appBar: AppBar(
              title: Text(title),
              actions: [
                ListenableBuilder(
                  listenable: c,
                  builder: (context, _) => Row(
                    children: [
                      IconButton(
                        tooltip: '실행 취소',
                        icon: const Icon(Icons.undo),
                        onPressed: c.canUndo
                            ? () {
                                c.undo();
                                _onCommitted();
                              }
                            : null,
                      ),
                      IconButton(
                        tooltip: '다시 실행',
                        icon: const Icon(Icons.redo),
                        onPressed: c.canRedo
                            ? () {
                                c.redo();
                                _onCommitted();
                              }
                            : null,
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  onSelected: (v) async {
                    if (v == 'clear') {
                      c.clear();
                      _onCommitted();
                    } else if (v == 'stylus') {
                      c.setStylusOnly(!c.stylusOnly);
                    }
                  },
                  itemBuilder: (context) => [
                    CheckedPopupMenuItem(
                      value: 'stylus',
                      checked: c.stylusOnly,
                      child: const Text('펜으로만 그리기 (손가락은 스크롤)'),
                    ),
                    const PopupMenuItem(value: 'clear', child: Text('모두 지우기')),
                  ],
                ),
                const SyncIndicator(),
              ],
            ),
            body: Column(
              children: [
                _Toolbar(controller: c),
                const Divider(height: 1),
                Expanded(
                  child: ColoredBox(
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest,
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1000),
                        child: DrawingCanvas(
                          controller: c,
                          onCommitted: _onCommitted,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.controller});

  final DrawingController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            SegmentedButton<DrawTool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: DrawTool.pen,
                  icon: Icon(Icons.edit),
                  tooltip: '펜',
                ),
                ButtonSegment(
                  value: DrawTool.eraser,
                  icon: Icon(Icons.auto_fix_normal),
                  tooltip: '지우개',
                ),
                ButtonSegment(
                  value: DrawTool.hand,
                  icon: Icon(Icons.pan_tool_outlined),
                  tooltip: '이동',
                ),
              ],
              selected: {c.tool},
              onSelectionChanged: (s) => c.setTool(s.first),
            ),
            const SizedBox(width: 12),
            for (final color in _palette)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => c.setColor(color),
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 1),
                      shape: BoxShape.circle,
                      border: Border.all(
                        width: c.color == color && c.tool == DrawTool.pen
                            ? 3
                            : 1,
                        color: c.color == color && c.tool == DrawTool.pen
                            ? Theme.of(context).colorScheme.primary
                            : Colors.black26,
                      ),
                    ),
                    child: color.a < 1
                        ? const Icon(
                            Icons.highlight,
                            size: 16,
                            color: Colors.black54,
                          )
                        : null,
                  ),
                ),
              ),
            const SizedBox(width: 12),
            const Icon(Icons.line_weight, size: 20),
            SizedBox(
              width: 140,
              child: Slider(
                value: c.size,
                min: 2,
                max: 32,
                onChanged: c.setSize,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
