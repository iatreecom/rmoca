import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../markdown/embedded_drawings.dart';
import '../models/note.dart';
import '../widgets/media_view.dart';
import '../widgets/sync_indicator.dart';
import '../services/search.dart';
import 'drawing_screen.dart';
import 'markdown_screen.dart';
import 'navigation.dart';

/// Note browser: folders as a tree, notes as cards or a list.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  /// Folder being browsed ('' = root).
  String _folder = '';
  String _query = '';
  bool _grid = true;

  /// Showing favorites instead of a folder.
  bool _favorites = false;

  /// Tablet split view: the note open next to the list.
  bool _split = true;
  String? _paneNote;
  bool _paneEdit = false;

  void _openInPane(String path, bool edit) => setState(() {
    _paneNote = path;
    _paneEdit = edit;
  });

  /// Paths selected in multi-select mode.
  final Set<String> _selected = {};
  final Set<String> _expanded = {};
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Lets the child widgets of this screen update its state.
  void update(VoidCallback fn) => setState(fn);

  void _openFolder(String folder) {
    setState(() {
      _folder = folder;
      _favorites = false;
      _selected.clear();
      // Reveal the folder in the sidebar tree.
      var f = folder;
      while (f.isNotEmpty) {
        f = Note.parentOf(f);
        if (f.isNotEmpty) _expanded.add(f);
      }
    });
  }

  void _showFavorites() => setState(() {
    _favorites = true;
    _selected.clear();
  });

  void _toggleSelect(String path) => setState(() {
    if (!_selected.remove(path)) _selected.add(path);
  });

  Future<void> _bulkFavorite() async {
    final app = context.read<AppState>();
    final allFav = _selected.every(app.isFavorite);
    await app.setFavorite(_selected, !allFav);
    setState(_selected.clear);
  }

  Future<void> _bulkMove() async {
    final app = context.read<AppState>();
    final folder = await _pickFolder(title: '${_selected.length}개 이동');
    if (folder == null) return;
    for (final path in _selected.toList()) {
      if (Note.parentOf(path) == folder) continue;
      final target = await app.store.uniquePath(
        Note.join(folder, p.posix.basename(path)),
      );
      await _guard(() => app.renameNote(path, target));
    }
    setState(_selected.clear);
  }

  Future<void> _bulkDelete() async {
    final paths = _selected.toList();
    await context.read<AppState>().deleteNotes(paths);
    setState(_selected.clear);
    _showUndoDelete(paths.length);
  }

  void _showUndoDelete(int count) {
    if (!mounted) return;
    final app = context.read<AppState>();
    final trashed = app.trash.take(count).map((n) => n.path).toList();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$count개를 휴지통으로 옮겼습니다'),
        action: SnackBarAction(
          label: '실행 취소',
          onPressed: () async {
            for (final t in trashed) {
              await app.restoreNote(t);
            }
          },
        ),
      ),
    );
  }

  Future<void> _pickFolderColor(String folder) async {
    final app = context.read<AppState>();
    const colors = [
      Color(0xFF5B6CFF),
      Color(0xFF0EA5E9),
      Color(0xFF10B981),
      Color(0xFFF59E0B),
      Color(0xFFEF4444),
      Color(0xFFEC4899),
      Color(0xFF8B5CF6),
      Color(0xFF6B7280),
    ];
    final current = app.folderColor(folder);
    final picked = await showDialog<Color?>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('폴더 색상'),
        content: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final c in colors)
              InkWell(
                customBorder: const CircleBorder(),
                onTap: () => Navigator.pop(context, c),
                child: CircleAvatar(
                  radius: 20,
                  backgroundColor: c,
                  child: current?.toARGB32() == c.toARGB32()
                      ? const Icon(Icons.check_rounded, color: Colors.white)
                      : null,
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, Colors.transparent),
            child: const Text('기본 색'),
          ),
        ],
      ),
    );
    if (picked == null) return;
    await app.setFolderColor(
      folder,
      picked == Colors.transparent ? null : picked,
    );
  }

  /// Whether the last layout showed the split view.
  bool _splitActive = false;

  Future<void> _open(Note note, {bool edit = false}) async {
    if (_splitActive && note.kind == NoteKind.markdown) {
      _openInPane(note.path, edit);
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => note.kind == NoteKind.drawing
            ? DrawingScreen(path: note.path)
            : MarkdownScreen(path: note.path, startEditing: edit),
      ),
    );
  }

  // --- creating --------------------------------------------------------------

  Future<void> _newNote() async {
    final app = context.read<AppState>();
    final stamp = DateFormat('yyyy-MM-dd HHmm').format(DateTime.now());
    final templates = templatesOf(app);
    final result = await showDialog<(String, Note?)>(
      context: context,
      builder: (_) =>
          _NewNoteDialog(initialName: '메모 $stamp', templates: templates),
    );
    if (result == null || !mounted) return;
    final (name, template) = result;
    final path = await app.newNotePath(name, 'md', folder: _folder);
    final title = p.posix.basenameWithoutExtension(path);
    await app.saveText(
      path,
      template == null
          ? '# $title\n\n'
          : applyTemplate(
              await app.store.readText(template.path),
              title,
              DateTime.now(),
            ),
    );
    if (!mounted) return;
    await _open(Note(path: path, modified: DateTime.now()), edit: true);
  }

  Future<void> _newDrawing() async {
    final app = context.read<AppState>();
    final stamp = DateFormat('yyyy-MM-dd HHmm').format(DateTime.now());
    final result = await showDialog<(String, DrawingMode)>(
      context: context,
      builder: (_) =>
          _NewDrawingDialog(initialName: '그림 $stamp', mode: app.drawingMode),
    );
    if (result == null || !mounted) return;
    final (name, mode) = result;
    await app.setDrawingMode(mode);
    if (mode == DrawingMode.file) {
      final path = await app.newNotePath(name, 'svg', folder: _folder);
      if (!mounted) return;
      await Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => DrawingScreen(path: path)));
    } else {
      // A memo whose content is the drawing; more text can be added later.
      final path = await app.newNotePath(name, 'md', folder: _folder);
      await app.saveText(
        path,
        '# ${p.posix.basenameWithoutExtension(path)}\n\n',
      );
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => MarkdownScreen(
            path: path,
            openDrawingId: EmbeddedDrawings.newId(),
          ),
        ),
      );
    }
  }

  Future<void> _newFolder() async {
    final app = context.read<AppState>();
    final name = await _askName(title: '새 폴더', initial: '새 폴더');
    if (name == null) return;
    try {
      final path = await app.createFolder(_folder, name);
      _expanded.add(_folder);
      _showInfo("'${p.posix.basename(path)}' 폴더를 만들었습니다");
    } catch (e) {
      _showInfo('폴더를 만들 수 없습니다: 같은 이름이 이미 있습니다');
    }
  }

  void _showCreateMenu() => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _CreateTile(
            icon: Icons.edit_note_rounded,
            title: '새 메모',
            subtitle: '마크다운으로 작성',
            onTap: () {
              Navigator.pop(context);
              _newNote();
            },
          ),
          _CreateTile(
            icon: Icons.draw_rounded,
            title: '새 그림',
            subtitle: '펜으로 그리기 · SVG 파일 또는 메모에 넣기',
            onTap: () {
              Navigator.pop(context);
              _newDrawing();
            },
          ),
          _CreateTile(
            icon: Icons.create_new_folder_rounded,
            title: '새 폴더',
            subtitle: _folder.isEmpty ? '최상위에 만들기' : '$_folder 안에 만들기',
            onTap: () {
              Navigator.pop(context);
              _newFolder();
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );

  // --- organizing ------------------------------------------------------------

  Future<void> _renameNote(Note note) async {
    final app = context.read<AppState>();
    final name = await _askName(title: '이름 바꾸기', initial: note.title);
    if (name == null || name.trim() == note.title) return;
    final ext = p.posix.extension(note.path).substring(1);
    final target = await app.newNotePath(name, ext, folder: note.folder);
    await _guard(() => app.renameNote(note.path, target));
  }

  Future<void> _moveNote(Note note) async {
    final app = context.read<AppState>();
    final folder = await _pickFolder(title: "'${note.title}' 이동");
    if (folder == null || folder == note.folder) return;
    final target = await app.store.uniquePath(
      Note.join(folder, p.posix.basename(note.path)),
    );
    await _guard(() => app.renameNote(note.path, target));
    _showInfo(
      "'${note.title}'을(를) ${folder.isEmpty ? '최상위' : folder}(으)로 옮겼습니다",
    );
  }

  Future<void> _deleteNote(Note note) async {
    await context.read<AppState>().deleteNote(note.path);
    _showUndoDelete(1);
  }

  Future<void> _renameFolder(String folder) async {
    final app = context.read<AppState>();
    final old = p.posix.basename(folder);
    final name = await _askName(title: '폴더 이름 바꾸기', initial: old);
    if (name == null || name.trim() == old) return;
    final target = Note.join(
      Note.parentOf(folder),
      AppState.sanitizeName(name, fallback: old),
    );
    await _guard(() => app.moveFolder(folder, target));
    if (Note.isWithin(folder, _folder)) {
      _openFolder('$target${_folder.substring(folder.length)}');
    }
  }

  Future<void> _moveFolder(String folder) async {
    final app = context.read<AppState>();
    final dest = await _pickFolder(
      title: "'${p.posix.basename(folder)}' 폴더 이동",
      exclude: folder,
    );
    if (dest == null || dest == Note.parentOf(folder)) return;
    final target = Note.join(dest, p.posix.basename(folder));
    await _guard(() => app.moveFolder(folder, target));
    if (Note.isWithin(folder, _folder)) {
      _openFolder('$target${_folder.substring(folder.length)}');
    }
  }

  Future<void> _deleteFolder(String folder) async {
    final app = context.read<AppState>();
    final count = app.countUnder(folder);
    final ok = await _confirm(
      '폴더 삭제',
      "'${p.posix.basename(folder)}' 폴더${count > 0 ? '와 안에 있는 메모 $count개' : ''}를 "
          '휴지통으로 옮길까요? 30일 동안 복원할 수 있습니다.',
    );
    if (!ok || !mounted) return;
    if (Note.isWithin(folder, _folder)) _openFolder(Note.parentOf(folder));
    await app.deleteFolder(folder);
  }

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      _showInfo('작업을 완료할 수 없습니다: 같은 이름이 이미 있는지 확인하세요');
    }
  }

  // --- dialogs ---------------------------------------------------------------

  void _showInfo(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<bool> _confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('취소'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('삭제'),
            ),
          ],
        ),
      ) ??
      false;

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

  Future<String?> _pickFolder({required String title, String? exclude}) =>
      showDialog<String>(
        context: context,
        builder: (_) => _FolderPickerDialog(title: title, exclude: exclude),
      );

  // --- layout ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    // The browsed folder may vanish after a sync or a move.
    if (_folder.isNotEmpty && !app.folders.contains(_folder)) {
      _folder = '';
    }
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
            showQuickSwitcher(context),
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () =>
            showQuickSwitcher(context),
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): _newNote,
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true): _newNote,
      },
      child: Focus(
        autofocus: true,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 840;
            final canSplit = constraints.maxWidth >= 1100;
            final split = canSplit && _split;
            _splitActive = split;
            final listWidth = split
                ? (constraints.maxWidth * 0.3).clamp(340.0, 440.0)
                : constraints.maxWidth - (wide ? 280 : 0);
            final content = _Content(
              state: this,
              app: app,
              wide: wide,
              width: listWidth,
              canSplit: canSplit,
            );
            final paneNote =
                _paneNote != null && app.notes.any((n) => n.path == _paneNote)
                ? _paneNote
                : null;
            Widget body = wide
                ? Row(
                    children: [
                      SizedBox(
                        width: 280,
                        child: _Sidebar(state: this, app: app),
                      ),
                      const VerticalDivider(width: 1),
                      if (split) ...[
                        SizedBox(
                          width: listWidth,
                          child: Stack(
                            children: [
                              content,
                              Positioned(
                                right: 16,
                                bottom: 16,
                                child: FloatingActionButton(
                                  tooltip: '새로 만들기',
                                  onPressed: _showCreateMenu,
                                  child: const Icon(Icons.add_rounded),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const VerticalDivider(width: 1),
                        Expanded(
                          child: paneNote == null
                              ? const _PanePlaceholder()
                              : MarkdownScreen(
                                  key: ValueKey(paneNote),
                                  path: paneNote,
                                  startEditing: _paneEdit,
                                  onClose: () =>
                                      setState(() => _paneNote = null),
                                ),
                        ),
                      ] else
                        Expanded(child: content),
                    ],
                  )
                : content;
            if (split) body = NotePane(open: _openInPane, child: body);
            return Scaffold(
              body: body,
              floatingActionButton: split
                  ? null
                  : FloatingActionButton.extended(
                      onPressed: _showCreateMenu,
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('새로 만들기'),
                    ),
            );
          },
        ),
      ),
    );
  }
}

