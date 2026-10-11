import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:perfect_freehand/perfect_freehand.dart';

import 'shape_recognizer.dart';
import 'stroke.dart';
import 'svg_codec.dart';

enum DrawTool { pen, eraser, lasso, hand, text }

enum EraserMode {
  stroke('획 지우개'),
  area('부분 지우개');

  const EraserMode(this.label);

  final String label;
}

/// Holds the drawing being edited, tool settings and undo/redo history.
class DrawingController extends ChangeNotifier {
  DrawingController(this.drawing);

  Drawing drawing;
  DrawTool tool = DrawTool.pen;
  PenType penType = PenType.pen;
  Color color = const Color(0xFF1F1F1F);
  final Map<PenType, double> _sizes = {
    for (final t in PenType.values) t: t == PenType.highlighter ? 6 : 4,
  };
  EraserMode eraserMode = EraserMode.stroke;
  double eraserSize = 16;

  /// Straighten lines and shapes automatically.
  bool shapeAssist = false;

  /// When true, fingers scroll and only a stylus draws (palm rejection).
  bool stylusOnly = false;

  /// Colors the user picked beyond the presets.
  final List<Color> customColors = [];

  Stroke? live;

  /// Indices of selected strokes (lasso).
  Set<int> selection = {};

  final List<List<Stroke>> _undo = [];
  final List<List<Stroke>> _redo = [];

  /// Bumped whenever committed strokes change, to repaint the cached layer.
  int version = 0;

  /// Bumped to ask the canvas to fit the page to the screen again.
  final ValueNotifier<int> resetView = ValueNotifier(0);

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  double get size => _sizes[penType]!;

  Rect? get selectionBounds => selection.isEmpty
      ? null
      : selection
            .map((i) => drawing.strokes[i].bounds)
            .reduce((a, b) => a.expandToInclude(b));

  void setTool(DrawTool t) {
    tool = t;
    if (t != DrawTool.lasso) selection = {};
    notifyListeners();
  }

  void setPenType(PenType t) {
    penType = t;
    tool = DrawTool.pen;
    selection = {};
    notifyListeners();
  }

  void setColor(Color c) {
    color = c;
    if (selection.isNotEmpty) {
      recolorSelection(c);
    } else if (tool != DrawTool.pen) {
      tool = DrawTool.pen;
    }
    notifyListeners();
  }

  void addCustomColor(Color c) {
    customColors.remove(c);
    customColors.insert(0, c);
    if (customColors.length > 8) customColors.removeLast();
    setColor(c);
  }

  void setSize(double s) {
    _sizes[penType] = s;
    notifyListeners();
  }

  void setEraser(EraserMode mode, double size) {
    eraserMode = mode;
    eraserSize = size;
    tool = DrawTool.eraser;
    notifyListeners();
  }

  void setShapeAssist(bool v) {
    shapeAssist = v;
    notifyListeners();
  }

  void setStylusOnly(bool v) {
    stylusOnly = v;
    notifyListeners();
  }

  void setPaper(PaperStyle p) {
    drawing.paper = p;
    _changed();
  }

  void replace(Drawing d) {
    drawing = d;
    _undo.clear();
    _redo.clear();
    selection = {};
    _changed();
  }

  void checkpoint() {
    _undo.add(List.of(drawing.strokes));
    if (_undo.length > 200) _undo.removeAt(0);
    _redo.clear();
  }

  /// Drops the checkpoint taken for a gesture that changed nothing.
  void undoCheckpointIfUnused() {
    if (_undo.isNotEmpty) _undo.removeLast();
  }

  void undo() {
    if (_undo.isEmpty) return;
    _redo.add(List.of(drawing.strokes));
    _restore(_undo.removeLast());
  }

  void redo() {
    if (_redo.isEmpty) return;
    _undo.add(List.of(drawing.strokes));
    _restore(_redo.removeLast());
  }

