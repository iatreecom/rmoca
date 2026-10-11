import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:rmoca/drawing/stroke.dart';
import 'package:rmoca/drawing/svg_codec.dart';

void main() {
  test('drawing round-trips through SVG', () {
    final drawing = Drawing(
      strokes: [
        Stroke(
          points: const [
            PointVector(10, 10, 0.3),
            PointVector(50, 60, 0.8),
            PointVector(90, 20, 0.5),
          ],
          color: const Color(0xFF1E5EFF),
          size: 6,
        ),
        Stroke(
          points: const [PointVector(5, 5), PointVector(6, 6)],
          color: const Color(0x66FFE14D),
          size: 20,
          simulatePressure: true,
        ),
      ],
      height: 2000,
    );

    final svg = SvgCodec.encode(drawing);
    expect(svg, contains('<svg'));
    expect(svg, contains('data-page-height="2000"'));

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
    expect(
      SvgCodec.decode(
        '<svg xmlns="http://www.w3.org/2000/svg"><circle r="4"/></svg>',
      ),
      isNull,
    );
    expect(SvgCodec.decode('not xml'), isNull);
  });

  test('visible area is cropped to the ink but the page is kept', () {
    final drawing = Drawing(
      strokes: [
        Stroke(
          points: const [PointVector(400, 500), PointVector(450, 520)],
          color: const Color(0xFF000000),
          size: 4,
        ),
      ],
    );
    final svg = SvgCodec.encode(drawing);
    final viewBox = RegExp(r'viewBox="([^"]+)"').firstMatch(svg)!.group(1)!;
    final v = viewBox.split(' ').map(double.parse).toList();
    expect(v[0], lessThan(400));
    expect(v[0], greaterThan(300));
    expect(v[2], lessThan(200)); // Far narrower than the 1000 wide page.

    final decoded = SvgCodec.decode(svg)!;
    expect(decoded.width, Drawing.defaultWidth);
    expect(decoded.height, Drawing.defaultHeight);
    expect(decoded.strokes.single.points.first.x, 400);
  });

  test('text boxes round-trip as SVG text and erase as a whole', () {
    final d = Drawing(
      strokes: [
        Stroke.text(
          '첫 줄\n둘째 <줄> & "따옴표"',
          const Offset(100, 200),
          const Color(0xFF2563EB),
          32,
        ),
        Stroke(
          points: [PointVector(10, 10, 0.5), PointVector(50, 50, 0.5)],
          color: const Color(0xFF000000),
          size: 4,
        ),
      ],
    );
    final svg = SvgCodec.encode(d);
    expect(svg, contains('<text'));
    expect(svg, contains('<tspan'));
    final back = SvgCodec.decode(svg)!;
    expect(back.strokes, hasLength(2));
    final t = back.strokes.firstWhere((s) => s.isText);
    expect(t.text, '첫 줄\n둘째 <줄> & "따옴표"');
    expect(t.anchor, const Offset(100, 200));
    expect(t.size, 32);
    expect(t.color.toARGB32(), 0xFF2563EB);

    // Moving and scaling keep it a text box.
    final moved = t
        .translated(const Offset(10, 5))
        .scaled(const Offset(110, 205), 2, 2);
    expect(moved.isText, isTrue);
    expect(moved.anchor, const Offset(110, 205));
    expect(moved.size, 64);

    // The area eraser removes the whole box.
    expect(t.eraseArea(t.bounds.center, 4), isEmpty);
    expect(t.hitTest(t.bounds.center, 1), isTrue);
  });
}
