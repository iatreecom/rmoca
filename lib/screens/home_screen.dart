import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/note.dart';
import '../widgets/sync_indicator.dart';
import 'drawing_screen.dart';
import 'markdown_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _query = '';

  Future<void> _open(Note note) => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => note.kind == NoteKind.drawing
          ? DrawingScreen(path: note.path)
          : MarkdownScreen(path: note.path),
    ),
  );

  Future<void> _create(NoteKind kind) async {
    final app = context.read<AppState>();
    final stamp = DateFormat('yyyy-MM-dd HHmm').format(DateTime.now());
    final name = await _askName(
      title: kind == NoteKind.drawing ? '새 그림' : '새 메모',
      initial: kind == NoteKind.drawing ? '그림 $stamp' : '메모 $stamp',
    );
    if (name == null || !mounted) return;
    final ext = kind == NoteKind.drawing ? 'svg' : 'md';
    final path = await app.newNotePath(name, ext);
    if (kind == NoteKind.markdown) {
      await app.saveText(
        path,
        '# ${p.posix.basenameWithoutExtension(path)}\n\n',
      );
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => kind == NoteKind.drawing
            ? DrawingScreen(path: path)
            : MarkdownScreen(path: path, startEditing: true),
      ),
    );
  }

  Future<String?> _askName({required String title, required String initial}) {
    final controller = TextEditingController(text: initial)
      ..selection = TextSelection(baseOffset: 0, extentOffset: initial.length);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '이름'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('확인'),
          ),
        ],
      ),
    );
  }

  Future<void> _rename(Note note) async {
    final app = context.read<AppState>();
    final name = await _askName(title: '이름 바꾸기', initial: note.title);
    if (name == null || name.trim() == note.title) return;
    final ext = p.posix.extension(note.path).substring(1);
    final target = await app.newNotePath(name, ext, folder: note.folder);
    try {
      await app.renameNote(note.path, target);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('이름을 바꿀 수 없습니다: $e')));
      }
    }
  }

  Future<void> _delete(Note note) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('메모 삭제'),
        content: Text("'${note.title}'을(를) 삭제할까요? 동기화되면 저장소에서도 삭제됩니다."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await context.read<AppState>().deleteNote(note.path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final q = _query.toLowerCase();
    final notes = q.isEmpty
        ? app.notes
        : app.notes
              .where(
                (n) =>
                    n.path.toLowerCase().contains(q) ||
                    n.preview.toLowerCase().contains(q),
              )
              .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('rmoca'),
        actions: [
          const SyncIndicator(),
          IconButton(
            tooltip: '설정',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).pushNamed('/settings'),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: SearchBar(
              hintText: '메모 검색',
              leading: const Icon(Icons.search),
              elevation: const WidgetStatePropertyAll(0),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () => app.syncNow(),
        child: notes.isEmpty
            ? ListView(
                children: [
                  const SizedBox(height: 120),
                  Icon(
                    Icons.sticky_note_2_outlined,
                    size: 64,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                  const SizedBox(height: 12),
                  Center(
                    child: Text(_query.isEmpty ? '아직 메모가 없습니다' : '검색 결과가 없습니다'),
                  ),
                  if (!app.settings.isConfigured) ...[
                    const SizedBox(height: 12),
                    Center(
                      child: TextButton.icon(
                        icon: const Icon(Icons.link),
                        label: const Text('Git 저장소 연결하기'),
                        onPressed: () =>
                            Navigator.of(context).pushNamed('/settings'),
                      ),
                    ),
                  ],
                ],
              )
            : ListView.separated(
                itemCount: notes.length,
                separatorBuilder: (_, _) =>
                    const Divider(height: 1, indent: 72),
                itemBuilder: (context, i) => _NoteTile(
                  note: notes[i],
                  onTap: () => _open(notes[i]),
                  onRename: () => _rename(notes[i]),
                  onDelete: () => _delete(notes[i]),
                ),
              ),
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.small(
            heroTag: 'draw',
            tooltip: '새 그림',
            onPressed: () => _create(NoteKind.drawing),
            child: const Icon(Icons.brush_outlined),
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            heroTag: 'note',
            onPressed: () => _create(NoteKind.markdown),
            icon: const Icon(Icons.edit_note),
            label: const Text('새 메모'),
          ),
        ],
      ),
    );
  }
}

class _NoteTile extends StatelessWidget {
  const _NoteTile({
    required this.note,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
  });

  final Note note;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final leading = note.kind == NoteKind.drawing
        ? ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Container(
              width: 44,
              height: 44,
              color: Colors.white,
              child: SvgPicture.file(
                app.store.fileFor(note.path),
                key: ValueKey(
                  '${note.path}@${note.modified.millisecondsSinceEpoch}',
                ),
                fit: BoxFit.contain,
                placeholderBuilder: (_) => const Icon(Icons.brush_outlined),
              ),
            ),
          )
        : CircleAvatar(
            backgroundColor: scheme.secondaryContainer,
            child: Icon(Icons.notes, color: scheme.onSecondaryContainer),
          );
    final subtitle = [
      DateFormat('yyyy-MM-dd HH:mm').format(note.modified),
      if (note.folder.isNotEmpty) note.folder,
      if (note.preview.isNotEmpty) note.preview,
    ].join(' · ');
    return ListTile(
      leading: SizedBox(width: 44, child: Center(child: leading)),
      title: Text(note.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      onTap: onTap,
      onLongPress: () => _menu(context),
      trailing: PopupMenuButton<String>(
        onSelected: (v) => v == 'rename' ? onRename() : onDelete(),
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'rename', child: Text('이름 바꾸기')),
          PopupMenuItem(value: 'delete', child: Text('삭제')),
        ],
      ),
    );
  }

  void _menu(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.drive_file_rename_outline),
            title: const Text('이름 바꾸기'),
            onTap: () {
              Navigator.pop(context);
              onRename();
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('삭제'),
            onTap: () {
              Navigator.pop(context);
              onDelete();
            },
          ),
        ],
      ),
    ),
  );
}