  void _restore(List<Stroke> strokes) {
    drawing.strokes
      ..clear()
      ..addAll(strokes);
    selection = {};
    _changed();
  }

  void clear() {
    if (drawing.strokes.isEmpty) return;
    checkpoint();
    drawing.strokes.clear();
    selection = {};
    _changed();
  }

  void addStroke(Stroke s) {
    checkpoint();
    drawing.strokes.add(s);
    _changed();
  }

  /// Stroke eraser: removes touched strokes.
  bool eraseStrokesAt(Offset point, double radius) {
    final before = drawing.strokes.length;
    drawing.strokes.removeWhere((s) => s.hitTest(point, radius));
    if (drawing.strokes.length == before) return false;
    _changed();
    return true;
  }

  /// Area eraser: cuts the touched parts out of strokes.
  bool eraseAreaAt(Offset point, double radius) {
    var changed = false;
    final next = <Stroke>[];
    for (final s in drawing.strokes) {
      final pieces = s.eraseArea(point, radius);
      if (pieces == null) {
        next.add(s);
      } else {
        changed = true;
        next.addAll(pieces);
      }
    }
    if (!changed) return false;
    drawing.strokes
      ..clear()
      ..addAll(next);
    _changed();
    return true;
  }

  /// Selects strokes mostly inside the lasso polygon.
  void selectInside(Path lasso) {
    final selected = <int>{};
    for (var i = 0; i < drawing.strokes.length; i++) {
      final s = drawing.strokes[i];
      if (s.isText) {
        if (lasso.contains(s.bounds.center)) selected.add(i);
        continue;
      }
      final pts = s.points;
      final inside = pts.where((p) => lasso.contains(p)).length;
      if (pts.isNotEmpty && inside >= pts.length * 0.6) selected.add(i);
    }
    selection = selected;
    notifyListeners();
  }

  void clearSelection() {
    if (selection.isEmpty) return;
    selection = {};
    notifyListeners();
  }

  /// Applies [transform] to the selected strokes, based on [originals].
  void transformSelection(
    Map<int, Stroke> originals,
    Stroke Function(Stroke) transform,
  ) {
    for (final e in originals.entries) {
      drawing.strokes[e.key] = transform(e.value);
    }
    _changed();
  }

  void deleteSelection() {
    if (selection.isEmpty) return;
    checkpoint();
    final keep = <Stroke>[
      for (var i = 0; i < drawing.strokes.length; i++)
        if (!selection.contains(i)) drawing.strokes[i],
    ];
    drawing.strokes
      ..clear()
      ..addAll(keep);
    selection = {};
    _changed();
  }

  void duplicateSelection() {
    if (selection.isEmpty) return;
    checkpoint();
    final start = drawing.strokes.length;
    for (final i in selection.toList()..sort()) {
      drawing.strokes.add(drawing.strokes[i].translated(const Offset(24, 24)));
    }
    selection = {for (var i = start; i < drawing.strokes.length; i++) i};
    _changed();
  }

  void recolorSelection(Color c) {
    if (selection.isEmpty) return;
    checkpoint();
    for (final i in selection) {
      drawing.strokes[i] = drawing.strokes[i].copyWith(color: c);
    }
    _changed();
  }

  /// Font size for new text boxes (page units; the page is 1000 wide).
  double textSize = 28;

  void setTextSize(double s) {
    textSize = s;
    notifyListeners();
  }

  /// Index of the text box at [point], if any (topmost first).
  int? textAt(Offset point) {
    for (var i = drawing.strokes.length - 1; i >= 0; i--) {
      final s = drawing.strokes[i];
      if (s.isText && s.bounds.inflate(6).contains(point)) return i;
    }
    return null;
  }

