import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:rmoca/drawing/stroke.dart';
import 'package:rmoca/drawing/svg_codec.dart';

void main() {
  test('drawing round-trips through SVG', () {
    final drawing = Drawing(strokes: [
      Stroke(
        points: const [PointVector(10, 10, 0.3), PointVector(50, 60, 0.8), PointVector(90, 20, 0.5)],
        color: const Color(0xFF1E5EFF),
        size: 6,
      ),
      Stroke(
        points: const [PointVector(5, 5), PointVector(6, 6)],
        color: const Color(0x66FFE14D),
        size: 20,
        simulatePressure: true,
      ),
    ], height: 2000);

    final svg = SvgCodec.encode(drawing);
    expect(svg, contains('<svg'));
    expect(svg, contains('viewBox="0 0 1000 2000"'));

    final decoded = SvgCodec.decode(svg)!;
    expect(decoded.height, 2000);
    expect(decoded.strokes, hasLength(2));
    final a = decoded.strokes[0];
    expect(a.color.toARGB32(), 0xFF1E5EFF);
    expect(a.size, 6);
    expect(a.points[1].x, 50);
    expect(a.points[1].pressure, 0.8);
    final b = decoded.strokes[1];
    expect(b.simulatePressure, isTrue);
    expect(b.color.a, closeTo(0.4, 0.01));
  });

  test('foreign SVGs are not editable', () {
    expect(SvgCodec.decode('<svg xmlns="http://www.w3.org/2000/svg"><circle r="4"/></svg>'), isNull);
    expect(SvgCodec.decode('not xml'), isNull);
  });
}