/// Main pane: header, search, folders and notes of the current folder.
class _Content extends StatelessWidget {
  const _Content({
    required this.state,
    required this.app,
    required this.wide,
    required this.width,
    this.canSplit = false,
  });

  final _HomeScreenState state;
  final AppState app;
  final bool wide;
  final double width;

  /// Wide enough for the split view (shows its toggle).
  final bool canSplit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final folder = state._folder;
    final q = state._query.trim().toLowerCase();
    final searching = q.isNotEmpty;
    final favorites = state._favorites;
    final selecting = state._selected.isNotEmpty;
    final folders = searching || favorites
        ? <String>[]
        : app.subfolders(folder);
    final notes = favorites && !searching
        ? app.favorites
        : searching
        ? [
            for (final hit in searchNotes(app.notes, q))
              hit.note.withPreview(hit.snippet),
          ]
        : app.notesIn(folder);
    final empty = folders.isEmpty && notes.isEmpty;
    final columns = (width / 230).floor().clamp(2, 6);

    return RefreshIndicator(
      onRefresh: () => app.syncNow(),
      child: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            floating: true,
            toolbarHeight: 64,
            titleSpacing: (folder.isEmpty && !favorites) || wide ? 20 : 0,
            leading: selecting
                ? IconButton(
                    tooltip: '선택 취소',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => state.update(state._selected.clear),
                  )
                : (folder.isNotEmpty || favorites) && !wide
                ? IconButton(
                    icon: const Icon(Icons.arrow_back_rounded),
                    onPressed: () => state._openFolder(
                      favorites ? '' : Note.parentOf(folder),
                    ),
                  )
                : null,
            title: selecting
                ? Text(
                    '${state._selected.length}개 선택',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  )
                : favorites
                ? Text(
                    '즐겨찾기',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  )
                : _Breadcrumb(
                    folder: folder,
                    onOpen: state._openFolder,
                    showRootTitle: !wide,
                  ),
            actions: selecting
                ? [
                    IconButton(
                      tooltip: '모두 선택',
                      icon: const Icon(Icons.select_all_rounded),
                      onPressed: () => state.update(
                        () => state._selected.addAll(notes.map((n) => n.path)),
                      ),
                    ),
                    IconButton(
                      tooltip: '즐겨찾기',
                      icon: const Icon(Icons.star_outline_rounded),
                      onPressed: state._bulkFavorite,
                    ),
                    IconButton(
                      tooltip: '폴더로 이동',
                      icon: const Icon(Icons.drive_file_move_outline),
                      onPressed: state._bulkMove,
                    ),
                    IconButton(
                      tooltip: '삭제',
                      icon: const Icon(Icons.delete_outline_rounded),
                      onPressed: state._bulkDelete,
                    ),
                    const SizedBox(width: 8),
                  ]
                : [
                    PopupMenuButton<SortMode>(
                      tooltip: '정렬',
                      icon: const Icon(Icons.sort_rounded),
                      initialValue: app.sortMode,
                      onSelected: app.setSortMode,
                      itemBuilder: (_) => [
                        for (final m in SortMode.values)
                          CheckedPopupMenuItem(
                            value: m,
                            checked: m == app.sortMode,
                            child: Text(m.label),
                          ),
                      ],
                    ),
                    if (canSplit)
                      IconButton(
                        tooltip: state._split ? '분할 보기 끄기' : '분할 보기',
                        isSelected: state._split,
                        icon: const Icon(Icons.vertical_split_outlined),
                        selectedIcon: const Icon(Icons.vertical_split_rounded),
                        onPressed: () =>
                            state.update(() => state._split = !state._split),
                      ),
                    IconButton(
                      tooltip: state._grid ? '목록으로 보기' : '카드로 보기',
                      icon: Icon(
                        state._grid
                            ? Icons.view_agenda_outlined
                            : Icons.grid_view_rounded,
                      ),
                      onPressed: () =>
                          state.update(() => state._grid = !state._grid),
                    ),
                    if (!wide) ...[
                      IconButton(
                        tooltip: '오늘의 노트',
                        icon: const Icon(Icons.today_rounded),
                        onPressed: () => openDailyNote(context),
                      ),
                      IconButton(
                        tooltip: '태그',
                        icon: const Icon(Icons.tag_rounded),
                        onPressed: () => _showTags(context, app),
                      ),
                    ],
                    const SyncIndicator(),
                    if (!wide)
                      PopupMenuButton<String>(
                        tooltip: '더보기',
                        onSelected: (v) => switch (v) {
                          'favorites' => state._showFavorites(),
                          'trash' => openTrash(context),
                          'calendar' => openCalendar(context),
                          'graph' => openGraph(context),
                          _ => Navigator.of(context).pushNamed('/settings'),
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: 'favorites',
                            child: ListTile(
                              leading: Icon(Icons.star_rounded),
                              title: Text('즐겨찾기'),
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'calendar',
                            child: ListTile(
                              leading: Icon(Icons.calendar_month_rounded),
                              title: Text('캘린더'),
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'graph',
                            child: ListTile(
                              leading: Icon(Icons.hub_outlined),
                              title: Text('그래프'),
                            ),
                          ),
                          PopupMenuItem(
                            value: 'trash',
                            child: ListTile(
                              leading: const Icon(Icons.delete_outline_rounded),
                              title: Text('휴지통 (${app.trash.length})'),
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'settings',
                            child: ListTile(
                              leading: Icon(Icons.settings_outlined),
                              title: Text('설정'),
                            ),
                          ),
                        ],
                      ),
                    const SizedBox(width: 8),
                  ],
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(64),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: SearchBar(
                  controller: state._search,
                  hintText: '제목·내용·#태그 검색',
                  leading: const Icon(Icons.search_rounded),
                  elevation: const WidgetStatePropertyAll(0),
                  backgroundColor: WidgetStatePropertyAll(
                    theme.colorScheme.surfaceContainerHigh,
                  ),
                  trailing: [
                    if (searching)
                      IconButton(
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () {
                          state._search.clear();
                          state.update(() => state._query = '');
                        },
                      ),
                  ],
                  onChanged: (v) => state.update(() => state._query = v),
                ),
              ),
            ),
          ),
          if (empty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _EmptyState(
                searching: searching,
                configured: app.settings.isConfigured,
              ),
            ),
          if (folders.isNotEmpty) ...[
            const _SectionHeader('폴더'),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverGrid.builder(
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: wide ? 260 : 220,
                  mainAxisExtent: 64,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                ),
                itemCount: folders.length,
                itemBuilder: (context, i) => _FolderCard(
                  folder: folders[i],
                  count: app.countUnder(folders[i]),
                  images: app.attachmentsUnder(folders[i]),
                  color: app.folderColor(folders[i]),
                  onTap: () => state._openFolder(folders[i]),
                  onAction: (a) => switch (a) {
                    'rename' => state._renameFolder(folders[i]),
                    'move' => state._moveFolder(folders[i]),
                    'color' => state._pickFolderColor(folders[i]),
                    _ => state._deleteFolder(folders[i]),
                  },
                ),
              ),
            ),
          ],
          if (notes.isNotEmpty) ...[
            _SectionHeader(searching ? '검색 결과 ${notes.length}개' : '메모'),
            if (state._grid)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
                sliver: SliverGrid.builder(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    childAspectRatio: 0.82,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  ),
                  itemCount: notes.length,
                  itemBuilder: (context, i) => _NoteCard(
                    note: notes[i],
                    showFolder: searching || favorites,
                    favorite: app.isFavorite(notes[i].path),
                    selected: state._selected.contains(notes[i].path),
                    onTap: () => selecting
                        ? state._toggleSelect(notes[i].path)
                        : state._open(notes[i]),
                    onLongPress: () => state._toggleSelect(notes[i].path),
                    onAction: (a) => _noteAction(a, notes[i]),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 96),
                sliver: SliverList.builder(
                  itemCount: notes.length,
                  itemBuilder: (context, i) => _NoteRow(
                    note: notes[i],
                    showFolder: searching || favorites,
                    favorite: app.isFavorite(notes[i].path),
                    selected: state._selected.contains(notes[i].path),
                    onTap: () => selecting
                        ? state._toggleSelect(notes[i].path)
                        : state._open(notes[i]),
                    onLongPress: () => state._toggleSelect(notes[i].path),
                    onAction: (a) => _noteAction(a, notes[i]),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  void _showTags(BuildContext context, AppState app) {
    final tags = app.tagCounts;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: tags.isEmpty
              ? const Text('아직 태그가 없습니다. 메모에 #태그 를 적어 보세요.')
              : Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final e in tags.entries)
                      ActionChip(
                        avatar: const Icon(Icons.tag_rounded, size: 16),
                        label: Text('${e.key}  ${e.value}'),
                        onPressed: () {
                          Navigator.pop(context);
                          openTag(context, e.key);
                        },
                      ),
                  ],
                ),
        ),
      ),
    );
  }

  void _noteAction(String action, Note note) => switch (action) {
    'favorite' => app.setFavorite([note.path], !app.isFavorite(note.path)),
    'select' => state._toggleSelect(note.path),
    'rename' => state._renameNote(note),
    'move' => state._moveNote(note),
    _ => state._deleteNote(note),
  };
}