  /// Adds a text box, or replaces/removes (empty [text]) the one at [index].
  void putText({int? index, required String text, Offset? at}) {
    checkpoint();
    if (index == null) {
      if (text.trim().isEmpty) {
        undoCheckpointIfUnused();
        return;
      }
      drawing.strokes.add(Stroke.text(text, at!, color, textSize));
    } else if (text.trim().isEmpty) {
      drawing.strokes.removeAt(index);
      selection = {};
    } else {
      final old = drawing.strokes[index];
      drawing.strokes[index] = Stroke.text(
        text,
        old.anchor,
        old.color,
        old.size,
      );
    }
    _changed();
  }

  void growTo(double y) {
    if (y > drawing.height - 300) {
      drawing.height = (y + 800).ceilToDouble();
      notifyListeners();
    }
  }

  void _changed() {
    version++;
    notifyListeners();
  }

  void notifyLive() => notifyListeners();

  @override
  void dispose() {
    resetView.dispose();
    super.dispose();
  }
}

/// Zoomable, pannable page that turns pointer input into ink.
///
/// One pointer uses the current tool; two fingers pinch-zoom and pan; the
/// mouse wheel scrolls (Ctrl+wheel zooms); trackpads pan and pinch.
class DrawingCanvas extends StatefulWidget {
  const DrawingCanvas({
    super.key,
    required this.controller,
    required this.onCommitted,
    this.onText,
  });

  final DrawingController controller;

  /// Text tool: a tap at [at] (page coordinates) on the text box [index],
  /// or on empty paper (null) to start a new one.
  final void Function(Offset at, int? index)? onText;

  /// Called after each change to the strokes (stroke, erase, move…).
  final VoidCallback onCommitted;

  @override
  State<DrawingCanvas> createState() => _DrawingCanvasState();
}

enum _Gesture { none, draw, erase, lasso, move, resize, pan, pinch }

class _DrawingCanvasState extends State<DrawingCanvas> {
  Size _viewport = Size.zero;
  double _zoom = 1; // Relative to fitting the page width.
  Offset _pan = Offset.zero;
  bool _initialized = false;

  final Map<int, Offset> _pointers = {};
  _Gesture _gesture = _Gesture.none;
  int? _primary;

  // Drawing state.
  final List<PointVector> _points = [];
  bool _simulate = false;
  DateTime _lastMove = DateTime.now();
  Offset? _lastPoint;

  // Erasing / lasso / move state.
  bool _changedSomething = false;
  final List<Offset> _lasso = [];
  Offset? _gestureStart;
  Map<int, Stroke> _originals = {};
  Rect? _startBounds;
  Offset? _cursor;

  // Pinch state.
  double _pinchStartDistance = 1;
  double _pinchStartZoom = 1;
  Offset _pinchStartFocal = Offset.zero;
  Offset _pinchStartPan = Offset.zero;

  ui.Picture? _cache;
  int _cacheVersion = -1;

