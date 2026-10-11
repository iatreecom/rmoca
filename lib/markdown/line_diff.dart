enum DiffOp { same, added, removed }

class DiffLine {
  const DiffLine(this.op, this.text);

  final DiffOp op;
  final String text;

  @override
  String toString() =>
      '${switch (op) {
        DiffOp.same => ' ',
        DiffOp.added => '+',
        DiffOp.removed => '-',
      }}$text';
}

/// Line-by-line difference from [before] to [after] (longest common
/// subsequence). Very large inputs fall back to "all removed, all added"
/// for the differing middle part.
List<DiffLine> diffLines(String before, String after) {
  final a = before.split('\n');
  final b = after.split('\n');
  var start = 0;
  while (start < a.length && start < b.length && a[start] == b[start]) {
    start++;
  }
  var endA = a.length, endB = b.length;
  while (endA > start && endB > start && a[endA - 1] == b[endB - 1]) {
    endA--;
    endB--;
  }
  final out = <DiffLine>[
    for (var i = 0; i < start; i++) DiffLine(DiffOp.same, a[i]),
  ];
  final n = endA - start, m = endB - start;
  if (n * m > 1000000) {
    out
      ..addAll([
        for (var i = start; i < endA; i++) DiffLine(DiffOp.removed, a[i]),
      ])
      ..addAll([
        for (var j = start; j < endB; j++) DiffLine(DiffOp.added, b[j]),
      ]);
  } else {
    // lcs[i][j] = LCS length of a[start+i..endA) and b[start+j..endB).
    final lcs = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
    for (var i = n - 1; i >= 0; i--) {
      for (var j = m - 1; j >= 0; j--) {
        lcs[i][j] = a[start + i] == b[start + j]
            ? lcs[i + 1][j + 1] + 1
            : (lcs[i + 1][j] >= lcs[i][j + 1] ? lcs[i + 1][j] : lcs[i][j + 1]);
      }
    }
    var i = 0, j = 0;
    while (i < n && j < m) {
      if (a[start + i] == b[start + j]) {
        out.add(DiffLine(DiffOp.same, a[start + i]));
        i++;
        j++;
      } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
        out.add(DiffLine(DiffOp.removed, a[start + i++]));
      } else {
        out.add(DiffLine(DiffOp.added, b[start + j++]));
      }
    }
    while (i < n) {
      out.add(DiffLine(DiffOp.removed, a[start + i++]));
    }
    while (j < m) {
      out.add(DiffLine(DiffOp.added, b[start + j++]));
    }
  }
  for (var i = endA; i < a.length; i++) {
    out.add(DiffLine(DiffOp.same, a[i]));
  }
  return out;
}

/// Numbers of added and removed lines.
(int, int) diffStats(List<DiffLine> diff) => (
  diff.where((d) => d.op == DiffOp.added).length,
  diff.where((d) => d.op == DiffOp.removed).length,
);
