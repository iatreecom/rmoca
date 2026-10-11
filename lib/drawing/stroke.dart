import 'dart:ui';

import 'package:flutter/material.dart'
    show Icons, IconData, TextPainter, TextSpan, TextStyle, TextDirection;
import 'package:perfect_freehand/perfect_freehand.dart';

/// Pen styles, like Samsung Notes' pen types.
enum PenType {
  pen('펜', Icons.edit_rounded, opacity: 1, sizeFactor: 1, thinning: 0.45),
  fountain(
    '만년필',
    Icons.history_edu_rounded,
    opacity: 1,
    sizeFactor: 1.6,
    thinning: 0.6,
    taper: true,
  ),
  pencil(
    '연필',
    Icons.create_outlined,
    opacity: 0.7,
    sizeFactor: 0.7,
    thinning: 0.15,
  ),
  brush(
    '붓',
    Icons.brush_rounded,
    opacity: 0.95,
    sizeFactor: 2.2,
    thinning: 0.9,
    taper: true,
  ),
  highlighter(
    '형광펜',
    Icons.highlight_rounded,
    opacity: 0.35,
    sizeFactor: 3.5,
    thinning: 0,
  );

  const PenType(
    this.label,
    this.icon, {
    required this.opacity,
    required this.sizeFactor,
    required this.thinning,
    this.taper = false,
  });

  final String label;
  final IconData icon;

  /// Ink opacity multiplied into the stroke color.
  final double opacity;

  /// Width relative to the chosen size.
  final double sizeFactor;
  final double thinning;
  final bool taper;

  static PenType byName(String? name) =>
      PenType.values.where((t) => t.name == name).firstOrNull ?? PenType.pen;
}

/// One pen stroke: raw input points (with pressure) plus style.
///
/// The filled outline is derived from the points with perfect_freehand, which
/// gives pressure-sensitive, smooth ink in both Flutter and the SVG file.
class Stroke {
  Stroke({
    required this.points,
    required this.color,
    required this.size,
    this.simulatePressure = false,
    this.type = PenType.pen,
    this.text,
  });

  /// A text box: [text] drawn with its top-left at the single point, in
  /// [size] font size. Moves, scales, erases and undoes like ink.
  factory Stroke.text(String text, Offset at, Color color, double fontSize) =>
      Stroke(
        points: [PointVector(at.dx, at.dy)],
        color: color,
        size: fontSize,
        text: text,
      );

  final List<PointVector> points;

  /// Non-null for a text box.
  final String? text;

  bool get isText => text != null;

  TextPainter? _painter;

