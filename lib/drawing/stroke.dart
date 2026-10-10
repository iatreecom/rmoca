import 'dart:ui';

import 'package:perfect_freehand/perfect_freehand.dart';

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
  });

  final List<PointVector> points;
  final Color color;
  final double size;

  /// True for mouse/finger input, which reports no real pressure.
  final bool simulatePressure;

  List<Offset>? _outline;
  Path? _path;

  StrokeOptions get options => StrokeOptions(
    size: size,
    thinning: 0.6,
    smoothing: 0.5,
    streamline: 0.5,
    simulatePressure: simulatePressure,
    isComplete: true,
  );

  List<Offset> get outline => _outline ??= getStroke(points, options: options);

  Path get path => _path ??= outlineToPath(outline);

  Rect get bounds => path.getBounds();

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

  /// Whether [point] is within [radius] of this stroke (for the eraser).
  bool hitTest(Offset point, double radius) {
    if (!bounds.inflate(radius).contains(point)) return false;
    if (path.contains(point)) return true;
    final r2 = radius * radius;
    for (var i = 0; i < points.length; i++) {
      final a = points[i];
      final b = i + 1 < points.length ? points[i + 1] : a;
      if (_distSqToSegment(point, a, b) <= r2 + size * size / 4) return true;
    }
    return false;
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