class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({
    required this.folder,
    required this.onOpen,
    required this.showRootTitle,
  });

  final String folder;
  final ValueChanged<String> onOpen;
  final bool showRootTitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (folder.isEmpty) {
      return Text(
        showRootTitle ? 'rmoca' : '모든 메모',
        style: theme.textTheme.headlineSmall?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      );
    }
    final parts = folder.split('/');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          parts.last,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          reverse: true,
          child: Row(
            children: [
              _crumb(context, '모든 메모', ''),
              for (var i = 0; i < parts.length - 1; i++) ...[
                _sep(context),
                _crumb(context, parts[i], parts.sublist(0, i + 1).join('/')),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _crumb(BuildContext context, String label, String path) => InkWell(
    borderRadius: BorderRadius.circular(4),
    onTap: () => onOpen(path),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelMedium
          ?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );

  Widget _sep(BuildContext context) => Icon(
    Icons.chevron_right_rounded,
    size: 16,
    color: Theme.of(context).colorScheme.outline,
  );
}

/// Desktop/tablet sidebar with the folder tree.
class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.state, required this.app});

  final _HomeScreenState state;
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.surfaceContainerLow,
      child: SafeArea(
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 12, 12),
              child: Row(
                children: [
                  const _Logo(),
                  const SizedBox(width: 10),
                  Text(
                    'rmoca',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: '새 폴더',
                    icon: const Icon(Icons.create_new_folder_outlined),
                    onPressed: state._newFolder,
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                children: [
                  _TreeRow(
                    icon: Icons.notes_rounded,
                    label: '모든 메모',
                    count: app.notes.length,
                    depth: 0,
                    selected: state._folder.isEmpty && !state._favorites,
                    onTap: () => state._openFolder(''),
                  ),
                  _TreeRow(
                    icon: Icons.star_rounded,
                    label: '즐겨찾기',
                    count: app.favorites.length,
                    depth: 0,
                    selected: state._favorites,
                    onTap: state._showFavorites,
                  ),
                  _TreeRow(
                    icon: Icons.delete_outline_rounded,
                    label: '휴지통',
                    count: app.trash.length,
                    depth: 0,
                    selected: false,
                    onTap: () => openTrash(context),
                  ),
                  _TreeRow(
                    icon: Icons.today_rounded,
                    label: '오늘의 노트',
                    count: null,
                    depth: 0,
                    selected: false,
                    onTap: () => openDailyNote(context),
                  ),
                  _TreeRow(
                    icon: Icons.calendar_month_rounded,
                    label: '캘린더',
                    count: null,
                    depth: 0,
                    selected: false,
                    onTap: () => openCalendar(context),
                  ),
                  _TreeRow(
                    icon: Icons.hub_outlined,
                    label: '그래프',
                    count: null,
                    depth: 0,
                    selected: false,
                    onTap: () => openGraph(context),
                  ),
                  _TreeRow(
                    icon: Icons.search_rounded,
                    label: '빠른 이동',
                    trailing: 'Ctrl K',
                    count: null,
                    depth: 0,
                    selected: false,
                    onTap: () => showQuickSwitcher(context),
                  ),
                  const _SidebarHeader('폴더'),
                  ..._tree(context, ''),
                  if (app.tagCounts.isNotEmpty) ...[
                    const _SidebarHeader('태그'),
                    for (final e in app.tagCounts.entries)
                      _TreeRow(
                        icon: Icons.tag_rounded,
                        label: e.key.split('/').last,
                        count: e.value,
                        depth: e.key.split('/').length,
                        selected: false,
                        onTap: () => openTag(context, e.key),
                      ),
                  ],
                ],
              ),
            ),
            const Divider(height: 1),
            Material(
              type: MaterialType.transparency,
              child: ListTile(
                leading: const Icon(Icons.settings_outlined),
                title: const Text('설정'),
                subtitle: Text(
                  app.settings.isConfigured
                      ? app.settings.displayTarget
                      : '저장소 연결 안 됨',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.of(context).pushNamed('/settings'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _tree(BuildContext context, String parent) {
    final rows = <Widget>[];
    for (final f in app.subfolders(parent)) {
      final hasChildren = app.subfolders(f).isNotEmpty;
      final open = state._expanded.contains(f);
      rows.add(
        _TreeRow(
          iconColor: app.folderColor(f),
          icon: open ? Icons.folder_open_rounded : Icons.folder_rounded,
          label: p.posix.basename(f),
          count: app.countUnder(f),
          depth: f.split('/').length,
          selected: state._folder == f,
          expanded: hasChildren ? open : null,
          onToggle: () => state.update(() {
            if (!state._expanded.remove(f)) state._expanded.add(f);
          }),
          onTap: () => state._openFolder(f),
        ),
      );
      if (open) rows.addAll(_tree(context, f));
    }
    return rows;
  }
}

class _TreeRow extends StatelessWidget {
  const _TreeRow({
    required this.icon,
    required this.label,
    required this.count,
    required this.depth,
    required this.selected,
    required this.onTap,
    this.expanded,
    this.onToggle,
    this.trailing,
    this.iconColor,
  });

  final Color? iconColor;
  final IconData icon;
  final String label;
  final int? count;
  final String? trailing;
  final int depth;
  final bool selected;
  final VoidCallback onTap;

  /// null when the folder has no subfolders (no chevron).
  final bool? expanded;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: selected ? scheme.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: SizedBox(
            height: 40,
            child: Row(
              children: [
                SizedBox(width: 4.0 + (depth - 1).clamp(0, 8) * 16),
                SizedBox(
                  width: 28,
                  child: expanded == null
                      ? null
                      : InkWell(
                          borderRadius: BorderRadius.circular(6),
                          onTap: onToggle,
                          child: AnimatedRotation(
                            turns: expanded! ? 0.25 : 0,
                            duration: const Duration(milliseconds: 150),
                            child: Icon(
                              Icons.chevron_right_rounded,
                              size: 20,
                              color: fg,
                            ),
                          ),
                        ),
                ),
                Icon(
                  icon,
                  size: 20,
                  color: iconColor ?? (selected ? scheme.primary : fg),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: fg,
                      fontWeight: selected ? FontWeight.w600 : null,
                    ),
                  ),
                ),
                Text(
                  trailing ?? (count == null ? '' : '$count'),
                  style: Theme.of(context).textTheme.labelSmall
                      ?.copyWith(color: scheme.outline),
                ),
                const SizedBox(width: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarHeader extends StatelessWidget {
  const _SidebarHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 18, 14, 6),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: Theme.of(context).colorScheme.outline,
        letterSpacing: 0.5,
      ),
    ),
  );
}

class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [scheme.primary, scheme.tertiary],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Icon(Icons.edit_rounded, size: 18, color: scheme.onPrimary),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: Theme.of(context).colorScheme.outline,
          letterSpacing: 0.4,
        ),
      ),
    ),
  );
}

