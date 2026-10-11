import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../markdown/edit_helpers.dart';
import '../theme.dart';

/// What a block template does besides inserting text.
enum BlockAction { text, table, drawing, image, camera, date, time }

/// An entry of the block menu (the `/` menu).
class BlockTemplate {
  const BlockTemplate(
    this.label,
    this.icon,
    this.snippet, {
    this.group = '기본',
    this.keywords = '',
    this.action = BlockAction.text,
    this.blockLevel = true,
  });

  final String label;
  final IconData icon;

  /// Markdown to insert; [caretMark] marks the cursor position.
  final String snippet;
  final String group;
  final String keywords;
  final BlockAction action;

  /// Whether it must stand on its own lines (tables, code, callouts…).
  final bool blockLevel;

  String get preview => snippet.replaceAll(caretMark, '').split('\n').first;

  /// The snippet with dynamic values (dates) filled in.
  String resolve(DateTime now) => switch (action) {
    BlockAction.date => DateFormat('yyyy-MM-dd (E)', 'ko').format(now),
    BlockAction.time => DateFormat('HH:mm').format(now),
    _ => snippet,
  };

  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return '$label $keywords $group'.toLowerCase().contains(q);
  }
}

const _c = caretMark;

const blockTemplates = <BlockTemplate>[
  BlockTemplate('텍스트', Icons.notes_rounded, _c, keywords: 'text p 문단'),
  BlockTemplate(
    '제목 1',
    Icons.looks_one_outlined,
    '# $_c',
    keywords: 'h1 heading',
  ),
  BlockTemplate(
    '제목 2',
    Icons.looks_two_outlined,
    '## $_c',
    keywords: 'h2 heading',
  ),
  BlockTemplate(
    '제목 3',
    Icons.looks_3_outlined,
    '### $_c',
    keywords: 'h3 heading',
  ),
  BlockTemplate(
    '글머리 목록',
    Icons.format_list_bulleted_rounded,
    '- $_c',
    keywords: 'list ul bullet',
  ),
  BlockTemplate(
    '번호 목록',
    Icons.format_list_numbered_rounded,
    '1. $_c',
    keywords: 'list ol number',
  ),
  BlockTemplate(
    '체크리스트',
    Icons.check_box_outlined,
    '- [ ] $_c',
    keywords: 'todo task 할일',
  ),
  BlockTemplate(
    '인용',
    Icons.format_quote_rounded,
    '> $_c',
    keywords: 'quote blockquote',
  ),
  BlockTemplate(
    '구분선',
    Icons.horizontal_rule_rounded,
    '---',
    keywords: 'divider hr line',
  ),
  BlockTemplate(
    '메모 콜아웃',
    Icons.info_outline_rounded,
    '> [!note] $_c\n> 내용',
    group: '강조',
    keywords: 'callout note',
  ),
  BlockTemplate(
    '팁',
    Icons.lightbulb_outline_rounded,
    '> [!tip] $_c\n> 내용',
    group: '강조',
    keywords: 'callout tip hint',
  ),
  BlockTemplate(
    '주의',
    Icons.warning_amber_rounded,
    '> [!warning] $_c\n> 내용',
    group: '강조',
    keywords: 'callout warning caution',
  ),
  BlockTemplate(
    '위험',
    Icons.dangerous_outlined,
    '> [!danger] $_c\n> 내용',
    group: '강조',
    keywords: 'callout danger error',
  ),
  BlockTemplate(
    '접는 콜아웃',
    Icons.unfold_less_rounded,
    '> [!example]- $_c\n> 펼치면 보이는 내용',
    group: '강조',
    keywords: 'callout fold collapse toggle 토글',
  ),
  BlockTemplate(
    '표',
    Icons.table_chart_outlined,
    '| 항목 | 내용 |\n| --- | --- |\n|  |  |',
    group: '데이터',
    keywords: 'table grid',
    action: BlockAction.table,
  ),
  BlockTemplate(
    '코드',
    Icons.code_rounded,
    '```\n$_c\n```',
    group: '데이터',
    keywords: 'code fence',
  ),
  BlockTemplate(
    '수식',
    Icons.functions_rounded,
    '\$\$\n$_c\n\$\$',
    group: '데이터',
    keywords: 'math latex tex equation',
  ),
  BlockTemplate(
    '순서도',
    Icons.account_tree_outlined,
    '```mermaid\nflowchart TD\n  A[시작] --> B{조건}\n  B -->|예| C[처리]\n  B -->|아니오| D[끝]\n```',
    group: '데이터',
    keywords: 'mermaid flowchart diagram graph 다이어그램',
  ),
  BlockTemplate(
    '시퀀스 다이어그램',
    Icons.swap_horiz_rounded,
    '```mermaid\nsequenceDiagram\n  사용자->>앱: 요청\n  앱-->>사용자: 응답\n```',
    group: '데이터',
    keywords: 'mermaid sequence diagram',
  ),
  BlockTemplate(
    '파이 차트',
    Icons.pie_chart_outline_rounded,
    '```mermaid\npie title 비율\n  "A" : 40\n  "B" : 35\n  "C" : 25\n```',
    group: '데이터',
    keywords: 'mermaid pie chart',
  ),
  BlockTemplate(
    '간트 차트',
    Icons.view_timeline_outlined,
    '```mermaid\ngantt\n  dateFormat YYYY-MM-DD\n  section 계획\n  준비 :a1, 2026-01-01, 7d\n  진행 :after a1, 14d\n```',
    group: '데이터',
    keywords: 'mermaid gantt schedule 일정',
  ),
  BlockTemplate(
    '사진 / 이미지',
    Icons.image_outlined,
    '',
    group: '삽입',
    keywords: 'image photo picture gallery 갤러리',
    action: BlockAction.image,
  ),
  BlockTemplate(
    '카메라',
    Icons.photo_camera_outlined,
    '',
    group: '삽입',
    keywords: 'camera photo 촬영',
    action: BlockAction.camera,
  ),
  BlockTemplate(
    '손글씨 그림',
    Icons.draw_outlined,
    '',
    group: '삽입',
    keywords: 'drawing pen sketch svg 필기',
    action: BlockAction.drawing,
  ),
  BlockTemplate(
    '메모 링크',
    Icons.link_rounded,
    '[[$_c]]',
    group: '삽입',
    keywords: 'link wiki 연결',
    blockLevel: false,
  ),
  BlockTemplate(
    '메모 넣기',
    Icons.input_rounded,
    '![[$_c]]',
    group: '삽입',
    keywords: 'embed transclude 임베드',
  ),
  BlockTemplate(
    '태그',
    Icons.tag_rounded,
    '#$_c',
    group: '삽입',
    keywords: 'tag',
    blockLevel: false,
  ),
  BlockTemplate(
    '오늘 날짜',
    Icons.today_rounded,
    '',
    group: '삽입',
    keywords: 'date today',
    action: BlockAction.date,
    blockLevel: false,
  ),
  BlockTemplate(
    '현재 시각',
    Icons.schedule_rounded,
    '',
    group: '삽입',
    keywords: 'time now',
    action: BlockAction.time,
    blockLevel: false,
  ),
  BlockTemplate(
    '접기 (details)',
    Icons.expand_circle_down_outlined,
    '<details>\n<summary>$_c</summary>\n펼치면 보이는 내용\n</details>',
    group: '강조',
    keywords: 'details summary fold toggle 토글',
  ),
];

