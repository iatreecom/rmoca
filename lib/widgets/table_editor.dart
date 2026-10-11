import 'package:flutter/material.dart';

import '../markdown/md_table.dart';

/// Edits a markdown table as a grid. Returns the edited table, or null when
/// cancelled. A result with no rows and only empty header cells means
/// "delete the table".
Future<MdTable?> showTableEditor(BuildContext context, MdTable table) =>
    Navigator.of(context).push<MdTable>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _TableEditor(table: table.copy()),
      ),
    );

class _TableEditor extends StatefulWidget {
  const _TableEditor({required this.table});

  final MdTable table;

  @override
  State<_TableEditor> createState() => _TableEditorState();
}

class _TableEditorState extends State<_TableEditor> {
  MdTable get t => widget.table;

  // Controllers are rebuilt whenever the shape changes.
  late List<TextEditingController> _head;
  late List<List<TextEditingController>> _cells;

  @override
  void initState() {
    super.initState();
    _rebuild();
  }

  void _rebuild() {
    _head = [for (final h in t.header) TextEditingController(text: h)];
    _cells = [
      for (final r in t.rows)
        [for (final c in r) TextEditingController(text: c)],
    ];
  }

  void _pull() {
    for (var c = 0; c < t.columns; c++) {
      t.header[c] = _head[c].text;
      for (var r = 0; r < t.rows.length; r++) {
        t.rows[r][c] = _cells[r][c].text;
      }
    }
  }

  void _reshape(void Function() change) {
    _pull();
    final old = [..._head, for (final r in _cells) ...r];
    setState(() {
      change();
      _rebuild();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final c in old) {
        c.dispose();
      }
    });
  }

  @override
  void dispose() {
    for (final c in [..._head, for (final r in _cells) ...r]) {
      c.dispose();
    }
    super.dispose();
  }

  TextAlign _align(ColumnAlign a) => switch (a) {
    ColumnAlign.center => TextAlign.center,
    ColumnAlign.right => TextAlign.right,
    _ => TextAlign.left,
  };

  IconData _alignIcon(ColumnAlign a) => switch (a) {
    ColumnAlign.center => Icons.format_align_center_rounded,
    ColumnAlign.right => Icons.format_align_right_rounded,
    ColumnAlign.left => Icons.format_align_left_rounded,
    ColumnAlign.none => Icons.format_align_justify_rounded,
  };

  Widget _cell(TextEditingController c, ColumnAlign a, {bool header = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 160,
      decoration: BoxDecoration(
        color: header ? scheme.secondaryContainer : scheme.surface,
        border: Border.all(color: scheme.outlineVariant, width: 0.5),
      ),
      child: TextField(
        controller: c,
        textAlign: _align(a),
        maxLines: null,
        style: TextStyle(fontWeight: header ? FontWeight.w700 : null),
        decoration: const InputDecoration(
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('표 편집'),
        actions: [
          IconButton(
            tooltip: '표 삭제',
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: () =>
                Navigator.pop(context, MdTable([''], [ColumnAlign.none], [])),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: () {
                _pull();
                Navigator.pop(context, t);
              },
              child: const Text('완료'),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Column tools.
              Row(
                children: [
                  const SizedBox(width: 44),
                  for (var c = 0; c < t.columns; c++)
                    SizedBox(
                      width: 160,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            tooltip: '정렬',
                            visualDensity: VisualDensity.compact,
                            icon: Icon(_alignIcon(t.aligns[c]), size: 18),
                            onPressed: () =>
                                setState(() => t.aligns[c] = t.aligns[c].next),
                          ),
                          IconButton(
                            tooltip: '왼쪽에 열 추가',
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.add_rounded, size: 18),
                            onPressed: () => _reshape(() => t.addColumn(c)),
                          ),
                          IconButton(
                            tooltip: '열 삭제',
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.close_rounded, size: 18),
                            onPressed: t.columns <= 1
                                ? null
                                : () => _reshape(() => t.removeColumn(c)),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
              Row(
                children: [
                  const SizedBox(width: 44),
                  for (var c = 0; c < t.columns; c++)
                    _cell(_head[c], t.aligns[c], header: true),
                  IconButton(
                    tooltip: '열 추가',
                    icon: const Icon(Icons.add_box_outlined),
                    onPressed: () => _reshape(t.addColumn),
                  ),
                ],
              ),
              for (var r = 0; r < t.rows.length; r++)
                Row(
                  children: [
                    SizedBox(
                      width: 44,
                      child: IconButton(
                        tooltip: '행 삭제',
                        visualDensity: VisualDensity.compact,
                        icon: Icon(
                          Icons.remove_circle_outline_rounded,
                          size: 18,
                          color: scheme.outline,
                        ),
                        onPressed: () => _reshape(() => t.removeRow(r)),
                      ),
                    ),
                    for (var c = 0; c < t.columns; c++)
                      _cell(_cells[r][c], t.aligns[c]),
                  ],
                ),
              Padding(
                padding: const EdgeInsets.only(left: 44, top: 8),
                child: OutlinedButton.icon(
                  onPressed: () => _reshape(t.addRow),
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('행 추가'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