PopupMenuButton<String> _actionsMenu(
  ValueChanged<String> onAction, {
  bool folder = false,
  bool favorite = false,
}) => PopupMenuButton<String>(
  icon: const Icon(Icons.more_horiz_rounded, size: 20),
  tooltip: '메뉴',
  onSelected: onAction,
  itemBuilder: (context) => [
    if (!folder) ...[
      PopupMenuItem(
        value: 'favorite',
        child: ListTile(
          leading: Icon(
            favorite ? Icons.star_rounded : Icons.star_outline_rounded,
          ),
          title: Text(favorite ? '즐겨찾기 해제' : '즐겨찾기'),
        ),
      ),
      const PopupMenuItem(
        value: 'select',
        child: ListTile(
          leading: Icon(Icons.check_circle_outline_rounded),
          title: Text('선택'),
        ),
      ),
    ],
    if (folder)
      const PopupMenuItem(
        value: 'color',
        child: ListTile(
          leading: Icon(Icons.palette_outlined),
          title: Text('색상'),
        ),
      ),
    const PopupMenuItem(
      value: 'rename',
      child: ListTile(
        leading: Icon(Icons.drive_file_rename_outline),
        title: Text('이름 바꾸기'),
      ),
    ),
    const PopupMenuItem(
      value: 'move',
      child: ListTile(
        leading: Icon(Icons.drive_file_move_outline),
        title: Text('폴더로 이동'),
      ),
    ),
    PopupMenuItem(
      value: 'delete',
      child: ListTile(
        leading: Icon(
          Icons.delete_outline_rounded,
          color: Theme.of(context).colorScheme.error,
        ),
        title: Text(folder ? '폴더 삭제' : '삭제'),
      ),
    ),
  ],
);

