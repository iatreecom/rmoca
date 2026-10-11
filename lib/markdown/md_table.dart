/// A GitHub-flavored markdown table, for the visual table editor.
class MdTable {
  MdTable(this.header, this.aligns, this.rows);

  /// An empty table with [cols] columns and [rowCount] body rows.
  factory MdTable.blank(int cols, int rowCount) => MdTable(
    [for (var c = 0; c < cols; c++) '열 ${c + 1}'],
    List.filled(cols, ColumnAlign.none, growable: true),
    [for (var r = 0; r < rowCount; r++) List.filled(cols, '', growable: true)],
  );

  final List<String> header;
  final List<ColumnAlign> aligns;
  final List<List<String>> rows;

  int get columns => header.length;

  static MdTable? parse(String text) {
    final lines = text
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.length < 2) return null;
    final header = _cells(lines[0]);
    final sep = _cells(lines[1]);
    if (sep.isEmpty || !sep.every((c) => RegExp(r'^:?-+:?$').hasMatch(c))) {
      return null;
    }
    final cols = header.length;
    final aligns = [
      for (var c = 0; c < cols; c++)
        c < sep.length ? ColumnAlign.of(sep[c]) : ColumnAlign.none,
    ];
    final rows = [
      for (final l in lines.skip(2))
        () {
          final cells = _cells(l);
          return [
            for (var c = 0; c < cols; c++) c < cells.length ? cells[c] : '',
          ];
        }(),
    ];
    return MdTable(header, aligns, rows);
  }

  /// Splits a row on unescaped pipes (GFM: also inside inline code).
  static List<String> _cells(String line) {
    var s = line.trim();
    if (s.startsWith('|')) s = s.substring(1);
    if (s.endsWith('|') && !s.endsWith(r'\|')) s = s.substring(0, s.length - 1);
    final cells = <String>[];
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      final ch = s[i];
      if (ch == r'\' && i + 1 < s.length && s[i + 1] == '|') {
        buf.write(r'\|');
        i++;
      } else if (ch == '|') {
        cells.add(buf.toString().trim());
        buf.clear();
      } else {
        buf.write(ch);
      }
    }
    cells.add(buf.toString().trim());
    return cells;
  }

  static String _escape(String cell) => cell
      .replaceAll('\n', ' ')
      .replaceAllMapped(RegExp(r'(?<!\\)\|'), (_) => r'\|');

  String encode() {
    final cols = columns;
    String row(List<String> cells) =>
        '| ${[for (var c = 0; c < cols; c++) _escape(c < cells.length ? cells[c] : '')].join(' | ')} |';
    return [
      row(header),
      '| ${[for (final a in aligns) a.marker].join(' | ')} |',
      for (final r in rows) row(r),
    ].join('\n');
  }

  void addRow([int? at]) =>
      rows.insert(at ?? rows.length, List.filled(columns, '', growable: true));

  void removeRow(int r) => rows.removeAt(r);

  void addColumn([int? at]) {
    final c = at ?? columns;
    header.insert(c, '열 ${columns + 1}');
    aligns.insert(c, ColumnAlign.none);
    for (final r in rows) {
      r.insert(c, '');
    }
  }

  void removeColumn(int c) {
    if (columns <= 1) return;
    header.removeAt(c);
    aligns.removeAt(c);
    for (final r in rows) {
      r.removeAt(c);
    }
  }

  MdTable copy() => MdTable([...header], [...aligns], [
    for (final r in rows) [...r],
  ]);
}

enum ColumnAlign {
  none('---'),
  left(':---'),
  center(':---:'),
  right('---:');

  const ColumnAlign(this.marker);

  final String marker;

  static ColumnAlign of(String sep) {
    final l = sep.startsWith(':'), r = sep.endsWith(':');
    if (l && r) return center;
    if (l) return left;
    if (r) return right;
    return none;
  }

  ColumnAlign get next => values[(index + 1) % values.length];
}
