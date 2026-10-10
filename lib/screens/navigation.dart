import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/note.dart';
import 'drawing_screen.dart';
import 'markdown_screen.dart';

/// Opens the editor for the note at [path].
Future<void> openNote(BuildContext context, String path, {bool edit = false}) =>
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Note.isDrawingPath(path)
            ? DrawingScreen(path: path)
            : MarkdownScreen(path: path, startEditing: edit),
      ),
    );

/// Shows the notes tagged [tag].
Future<void> openTag(BuildContext context, String tag) =>
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => TagScreen(tag: tag)));

/// Creates the note a `[[target]]` link points to, after asking.
Future<void> createFromWiki(
  BuildContext context,
  String target,
  String fromPath,
) async {
  final name = target.split('#').first.trim();
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('새 메모 만들기'),
      content: Text("'$name' 메모가 아직 없습니다. 만들까요?"),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('만들기'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  final app = context.read<AppState>();
  // A target with a folder ("a/b") is created there; otherwise next to the
  // linking note, like Obsidian's default.
  final folder = name.contains('/')
      ? Note.parentOf(name)
      : Note.parentOf(fromPath);
  final path = await app.newNotePath(
    p.posix.basename(name),
    'md',
    folder: folder,
  );
  if (folder.isNotEmpty && !app.folders.contains(folder)) {
    await app.store.dirFor(folder).create(recursive: true);
  }
  await app.saveText(path, '# ${p.posix.basenameWithoutExtension(path)}\n\n');
  if (context.mounted) await openNote(context, path, edit: true);
}

class TagScreen extends StatelessWidget {
  const TagScreen({super.key, required this.tag});

  final String tag;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final notes = app.notesWithTag(tag);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('#$tag', style: TextStyle(color: scheme.primary)),
      ),
      body: notes.isEmpty
          ? const Center(child: Text('이 태그가 달린 메모가 없습니다'))
          : ListView.separated(
              padding: const EdgeInsets.all(8),
              itemCount: notes.length,
              separatorBuilder: (_, _) => const SizedBox(height: 4),
              itemBuilder: (context, i) {
                final n = notes[i];
                return ListTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  tileColor: scheme.surfaceContainerLow,
                  leading: const Icon(Icons.description_outlined),
                  title: Text(
                    n.title,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    [
                      DateFormat('yyyy-MM-dd').format(n.modified),
                      if (n.folder.isNotEmpty) n.folder,
                      if (n.preview.isNotEmpty) n.preview,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => openNote(context, n.path),
                );
              },
            ),
    );
  }
}

/// Folder for daily notes and for templates (Obsidian's conventions).
const dailyFolder = 'Daily';
const templatesFolder = 'Templates';

/// Markdown templates in the `Templates` folder.
List<Note> templatesOf(AppState app) => app.notes
    .where(
      (n) =>
          n.kind == NoteKind.markdown && Note.isWithin(templatesFolder, n.path),
    )
    .toList();

/// Fills `{{title}}`, `{{date}}` and `{{time}}` in a template.
String applyTemplate(String template, String title, DateTime now) => template
    .replaceAll('{{title}}', title)
    .replaceAll('{{date}}', DateFormat('yyyy-MM-dd').format(now))
    .replaceAll('{{time}}', DateFormat('HH:mm').format(now));

/// Opens today's note in `Daily/`, creating it from `Templates/Daily.md`
/// (or a default layout) the first time.
Future<void> openDailyNote(BuildContext context) async {
  final app = context.read<AppState>();
  final now = DateTime.now();
  final name = DateFormat('yyyy-MM-dd').format(now);
  final path = '$dailyFolder/$name.md';
  if (!await app.store.exists(path)) {
    final tpl = app.resolveWiki('$templatesFolder/Daily', '');
    final body = tpl != null
        ? applyTemplate(await app.store.readText(tpl), name, now)
        : '# $name (${DateFormat('E', 'ko').format(now)})\n\n'
              '## 할 일\n- [ ] \n\n## 메모\n\n';
    await app.saveText(path, body);
  }
  if (context.mounted) await openNote(context, path, edit: true);
}