  /// Laid-out text of a text box.
  TextPainter get textPainter => _painter ??= TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(color: inkColor, fontSize: size, height: textLineHeight),
    ),
    textDirection: TextDirection.ltr,
  )..layout();

  static const textLineHeight = 1.3;

  Offset get anchor => Offset(points.first.x, points.first.y);

  /// Base color; [type]'s opacity is applied on top when painting.
  final Color color;
  final double size;

  /// True for mouse/finger input, which reports no real pressure.
  final bool simulatePressure;
  final PenType type;

  List<Offset>? _outline;
  Path? _path;

  /// Color actually painted.
  Color get inkColor => color.withValues(alpha: color.a * type.opacity);

  StrokeOptions get options => StrokeOptions(
    size: size * type.sizeFactor,
    thinning: type.thinning,
    smoothing: 0.5,
    streamline: 0.5,
    // Highlighters keep an even width.
    simulatePressure: simulatePressure && type != PenType.highlighter,
    start: StrokeEndOptions.start(
      taperEnabled: type.taper,
      customTaper: type.taper ? size * 4 : null,
    ),
    end: StrokeEndOptions.end(
      taperEnabled: type.taper,
      customTaper: type.taper ? size * 4 : null,
    ),
    isComplete: true,
  );

  List<Offset> get outline => _outline ??= getStroke(
    type == PenType.highlighter
        ? [for (final p in points) PointVector(p.x, p.y, 0.5)]
        : points,
    options: options,
  );

  Path get path =>
      _path ??= isText ? (Path()..addRect(bounds)) : outlineToPath(outline);

  Rect get bounds => isText
      ? anchor & Size(textPainter.width, textPainter.height)
      : path.getBounds();

  Stroke copyWith({
    List<PointVector>? points,
    Color? color,
    double? size,
    PenType? type,
    String? text,
  }) => Stroke(
    points: points ?? this.points,
    color: color ?? this.color,
    size: size ?? this.size,
    simulatePressure: simulatePressure,
    type: type ?? this.type,
    text: text ?? this.text,
  );

  /// Moved by [delta].
  Stroke translated(Offset delta) => copyWith(
    points: [
      for (final p in points)
        PointVector(p.x + delta.dx, p.y + delta.dy, p.pressure),
    ],
  );

  /// Scaled around [origin] (width scales with the average factor).
  Stroke scaled(Offset origin, double sx, double sy) => copyWith(
    points: [
      for (final p in points)
        PointVector(
          origin.dx + (p.x - origin.dx) * sx,
          origin.dy + (p.y - origin.dy) * sy,
          p.pressure,
        ),
    ],
    size: (size * (sx.abs() + sy.abs()) / 2).clamp(0.5, 200),
  );

  /// Smooth closed path through the outline using quadratic midpoints,
  /// mirroring perfect-freehand's `getSvgPathFromStroke`.
  static Path outlineToPath(List<Offset> pts) {
    final path = Path();
    if (pts.isEmpty) return path;
    if (pts.length < 3) {
      final c = pts.first;
      return path..addOval(Rect.fromCircle(center: c, radius: 1));
    }
    path.moveTo(pts[0].dx, pts[0].dy);
    for (var i = 0; i < pts.length; i++) {
      final a = pts[i];
      final b = pts[(i + 1) % pts.length];
      path.quadraticBezierTo(a.dx, a.dy, (a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
    }
    return path..close();
  }

  /// SVG path data equivalent to [path].
  String svgPathData() {
    final pts = outline;
    if (pts.isEmpty) return '';
    String f(double v) => v.toStringAsFixed(2);
    if (pts.length < 3) {
      final c = pts.first;
      return 'M${f(c.dx - 1)},${f(c.dy)}a1,1 0 1,0 2,0a1,1 0 1,0 -2,0Z';
    }
    final b = StringBuffer('M${f(pts[0].dx)},${f(pts[0].dy)}');
    for (var i = 0; i < pts.length; i++) {
      final a = pts[i];
      final n = pts[(i + 1) % pts.length];
      b.write(
        'Q${f(a.dx)},${f(a.dy)} ${f((a.dx + n.dx) / 2)},${f((a.dy + n.dy) / 2)}',
      );
    }
    b.write('Z');
    return b.toString();
  }

  double get _halfWidth => size * type.sizeFactor / 2;

  /// Whether [point] is within [radius] of this stroke (for the eraser).
  bool hitTest(Offset point, double radius) {
    if (!bounds.inflate(radius).contains(point)) return false;
    if (isText) return true;
    if (path.contains(point)) return true;
    final r = radius + _halfWidth;
    final r2 = r * r;
    for (var i = 0; i < points.length; i++) {
      final a = points[i];
      final b = i + 1 < points.length ? points[i + 1] : a;
      if (_distSqToSegment(point, a, b) <= r2) return true;
    }
    return false;
  }

  /// Area eraser: removes the part of the stroke within [radius] of
  /// [point]. Returns the remaining pieces, or null if nothing was erased.
  List<Stroke>? eraseArea(Offset point, double radius) {
    if (!bounds.inflate(radius).contains(point)) return null;
    // Text cannot be cut: the whole box goes.
    if (isText) return const [];
    final r = radius + _halfWidth * 0.5;
    final r2 = r * r;
    // Densify so long segments can be cut in the middle.
    final dense = <PointVector>[];
    for (var i = 0; i < points.length; i++) {
      final a = points[i];
      dense.add(a);
      if (i + 1 < points.length) {
        final b = points[i + 1];
        final steps = ((b - a).distance / (radius / 2)).floor();
        for (var s = 1; s < steps; s++) {
          final t = s / steps;
          dense.add(
            PointVector(
              a.x + (b.x - a.x) * t,
              a.y + (b.y - a.y) * t,
              a.pressure == null || b.pressure == null
                  ? null
                  : a.pressure! + (b.pressure! - a.pressure!) * t,
            ),
          );
        }
      }
    }
    final pieces = <List<PointVector>>[[]];
    var erased = false;
    for (final p in dense) {
      if ((p - point).distanceSquared <= r2) {
        erased = true;
        if (pieces.last.isNotEmpty) pieces.add([]);
      } else {
        pieces.last.add(p);
      }
    }
    if (!erased) return null;
    return [
      for (final piece in pieces)
        if (piece.length > 1) copyWith(points: piece),
    ];
  }

  static double _distSqToSegment(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
    var t = len2 == 0 ? 0.0 : ((p - a).dx * ab.dx + (p - a).dy * ab.dy) / len2;
    t = t.clamp(0.0, 1.0);
    final proj = a + ab * t;
    return (p - proj).distanceSquared;
  }
}