/// Shows the block menu; returns the chosen template.
Future<BlockTemplate?> showBlockMenu(BuildContext context) =>
    showModalBottomSheet<BlockTemplate>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => const _BlockMenu(),
    );

class _BlockMenu extends StatefulWidget {
  const _BlockMenu();

  @override
  State<_BlockMenu> createState() => _BlockMenuState();
}

class _BlockMenuState extends State<_BlockMenu> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final items = blockTemplates.where((t) => t.matches(_query)).toList();
    final groups = <String, List<BlockTemplate>>{};
    for (final t in items) {
      groups.putIfAbsent(t.group, () => []).add(t);
    }
    final wide = MediaQuery.sizeOf(context).width >= 600;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                autofocus: wide,
                decoration: const InputDecoration(
                  hintText: '블록 검색 (예: 표, 체크, 수식)',
                  prefixIcon: Icon(Icons.search_rounded),
                  contentPadding: EdgeInsets.symmetric(vertical: 12),
                ),
                onChanged: (v) => setState(() => _query = v),
                onSubmitted: (_) {
                  if (items.isNotEmpty) Navigator.pop(context, items.first);
                },
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                children: [
                  for (final g in groups.entries) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
                      child: Text(
                        g.key,
                        style: Theme.of(context).textTheme.labelLarge
                            ?.copyWith(color: scheme.primary),
                      ),
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final t in g.value)
                          SizedBox(
                            width: wide
                                ? 200
                                : (MediaQuery.sizeOf(context).width - 40) / 2,
                            child: _Item(template: t),
                          ),
                      ],
                    ),
                  ],
                  if (items.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: Text('일치하는 블록이 없습니다')),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Item extends StatelessWidget {
  const _Item({required this.template});

  final BlockTemplate template;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final preview = template.preview;
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => Navigator.pop(context, template),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  template.icon,
                  size: 20,
                  color: scheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      template.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    if (preview.trim().isNotEmpty)
                      Text(
                        preview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: monoFont,
                          fontFamilyFallback: monoFallback,
                          fontSize: 11,
                          color: scheme.outline,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
