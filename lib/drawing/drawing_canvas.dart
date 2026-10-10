import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:perfect_freehand/perfect_freehand.dart';

import 'stroke.dart';
import 'svg_codec.dart';

enum DrawTool { pen, eraser, hand }

/// Holds the drawing being edited plus undo/redo history.
class DrawingController extends ChangeNotifier {
  DrawingController(this.drawing);

  Drawing drawing;
  DrawTool tool = DrawTool.pen;
  Color color = const Color(0xFF1F1F1F);
  double size = 6;

  /// When true, fingers scroll and only a stylus draws (palm rejection).
  bool stylusOnly = false;

  Stroke? live;
  final List<List<Stroke>> _undo = [];
  final List<List<Stroke>> _redo = [];

  /// Bumped whenever committed strokes change, to repaint the cached layer.
  int version = 0;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  void setTool(DrawTool t) {
    tool = t;
    notifyListeners();
  }

  void setColor(Color c) {
    color = c;
    if (tool != DrawTool.pen) tool = DrawTool.pen;
    notifyListeners();
  }

  void setSize(double s) {
    size = s;
    notifyListeners();
  }

  void setStylusOnly(bool v) {
    stylusOnly = v;
    notifyListeners();
  }

  void replace(Drawing d) {
    drawing = d;
    _undo.clear();
    _redo.clear();
    _changed();
  }

  void checkpoint() {
    _undo.add(List.of(drawing.strokes));
    if (_undo.length > 200) _undo.removeAt(0);
    _redo.clear();
  }

  /// Drops the checkpoint taken for an eraser gesture that erased nothing.
  void undoCheckpointIfUnused() {
    if (_undo.isNotEmpty) _undo.removeLast();
  }

  void undo() {
    if (_undo.isEmpty) return;
    _redo.add(List.of(drawing.strokes));
    drawing.strokes
      ..clear()
      ..addAll(_undo.removeLast());
    _changed();
  }

  void redo() {
    if (_redo.isEmpty) return;
    _undo.add(List.of(drawing.strokes));
    drawing.strokes
      ..clear()
      ..addAll(_redo.removeLast());
    _changed();
  }

  void clear() {
    if (drawing.strokes.isEmpty) return;
    checkpoint();
    drawing.strokes.clear();
    _changed();
  }

  void addStroke(Stroke s) {
    checkpoint();
    drawing.strokes.add(s);
    _changed();
  }

  /// Removes strokes touched by the eraser; returns whether any were removed.
  bool eraseAt(Offset point, double radius) {
    final before = drawing.strokes.length;
    drawing.strokes.removeWhere((s) => s.hitTest(point, radius));
    if (drawing.strokes.length == before) return false;
    _changed();
    return true;
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
}

/// Scrollable page that turns pointer input into strokes.
class DrawingCanvas extends StatefulWidget {
  const DrawingCanvas({
    super.key,
    required this.controller,
    required this.onCommitted,
  });

  final DrawingController controller;

  /// Called after each completed stroke or erase gesture.
  final VoidCallback onCommitted;

  @override
  State<DrawingCanvas> createState() => _DrawingCanvasState();
}

class _DrawingCanvasState extends State<DrawingCanvas> {
  int? _pointer;
  bool _erasing = false;
  bool _erasedSomething = false;
  final List<PointVector> _points = [];
  bool _simulate = false;
  Color _liveColor = Colors.black;
  double _liveSize = 6;

  DrawingController get c => widget.controller;

