import 'dart:math' as math;
import 'dart:ui';

import 'package:perfect_freehand/perfect_freehand.dart';

enum ShapeKind { line, triangle, rectangle, ellipse }

/// Turns a rough hand-drawn line, triangle, rectangle or circle into a clean
/// one (Samsung Notes' "auto shape"). Returns null for free-form strokes.
class ShapeRecognizer {
  static ({ShapeKind kind, List<PointVector> points})? recognize(
    List<Offset> input,
  ) {
    if (input.length < 4) return null;
    final bounds = _bounds(input);
    final diag = math.sqrt(
      bounds.width * bounds.width + bounds.height * bounds.height,
    );
    if (diag < 20) return null;

    final length = _length(input);
    final gap = (input.first - input.last).distance;
    final closed = gap < length * 0.15;

    if (!closed) {
      // A straight line: every point stays close to the chord.
      final maxDev = input
          .map((p) => _distToSegment(p, input.first, input.last))
          .reduce(math.max);
      if (maxDev < diag * 0.06) {
        return (
          kind: ShapeKind.line,
          points: _sample([input.first, input.last], closed: false),
        );
      }
      return null;
    }

    final corners = _rdp(input, diag * 0.09);
    // RDP keeps the first and last (≈ same) points; drop the duplicate.
    if (corners.length > 1 &&
        (corners.first - corners.last).distance < diag * 0.15) {
      corners.removeLast();
    }

    if (corners.length == 3) {
      return (kind: ShapeKind.triangle, points: _sample(corners, closed: true));
    }
    if (corners.length == 4 && _isAxisRectangle(corners, bounds)) {
      final r = bounds;
      return (
        kind: ShapeKind.rectangle,
        points: _sample([
          r.topLeft,
          r.topRight,
          r.bottomRight,
          r.bottomLeft,
        ], closed: true),
      );
    }
    if (corners.length == 4) {
      return (
        kind: ShapeKind.rectangle,
        points: _sample(corners, closed: true),
      );
    }

    // Ellipse: distance to the bounding ellipse stays small.
    final c = bounds.center;
    final rx = bounds.width / 2, ry = bounds.height / 2;
    if (rx < 5 || ry < 5) return null;
    var err = 0.0;
    for (final p in input) {
      final nx = (p.dx - c.dx) / rx, ny = (p.dy - c.dy) / ry;
      err += (math.sqrt(nx * nx + ny * ny) - 1).abs();
    }
    if (err / input.length < 0.18) {
      const n = 72;
      return (
        kind: ShapeKind.ellipse,
        points: [
          for (var i = 0; i <= n; i++)
            PointVector(
              c.dx + rx * math.cos(2 * math.pi * i / n),
              c.dy + ry * math.sin(2 * math.pi * i / n),
              0.5,
            ),
        ],
      );
    }
    return null;
  }

  static bool _isAxisRectangle(List<Offset> corners, Rect b) {
    final tol = math.max(b.width, b.height) * 0.18;
    final targets = [b.topLeft, b.topRight, b.bottomRight, b.bottomLeft];
    return targets.every((t) => corners.any((c) => (c - t).distance < tol));
  }

  /// Points along the polygon edges, so the stroke renders evenly.
  static List<PointVector> _sample(
    List<Offset> vertices, {
    required bool closed,
  }) {
    final pts = <PointVector>[];
    final edges = closed ? vertices.length : vertices.length - 1;
    for (var i = 0; i < edges; i++) {
      final a = vertices[i];
      final b = vertices[(i + 1) % vertices.length];
      final steps = math.max(2, ((b - a).distance / 8).ceil());
      // Repeat the corner so stroke smoothing keeps it sharp.
      pts.add(PointVector(a.dx, a.dy, 0.5));
      pts.add(PointVector(a.dx, a.dy, 0.5));
      for (var s = 0; s < steps; s++) {
        final t = s / steps;
        pts.add(
          PointVector(a.dx + (b.dx - a.dx) * t, a.dy + (b.dy - a.dy) * t, 0.5),
        );
      }
    }
    final end = closed ? vertices.first : vertices.last;
    for (var i = 0; i < 3; i++) {
      pts.add(PointVector(end.dx, end.dy, 0.5));
    }
    return pts;
  }

  static Rect _bounds(List<Offset> pts) {
    var l = pts.first.dx, t = pts.first.dy, r = l, b = t;
    for (final p in pts) {
      l = math.min(l, p.dx);
      t = math.min(t, p.dy);
      r = math.max(r, p.dx);
      b = math.max(b, p.dy);
    }
    return Rect.fromLTRB(l, t, r, b);
  }

  static double _length(List<Offset> pts) {
    var len = 0.0;
    for (var i = 1; i < pts.length; i++) {
      len += (pts[i] - pts[i - 1]).distance;
    }
    return len;
  }

  static double _distToSegment(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
    var t = len2 == 0 ? 0.0 : ((p - a).dx * ab.dx + (p - a).dy * ab.dy) / len2;
    t = t.clamp(0.0, 1.0);
    return (p - (a + ab * t)).distance;
  }

  /// Ramer–Douglas–Peucker simplification.
  static List<Offset> _rdp(List<Offset> pts, double epsilon) {
    if (pts.length < 3) return List.of(pts);
    var maxDist = 0.0;
    var index = 0;
    for (var i = 1; i < pts.length - 1; i++) {
      final d = _distToSegment(pts[i], pts.first, pts.last);
      if (d > maxDist) {
        maxDist = d;
        index = i;
      }
    }
    // A closed stroke's chord is ~0, so split at the farthest point first.
    if ((pts.first - pts.last).distance < epsilon) {
      var far = 0.0;
      for (var i = 1; i < pts.length - 1; i++) {
        final d = (pts[i] - pts.first).distance;
        if (d > far) {
          far = d;
          index = i;
        }
      }
      final left = _rdp(pts.sublist(0, index + 1), epsilon);
      final right = _rdp(pts.sublist(index), epsilon);
      return [...left.sublist(0, left.length - 1), ...right];
    }
    if (maxDist <= epsilon) return [pts.first, pts.last];
    final left = _rdp(pts.sublist(0, index + 1), epsilon);
    final right = _rdp(pts.sublist(index), epsilon);
    return [...left.sublist(0, left.length - 1), ...right];
  }
}
