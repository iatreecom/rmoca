import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../models/note.dart';

final _wikiQuery = RegExp(r'\[\[([^\[\]\n|#]*)$');

/// `[[partial` right before the cursor, if any.
String? wikiQueryOf(TextEditingValue value) {
  final sel = value.selection;
  if (!sel.isValid || !sel.isCollapsed) return null;
  return _wikiQuery.firstMatch(value.text.substring(0, sel.start))?[1];
}

/// Completes the `[[partial` before the cursor with [name].
TextEditingValue completeWiki(TextEditingValue value, String name) {
  final sel = value.selection;
  final text = value.text;
  final query = wikiQueryOf(value) ?? '';
  final start = sel.start - query.length;
  final after = text.substring(sel.start);
  final close = after.startsWith(']]') ? '' : ']]';
  return TextEditingValue(
    text: text.substring(0, start) + name + close + after,
    selection: TextSelection.collapsed(offset: start + name.length + 2),
  );
}

/// A row of note names matching the `[[` query being typed.
class WikiSuggestions extends StatelessWidget {
  const WikiSuggestions({
    super.key,
    required this.query,
    required this.notes,
    required this.currentPath,
    required this.onPick,
  });

  final String query;
  final List<Note> notes;
  final String currentPath;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final q = query.toLowerCase();
    final matches = notes
        .where(
          (n) => n.path != currentPath && n.title.toLowerCase().contains(q),
        )
        .take(8)
        .toList();
    if (matches.isEmpty && query.isEmpty) return const SizedBox.shrink();
    return Container(
      height: 48,
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        children: [
          for (final n in matches)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ActionChip(
                avatar: Icon(
                  n.kind == NoteKind.drawing
                      ? Icons.draw_outlined
                      : Icons.description_outlined,
                  size: 16,
                ),
                label: Text(n.title),
                onPressed: () => onPick(
                  n.kind == NoteKind.drawing
                      ? p.posix.basename(n.path)
                      : n.title,
                ),
              ),
            ),
          if (query.isNotEmpty && !matches.any((n) => n.title == query))
            ActionChip(
              avatar: const Icon(Icons.add_rounded, size: 16),
              label: Text("새 메모 '$query'"),
              onPressed: () => onPick(query),
            ),
        ],
      ),
    );
  }
}
