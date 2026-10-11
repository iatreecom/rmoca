import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/note.dart';
import 'navigation.dart';

/// Notes as dots and their links as lines (Obsidian's graph view). With
/// [focus], only notes within two links of that note are shown.
class GraphScreen extends StatefulWidget {
  const GraphScreen({super.key, this.focus});

  final String? focus;

  @override
  State<GraphScreen> createState() => _GraphScreenState();
}

class _Node {
  _Node(this.note, this.pos);

  final Note note;
  Offset pos;
  Offset velocity = Offset.zero;
  int degree = 0;
}

class _GraphScreenState extends State<GraphScreen>
    with SingleTickerProviderStateMixin {
  static const _size = 3000.0;
  static const _maxNodes = 400;

  final List<_Node> _nodes = [];
  final List<(int, int)> _edges = [];
  late final Ticker _ticker = createTicker(_tick);
  final _view = TransformationController();
  bool _hideOrphans = false;
  int _steps = 0;
  String? _hover;

  @override
  void initState() {
    super.initState();
    _build();
    WidgetsBinding.instance.addPostFrameCallback((_) => _center());
  }

  @override
  void dispose() {
    _ticker.dispose();
    _view.dispose();
    super.dispose();
  }

  void _build() {
    final app = context.read<AppState>();
    final graph = app.linkGraph;
    var paths = graph.keys.toSet();
    final focus = widget.focus;
    if (focus != null) {
      // Two steps out, both directions.
      final undirected = <String, Set<String>>{};
      graph.forEach((from, tos) {
        for (final to in tos) {
          undirected.putIfAbsent(from, () => {}).add(to);
          undirected.putIfAbsent(to, () => {}).add(from);
        }
      });
      var frontier = {focus};
      final seen = {focus};
      for (var depth = 0; depth < 2; depth++) {
        frontier = {for (final p in frontier) ...?undirected[p]}
          ..removeAll(seen);
        seen.addAll(frontier);
      }
      paths = seen;
    }
    final degree = <String, int>{};
    graph.forEach((from, tos) {
      if (!paths.contains(from)) return;
      for (final to in tos.where(paths.contains)) {
        degree[from] = (degree[from] ?? 0) + 1;
        degree[to] = (degree[to] ?? 0) + 1;
      }
    });
    var notes = app.notes.where((n) => paths.contains(n.path)).toList();
    if (_hideOrphans) {
      notes = notes
          .where((n) => (degree[n.path] ?? 0) > 0 || n.path == focus)
          .toList();
    }
    if (notes.length > _maxNodes) {
      notes.sort(
        (a, b) => (degree[b.path] ?? 0).compareTo(degree[a.path] ?? 0),
      );
      notes = notes.take(_maxNodes).toList();
    }
    final rnd = math.Random(42);
    final index = <String, int>{};
    _nodes.clear();
    _edges.clear();
    for (final n in notes) {
      index[n.path] = _nodes.length;
      // Start on a spiral so the layout unfolds evenly.
      final a = _nodes.length * 2.4;
      final r = 20.0 * math.sqrt(_nodes.length + 1);
      _nodes.add(
        _Node(
          n,
          Offset(
            _size / 2 + r * math.cos(a) + rnd.nextDouble(),
            _size / 2 + r * math.sin(a) + rnd.nextDouble(),
          ),
        )..degree = degree[n.path] ?? 0,
      );
    }
    graph.forEach((from, tos) {
      final i = index[from];
      if (i == null) return;
      for (final to in tos) {
        final j = index[to];
        if (j != null && i != j) _edges.add((i, j));
      }
    });
    _steps = 0;
    if (!_ticker.isActive) _ticker.start();
  }

  /// One step of a force-directed layout: nodes repel, links pull.
  void _tick(Duration _) {
    const repulsion = 9000.0, spring = 0.02, length = 90.0, gravity = 0.004;
    final n = _nodes.length;
    final force = List.filled(n, Offset.zero);
    for (var i = 0; i < n; i++) {
      for (var j = i + 1; j < n; j++) {
        var d = _nodes[i].pos - _nodes[j].pos;
        var dist2 = d.distanceSquared;
        if (dist2 < 0.01) {
          d = const Offset(0.1, 0);
          dist2 = 0.01;
        }
        if (dist2 > 250000) continue;
        final f = d / math.sqrt(dist2) * (repulsion / dist2);
        force[i] += f;
        force[j] -= f;
      }
    }
    for (final (i, j) in _edges) {
      final d = _nodes[j].pos - _nodes[i].pos;
      final dist = d.distance;
      if (dist == 0) continue;
      final f = d / dist * ((dist - length) * spring);
      force[i] += f;
      force[j] -= f;
    }
    const center = Offset(_size / 2, _size / 2);
    final cooling = math.max(0.05, 1 - _steps / 400);
    for (var i = 0; i < n; i++) {
      final node = _nodes[i];
      force[i] += (center - node.pos) * gravity;
      node.velocity = (node.velocity + force[i]) * 0.6;
      final v = node.velocity * cooling;
      final capped = v.distance > 30 ? v / v.distance * 30 : v;
      node.pos += capped;
    }
    _steps++;
    if (_steps > 500) _ticker.stop();
    setState(() {});
  }

  void _center() {
    final size = context.size ?? const Size(800, 600);
    final focus = widget.focus;
    final target = focus == null
        ? const Offset(_size / 2, _size / 2)
        : _nodes.where((n) => n.note.path == focus).firstOrNull?.pos ??
              const Offset(_size / 2, _size / 2);
    _view.value = Matrix4.identity()
      ..translateByDouble(
        size.width / 2 - target.dx,
        size.height / 2 - target.dy,
        0,
        1,
      );
  }

  _Node? _hit(Offset p) {
    _Node? best;
    var bestD = double.infinity;
    for (final n in _nodes) {
      final d = (n.pos - p).distance;
      if (d < _radius(n) + 8 && d < bestD) {
        best = n;
        bestD = d;
      }
    }
    return best;
  }

  static double _radius(_Node n) => 5 + math.sqrt(n.degree.toDouble()) * 2.5;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.focus == null ? '그래프' : '연결 그래프'),
        actions: [
          FilterChip(
            label: const Text('연결 없는 메모 숨기기'),
            selected: _hideOrphans,
            onSelected: (v) => setState(() {
              _hideOrphans = v;
              _build();
            }),
          ),
          IconButton(
            tooltip: '가운데로',
            icon: const Icon(Icons.center_focus_strong_rounded),
            onPressed: _center,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _nodes.isEmpty
          ? const Center(child: Text('표시할 메모가 없습니다'))
          : InteractiveViewer(
              transformationController: _view,
              constrained: false,
              minScale: 0.1,
              maxScale: 4,
              boundaryMargin: const EdgeInsets.all(_size),
              child: MouseRegion(
                onHover: (e) {
                  final path = _hit(e.localPosition)?.note.path;
                  if (path != _hover) setState(() => _hover = path);
                },
                cursor: _hover == null
                    ? MouseCursor.defer
                    : SystemMouseCursors.click,
                child: GestureDetector(
                  onTapUp: (e) {
                    final node = _hit(e.localPosition);
                    if (node != null) openNote(context, node.note.path);
                  },
                  child: CustomPaint(
                    size: const Size(_size, _size),
                    painter: _GraphPainter(
                      nodes: _nodes,
                      edges: _edges,
                      focus: widget.focus,
                      hover: _hover,
                      scheme: scheme,
                      scale: _view.value.getMaxScaleOnAxis(),
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

class _GraphPainter extends CustomPainter {
  _GraphPainter({
    required this.nodes,
    required this.edges,
    required this.focus,
    required this.hover,
    required this.scheme,
    required this.scale,
  });

  final List<_Node> nodes;
  final List<(int, int)> edges;
  final String? focus;
  final String? hover;
  final ColorScheme scheme;
  final double scale;

  static const _palette = [
    Color(0xFF5B6CFF),
    Color(0xFF14B8A6),
    Color(0xFFF59E0B),
    Color(0xFFEC4899),
    Color(0xFF8B5CF6),
    Color(0xFF22C55E),
    Color(0xFFEF4444),
    Color(0xFF0EA5E9),
  ];

  Color _colorFor(Note n) {
    if (n.kind == NoteKind.drawing) return scheme.tertiary;
    final top = n.folder.split('/').first;
    if (top.isEmpty) return scheme.primary;
    return _palette[top.hashCode.abs() % _palette.length];
  }

  @override
  void paint(Canvas canvas, Size size) {
    final hi = hover ?? focus;
    final linked = <int>{};
    if (hi != null) {
      final h = nodes.indexWhere((n) => n.note.path == hi);
      for (final (i, j) in edges) {
        if (i == h) linked.add(j);
        if (j == h) linked.add(i);
      }
      linked.add(h);
    }
    final line = Paint()
      ..strokeWidth = 1.2
      ..color = scheme.outlineVariant;
    final strong = Paint()
      ..strokeWidth = 2
      ..color = scheme.primary.withValues(alpha: 0.8);
    for (final (i, j) in edges) {
      final emphasized =
          hi != null &&
          linked.contains(i) &&
          linked.contains(j) &&
          (nodes[i].note.path == hi || nodes[j].note.path == hi);
      canvas.drawLine(nodes[i].pos, nodes[j].pos, emphasized ? strong : line);
    }
    for (var i = 0; i < nodes.length; i++) {
      final n = nodes[i];
      final dim = hi != null && !linked.contains(i);
      final r = _GraphScreenState._radius(n);
      final color = _colorFor(n.note).withValues(alpha: dim ? 0.3 : 1);
      canvas.drawCircle(n.pos, r, Paint()..color = color);
      if (n.note.path == hi) {
        canvas.drawCircle(
          n.pos,
          r + 4,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = scheme.primary,
        );
      }
      // Labels when zoomed in, or for well-connected / highlighted notes.
      if (scale > 0.6 || n.degree >= 3 || linked.contains(i)) {
        final tp = TextPainter(
          text: TextSpan(
            text: n.note.title,
            style: TextStyle(
              fontSize: 12,
              color: scheme.onSurface.withValues(alpha: dim ? 0.35 : 0.9),
              fontWeight: n.note.path == hi ? FontWeight.w700 : null,
            ),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
          ellipsis: '…',
        )..layout(maxWidth: 160);
        tp.paint(canvas, n.pos + Offset(-tp.width / 2, r + 3));
      }
    }
  }

  @override
  bool shouldRepaint(_GraphPainter old) => true;
}
