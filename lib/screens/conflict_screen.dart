import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../markdown/line_diff.dart';
import '../models/note.dart';
import '../services/conflicts.dart';
import '../theme.dart';
import '../widgets/media_view.dart';

/// Notes edited on two devices before they synced: compare both versions
/// and keep one, or keep both as separate notes.
class ConflictScreen extends StatelessWidget {
  const ConflictScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final conflicts = app.conflicts;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('동기화 충돌')),
      body: conflicts.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.check_circle_outline_rounded,
                    size: 56,
                    color: scheme.primary,
                  ),
                  const SizedBox(height: 12),
                  const Text('해결할 충돌이 없습니다'),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Text(
                    '두 기기에서 같은 메모를 동시에 고쳐서, 다른 기기의 내용은 원래 메모에 두고 '
                    '이 기기의 내용은 따로 저장해 두었습니다. 비교해서 하나를 고르거나 둘 다 남기세요.',
                    style: TextStyle(color: scheme.outline),
                  ),
                ),
                for (final c in conflicts)
                  ListTile(
                    leading: Icon(
                      Note.isDrawingPath(c.original)
                          ? Icons.draw_outlined
                          : Icons.call_split_rounded,
                      color: scheme.error,
                    ),
                    title: Text(
                      Note(path: c.original, modified: DateTime(0)).title,
                    ),
                    subtitle: Text(
                      [
                        if (c.copy.folder.isNotEmpty) c.copy.folder,
                        '${c.device} · ${c.when}',
                      ].join(' · '),
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => _ConflictDetail(conflict: c),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _ConflictDetail extends StatefulWidget {
  const _ConflictDetail({required this.conflict});

  final ConflictPair conflict;

  @override
  State<_ConflictDetail> createState() => _ConflictDetailState();
}

class _ConflictDetailState extends State<_ConflictDetail> {
  late final Future<(String?, String)> _texts = _load();

  Future<(String?, String)> _load() async {
    final store = context.read<AppState>().store;
    final c = widget.conflict;
    final original = await store.exists(c.original)
        ? await store.readText(c.original)
        : null;
    return (original, await store.readText(c.copy.path));
  }

  Future<void> _resolve(Future<void> Function() action, String done) async {
    await action();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.conflict;
    final app = context.read<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final drawing = Note.isDrawingPath(c.original);
    return Scaffold(
      appBar: AppBar(
        title: Text(Note(path: c.original, modified: DateTime(0)).title),
      ),
      body: FutureBuilder(
        future: _texts,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final (original, mine) = snap.data!;
          Widget content;
          if (drawing) {
            content = Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                _Side(
                  label: '다른 기기',
                  child: original == null
                      ? const Text('삭제됨')
                      : SvgView(original, height: 280),
                ),
                _Side(
                  label: '이 기기 (${c.device})',
                  child: SvgView(mine, height: 280),
                ),
              ],
            );
          } else {
            final diff = diffLines(original ?? '', mine);
            content = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  original == null
                      ? '다른 기기에서는 이 메모가 삭제되었습니다.'
                      : '빨간 줄: 다른 기기에만 있음 · 초록 줄: 이 기기(${c.device})에만 있음',
                  style: Theme.of(context).textTheme.labelMedium
                      ?.copyWith(color: scheme.outline),
                ),
                const SizedBox(height: 8),
                for (final line in diff)
                  Container(
                    color: switch (line.op) {
                      DiffOp.added => Colors.green.withValues(alpha: 0.18),
                      DiffOp.removed => scheme.error.withValues(alpha: 0.16),
                      DiffOp.same => null,
                    },
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
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
            );
          }
          return Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: content,
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.end,
                    children: [
                      OutlinedButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('둘 다 남기기'),
                      ),
                      FilledButton.tonal(
                        onPressed: () => _resolve(
                          () => app.resolveWithOriginal(c),
                          '다른 기기의 내용을 남겼습니다 (이 기기 사본은 휴지통으로)',
                        ),
                        child: const Text('다른 기기 내용 사용'),
                      ),
                      FilledButton(
                        onPressed: () => _resolve(
                          () => app.resolveWithCopy(c),
                          '이 기기의 내용으로 바꿨습니다 (이전 내용은 버전 기록에)',
                        ),
                        child: Text('이 기기 내용 사용'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Side extends StatelessWidget {
  const _Side({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 6),
      DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Theme.of(context).colorScheme.outline),
        ),
        child: Padding(padding: const EdgeInsets.all(4), child: child),
      ),
    ],
  );
}