class _FolderCard extends StatelessWidget {
  const _FolderCard({
    required this.folder,
    required this.count,
    required this.onTap,
    required this.onAction,
    this.color,
    this.images = 0,
  });

  final String folder;
  final int count;
  final int images;
  final Color? color;
  final VoidCallback onTap;
  final ValueChanged<String> onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: color == null
          ? scheme.surfaceContainer
          : Color.alphaBlend(color!.withValues(alpha: 0.14), scheme.surface),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Row(
          children: [
            const SizedBox(width: 14),
            Icon(
              Icons.folder_rounded,
              color: color ?? scheme.primary,
              size: 28,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    p.posix.basename(folder),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    images > 0 ? '메모 $count개 · 이미지 $images개' : '메모 $count개',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: scheme.outline),
                  ),
                ],
              ),
            ),
            _actionsMenu(onAction, folder: true),
          ],
        ),
      ),
    );
  }
}

String _formatDate(DateTime d) {
  final now = DateTime.now();
  if (d.year == now.year && d.month == now.month && d.day == now.day) {
    return DateFormat('HH:mm').format(d);
  }
  if (d.year == now.year) return DateFormat('M월 d일').format(d);
  return DateFormat('yyyy. M. d.').format(d);
}

/// Thumbnail: the drawing for drawing notes / memos with drawings, else text.
class _NotePreview extends StatelessWidget {
  const _NotePreview({required this.note});

