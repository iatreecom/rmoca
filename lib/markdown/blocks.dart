/// Splits a note into top-level blocks (paragraphs, headings, lists, code,
/// math, tables, drawings…) for block-by-block editing. Every block keeps
/// its exact range in the source, so editing one block never touches the
/// rest of the note.
library;

enum BlockKind {
  frontmatter,
  heading,
  paragraph,
  list,
  tasks,
  quote,
  callout,
  code,
  math,
  mermaid,
  table,
  rule,
  drawing,
  embed,
}

class MdBlock {
  const MdBlock(this.start, this.end, this.text, this.kind, this.firstLine);

  /// Range in the source; [end] is exclusive and excludes the line break.
  final int start;
  final int end;
  final String text;
  final BlockKind kind;

  /// Zero-based line of the block's first line in the source.
  final int firstLine;

  @override
  String toString() => 'MdBlock($kind, $start-$end)';
}

final _fence = RegExp(r'^\s{0,3}(`{3,}|~{3,})\s*([^\s`]*)');
final _heading = RegExp(r'^\s{0,3}#{1,6}(\s|$)');
final _rule = RegExp(r'^\s{0,3}([-*_])(\s*\1){2,}\s*$');
final _listItem = RegExp(r'^\s*([-*+]|\d+[.)])\s');
final _task = RegExp(r'^\s*([-*+]|\d+[.)])\s+\[[ xX]\]');
final _tableSep = RegExp(r'^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$');

List<MdBlock> splitBlocks(String source) {
  final lines = source.split('\n');
  final offsets = <int>[];
  var off = 0;
  for (final l in lines) {
    offsets.add(off);
    off += l.length + 1;
  }
  int lineEnd(int i) => offsets[i] + lines[i].length;

  final blocks = <MdBlock>[];
  void add(int from, int to, BlockKind kind) {
    final start = offsets[from];
    final end = lineEnd(to);
    blocks.add(MdBlock(start, end, source.substring(start, end), kind, from));
  }

  var i = 0;
  // YAML frontmatter.
  if (lines.isNotEmpty && lines[0].trim() == '---') {
    for (var j = 1; j < lines.length; j++) {
      final t = lines[j].trim();
      if (t == '---' || t == '...') {
        add(0, j, BlockKind.frontmatter);
        i = j + 1;
        break;
      }
    }
  }

  bool startsSpecial(String line) =>
      _fence.hasMatch(line) ||
      _heading.hasMatch(line) ||
      line.trimLeft().startsWith(r'$$') ||
      line.trimLeft().startsWith('<svg');

  while (i < lines.length) {
    final line = lines[i];
    final t = line.trim();
    if (t.isEmpty) {
      i++;
      continue;
    }
    // Fenced code (also math / mermaid).
    final fence = _fence.firstMatch(line);
    if (fence != null) {
      final marker = fence[1]!;
      var j = i + 1;
      while (j < lines.length) {
        final close = lines[j].trim();
        if (close.startsWith(marker[0] * marker.length) &&
            close.replaceAll(marker[0], '').trim().isEmpty) {
          break;
        }
        j++;
      }
      final lang = fence[2]!.toLowerCase();
      add(
        i,
        j.clamp(i, lines.length - 1),
        lang == 'mermaid'
            ? BlockKind.mermaid
            : (lang == 'math' || lang == 'latex')
            ? BlockKind.math
            : BlockKind.code,
      );
      i = j + 1;
      continue;
    }
    // Display math.
    if (t.startsWith(r'$$') || t == r'\[') {
      final closer = t == r'\[' ? r'\]' : r'$$';
      final oneLine = t.length > 2 && t.endsWith(closer) && t != r'$$';
      var j = i;
      if (!oneLine) {
        j = i + 1;
        while (j < lines.length && !lines[j].trim().endsWith(closer)) {
          j++;
        }
      }
      add(i, j.clamp(i, lines.length - 1), BlockKind.math);
      i = j + 1;
      continue;
    }
    // Embedded drawing.
    if (t.startsWith('<svg')) {
      var j = i;
      while (j < lines.length && !lines[j].contains('</svg>')) {
        j++;
      }
      add(i, j.clamp(i, lines.length - 1), BlockKind.drawing);
      i = j + 1;
      continue;
    }
    if (_heading.hasMatch(line)) {
      add(i, i, BlockKind.heading);
      i++;
      continue;
    }
    // Everything else runs until a blank line or a block that may interrupt.
    var j = i;
    while (j + 1 < lines.length &&
        lines[j + 1].trim().isNotEmpty &&
        !startsSpecial(lines[j + 1])) {
      j++;
    }
    add(i, j, _kindOf(lines.sublist(i, j + 1)));
    i = j + 1;
  }
  return blocks;
}

