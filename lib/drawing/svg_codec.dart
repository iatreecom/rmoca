import 'dart:ui';

import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:xml/xml.dart';

import 'stroke.dart';

/// Page background, like note paper.
enum PaperStyle {
  plain('무지'),
  lined('줄'),
  grid('모눈'),
  dots('점');

  const PaperStyle(this.label);

  final String label;

  static PaperStyle byName(String? name) =>
      PaperStyle.values.where((p) => p.name == name).firstOrNull ??
      PaperStyle.plain;

  /// Spacing of lines/dots in page units.
  static const double spacing = 36;
}

/// A drawing page: fixed width, height grows as you draw further down.
class Drawing {
  Drawing({
    required this.strokes,
    this.width = defaultWidth,
    this.height = defaultHeight,
    this.paper = PaperStyle.plain,
  });

  static const double defaultWidth = 1000;
  static const double defaultHeight = 1400;

  final List<Stroke> strokes;
  double width;
  double height;
  PaperStyle paper;
}

/// Reads and writes drawings as standard SVG.
///
/// Each stroke becomes a filled `<path>` that any SVG viewer (GitHub, a
/// browser, Finder preview) can render. The raw pen points are kept in a
/// `data-points` attribute so the drawing can be edited again later.
class SvgCodec {
  static const _marker = 'rmoca-drawing';

  /// Blank space kept around the ink when cropping.
  static const double margin = 24;

  /// Encodes [d] as a standalone `.svg` file, or with [embedId] as an
  /// `<svg>` element (no XML declaration) to put inside a markdown note.
  static String encode(Drawing d, {String? embedId}) {
    // Crop the visible area to the ink so thumbnails, embeds and GitHub show
    // the drawing rather than a mostly blank page. Coordinates are unchanged;
    // the page size is kept in data-page-* for editing.
    final page = Rect.fromLTWH(0, 0, d.width, d.height);
    final view = d.strokes.isEmpty
        ? page
        : d.strokes
              .map((s) => s.bounds)
              .reduce((a, b) => a.expandToInclude(b))
              .inflate(margin)
              .intersect(page);
    final b = XmlBuilder();
    if (embedId == null) {
      b.processing('xml', 'version="1.0" encoding="UTF-8"');
    }
    b.element(
      'svg',
      attributes: {
        'xmlns': 'http://www.w3.org/2000/svg',
        'width': _num(view.width),
        'height': _num(view.height),
        'viewBox':
            '${_num(view.left)} ${_num(view.top)} ${_num(view.width)} ${_num(view.height)}',
        'data-generator': _marker,
        'data-id': ?embedId,
        'data-page-width': _num(d.width),
        'data-page-height': _num(d.height),
        if (d.paper != PaperStyle.plain) 'data-paper': d.paper.name,
      },
      nest: () {
        final rect = {
          'x': _num(view.left),
          'y': _num(view.top),
          'width': _num(view.width),
          'height': _num(view.height),
        };
        b.element('rect', attributes: {...rect, 'fill': '#ffffff'});
        if (d.paper != PaperStyle.plain) {
          _paperPattern(b, d.paper);
          b.element('rect', attributes: {...rect, 'fill': 'url(#rmoca-paper)'});
        }
        for (final s in d.strokes) {
          b.element(
            'path',
            attributes: {
              'd': s.svgPathData(),
              'fill': _hex(s.color),
              if (s.inkColor.a < 1)
                'fill-opacity': s.inkColor.a.toStringAsFixed(3),
              'data-size': _num(s.size),
              if (s.type != PenType.pen) 'data-tool': s.type.name,
              if (s.simulatePressure) 'data-simulate-pressure': 'true',
              'data-points': s.points
                  .map(
                    (p) =>
                        '${_num(p.x)},${_num(p.y)},${(p.pressure ?? 0.5).toStringAsFixed(2)}',
                  )
                  .join(' '),
            },
          );
        }
      },
    );
    return b.buildDocument().toXmlString(pretty: true, indent: '  ');
  }

