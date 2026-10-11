import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmoca/markdown/blocks.dart';
import 'package:rmoca/markdown/edit_helpers.dart';
import 'package:rmoca/markdown/md_table.dart';

void main() {
  const note = '''---
tags: [a]
---
# 제목

첫 문단
이어지는 줄
## 소제목
- [ ] 할 일
- [x] 끝

```dart
void main() {

  print(1);
}
```

\$\$
x^2

+ 1
\$\$

> [!tip] 팁
> 내용

| a | b |
| --- | :-: |
| 1 | 2 |

---
<svg id="d1">
<path/>
</svg>
![[그림.png]]
''';

  test('splits into blocks with exact ranges', () {
    final blocks = splitBlocks(note);
    expect(
      [for (final b in blocks) b.kind],
      [
        BlockKind.frontmatter,
        BlockKind.heading,
        BlockKind.paragraph,
        BlockKind.heading,
        BlockKind.tasks,
        BlockKind.code,
        BlockKind.math,
        BlockKind.callout,
        BlockKind.table,
        BlockKind.rule,
        BlockKind.drawing,
        BlockKind.embed,
      ],
    );
    for (final b in blocks) {
      expect(note.substring(b.start, b.end), b.text);
    }
    expect(blocks[2].text, '첫 문단\n이어지는 줄');
    expect(blocks[5].text, contains('\n\n  print(1);'));
    expect(blocks[6].text, '\$\$\nx^2\n\n+ 1\n\$\$');
    expect(blocks[4].firstLine, 8);
  });

  test('replacing a block leaves the rest untouched', () {
    final blocks = splitBlocks(note);
    final out = replaceBlock(note, blocks[2], '바뀐 문단');
    expect(out, note.replaceFirst('첫 문단\n이어지는 줄', '바뀐 문단'));
  });

  test('removing a block keeps one blank line', () {
    const src = '# a\n\npara\n\n\n- x\n';
    final blocks = splitBlocks(src);
    expect(replaceBlock(src, blocks[1], ''), '# a\n\n- x\n');
    expect(replaceBlock(src, blocks[2], ' '), '# a\n\npara\n');
    expect(replaceBlock(src, blocks[0], ''), 'para\n\n\n- x\n');
  });

  test('inserting and moving blocks', () {
    const src = '# a\n\npara\n';
    final blocks = splitBlocks(src);
    final (out, start) = insertBlock(src, blocks, 1, '- [ ] new');
    expect(out, '# a\n\n- [ ] new\n\npara\n');
    expect(out.substring(start), startsWith('- [ ] new'));
    expect(insertBlock(src, blocks, 2, 'end').$1, '# a\n\npara\n\nend\n');
    expect(insertBlock('', const [], 0, 'x').$1, 'x\n');
    expect(moveBlock(src, blocks, 1, 0), 'para\n\n# a\n');
    final fm = splitBlocks('---\na: 1\n---\nx\n\ny\n');
    expect(
      moveBlock('---\na: 1\n---\nx\n\ny\n', fm, 2, 0),
      '---\na: 1\n---\n\ny\n\nx\n',
    );
  });

  test('tables round trip and edit', () {
    final t = MdTable.parse(
      '| 이름 | 값 |\n|:--|--:|\n| a \\| b | `x\\|y` |\n| c |',
    )!;
    expect(t.header, ['이름', '값']);
    expect(t.aligns, [ColumnAlign.left, ColumnAlign.right]);
    expect(t.rows, [
      ['a \\| b', '`x\\|y`'],
      ['c', ''],
    ]);
    t
      ..addColumn()
      ..addRow();
    t.rows.last[2] = 'new|cell';
    expect(t.encode(), '''| 이름 | 값 | 열 3 |
| :--- | ---: | --- |
| a \\| b | `x\\|y` |  |
| c |  |  |
|  |  | new\\|cell |''');
    expect(MdTable.parse('just text\nmore'), isNull);
  });

  test('list continuation, slash trigger, prefixes', () {
    var v = continueList(
      '- [x] 하나',
      const TextEditingValue(
        text: '- [x] 하나\n',
        selection: TextSelection.collapsed(offset: 9),
      ),
    )!;
    expect(v.text, '- [x] 하나\n- [ ] ');
    v = continueList(
      '1. a\n2. ',
      const TextEditingValue(
        text: '1. a\n2. \n',
        selection: TextSelection.collapsed(offset: 9),
      ),
    )!;
    expect(v.text, '1. a\n');

    expect(
      typedSlashAtLineStart(
        'ab\n  ',
        const TextEditingValue(
          text: 'ab\n  /',
          selection: TextSelection.collapsed(offset: 6),
        ),
      ),
      isTrue,
    );
    expect(
      typedSlashAtLineStart(
        '',
        const TextEditingValue(
          text: '/',
          selection: TextSelection.collapsed(offset: 1),
        ),
      ),
      isTrue,
    );
    expect(
      continueList(
        '',
        const TextEditingValue(
          text: '\n',
          selection: TextSelection.collapsed(offset: 1),
        ),
      ),
      isNull,
    );
    expect(
      typedSlashAtLineStart(
        'a',
        const TextEditingValue(
          text: 'a/',
          selection: TextSelection.collapsed(offset: 2),
        ),
      ),
      isFalse,
    );

    v = setLinePrefix(
      const TextEditingValue(
        text: 'x\n## 제목',
        selection: TextSelection.collapsed(offset: 6),
      ),
      '# ',
    );
    expect(v.text, 'x\n# 제목');
    v = setLinePrefix(v, '# ');
    expect(v.text, 'x\n제목');
    v = setLinePrefix(
      const TextEditingValue(
        text: '- 항목',
        selection: TextSelection.collapsed(offset: 4),
      ),
      '- [ ] ',
    );
    expect(v.text, '- [ ] 항목');

    v = insertSnippet(
      const TextEditingValue(
        text: 'ab',
        selection: TextSelection.collapsed(offset: 1),
      ),
      '[[$caretMark]]',
    );
    expect(v.text, 'a[[]]b');
    expect(v.selection.start, 3);
  });
}