  DrawingController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.resetView.addListener(_fit);
  }

  @override
  void dispose() {
    c.resetView.removeListener(_fit);
    _cache?.dispose();
    super.dispose();
  }

  double get _fitScale =>
      _viewport.width <= 0 ? 1 : (_viewport.width - 32) / c.drawing.width;
  double get _scale => _fitScale * _zoom;

  void _fit() => setState(() {
    _zoom = 1;
    _pan = const Offset(16, 16);
  });

  Offset _toPage(Offset local) => (local - _pan) / _scale;
  Offset _toScreen(Offset page) => page * _scale + _pan;

  void _clampPan() {
    final w = c.drawing.width * _scale;
    final h = c.drawing.height * _scale;
    const keep = 120.0;
    _pan = Offset(
      _pan.dx.clamp(keep - w, _viewport.width - keep),
      _pan.dy.clamp(keep - h, _viewport.height - keep),
    );
  }

  void _zoomAt(Offset focal, double newZoom) {
    final page = _toPage(focal);
    _zoom = newZoom.clamp(0.4, 6.0);
    _pan = focal - page * _scale;
    _clampPan();
  }

  /// Pointer kinds that pan instead of using the tool.
  bool _pans(PointerEvent e) =>
      c.tool == DrawTool.hand ||
      e.kind == PointerDeviceKind.trackpad ||
      (c.stylusOnly && e.kind == PointerDeviceKind.touch);

  // --- pointer handling ------------------------------------------------------

  void _down(PointerDownEvent e) {
    if (e.kind == PointerDeviceKind.mouse && e.buttons == kMiddleMouseButton) {
      _primary = e.pointer;
      _gesture = _Gesture.pan;
      _pointers[e.pointer] = e.localPosition;
      return;
    }
    if (e.kind == PointerDeviceKind.mouse && e.buttons != kPrimaryMouseButton) {
      return;
    }
    _pointers[e.pointer] = e.localPosition;

    if (_pointers.length == 2 && e.kind == PointerDeviceKind.touch) {
      _startPinch();
      return;
    }
    if (_pointers.length > 1) return;

    _primary = e.pointer;
    if (_pans(e)) {
      _gesture = _Gesture.pan;
      return;
    }
    final page = _toPage(e.localPosition);
    final eraserEnd = e.kind == PointerDeviceKind.invertedStylus;
    if (c.tool == DrawTool.eraser || eraserEnd) {
      _gesture = _Gesture.erase;
      c.checkpoint();
      _changedSomething = false;
      _erase(page);
    } else if (c.tool == DrawTool.lasso) {
      _startLassoOrMove(e.localPosition, page);
    } else if (c.tool == DrawTool.text) {
      // Handled on release so a tap does not start anything else.
      _gestureStart = page;
    } else if (c.tool == DrawTool.pen) {
      _gesture = _Gesture.draw;
      _simulate = e.kind != PointerDeviceKind.stylus;
      _points
        ..clear()
        ..add(_point(e, page));
      _lastMove = DateTime.now();
      _lastPoint = page;
      _updateLive();
    }
  }

  void _move(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    final previous = _pointers[e.pointer]!;
    _pointers[e.pointer] = e.localPosition;

    if (_gesture == _Gesture.pinch) {
      _updatePinch();
      return;
    }
    if (e.pointer != _primary) return;
    final page = _toPage(e.localPosition);
    switch (_gesture) {
      case _Gesture.pan:
        setState(() {
          _pan += e.localPosition - previous;
          _clampPan();
        });
      case _Gesture.draw:
        _points.add(_point(e, page));
        if ((page - _lastPoint!).distance > 2 / _scale) {
          _lastMove = DateTime.now();
          _lastPoint = page;
        }
        _updateLive();
      case _Gesture.erase:
        _erase(page);
        setState(() => _cursor = e.localPosition);
      case _Gesture.lasso:
        setState(() => _lasso.add(page));
      case _Gesture.move:
        final delta = page - _gestureStart!;
        c.transformSelection(_originals, (s) => s.translated(delta));
        _changedSomething = true;
      case _Gesture.resize:
        final b = _startBounds!;
        final sx = ((page.dx - b.left) / b.width).clamp(0.05, 50.0);
        final sy = ((page.dy - b.top) / b.height).clamp(0.05, 50.0);
        // Keep proportions unless Shift is held.
        final shift = HardwareKeyboard.instance.isShiftPressed;
        final u = (sx + sy) / 2;
        c.transformSelection(
          _originals,
          (s) => s.scaled(b.topLeft, shift ? sx : u, shift ? sy : u),
        );
        _changedSomething = true;
      case _Gesture.pinch:
      case _Gesture.none:
        break;
    }
  }

  void _up(PointerEvent e, {bool cancel = false}) {
    _pointers.remove(e.pointer);
    if (_gesture == _Gesture.pinch) {
      if (_pointers.isEmpty) _gesture = _Gesture.none;
      return;
    }
    if (e.pointer != _primary) return;
    _primary = null;
    final gesture = _gesture;
    _gesture = _Gesture.none;
    if (gesture == _Gesture.none &&
        c.tool == DrawTool.text &&
        !cancel &&
        _gestureStart != null) {
      final at = _gestureStart!;
      _gestureStart = null;
      widget.onText?.call(at, c.textAt(at));
      return;
    }
    switch (gesture) {
      case _Gesture.draw:
        if (cancel) {
          _points.clear();
          c.live = null;
          c.notifyLive();
          return;
        }
        _finishStroke();
      case _Gesture.erase:
        setState(() => _cursor = null);
        if (_changedSomething) {
          widget.onCommitted();
        } else {
          c.undoCheckpointIfUnused();
        }
      case _Gesture.lasso:
        if (_lasso.length > 2) {
          final path = Path()..addPolygon(_lasso, true);
          c.selectInside(path);
        }
        setState(_lasso.clear);
      case _Gesture.move:
      case _Gesture.resize:
        if (_changedSomething) {
          widget.onCommitted();
        } else {
          c.undoCheckpointIfUnused();
        }
      case _Gesture.pan:
      case _Gesture.pinch:
      case _Gesture.none:
        break;
    }
  }

  void _hover(PointerHoverEvent e) {
    if (c.tool == DrawTool.eraser) setState(() => _cursor = e.localPosition);
  }

  void _signal(PointerSignalEvent e) {
    if (e is PointerScrollEvent) {
      setState(() {
        if (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed) {
          _zoomAt(e.localPosition, _zoom * math.exp(-e.scrollDelta.dy / 300));
        } else {
          _pan -= e.scrollDelta;
          _clampPan();
        }
      });
    }
  }

  void _panZoomUpdate(PointerPanZoomUpdateEvent e) {
    setState(() {
      _pan += e.panDelta;
      if (e.scale != 1) {
        _zoomAt(e.localPosition, _zoom * (1 + (e.scale - 1) * 0.08));
      }
      _clampPan();
    });
  }

  // --- tools -----------------------------------------------------------------

  void _startPinch() {
    // A second finger: whatever the first one started becomes a pinch.
    if (_gesture == _Gesture.draw) {
      _points.clear();
      c.live = null;
      c.notifyLive();
    } else if (_gesture == _Gesture.erase && !_changedSomething) {
      c.undoCheckpointIfUnused();
    }
    _lasso.clear();
    _gesture = _Gesture.pinch;
    final pts = _pointers.values.toList();
    _pinchStartDistance = math.max(1, (pts[0] - pts[1]).distance);
    _pinchStartFocal = (pts[0] + pts[1]) / 2;
    _pinchStartZoom = _zoom;
    _pinchStartPan = _pan;
  }

  void _updatePinch() {
    if (_pointers.length < 2) return;
    final pts = _pointers.values.toList();
    final focal = (pts[0] + pts[1]) / 2;
    final distance = math.max(1.0, (pts[0] - pts[1]).distance);
    setState(() {
      // Zoom around the starting focal point, then follow the fingers.
      final pageAtFocal =
          (_pinchStartFocal - _pinchStartPan) / (_fitScale * _pinchStartZoom);
      _zoom = (_pinchStartZoom * distance / _pinchStartDistance).clamp(
        0.4,
        6.0,
      );
      _pan = focal - pageAtFocal * _scale;
      _clampPan();
    });
  }

  void _erase(Offset page) {
    final radius = c.eraserSize / 2 / _scale;
    final changed = c.eraserMode == EraserMode.stroke
        ? c.eraseStrokesAt(page, radius)
        : c.eraseAreaAt(page, radius);
    _changedSomething = changed || _changedSomething;
  }

  void _startLassoOrMove(Offset local, Offset page) {
    final bounds = c.selectionBounds;
    if (bounds != null) {
      final handle = _toScreen(bounds.bottomRight);
      if ((local - handle).distance < 22) {
        _beginTransform(page, _Gesture.resize, bounds);
        return;
      }
      if (bounds.inflate(8 / _scale).contains(page)) {
        _beginTransform(page, _Gesture.move, bounds);
        return;
      }
      c.clearSelection();
    }
    _gesture = _Gesture.lasso;
    setState(() {
      _lasso
        ..clear()
        ..add(page);
    });
  }

  void _beginTransform(Offset page, _Gesture gesture, Rect bounds) {
    c.checkpoint();
    _gesture = gesture;
    _gestureStart = page;
    _startBounds = bounds;
    _changedSomething = false;
    _originals = {for (final i in c.selection) i: c.drawing.strokes[i]};
  }

  void _finishStroke() {
    if (_points.isEmpty) return;
    var stroke = _makeStroke();
    // Shape assist: always when enabled, or when the pen rests at the end.
    final held = DateTime.now().difference(_lastMove).inMilliseconds > 650;
    if ((c.shapeAssist || held) && c.penType != PenType.highlighter) {
      final shape = ShapeRecognizer.recognize(_points.toList());
      if (shape != null) {
        stroke = Stroke(
          points: shape.points,
          color: stroke.color,
          size: stroke.size,
          type: stroke.type,
        );
      }
    }
    c.live = null;
    c.addStroke(stroke);
    c.growTo(stroke.bounds.bottom);
    _points.clear();
    widget.onCommitted();
  }

  PointVector _point(PointerEvent e, Offset pos) {
    if (e.kind != PointerDeviceKind.stylus) return PointVector(pos.dx, pos.dy);
    final range = e.pressureMax - e.pressureMin;
    final pressure = range > 0 ? (e.pressure - e.pressureMin) / range : 0.5;
    return PointVector(pos.dx, pos.dy, pressure.clamp(0.05, 1.0));
  }

  Stroke _makeStroke() => Stroke(
    points: List.of(_points),
    color: c.color,
    size: c.size,
    simulatePressure: _simulate,
    type: c.penType,
  );

  void _updateLive() {
    c.live = _makeStroke();
    c.notifyLive();
  }

  ui.Picture _strokesPicture() {
    if (_cache != null && _cacheVersion == c.version) return _cache!;
    _cache?.dispose();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    paintPage(canvas, c.drawing);
    for (final s in c.drawing.strokes) {
      paintStroke(canvas, s);
    }
    _cacheVersion = c.version;
    return _cache = recorder.endRecording();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (size != _viewport) {
          final first = !_initialized;
          _viewport = size;
          if (first) {
            _initialized = true;
            _pan = const Offset(16, 16);
          }
        }
        return ListenableBuilder(
          listenable: c,
          builder: (context, _) => MouseRegion(
            cursor: c.tool == DrawTool.hand
                ? SystemMouseCursors.grab
                : c.tool == DrawTool.eraser
                ? SystemMouseCursors.none
                : SystemMouseCursors.precise,
            onExit: (_) => setState(() => _cursor = null),
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _down,
              onPointerMove: _move,
              onPointerUp: _up,
              onPointerCancel: (e) => _up(e, cancel: true),
              onPointerHover: _hover,
              onPointerSignal: _signal,
              onPointerPanZoomUpdate: _panZoomUpdate,
              child: CustomPaint(
                size: size,
                painter: _CanvasPainter(
                  picture: _strokesPicture(),
                  drawing: c.drawing,
                  live: c.live,
                  scale: _scale,
                  pan: _pan,
                  selection: c.selectionBounds,
                  lasso: List.of(_lasso),
                  cursor: _cursor,
                  cursorRadius: c.eraserSize / 2,
                  background: Theme.of(context)
                      .colorScheme
                      .surfaceContainerHigh,
                  accent: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// White page with its paper pattern, in page coordinates.
void paintPage(Canvas canvas, Drawing d) {
  final page = Rect.fromLTWH(0, 0, d.width, d.height);
  canvas.drawRect(page, Paint()..color = Colors.white);
  const s = PaperStyle.spacing;
  final line = Paint()
    ..color = const Color(0xFFD5DAE5)
    ..strokeWidth = 1;
  switch (d.paper) {
    case PaperStyle.lined:
      for (var y = s; y < d.height; y += s) {
        canvas.drawLine(Offset(0, y - 0.5), Offset(d.width, y - 0.5), line);
      }
    case PaperStyle.grid:
      for (var y = s; y < d.height; y += s) {
        canvas.drawLine(Offset(0, y), Offset(d.width, y), line);
      }
      for (var x = s; x < d.width; x += s) {
        canvas.drawLine(Offset(x, 0), Offset(x, d.height), line);
      }
    case PaperStyle.dots:
      final dot = Paint()..color = const Color(0xFFC3C9D6);
      for (var y = s / 2; y < d.height; y += s) {
        for (var x = s / 2; x < d.width; x += s) {
          canvas.drawCircle(Offset(x, y), 1.8, dot);
        }
      }
    case PaperStyle.plain:
      break;
  }
}

void paintStroke(Canvas canvas, Stroke s) {
  if (s.isText) {
    s.textPainter.paint(canvas, s.anchor);
    return;
  }
  canvas.drawPath(
    s.path,
    Paint()
      ..color = s.inkColor
      ..style = PaintingStyle.fill
      ..isAntiAlias = true
      // Highlighter ink darkens what is under it, like a real marker.
      ..blendMode = s.type == PenType.highlighter
          ? BlendMode.multiply
          : BlendMode.srcOver,
  );
}

class _CanvasPainter extends CustomPainter {
  _CanvasPainter({
    required this.picture,
    required this.drawing,
    required this.live,
    required this.scale,
    required this.pan,
    required this.selection,
    required this.lasso,
    required this.cursor,
    required this.cursorRadius,
    required this.background,
    required this.accent,
  });

  final ui.Picture picture;
  final Drawing drawing;
  final Stroke? live;
  final double scale;
  final Offset pan;
  final Rect? selection;
  final List<Offset> lasso;
  final Offset? cursor;
  final double cursorRadius;
  final Color background;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = background);
    final pageRect = Rect.fromLTWH(
      pan.dx,
      pan.dy,
      drawing.width * scale,
      drawing.height * scale,
    );
    // Soft paper shadow.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        pageRect.shift(const Offset(0, 2)),
        const Radius.circular(4),
      ),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.12)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );

    canvas.save();
    canvas.clipRect(pageRect);
    canvas.translate(pan.dx, pan.dy);
    canvas.scale(scale);
    canvas.drawPicture(picture);
    if (live != null) paintStroke(canvas, live!);
    canvas.restore();

    if (lasso.length > 1) {
      final path = Path()
        ..addPolygon([for (final p in lasso) p * scale + pan], true);
      canvas.drawPath(path, Paint()..color = accent.withValues(alpha: 0.08));
      _dashed(canvas, path, accent);
    }
    if (selection != null) {
      final r = Rect.fromLTRB(
        selection!.left * scale + pan.dx,
        selection!.top * scale + pan.dy,
        selection!.right * scale + pan.dx,
        selection!.bottom * scale + pan.dy,
      ).inflate(6);
      canvas.drawRect(r, Paint()..color = accent.withValues(alpha: 0.06));
      _dashed(canvas, Path()..addRect(r), accent);
      // Resize handle.
      canvas.drawCircle(r.bottomRight, 9, Paint()..color = Colors.white);
      canvas.drawCircle(
        r.bottomRight,
        9,
        Paint()
          ..color = accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );
    }
    if (cursor != null) {
      canvas.drawCircle(
        cursor!,
        cursorRadius,
        Paint()
          ..color = Colors.black54
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
    }
  }

  void _dashed(Canvas canvas, Path path, Color color) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 10) {
        canvas.drawPath(metric.extractPath(d, d + 6), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_CanvasPainter old) => true;
}