  /// Parses an SVG written by [encode]. Returns null for SVGs from other
  /// tools, which the app shows read-only.
  static Drawing? decode(String svg) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(svg);
    } on XmlException {
      return null;
    }
    final root = doc.rootElement;
    if (root.name.local != 'svg' ||
        root.getAttribute('data-generator') != _marker) {
      return null;
    }
    final strokes = <Stroke>[];
    for (final el in root.findAllElements('path')) {
      final raw = el.getAttribute('data-points');
      if (raw == null || raw.trim().isEmpty) continue;
      final points = <PointVector>[];
      for (final triple in raw.trim().split(RegExp(r'\s+'))) {
        final v = triple.split(',').map(double.tryParse).toList();
        if (v.length < 2 || v[0] == null || v[1] == null) continue;
        points.add(PointVector(v[0]!, v[1]!, v.length > 2 ? v[2] : null));
      }
      if (points.isEmpty) continue;
      final type = PenType.byName(el.getAttribute('data-tool'));
      var color = _parseHex(el.getAttribute('fill')) ?? const Color(0xFF000000);
      final opacity = double.tryParse(el.getAttribute('fill-opacity') ?? '');
      if (opacity != null) {
        // fill-opacity includes the pen type's own opacity.
        color = color.withValues(alpha: (opacity / type.opacity).clamp(0, 1));
      }
      strokes.add(
        Stroke(
          points: points,
          color: color,
          size: double.tryParse(el.getAttribute('data-size') ?? '') ?? 4,
          simulatePressure: el.getAttribute('data-simulate-pressure') == 'true',
          type: type,
        ),
      );
    }
    return Drawing(
      strokes: strokes,
      width: _attr(root, 'data-page-width', 'width') ?? Drawing.defaultWidth,
      height:
          _attr(root, 'data-page-height', 'height') ?? Drawing.defaultHeight,
      paper: PaperStyle.byName(root.getAttribute('data-paper')),
    );
  }

  /// Note-paper pattern in page coordinates so GitHub shows it too.
  static void _paperPattern(XmlBuilder b, PaperStyle paper) {
    const s = PaperStyle.spacing;
    const ink = '#d5dae5';
    b.element(
      'defs',
      nest: () => b.element(
        'pattern',
        attributes: {
          'id': 'rmoca-paper',
          'patternUnits': 'userSpaceOnUse',
          'width': _num(s),
          'height': _num(s),
        },
        nest: () {
          switch (paper) {
            case PaperStyle.lined:
              b.element(
                'path',
                attributes: {
                  'd': 'M0,${_num(s - 0.5)}H${_num(s)}',
                  'stroke': ink,
                  'stroke-width': '1',
                },
              );
            case PaperStyle.grid:
              b.element(
                'path',
                attributes: {
                  'd': 'M${_num(s)},0V${_num(s)}M0,${_num(s)}H${_num(s)}',
                  'stroke': ink,
                  'stroke-width': '1',
                  'fill': 'none',
                },
              );
            case PaperStyle.dots:
              b.element(
                'circle',
                attributes: {
                  'cx': _num(s / 2),
                  'cy': _num(s / 2),
                  'r': '1.8',
                  'fill': '#c3c9d6',
                },
              );
            case PaperStyle.plain:
              break;
          }
        },
      ),
    );
  }

  static double? _attr(XmlElement el, String name, String fallback) =>
      double.tryParse(el.getAttribute(name) ?? el.getAttribute(fallback) ?? '');

  static String _num(double v) {
    final s = v.toStringAsFixed(1);
    return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  }

  static String _hex(Color c) {
    String h(double v) =>
        (v * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
    return '#${h(c.r)}${h(c.g)}${h(c.b)}';
  }

  static Color? _parseHex(String? value) {
    if (value == null || !value.startsWith('#')) return null;
    var hex = value.substring(1);
    if (hex.length == 3) hex = hex.split('').map((c) => '$c$c').join();
    final v = int.tryParse(hex, radix: 16);
    return v == null || hex.length != 6 ? null : Color(0xFF000000 | v);
  }
}