  final Note note;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final app = context.read<AppState>();
    final key = ValueKey(
      '${note.path}@${note.modified.millisecondsSinceEpoch}',
    );
    Widget? drawing;
    if (note.kind == NoteKind.drawing) {
      drawing = FutureBuilder<String>(
        key: key,
        future: app.store.readText(note.path),
        builder: (context, snap) =>
            snap.hasData ? SvgView(snap.data!) : const SizedBox.shrink(),
      );
    } else if (note.embeddedSvg != null) {
      drawing = SvgView(note.embeddedSvg!, key: key);
    }
    if (drawing != null) {
      return ColoredBox(
        color: Colors.white,
        child: Padding(padding: const EdgeInsets.all(10), child: drawing),
      );
    }
    return Container(
      color: scheme.surfaceContainerLowest,
      padding: const EdgeInsets.all(14),
      alignment: Alignment.topLeft,
      child: Text(
        note.preview.isEmpty ? '내용 없음' : note.preview,
        maxLines: 6,
        overflow: TextOverflow.fade,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: note.preview.isEmpty
              ? scheme.outline
              : scheme.onSurfaceVariant,
          height: 1.5,
        ),
      ),
    );
  }
}

class _NoteCard extends StatelessWidget {
  const _NoteCard({
    required this.note,
    required this.showFolder,
    required this.onTap,
    required this.onAction,
    required this.onLongPress,
    this.favorite = false,
    this.selected = false,
  });

