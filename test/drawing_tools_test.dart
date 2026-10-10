import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:rmoca/drawing/drawing_canvas.dart';
import 'package:rmoca/drawing/shape_recognizer.dart';
import 'package:rmoca/drawing/stroke.dart';
import 'package:rmoca/drawing/svg_codec.dart';

List<Offset> wobbly(List<Offset> pts, {double amp = 2}) => [
  for (var i = 0; i < pts.length; i++)
    pts[i] + Offset(math.sin(i * 1.7) * amp, math.cos(i * 2.3) * amp),
];

List<Offset> polyline(List<Offset> corners, {int perEdge = 12}) {
  final out = <Offset>[];
  for (var i = 0; i < corners.length - 1; i++) {
    for (var s = 0; s < perEdge; s++) {
      out.add(Offset.lerp(corners[i], corners[i + 1], s / perEdge)!);
    }
  }
  out.add(corners.last);
  return out;
}

Stroke stroke(List<Offset> pts, {PenType type = PenType.pen}) => Stroke(
  points: [for (final p in pts) PointVector(p.dx, p.dy, 0.5)],
  color: const Color(0xFF000000),
  size: 4,
  type: type,
);

void main() {
  group('ShapeRecognizer', () {
    test('line', () {
      final r = ShapeRecognizer.recognize(
        wobbly(polyline([const Offset(0, 0), const Offset(200, 100)])),
      );
      expect(r?.kind, ShapeKind.line);
    });

    test('rectangle', () {
      final r = ShapeRecognizer.recognize(
        wobbly(
          polyline([
            const Offset(100, 100),
            const Offset(300, 100),
            const Offset(300, 220),
            const Offset(100, 220),
            const Offset(102, 104),
          ]),
        ),
      );
      expect(r?.kind, ShapeKind.rectangle);
    });

    test('triangle', () {
      final r = ShapeRecognizer.recognize(
        wobbly(
          polyline([
            const Offset(100, 300),
            const Offset(200, 100),
            const Offset(300, 300),
            const Offset(104, 298),
          ]),
        ),
      );
      expect(r?.kind, ShapeKind.triangle);
    });

    test('circle', () {
      final pts = [
        for (var i = 0; i <= 60; i++)
          Offset(
            200 + 80 * math.cos(i / 60 * 2 * math.pi),
            200 + 80 * math.sin(i / 60 * 2 * math.pi),
          ),
      ];
      expect(ShapeRecognizer.recognize(wobbly(pts))?.kind, ShapeKind.ellipse);
    });

    test('free-form scribble is left alone', () {
      final pts = [
        for (var i = 0; i < 80; i++)
          Offset(i * 4.0, 100 + 60 * math.sin(i / 5)),
      ];
      expect(ShapeRecognizer.recognize(pts), isNull);
    });
  });

  test('area eraser cuts a stroke in two', () {
    final s = stroke(polyline([const Offset(0, 0), const Offset(200, 0)]));
    final pieces = s.eraseArea(const Offset(100, 0), 10)!;
    expect(pieces, hasLength(2));
    expect(pieces[0].points.last.x, lessThan(92));
    expect(pieces[1].points.first.x, greaterThan(108));
    expect(s.eraseArea(const Offset(100, 50), 10), isNull);
  });

  test('lasso selects, moves, scales and deletes strokes', () {
    final c = DrawingController(
      Drawing(
        strokes: [
          stroke(polyline([const Offset(10, 10), const Offset(50, 50)])),
          stroke(polyline([const Offset(500, 500), const Offset(550, 550)])),
        ],
      ),
    );
    c.selectInside(Path()..addRect(const Rect.fromLTWH(0, 0, 100, 100)));
    expect(c.selection, {0});

    final originals = {0: c.drawing.strokes[0]};
    c.transformSelection(originals, (s) => s.translated(const Offset(100, 0)));
    expect(c.drawing.strokes[0].points.first.x, 110);

    c.transformSelection(
      originals,
      (s) => s.scaled(const Offset(10, 10), 2, 2),
    );
    expect(c.drawing.strokes[0].points.last.x, 90);

    c.deleteSelection();
    expect(c.drawing.strokes, hasLength(1));
    c.undo();
    expect(c.drawing.strokes, hasLength(2));
  });

  test('pen type and paper survive an SVG round trip', () {
    final d = Drawing(
      strokes: [
        stroke(
          polyline([const Offset(10, 10), const Offset(80, 30)]),
          type: PenType.highlighter,
        ),
        stroke(
          polyline([const Offset(10, 60), const Offset(80, 90)]),
          type: PenType.fountain,
        ),
      ],
      paper: PaperStyle.grid,
    );
    final svg = SvgCodec.encode(d);
    expect(svg, contains('url(#rmoca-paper)'));
    final back = SvgCodec.decode(svg)!;
    expect(back.paper, PaperStyle.grid);
    expect(back.strokes.map((s) => s.type), [
      PenType.highlighter,
      PenType.fountain,
    ]);
    // The highlighter's own transparency is not baked into the color.
    expect(back.strokes.first.color.a, closeTo(1, 0.01));
  });
}