/// Ctrl/⌘+K: jump to any note by name, or create one.
Future<void> showQuickSwitcher(BuildContext context) async {
  final app = context.read<AppState>();
  final result = await showDialog<String>(
    context: context,
    builder: (_) => _QuickSwitcher(notes: app.notes),
  );
  if (result == null || !context.mounted) return;
  if (result.startsWith(':new:')) {
    final name = result.substring(5);
    final path = await app.newNotePath(name, 'md');
    await app.saveText(path, '# ${p.posix.basenameWithoutExtension(path)}\n\n');
    if (context.mounted) await openNote(context, path, edit: true);
  } else {
    await openNote(context, result);
  }
}

class _QuickSwitcher extends StatefulWidget {
  const _QuickSwitcher({required this.notes});

  final List<Note> notes;

  @override
  State<_QuickSwitcher> createState() => _QuickSwitcherState();
}

class _QuickSwitcherState extends State<_QuickSwitcher> {
  String _query = '';
  int _selected = 0;

  /// Matches all query characters in order; earlier and tighter is better.
  static int? _score(String text, String query) {
    final t = text.toLowerCase();
    var pos = 0;
    var score = 0;
    for (final ch in query.toLowerCase().split('')) {
      if (ch == ' ') continue;
      final i = t.indexOf(ch, pos);
      if (i < 0) return null;
      score += i - pos;
      pos = i + 1;
    }
    return score + t.length ~/ 10;
  }

  List<Note> get _matches {
    if (_query.trim().isEmpty) return widget.notes.take(30).toList();
    final scored = <(Note, int)>[];
    for (final n in widget.notes) {
      final s = _score(n.path, _query);
      if (s != null) scored.add((n, s));
    }
    scored.sort((a, b) => a.$2.compareTo(b.$2));
    return scored.take(30).map((e) => e.$1).toList();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final matches = _matches;
    final canCreate = _query.trim().isNotEmpty;
    final count = matches.length + (canCreate ? 1 : 0);
    if (_selected >= count) _selected = count == 0 ? 0 : count - 1;

    void choose(int i) {
      if (i < matches.length) {
        Navigator.pop(context, matches[i].path);
      } else if (canCreate) {
        Navigator.pop(context, ':new:${_query.trim()}');
      }
    }

    return Dialog(
      alignment: const Alignment(0, -0.6),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                      setState(
                        () => _selected =
                            (_selected + 1) % (count == 0 ? 1 : count),
                      ),
                  const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                      setState(
                        () => _selected =
                            (_selected - 1 + count) % (count == 0 ? 1 : count),
                      ),
                },
                child: TextField(
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: '메모 이름으로 이동…',
                    prefixIcon: const Icon(Icons.search_rounded),
                    filled: true,
                    fillColor: scheme.surfaceContainerHigh,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onChanged: (v) => setState(() {
                    _query = v;
                    _selected = 0;
                  }),
                  onSubmitted: (_) => choose(_selected),
                ),
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 8),
                itemCount: count,
                itemBuilder: (context, i) {
                  final selected = i == _selected;
                  if (i == matches.length) {
                    return ListTile(
                      selected: selected,
                      leading: const Icon(Icons.add_rounded),
                      title: Text("새 메모 '${_query.trim()}' 만들기"),
                      onTap: () => choose(i),
                    );
                  }
                  final n = matches[i];
                  return ListTile(
                    selected: selected,
                    selectedTileColor: scheme.secondaryContainer,
                    leading: Icon(
                      n.kind == NoteKind.drawing
                          ? Icons.draw_outlined
                          : Icons.description_outlined,
                    ),
                    title: Text(n.title),
                    subtitle: n.folder.isEmpty ? null : Text(n.folder),
                    onTap: () => choose(i),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
