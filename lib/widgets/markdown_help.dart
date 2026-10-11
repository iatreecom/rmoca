import 'package:flutter/material.dart';

import 'note_view.dart';
import '../theme.dart';

const _sections = <(String, List<(String, String)>)>[
  (
    '글자',
    [
      ('굵게', '**굵게**'),
      ('기울임', '*기울임*'),
      ('취소선', '~~취소선~~'),
      ('형광펜', '==형광펜=='),
      ('코드', '`코드`'),
      ('줄바꿈', '줄 끝에 공백 두 칸  \n다음 줄'),
    ],
  ),
  (
    '제목과 목록',
    [
      ('제목', '# 제목 1\n## 제목 2'),
      ('목록', '- 사과\n- 배\n  - 들여쓰기'),
      ('번호 목록', '1. 첫째\n2. 둘째'),
      ('체크리스트', '- [ ] 할 일\n- [x] 끝낸 일'),
      ('인용', '> 인용문'),
      ('구분선', '---'),
    ],
  ),
  (
    '링크와 그림',
    [
      ('메모 링크', '[[다른 메모]]'),
      ('표시 이름', '[[다른 메모|보이는 글자]]'),
      ('메모 넣기', '![[다른 메모]]'),
      ('웹 링크', '[rmoca](https://example.com)'),
      ('이미지', '![설명](attachments/사진.jpg)'),
      ('태그', '#태그 #일/회의'),
    ],
  ),
  (
    '블록',
    [
      ('표', '| 이름 | 값 |\n| --- | --: |\n| 사과 | 3 |'),
      ('콜아웃', '> [!tip] 팁\n> 내용'),
      ('코드 블록', '```python\nprint("안녕")\n```'),
      ('수식', r'$E = mc^2$'),
      ('수식 블록', '\$\$\n\\int_0^1 x^2\\,dx = \\frac{1}{3}\n\$\$'),
      ('다이어그램', '```mermaid\nflowchart LR\n  A --> B\n```'),
      ('주석 (숨김)', '보임 %%안 보임%%'),
    ],
  ),
];

/// A markdown cheat sheet: syntax next to how it looks. Tapping an entry
/// returns its syntax so it can be inserted.
Future<String?> showMarkdownHelp(BuildContext context, String notePath) =>
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        final wide = MediaQuery.sizeOf(context).width >= 700;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.85,
            ),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              children: [
                Text(
                  '마크다운 문법',
                  style: Theme.of(context).textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  '항목을 누르면 커서 위치에 넣습니다',
                  style: TextStyle(color: scheme.outline),
                ),
                for (final (title, rows) in _sections) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(0, 16, 0, 6),
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.labelLarge
                          ?.copyWith(color: scheme.primary),
                    ),
                  ),
                  for (final (name, syntax) in rows)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Material(
                        color: scheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(12),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => Navigator.pop(context, syntax),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Flex(
                              direction: wide ? Axis.horizontal : Axis.vertical,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                  width: wide ? 96 : null,
                                  child: Text(
                                    name,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                if (!wide) const SizedBox(height: 6),
                                _pair(
                                  wide,
                                  Text(
                                    syntax,
                                    style: TextStyle(
                                      fontFamily: monoFont,
                                      fontFamilyFallback: monoFallback,
                                      fontSize: 13,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                                if (!wide) const SizedBox(height: 6),
                                _pair(
                                  wide,
                                  IgnorePointer(
                                    child: NoteView(
                                      source: syntax,
                                      notePath: notePath,
                                      actions: NoteViewActions(
                                        openPath: (_) {},
                                        openTag: (_) {},
                                        openMissingWiki: (_) {},
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
        );
      },
    );

Widget _pair(bool wide, Widget child) => wide
    ? Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: child,
        ),
      )
    : child;
