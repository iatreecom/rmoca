import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../markdown/line_diff.dart';
import '../services/local_store.dart';
import '../theme.dart';
import '../widgets/note_view.dart';

/// Earlier versions of a note kept on this device, with restore.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, required this.path});

  final String path;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  late final Future<(String, List<(NoteVersion, String)>)> _data = _loadAll();

  Future<(String, List<(NoteVersion, String)>)> _loadAll() async {
    final store = context.read<AppState>().store;
    final current = await store.exists(widget.path)
        ? await store.readText(widget.path)
        : '';
    final versions = await store.versions(widget.path);
    return (current, [for (final v in versions) (v, await v.read())]);
  }

  static String _relative(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return '방금';
    if (d.inHours < 1) return '${d.inMinutes}분 전';
    if (d.inDays < 1) return '${d.inHours}시간 전';
    if (d.inDays < 30) return '${d.inDays}일 전';
    return DateFormat('yyyy-MM-dd').format(t);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('버전 기록')),
      body: FutureBuilder(
        future: _data,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final (current, versions) = snap.data!;
          if (versions.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  '아직 저장된 이전 버전이 없습니다.\n'
                  '메모를 고치거나 다른 기기의 변경이 동기화되면 '
                  '이전 내용이 이 기기에 보관됩니다 (메모당 최근 ${LocalStore.maxVersions}개).',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.outline),
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: versions.length,
            separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
            itemBuilder: (context, i) {
              final (v, text) = versions[i];
              final (added, removed) = diffStats(diffLines(text, current));
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: scheme.secondaryContainer,
                  child: Icon(
                    Icons.history_rounded,
                    color: scheme.onSecondaryContainer,
                  ),
                ),
                title: Text(DateFormat('M월 d일 (E) HH:mm', 'ko').format(v.time)),
                subtitle: Text(
                  '${_relative(v.time)} · 지금과 비교 '
                  '+$added줄 −$removed줄',
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () async {
                  final restored = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(
                      builder: (_) => _VersionScreen(
                        path: widget.path,
                        version: v,
                        text: text,
                        current: current,
                      ),
                    ),
                  );
                  if (restored == true && context.mounted) {
                    Navigator.of(context).pop();
                  }
                },
              );
            },
          );
        },
      ),
    );
  }
}

class _VersionScreen extends StatefulWidget {
  const _VersionScreen({
    required this.path,
    required this.version,
    required this.text,
    required this.current,
  });

  final String path;
  final NoteVersion version;
  final String text;
  final String current;

  @override
  State<_VersionScreen> createState() => _VersionScreenState();
}

class _VersionScreenState extends State<_VersionScreen> {
  bool _showDiff = true;

  Future<void> _restore() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('이 버전으로 복원'),
        content: const Text('지금 내용은 버전 기록에 남겨 두고 이 버전으로 바꿉니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('복원'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await context.read<AppState>().restoreVersion(widget.path, widget.text);
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final diff = diffLines(widget.text, widget.current);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          DateFormat('M월 d일 HH:mm', 'ko').format(widget.version.time),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: SegmentedButton<bool>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: const [
                ButtonSegment(value: true, label: Text('변경 내용')),
                ButtonSegment(value: false, label: Text('보기')),
              ],
              selected: {_showDiff},
              onSelectionChanged: (s) => setState(() => _showDiff = s.first),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _restore,
        icon: const Icon(Icons.restore_rounded),
        label: const Text('이 버전으로 복원'),
      ),
      body: _showDiff
          ? ListView(
              padding: const EdgeInsets.fromLTRB(0, 8, 0, 96),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    '빨간 줄: 이 버전에만 있음 · 초록 줄: 지금 내용에만 있음',
                    style: Theme.of(context).textTheme.labelMedium
                        ?.copyWith(color: scheme.outline),
                  ),
                ),
                for (final line in diff)
                  Container(
                    color: switch (line.op) {
                      DiffOp.added => Colors.green.withValues(alpha: 0.18),
                      DiffOp.removed => scheme.error.withValues(alpha: 0.16),
                      DiffOp.same => null,
                    },
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 1,
                    ),
                    child: Text(
                      '${switch (line.op) {
                        DiffOp.added => '+',
                        DiffOp.removed => '−',
                        DiffOp.same => ' ',
                      }} ${line.text}',
                      style: TextStyle(
                        fontFamily: monoFont,
                        fontFamilyFallback: monoFallback,
                        fontSize: 13,
                        color: line.op == DiffOp.same ? scheme.outline : null,
                      ),
                    ),
                  ),
              ],
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 96),
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 780),
                  child: NoteView(
                    source: widget.text,
                    notePath: widget.path,
                    actions: NoteViewActions(
                      openPath: (_) {},
                      openTag: (_) {},
                      openMissingWiki: (_) {},
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