  /// Pointer kinds that scroll the page instead of drawing.
  Set<PointerDeviceKind> get _scrollKinds {
    if (c.tool == DrawTool.hand) return PointerDeviceKind.values.toSet();
    return {
      PointerDeviceKind.trackpad,
      if (c.stylusOnly) PointerDeviceKind.touch,
    };
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final scale = constraints.maxWidth / c.drawing.width;
          final scrollKinds = _scrollKinds;
          return ScrollConfiguration(
            behavior: ScrollConfiguration.of(context)
                .copyWith(dragDevices: scrollKinds, scrollbars: true),
            child: SingleChildScrollView(
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (e) => _down(e, scale, scrollKinds),
                onPointerMove: (e) => _move(e, scale),
                onPointerUp: (e) => _up(e),
                onPointerCancel: (e) => _cancel(e),
                child: SizedBox(
                  width: constraints.maxWidth,
                  height: c.drawing.height * scale,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: RepaintBoundary(
                          child: CustomPaint(
                            painter: _StrokesPainter(
                              c.drawing.strokes,
                              scale,
                              c.version,
                            ),
                          ),
                        ),
                      ),
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _LivePainter(c.live, scale),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Offset _toPage(Offset local, double scale) => local / scale;

  void _down(
    PointerDownEvent e,
    double scale,
    Set<PointerDeviceKind> scrollKinds,
  ) {
    if (_pointer != null || scrollKinds.contains(e.kind)) return;
    if (e.kind == PointerDeviceKind.mouse && e.buttons != kPrimaryMouseButton) {
      return;
    }
    _pointer = e.pointer;
    final pos = _toPage(e.localPosition, scale);
    _erasing =
        c.tool == DrawTool.eraser || e.kind == PointerDeviceKind.invertedStylus;
    if (_erasing) {
      c.checkpoint();
      _erasedSomething = c.eraseAt(pos, 12);
      return;
    }
    _simulate = e.kind != PointerDeviceKind.stylus;
    _liveColor = c.color;
    _liveSize = c.size;
    _points
      ..clear()
      ..add(_point(e, pos));
    _updateLive();
  }

  void _move(PointerMoveEvent e, double scale) {
    if (e.pointer != _pointer) return;
    final pos = _toPage(e.localPosition, scale);
    if (_erasing) {
      _erasedSomething = c.eraseAt(pos, 12) || _erasedSomething;
      return;
    }
    _points.add(_point(e, pos));
    _updateLive();
  }

  void _up(PointerUpEvent e) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    if (_erasing) {
      _erasing = false;
      if (_erasedSomething) {
        widget.onCommitted();
      } else {
        c.undoCheckpointIfUnused();
      }
      return;
    }
    if (_points.isNotEmpty) {
      final stroke = _makeStroke();
      c.live = null;
      c.addStroke(stroke);
      c.growTo(stroke.bounds.bottom);
      widget.onCommitted();
    }
    _points.clear();
  }

  void _cancel(PointerCancelEvent e) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    if (_erasing) {
      _erasing = false;
      if (_erasedSomething) widget.onCommitted();
      return;
    }
    _points.clear();
    c.live = null;
    c.notifyLive();
  }

  PointVector _point(PointerEvent e, Offset pos) {
    if (e.kind != PointerDeviceKind.stylus) return PointVector(pos.dx, pos.dy);
    final range = e.pressureMax - e.pressureMin;
    final pressure = range > 0 ? (e.pressure - e.pressureMin) / range : 0.5;
    return PointVector(pos.dx, pos.dy, pressure.clamp(0.05, 1.0));
  }

  Stroke _makeStroke() => Stroke(
    points: List.of(_points),
    color: _liveColor,
    size: _liveSize,
    simulatePressure: _simulate,
  );

  void _updateLive() {
    c.live = _makeStroke();
    c.notifyLive();
  }
}

void _paintStroke(Canvas canvas, Stroke s) {
  canvas.drawPath(
    s.path,
    Paint()
      ..color = s.color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true,
  );
}

class _StrokesPainter extends CustomPainter {
  _StrokesPainter(this.strokes, this.scale, this.version);

  final List<Stroke> strokes;
  final double scale;
  final int version;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    canvas.save();
    canvas.scale(scale);
    for (final s in strokes) {
      _paintStroke(canvas, s);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_StrokesPainter old) =>
      old.version != version || old.scale != scale || old.strokes != strokes;
}

class _LivePainter extends CustomPainter {
  _LivePainter(this.stroke, this.scale);

  final Stroke? stroke;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final s = stroke;
    if (s == null) return;
    canvas.save();
    canvas.scale(scale);
    _paintStroke(canvas, s);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LivePainter old) => true;
}