  final Note note;
  final bool showFolder;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final ValueChanged<String> onAction;
  final bool favorite;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: selected
            ? BorderSide(color: scheme.primary, width: 2.5)
            : BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _NotePreview(note: note),
                  if (favorite)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Icon(
                        Icons.star_rounded,
                        size: 20,
                        color: Colors.amber.shade600,
                      ),
                    ),
                  if (selected)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: CircleAvatar(
                        radius: 12,
                        backgroundColor: scheme.primary,
                        child: Icon(
                          Icons.check_rounded,
                          size: 16,
                          color: scheme.onPrimary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Divider(
              height: 1,
              color: scheme.outlineVariant.withValues(alpha: 0.6),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 0, 6),
              child: Row(
                children: [
                  Icon(
                    note.kind == NoteKind.drawing
                        ? Icons.draw_rounded
                        : Icons.description_outlined,
                    size: 16,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          note.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          showFolder && note.folder.isNotEmpty
                              ? '${note.folder} · ${_formatDate(note.modified)}'
                              : _formatDate(note.modified),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.outline,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _actionsMenu(onAction, favorite: favorite),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoteRow extends StatelessWidget {
  const _NoteRow({
    required this.note,
    required this.showFolder,
    required this.onTap,
    required this.onAction,
    required this.onLongPress,
    this.favorite = false,
    this.selected = false,
  });

  final Note note;
  final bool showFolder;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final ValueChanged<String> onAction;
  final bool favorite;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final subtitle = [
      _formatDate(note.modified),
      if (showFolder && note.folder.isNotEmpty) note.folder,
      if (note.preview.isNotEmpty) note.preview,
    ].join(' · ');
    return ListTile(
      selected: selected,
      selectedTileColor: scheme.secondaryContainer,
      onLongPress: onLongPress,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 48,
          height: 48,
          child: note.kind == NoteKind.drawing || note.embeddedSvg != null
              ? _NotePreview(note: note)
              : ColoredBox(
                  color: scheme.secondaryContainer,
                  child: Icon(
                    Icons.description_outlined,
                    color: scheme.onSecondaryContainer,
                  ),
                ),
        ),
      ),
      title: Text(
        favorite ? '★ ${note.title}' : note.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: selected
          ? Icon(Icons.check_circle_rounded, color: scheme.primary)
          : _actionsMenu(onAction, favorite: favorite),
      onTap: onTap,
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.searching, required this.configured});

  final bool searching;
  final bool configured;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(
                searching ? Icons.search_off_rounded : Icons.edit_note_rounded,
                size: 44,
                color: scheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              searching ? '검색 결과가 없습니다' : '아직 메모가 없습니다',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              searching ? '다른 검색어를 입력해 보세요' : '아래 버튼으로 메모, 그림, 폴더를 만들어 보세요',
              style: TextStyle(color: scheme.outline),
            ),
            if (!searching && !configured) ...[
              const SizedBox(height: 16),
              OutlinedButton.icon(
                icon: const Icon(Icons.link_rounded),
                label: const Text('Git 저장소 연결하기'),
                onPressed: () => Navigator.of(context).pushNamed('/settings'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CreateTile extends StatelessWidget {
  const _CreateTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: scheme.primaryContainer,
        child: Icon(icon, color: scheme.onPrimaryContainer),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle),
      onTap: onTap,
    );
  }
}

/// Name + optional template for a new memo.
class _NewNoteDialog extends StatefulWidget {
  const _NewNoteDialog({required this.initialName, required this.templates});

  final String initialName;
  final List<Note> templates;

  @override
  State<_NewNoteDialog> createState() => _NewNoteDialogState();
}

class _NewNoteDialogState extends State<_NewNoteDialog> {
  late final _name = TextEditingController(text: widget.initialName)
    ..selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.initialName.length,
    );
  Note? _template;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, (_name.text, _template));

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('새 메모'),
    content: SizedBox(
      width: 400,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(labelText: '이름'),
            onSubmitted: (_) => _submit(),
          ),
          if (widget.templates.isNotEmpty) ...[
            const SizedBox(height: 16),
            DropdownButtonFormField<Note?>(
              initialValue: _template,
              decoration: const InputDecoration(labelText: '템플릿'),
              items: [
                const DropdownMenuItem(value: null, child: Text('빈 메모')),
                for (final t in widget.templates)
                  DropdownMenuItem(value: t, child: Text(t.title)),
              ],
              onChanged: (t) => setState(() => _template = t),
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('취소'),
      ),
      FilledButton(onPressed: _submit, child: const Text('만들기')),
    ],
  );
}

/// Name + storage mode for a new drawing.
class _NewDrawingDialog extends StatefulWidget {
  const _NewDrawingDialog({required this.initialName, required this.mode});

  final String initialName;
  final DrawingMode mode;

  @override
  State<_NewDrawingDialog> createState() => _NewDrawingDialogState();
}

class _NewDrawingDialogState extends State<_NewDrawingDialog> {
  late final _name = TextEditingController(text: widget.initialName)
    ..selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.initialName.length,
    );
  late DrawingMode _mode = widget.mode;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, (_name.text, _mode));

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('새 그림'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(labelText: '이름'),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 20),
            Text('저장 방식', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            SegmentedButton<DrawingMode>(
              segments: const [
                ButtonSegment(
                  value: DrawingMode.file,
                  icon: Icon(Icons.insert_drive_file_outlined),
                  label: Text('SVG 파일'),
                ),
                ButtonSegment(
                  value: DrawingMode.embedded,
                  icon: Icon(Icons.code_rounded),
                  label: Text('메모에 넣기'),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
            const SizedBox(height: 8),
            Text(
              _mode == DrawingMode.file
                  ? '.svg 파일로 저장합니다. 다른 메모에서 링크해 쓸 수 있습니다.'
                  : '.md 메모를 만들고 <svg> 코드를 그 안에 넣습니다. 글과 그림을 한 파일에 담을 수 있습니다.',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.outline),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        FilledButton(onPressed: _submit, child: const Text('그리기')),
      ],
    );
  }
}

