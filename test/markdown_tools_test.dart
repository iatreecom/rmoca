import 'package:flutter_test/flutter_test.dart';
import 'package:rmoca/markdown/embedded_drawings.dart';
import 'package:rmoca/markdown/link_rewriter.dart';

void main() {
  group('LinkRewriter', () {
    test('fixes links when the note moves into a folder', () {
      const md =
          '![a](a.svg) [b](notes/b.md) [web](https://x.y/a.md) [top](#h)';
      final out = LinkRewriter.rewrite(
        md,
        oldPath: 'memo.md',
        newPath: 'work/memo.md',
        moves: {'memo.md': 'work/memo.md'},
      );
      expect(
        out,
        '![a](../a.svg) [b](../notes/b.md) [web](https://x.y/a.md) [top](#h)',
      );
    });

    test('fixes links to a renamed drawing, keeping names readable', () {
      const md = '![그림](<old name.svg>) and ![x](old%20name.svg "title")';
      final out = LinkRewriter.rewrite(
        md,
        oldPath: 'memo.md',
        newPath: 'memo.md',
        moves: {'old name.svg': '그림/새 그림.svg'},
      );
      expect(out, '![그림](<그림/새 그림.svg>) and ![x](<그림/새 그림.svg> "title")');
    });

    test('links inside a moved folder keep working', () {
      const md = '![d](d.svg) ![up](../top.svg)';
      final out = LinkRewriter.rewrite(
        md,
        oldPath: 'a/memo.md',
        newPath: 'b/c/memo.md',
        moves: {'a/memo.md': 'b/c/memo.md', 'a/d.svg': 'b/c/d.svg'},
      );
      expect(out, '![d](d.svg) ![up](../../top.svg)');
    });

    test('untouched content is returned as is', () {
      const md = '![a](a.svg)';
      expect(
        LinkRewriter.rewrite(md, oldPath: 'm.md', newPath: 'm.md', moves: {}),
        md,
      );
    });
  });

  group('EmbeddedDrawings', () {
    const svg =
        '<svg xmlns="http://www.w3.org/2000/svg" data-generator="rmoca-drawing" data-id="abc">\n'
        '  <path d="M0,0Z"/>\n'
        '</svg>';
    final md = '# Title\n\nbefore\n\n$svg\n\nafter\n';

    test('splits text and drawings and joins back exactly', () {
      final segments = EmbeddedDrawings.split(md);
      expect(segments.where((s) => s.isSvg).single.id, 'abc');
      expect(segments.map((s) => s.svg ?? s.text).join('\n'), md);
      expect(EmbeddedDrawings.textOnly(md), isNot(contains('<svg')));
      expect(EmbeddedDrawings.firstSvg(md), svg);
    });

    test('ignores svg inside fenced code', () {
      final code = '```html\n$svg\n```\n';
      expect(EmbeddedDrawings.split(code).any((s) => s.isSvg), isFalse);
    });

    test('replaces a drawing by id or appends a new one', () {
      final replaced = EmbeddedDrawings.replace(
        md,
        'abc',
        '<svg data-id="abc">\n</svg>',
      );
      expect(replaced, contains('<svg data-id="abc">\n</svg>'));
      expect(replaced, isNot(contains('M0,0Z')));
      expect(replaced, endsWith('after\n'));

      final appended = EmbeddedDrawings.replace(
        'text',
        'new',
        '<svg data-id="new"></svg>',
      );
      expect(appended, 'text\n\n<svg data-id="new"></svg>\n');
    });
  });
}
