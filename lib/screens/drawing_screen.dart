import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../drawing/drawing_canvas.dart';
import '../drawing/stroke.dart';
import '../drawing/svg_codec.dart';
import '../widgets/media_view.dart';
import '../widgets/sync_indicator.dart';

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

  /// Text tool: type a new text box at [at], or edit the one at [index].
  Future<void> _editText(Offset at, int? index) async {
    final c = _controller;
    if (c == null) return;
    final existing = index == null ? null : c.drawing.strokes[index];
    final result = await showDialog<String>(
      context: context,
      builder: (context) => _TextBoxDialog(
        initial: existing?.text ?? '',
        controller: c,
        editing: existing != null,
      ),
    );
    if (result == null || !mounted) return;
    c.putText(index: index, text: result, at: at);
    _onCommitted();
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
                child: Center(child: SvgView(_foreignSvg!)),
              ),
            ),
          ],
        ),
      );
    }

    final c = _controller!;
    void undo() {
      c.undo();
      _onCommitted();
    }

    void redo() {
      c.redo();
      _onCommitted();
    }

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): undo,
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): undo,
        const SingleActivator(
          LogicalKeyboardKey.keyZ,
          control: true,
          shift: true,
        ): redo,
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true):
            redo,
        const SingleActivator(LogicalKeyboardKey.delete): () {
          c.deleteSelection();
          _onCommitted();
        },
        const SingleActivator(LogicalKeyboardKey.backspace): () {
          c.deleteSelection();
          _onCommitted();
        },
        const SingleActivator(LogicalKeyboardKey.keyP): () =>
            c.setTool(DrawTool.pen),
        const SingleActivator(LogicalKeyboardKey.keyE): () =>
            c.setTool(DrawTool.eraser),
        const SingleActivator(LogicalKeyboardKey.keyL): () =>
            c.setTool(DrawTool.lasso),
        const SingleActivator(LogicalKeyboardKey.keyH): () =>
            c.setTool(DrawTool.hand),
        const SingleActivator(LogicalKeyboardKey.keyT): () =>
            c.setTool(DrawTool.text),
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
              title: Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              actions: [
                ListenableBuilder(
                  listenable: c,
                  builder: (context, _) => Row(
                    children: [
                      IconButton(
                        tooltip: '실행 취소 (Ctrl+Z)',
                        icon: const Icon(Icons.undo_rounded),
                        onPressed: c.canUndo ? undo : null,
                      ),
                      IconButton(
                        tooltip: '다시 실행',
                        icon: const Icon(Icons.redo_rounded),
                        onPressed: c.canRedo ? redo : null,
                      ),
                    ],
                  ),
                ),
                _PageMenu(controller: c, onChanged: _onCommitted),
                const SyncIndicator(),
                const SizedBox(width: 4),
              ],
            ),
            body: Stack(
              children: [
                Positioned.fill(
                  child: DrawingCanvas(
                    controller: c,
                    onCommitted: _onCommitted,
                    onText: _editText,
                  ),
                ),
                Positioned(
                  top: 12,
                  left: 12,
                  right: 12,
                  child: Center(child: _Toolbar(controller: c)),
                ),
                Positioned(
                  bottom: 20,
                  left: 12,
                  right: 12,
                  child: Center(
                    child: _SelectionBar(
                      controller: c,
                      onChanged: _onCommitted,
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

const _presetColors = [
  Color(0xFF1F1F1F),
  Color(0xFF6B7280),
  Color(0xFF1E5EFF),
  Color(0xFF0EA5E9),
  Color(0xFFE5383B),
  Color(0xFFEC4899),
  Color(0xFF2B9348),
  Color(0xFFF59F00),
  Color(0xFFFACC15),
  Color(0xFF7B2CBF),
  Color(0xFF92400E),
  Color(0xFFFFFFFF),
];

/// Floating, rounded tool palette over the canvas.
class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.controller});

  final DrawingController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final narrow = MediaQuery.sizeOf(context).width < 720;
        return Material(
          elevation: 3,
          shadowColor: Colors.black26,
          color: scheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(28),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (narrow)
                  _PenTypeMenu(controller: c)
                else
                  for (final t in PenType.values)
                    _ToolButton(
                      icon: t.icon,
                      tooltip: t.label,
                      selected: c.tool == DrawTool.pen && c.penType == t,
                      dotColor: c.tool == DrawTool.pen && c.penType == t
                          ? c.color
                          : null,
                      onTap: () => c.setPenType(t),
                    ),
                const _Gap(),
                _EraserButton(controller: c),
                _ToolButton(
                  icon: Icons.gesture_rounded,
                  tooltip: '올가미 선택 (L)',
                  selected: c.tool == DrawTool.lasso,
                  onTap: () => c.setTool(DrawTool.lasso),
                ),
                _ToolButton(
                  icon: Icons.text_fields_rounded,
                  tooltip: '텍스트 (T)',
                  selected: c.tool == DrawTool.text,
                  dotColor: c.tool == DrawTool.text ? c.color : null,
                  onTap: () => c.setTool(DrawTool.text),
                ),
                _ToolButton(
                  icon: Icons.pan_tool_outlined,
                  tooltip: '이동 (H)',
                  selected: c.tool == DrawTool.hand,
                  onTap: () => c.setTool(DrawTool.hand),
                ),
                const _Gap(),
                _ColorButton(controller: c),
                _SizeButton(controller: c),
                const _Gap(),
                _ToolButton(
                  icon: Icons.category_outlined,
                  tooltip: c.shapeAssist
                      ? '도형 보정 켜짐'
                      : '도형 보정 (끝에서 잠시 멈추면 항상 보정)',
                  selected: c.shapeAssist,
                  onTap: () => c.setShapeAssist(!c.shapeAssist),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Gap extends StatelessWidget {
  const _Gap();

  @override
  Widget build(BuildContext context) => Container(
    width: 1,
    height: 24,
    margin: const EdgeInsets.symmetric(horizontal: 6),
    color: Theme.of(context).colorScheme.outlineVariant,
  );
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.icon,
    required this.tooltip,
    required this.selected,
    required this.onTap,
    this.dotColor,
  });

  final IconData icon;
  final String tooltip;
  final bool selected;
  final VoidCallback onTap;
  final Color? dotColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 40,
          height: 40,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: BoxDecoration(
            color: selected ? scheme.primaryContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(
                icon,
                size: 22,
                color: selected
                    ? scheme.onPrimaryContainer
                    : scheme.onSurfaceVariant,
              ),
              if (dotColor != null)
                Positioned(
                  bottom: 5,
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: dotColor,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.black26, width: 0.5),
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

class _PenTypeMenu extends StatelessWidget {
  const _PenTypeMenu({required this.controller});

  final DrawingController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return MenuAnchor(
      menuChildren: [
        for (final t in PenType.values)
          MenuItemButton(
            leadingIcon: Icon(t.icon),
            onPressed: () => c.setPenType(t),
            child: Text(t.label),
          ),
      ],
      builder: (context, menu, _) => _ToolButton(
        icon: c.penType.icon,
        tooltip: c.penType.label,
        selected: c.tool == DrawTool.pen,
        dotColor: c.color,
        onTap: () {
          if (c.tool != DrawTool.pen) {
            c.setTool(DrawTool.pen);
          } else {
            menu.isOpen ? menu.close() : menu.open();
          }
        },
      ),
    );
  }
}

class _EraserButton extends StatelessWidget {
  const _EraserButton({required this.controller});

  final DrawingController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return MenuAnchor(
      menuChildren: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: SizedBox(
            width: 240,
            child: ListenableBuilder(
              listenable: c,
              builder: (context, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SegmentedButton<EraserMode>(
                    segments: [
                      for (final m in EraserMode.values)
                        ButtonSegment(value: m, label: Text(m.label)),
                    ],
                    selected: {c.eraserMode},
                    onSelectionChanged: (s) =>
                        c.setEraser(s.first, c.eraserSize),
                  ),
                  const SizedBox(height: 8),
                  Text('크기 ${c.eraserSize.round()}'),
                  Slider(
                    value: c.eraserSize,
                    min: 6,
                    max: 80,
                    onChanged: (v) => c.setEraser(c.eraserMode, v),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
      builder: (context, menu, _) => _ToolButton(
        icon: c.eraserMode == EraserMode.stroke
            ? Icons.auto_fix_normal_rounded
            : Icons.cleaning_services_outlined,
        tooltip: '${c.eraserMode.label} (다시 누르면 설정)',
        selected: c.tool == DrawTool.eraser,
        onTap: () {
          if (c.tool != DrawTool.eraser) {
            c.setTool(DrawTool.eraser);
          } else {
            menu.isOpen ? menu.close() : menu.open();
          }
        },
      ),
    );
  }
}

class _ColorButton extends StatelessWidget {
  const _ColorButton({required this.controller});

  final DrawingController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return MenuAnchor(
      menuChildren: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: SizedBox(
            width: 252,
            child: ListenableBuilder(
              listenable: c,
              builder: (context, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final color in [..._presetColors, ...c.customColors])
                        _Swatch(
                          color: color,
                          selected: c.color.toARGB32() == color.toARGB32(),
                          onTap: () => c.setColor(color),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextButton.icon(
                    icon: const Icon(Icons.palette_outlined),
                    label: const Text('색 직접 고르기'),
                    onPressed: () async {
                      final picked = await showDialog<Color>(
                        context: context,
                        builder: (_) => _ColorPickerDialog(initial: c.color),
                      );
                      if (picked != null) c.addCustomColor(picked);
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
      builder: (context, menu, _) => Tooltip(
        message: '색',
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => menu.isOpen ? menu.close() : menu.open(),
          child: Padding(
            padding: const EdgeInsets.all(7),
            child: Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: c.color,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.black26),
                boxShadow: [
                  BoxShadow(
                    color: c.color.withValues(alpha: 0.4),
                    blurRadius: 6,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    customBorder: const CircleBorder(),
    onTap: onTap,
    child: Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(
          color: selected
              ? Theme.of(context).colorScheme.primary
              : Colors.black.withValues(alpha: 0.15),
          width: selected ? 3 : 1,
        ),
      ),
    ),
  );
}

class _SizeButton extends StatelessWidget {
  const _SizeButton({required this.controller});

  final DrawingController controller;

  static const _presets = [2.0, 4.0, 8.0, 14.0];

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final s in _presets)
          Tooltip(
            message: '굵기 ${s.round()}',
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => c.setSize(s),
              child: Container(
                width: 32,
                height: 40,
                alignment: Alignment.center,
                child: Container(
                  width: 4 + s * 0.9,
                  height: 4 + s * 0.9,
                  decoration: BoxDecoration(
                    color: (c.size - s).abs() < 0.5
                        ? scheme.primary
                        : scheme.onSurfaceVariant.withValues(alpha: 0.5),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          ),
        MenuAnchor(
          menuChildren: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: 240,
                child: ListenableBuilder(
                  listenable: c,
                  builder: (context, _) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${c.penType.label} 굵기 ${c.size.toStringAsFixed(1)}',
                      ),
                      Slider(
                        value: c.size.clamp(1, 40),
                        min: 1,
                        max: 40,
                        onChanged: c.setSize,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
          builder: (context, menu, _) => IconButton(
            tooltip: '굵기 직접 조절',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.tune_rounded, size: 20),
            onPressed: () => menu.isOpen ? menu.close() : menu.open(),
          ),
        ),
      ],
    );
  }
}

/// Actions for lasso-selected strokes.
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({required this.controller, required this.onChanged});

  final DrawingController controller;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => AnimatedSwitcher(
        duration: const Duration(milliseconds: 150),
        child: c.selection.isEmpty
            ? const SizedBox.shrink()
            : Material(
                key: const ValueKey('selection'),
                elevation: 4,
                color: scheme.inverseSurface,
                borderRadius: BorderRadius.circular(24),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Text(
                            '${c.selection.length}개 선택',
                            style: TextStyle(color: scheme.onInverseSurface),
                          ),
                        ),
                        for (final color in _presetColors.take(6))
                          InkWell(
                            customBorder: const CircleBorder(),
                            onTap: () {
                              c.recolorSelection(color);
                              onChanged();
                            },
                            child: Container(
                              width: 22,
                              height: 22,
                              margin: const EdgeInsets.all(4),
                              decoration: BoxDecoration(
                                color: color,
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white54),
                              ),
                            ),
                          ),
                        IconButton(
                          tooltip: '복제',
                          color: scheme.onInverseSurface,
                          icon: const Icon(Icons.copy_all_rounded),
                          onPressed: () {
                            c.duplicateSelection();
                            onChanged();
                          },
                        ),
                        IconButton(
                          tooltip: '삭제',
                          color: scheme.onInverseSurface,
                          icon: const Icon(Icons.delete_outline_rounded),
                          onPressed: () {
                            c.deleteSelection();
                            onChanged();
                          },
                        ),
                        IconButton(
                          tooltip: '선택 해제',
                          color: scheme.onInverseSurface,
                          icon: const Icon(Icons.close_rounded),
                          onPressed: c.clearSelection,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}

/// Paper style, palm rejection, view and clear.
class _PageMenu extends StatelessWidget {
  const _PageMenu({required this.controller, required this.onChanged});

  final DrawingController controller;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => MenuAnchor(
        menuChildren: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('종이 스타일'),
          ),
          for (final p in PaperStyle.values)
            MenuItemButton(
              leadingIcon: Icon(
                c.drawing.paper == p
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
              ),
              onPressed: () {
                c.setPaper(p);
                onChanged();
              },
              child: Text(p.label),
            ),
          const Divider(),
          MenuItemButton(
            leadingIcon: Icon(
              c.stylusOnly ? Icons.check_box : Icons.check_box_outline_blank,
            ),
            onPressed: () => c.setStylusOnly(!c.stylusOnly),
            child: const Text('펜으로만 그리기 (손가락은 이동)'),
          ),
          MenuItemButton(
            leadingIcon: const Icon(Icons.fit_screen_rounded),
            onPressed: () => c.resetView.value++,
            child: const Text('화면에 맞추기'),
          ),
          const Divider(),
          MenuItemButton(
            leadingIcon: const Icon(Icons.delete_sweep_outlined),
            onPressed: () {
              c.clear();
              onChanged();
            },
            child: const Text('모두 지우기'),
          ),
        ],
        builder: (context, menu, _) => IconButton(
          tooltip: '페이지',
          icon: const Icon(Icons.more_vert_rounded),
          onPressed: () => menu.isOpen ? menu.close() : menu.open(),
        ),
      ),
    );
  }
}

/// Hue / saturation / brightness picker with hex input.
class _ColorPickerDialog extends StatefulWidget {
  const _ColorPickerDialog({required this.initial});

  final Color initial;

  @override
  State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<_ColorPickerDialog> {
  late HSVColor _hsv = HSVColor.fromColor(widget.initial);
  late final _hex = TextEditingController(text: _hexOf(widget.initial));

  static String _hexOf(Color c) =>
      (c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();

  void _set(HSVColor hsv) => setState(() {
    _hsv = hsv;
    _hex.text = _hexOf(hsv.toColor());
  });

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  Widget _slider(
    String label,
    double value,
    double max,
    List<Color> track,
    ValueChanged<double> onChanged,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.labelMedium),
      Container(
        height: 28,
        margin: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: LinearGradient(colors: track),
        ),
        child: SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 0,
            activeTrackColor: Colors.transparent,
            inactiveTrackColor: Colors.transparent,
            thumbColor: Colors.white,
            overlayShape: SliderComponentShape.noOverlay,
          ),
          child: Slider(value: value, max: max, onChanged: onChanged),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final color = _hsv.toColor();
    return AlertDialog(
      title: const Text('색 고르기'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 56,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.black12),
              ),
            ),
            const SizedBox(height: 12),
            _slider('색상', _hsv.hue, 360, [
              for (var h = 0; h <= 360; h += 60)
                HSVColor.fromAHSV(1, h.toDouble(), 1, 1).toColor(),
            ], (v) => _set(_hsv.withHue(v))),
            _slider('채도', _hsv.saturation, 1, [
              _hsv.withSaturation(0).toColor(),
              _hsv.withSaturation(1).toColor(),
            ], (v) => _set(_hsv.withSaturation(v))),
            _slider('밝기', _hsv.value, 1, [
              Colors.black,
              _hsv.withValue(1).toColor(),
            ], (v) => _set(_hsv.withValue(v))),
            TextField(
              controller: _hex,
              decoration: const InputDecoration(
                prefixText: '#',
                labelText: 'HEX',
              ),
              onSubmitted: (v) {
                final parsed = int.tryParse(v.replaceAll('#', ''), radix: 16);
                if (parsed != null && v.replaceAll('#', '').length == 6) {
                  _set(HSVColor.fromColor(Color(0xFF000000 | parsed)));
                }
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, color),
          child: const Text('선택'),
        ),
      ],
    );
  }
}

/// Typing a text box: the text, plus its size for new boxes.
class _TextBoxDialog extends StatefulWidget {
  const _TextBoxDialog({
    required this.initial,
    required this.controller,
    required this.editing,
  });

  final String initial;
  final DrawingController controller;
  final bool editing;

  @override
  State<_TextBoxDialog> createState() => _TextBoxDialogState();
}

class _TextBoxDialogState extends State<_TextBoxDialog> {
  late final _text = TextEditingController(text: widget.initial);

  static const _sizes = [
    ('작게', 20.0),
    ('보통', 28.0),
    ('크게', 40.0),
    ('제목', 60.0),
  ];

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return AlertDialog(
      title: Text(widget.editing ? '텍스트 편집' : '텍스트 넣기'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _text,
              autofocus: true,
              minLines: 2,
              maxLines: 6,
              decoration: const InputDecoration(hintText: '내용'),
            ),
            if (!widget.editing) ...[
              const SizedBox(height: 12),
              ListenableBuilder(
                listenable: c,
                builder: (context, _) => Wrap(
                  spacing: 8,
                  children: [
                    for (final (label, size) in _sizes)
                      ChoiceChip(
                        label: Text(label),
                        selected: c.textSize == size,
                        onSelected: (_) => c.setTextSize(size),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (widget.editing)
          TextButton(
            onPressed: () => Navigator.pop(context, ''),
            child: Text(
              '삭제',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _text.text),
          child: const Text('확인'),
        ),
      ],
    );
  }
}
