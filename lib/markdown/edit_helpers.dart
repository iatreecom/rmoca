import 'package:flutter/services.dart';

final _listItem = RegExp(r'^(\s*)([-*+]|(\d+)([.)]))(\s+\[[ xX]\])?\s+(.*)$');

/// After Enter on a list item, starts the next item (or ends the list when
/// the item was empty), like Obsidian. Returns the corrected value, or null
/// when [value] is not such an edit of [previous].
TextEditingValue? continueList(String previous, TextEditingValue value) {
  final text = value.text;
  final sel = value.selection;
  if (!sel.isValid || !sel.isCollapsed) return null;
  if (text.length != previous.length + 1) return null;
  final pos = sel.start;
  if (pos < 1 || text[pos - 1] != '\n') return null;
  if (text.substring(0, pos - 1) != previous.substring(0, pos - 1)) {
    return null;
  }
  final lineStart = pos < 2 ? 0 : text.lastIndexOf('\n', pos - 2) + 1;
  final line = text.substring(lineStart, pos - 1);
  final m = _listItem.firstMatch(line);
  if (m == null) return null;

  if (m[6]!.trim().isEmpty) {
    // Empty item: remove its bullet instead of adding another.
    return TextEditingValue(
      text: text.substring(0, lineStart) + text.substring(pos),
      selection: TextSelection.collapsed(offset: lineStart),
    );
  }
  final number = m[3] == null ? null : int.parse(m[3]!) + 1;
  final bullet = number == null ? m[2]! : '$number${m[4]}';
  final task = m[5] == null ? '' : ' [ ]';
  final prefix = '${m[1]}$bullet$task ';
  return TextEditingValue(
    text: text.substring(0, pos) + prefix + text.substring(pos),
    selection: TextSelection.collapsed(offset: pos + prefix.length),
  );
}

/// Whether the edit from [previous] to [value] typed a `/` at the start of a
/// line (only spaces before it): the trigger for the block menu.
bool typedSlashAtLineStart(String previous, TextEditingValue value) {
  final text = value.text;
  final sel = value.selection;
  if (!sel.isValid || !sel.isCollapsed) return false;
  if (text.length != previous.length + 1) return false;
  final pos = sel.start;
  if (pos < 1 || text[pos - 1] != '/') return false;
  final lineStart = pos < 2 ? 0 : text.lastIndexOf('\n', pos - 2) + 1;
  return text.substring(lineStart, pos - 1).trim().isEmpty;
}

/// Wraps the selection in [before]/[after] (or inserts them at the cursor).
TextEditingValue wrapSelection(
  TextEditingValue value,
  String before, [
  String after = '',
]) {
  final sel = value.selection;
  final text = value.text;
  if (!sel.isValid) {
    return TextEditingValue(
      text: '$text$before$after',
      selection: TextSelection.collapsed(offset: text.length + before.length),
    );
  }
  final selected = sel.textInside(text);
  return TextEditingValue(
    text:
        sel.textBefore(text) + before + selected + after + sel.textAfter(text),
    selection: TextSelection.collapsed(
      offset:
          sel.start +
          before.length +
          selected.length +
          (selected.isEmpty ? 0 : after.length),
    ),
  );
}

/// Puts [prefix] at the start of the cursor's line, replacing an existing
/// heading/list/quote marker so toggling between them works.
TextEditingValue setLinePrefix(TextEditingValue value, String prefix) {
  final sel = value.selection;
  final text = value.text;
  final pos = sel.isValid ? sel.start : text.length;
  final lineStart = text.lastIndexOf('\n', pos == 0 ? 0 : pos - 1) + 1;
  final lineEndIdx = text.indexOf('\n', lineStart);
  final line = text.substring(
    lineStart,
    lineEndIdx < 0 ? text.length : lineEndIdx,
  );
  final existing =
      RegExp(r'^(#{1,6}\s+|>\s?|\s*(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?)')
          .firstMatch(line)?[0] ??
      '';
  final replace = existing == prefix ? '' : prefix;
  final delta = replace.length - existing.length;
  return TextEditingValue(
    text:
        text.substring(0, lineStart) +
        replace +
        text.substring(lineStart + existing.length),
    selection: TextSelection.collapsed(
      offset: (pos + delta).clamp(
        lineStart + replace.length,
        text.length + delta,
      ),
    ),
  );
}

/// Marks where the cursor goes in a snippet.
const caretMark = '\u2038';

/// Inserts [snippet] at the cursor (replacing the selection), placing the
/// cursor at [caretMark] or after the snippet.
TextEditingValue insertSnippet(TextEditingValue value, String snippet) {
  final text = value.text;
  final sel = value.selection;
  final start = sel.isValid ? sel.start : text.length;
  final end = sel.isValid ? sel.end : text.length;
  final caret = snippet.indexOf(caretMark);
  final clean = snippet.replaceFirst(caretMark, '');
  return TextEditingValue(
    text: text.substring(0, start) + clean + text.substring(end),
    selection: TextSelection.collapsed(
      offset: start + (caret < 0 ? clean.length : caret),
    ),
  );
}