/// Lets the user pick a destination folder from the tree.
class _FolderPickerDialog extends StatelessWidget {
  const _FolderPickerDialog({required this.title, this.exclude});

  final String title;

  /// A folder being moved: it and its subfolders can't be the destination.
  final String? exclude;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final options = [
      '',
      ...app.folders.where(
        (f) => exclude == null || !Note.isWithin(exclude!, f),
      ),
    ];
    return AlertDialog(
      title: Text(title),
      contentPadding: const EdgeInsets.symmetric(vertical: 12),
      content: SizedBox(
        width: 400,
        height: 360,
        child: ListView(
          children: [
            for (final f in options)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.only(
                  left: 24.0 + (f.isEmpty ? 0 : f.split('/').length * 18),
                  right: 24,
                ),
                leading: Icon(
                  f.isEmpty ? Icons.home_rounded : Icons.folder_rounded,
                  color: scheme.primary,
                ),
                title: Text(f.isEmpty ? '최상위' : p.posix.basename(f)),
                onTap: () => Navigator.pop(context, f),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            final controller = TextEditingController();
            final name = await showDialog<String>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('새 폴더 (최상위)'),
                content: TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: '이름'),
                  onSubmitted: (v) => Navigator.pop(context, v),
                ),
                actions: [
                  FilledButton(
                    onPressed: () => Navigator.pop(context, controller.text),
                    child: const Text('만들기'),
                  ),
                ],
              ),
            );
            if (name == null || name.trim().isEmpty) return;
            final path = await app.createFolder('', name);
            if (context.mounted) Navigator.pop(context, path);
          },
          child: const Text('새 폴더'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
      ],
    );
  }
}

class _PanePlaceholder extends StatelessWidget {
  const _PanePlaceholder();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surfaceContainerLowest,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.article_outlined,
              size: 56,
              color: scheme.outlineVariant,
            ),
            const SizedBox(height: 12),
            Text('메모를 선택하세요', style: TextStyle(color: scheme.outline)),
            const SizedBox(height: 4),
            Text(
              '목록에서 고른 메모가 여기에 열립니다',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.outline),
            ),
          ],
        ),
      ),
    );
  }
}