BlockKind _kindOf(List<String> lines) {
  final first = lines.first.trimLeft();
  if (lines.length == 1 && _rule.hasMatch(first)) return BlockKind.rule;
  if (first.startsWith('>')) {
    return RegExp(r'^>\s*\[!').hasMatch(first)
        ? BlockKind.callout
        : BlockKind.quote;
  }
  if (lines.length >= 2 &&
      first.contains('|') &&
      _tableSep.hasMatch(lines[1])) {
    return BlockKind.table;
  }
  if (_listItem.hasMatch(lines.first)) {
    return _task.hasMatch(lines.first) ? BlockKind.tasks : BlockKind.list;
  }
  if (lines.length == 1 && first.startsWith('![')) return BlockKind.embed;
  return BlockKind.paragraph;
}

/// Replaces [block] with [text]; empty [text] removes the block together
/// with the blank lines that separated it.
String replaceBlock(String source, MdBlock block, String text) {
  if (text.trim().isNotEmpty) {
    return source.substring(0, block.start) +
        text +
        source.substring(block.end);
  }
  final before = source.substring(0, block.start).replaceFirst(_trailingNl, '');
  final after = source.substring(block.end).replaceFirst(_leadingNl, '');
  if (before.isEmpty) return after;
  if (after.isEmpty) return '$before\n';
  return '$before\n\n$after';
}

final _trailingNl = RegExp(r'\n+$');
final _leadingNl = RegExp(r'^\n+');

/// The text that goes before and after a new block inserted before
/// `blocks[index]` (or at the end when [index] is `blocks.length`), so that
/// it is separated from its neighbours by one blank line.
(String, String) insertionContext(
  String source,
  List<MdBlock> blocks,
  int index,
) {
  final pos = index < blocks.length
      ? blocks[index].start
      : (blocks.isEmpty ? source.length : blocks.last.end);
  final before = source.substring(0, pos).replaceFirst(_trailingNl, '');
  final after = source.substring(pos).replaceFirst(_leadingNl, '');
  return (
    before.isEmpty ? '' : '$before\n\n',
    after.isEmpty ? '\n' : '\n\n$after',
  );
}

/// Inserts [text] as a new block at [index]; returns the new source and
/// where the new block starts.
(String, int) insertBlock(
  String source,
  List<MdBlock> blocks,
  int index,
  String text,
) {
  final (lead, tail) = insertionContext(source, blocks, index);
  return ('$lead$text$tail', lead.length);
}

/// Moves `blocks[from]` to position [to] (an index into the list without
/// the moved block). Blocks are re-joined with one blank line.
String moveBlock(String source, List<MdBlock> blocks, int from, int to) {
  // Frontmatter must stay first.
  final fixed = blocks.isNotEmpty && blocks.first.kind == BlockKind.frontmatter
      ? 1
      : 0;
  if (from < fixed) return source;
  final texts = [for (final b in blocks) b.text];
  final moved = texts.removeAt(from);
  texts.insert(to.clamp(fixed, texts.length), moved);
  final trailing = source.endsWith('\n') ? '\n' : '';
  return texts.join('\n\n') + trailing;
}

/// Index of the block that starts at [offset], if any.
int blockAt(List<MdBlock> blocks, int offset) =>
    blocks.indexWhere((b) => b.start == offset);
