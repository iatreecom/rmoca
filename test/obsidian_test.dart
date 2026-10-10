import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:rmoca/markdown/note_document.dart';
import 'package:rmoca/markdown/note_links.dart';
import 'package:rmoca/markdown/obsidian_syntax.dart';

void main() {
  const note = '''---
tags: [work, idea/new]
status: draft
---
# Title

Text with [[Other note|alias]] and #inline-tag %%hidden%% here.

> [!warning]- Careful
> folded body
> - [ ] inside callout

![[Diagram]]

\$\$
E = mc^2
\$\$

```md
# not a heading
- [ ] not a task
```

## Second
- [ ] top
  - [x] nested
- [ ] last
''';

  test('parses frontmatter, callouts, embeds, math and headings', () {
    final doc = NoteDocument.parse(note);
    expect(doc.properties['status'], 'draft');
    expect(doc.propertyTags, ['work', 'idea/new']);
    expect(doc.headings.map((h) => h.text), ['Title', 'Second']);

    final callout = doc.blocks.whereType<CalloutBlock>().single;
    expect(callout.type, 'warning');
    expect(callout.title, 'Careful');
    expect(callout.foldable, isTrue);
    expect(callout.initiallyOpen, isFalse);
    expect(callout.body.text, 'folded body\n- [ ] inside callout');

    expect(doc.blocks.whereType<EmbedBlock>().single.target, 'Diagram');
    expect(doc.blocks.whereType<MathBlock>().single.tex, 'E = mc^2');

    final text = doc.blocks.whereType<TextBlock>().map((b) => b.text).join();
    expect(text, isNot(contains('hidden')));
  });

  test('text lines keep their source line numbers', () {
    final doc = NoteDocument.parse(note);
    final lines = note.split('\n');
    for (final b in doc.blocks.whereType<TextBlock>()) {
      final own = b.text.split('\n');
      for (var i = 0; i < own.length; i++) {
        if (lines[b.lines[i]].contains('%%')) continue;
        expect(
          lines[b.lines[i]].startsWith(own[i].trimRight()),
          isTrue,
          reason: 'line ${b.lines[i]}: "${lines[b.lines[i]]}" vs "${own[i]}"',
        );
      }
    }
  });

  test('checkbox order maps to the right source lines for nested tasks', () {
    final doc = NoteDocument.parse(note);
    final last = doc.blocks.whereType<TextBlock>().last;
    final lines = note.split('\n');
    final mapped = checkboxLines(last.text, last.lines)!;
    // The renderer builds nested items first (post-order).
    expect(mapped.map((l) => lines[l].trim()), [
      '- [x] nested',
      '- [ ] top',
      '- [ ] last',
    ]);
  });

  test('toggles a task on a given line', () {
    const src = 'a\n- [ ] one\n  - [x] two';
    expect(NoteDocument.toggleTask(src, 1), 'a\n- [x] one\n  - [x] two');
    expect(NoteDocument.toggleTask(src, 2), 'a\n- [ ] one\n  - [ ] two');
  });

  test('extracts tags and links, ignoring code', () {
    final links = NoteLinks.extract('folder/n.md', note);
    expect(links.tags, containsAll(['work', 'idea/new', 'inline-tag']));
    expect(links.tags, isNot(contains('not')));
    expect(links.wikiTargets, ['Other note', 'Diagram']);
  });

  test('resolves wikilinks like Obsidian', () {
    final paths = [
      'a/Plan.md',
      'b/Plan.md',
      'Plan.md',
      'x/Diagram.svg',
      'x/deep/Note.md',
    ];
    expect(resolveWikiTarget('Plan', 'b/here.md', paths), 'Plan.md');
    expect(resolveWikiTarget('b/Plan', 'here.md', paths), 'b/Plan.md');
    expect(resolveWikiTarget('Diagram', 'here.md', paths), 'x/Diagram.svg');
    expect(
      resolveWikiTarget('Note#Section', 'here.md', paths),
      'x/deep/Note.md',
    );
    expect(resolveWikiTarget('Missing', 'here.md', paths), isNull);
  });

  group('inline math', () {
    List<String> maths(String text) {
      final nodes = md.Document(
        extensionSet: obsidianExtensions,
        inlineSyntaxes: obsidianInlineSyntaxes(),
      ).parseInline(text);
      final out = <String>[];
      void walk(md.Node n) {
        if (n is md.Element) {
          if (n.tag == 'math') {
            out.add('${n.attributes['display']}:${n.textContent}');
          }
          n.children?.forEach(walk);
        }
      }

      nodes.forEach(walk);
      return out;
    }

    test(r'$x$, \(x\) and inline $$x$$', () {
      expect(maths(r'a $x^2$ b \(\alpha_1\) c $$\sum_i i$$'), [
        r'false:x^2',
        r'false:\alpha_1',
        r'true:\sum_i i',
      ]);
    });

    test('prices are not math', () {
      expect(maths(r'it costs $5 and $10 today'), isEmpty);
      expect(maths(r'$ x $ is not math'), isEmpty);
    });

    test('underscores and stars inside math are not emphasis', () {
      expect(maths(r'$a_1 * b_2 * c$'), [r'false:a_1 * b_2 * c']);
    });

    test(r'\[ \] display blocks are parsed', () {
      final doc = NoteDocument.parse('text\n\\[\nE = mc^2\n\\]\nmore');
      expect(doc.blocks.whereType<MathBlock>().single.tex, 'E = mc^2');
    });

    test('math and blocks inside callouts keep source lines', () {
      const src = '> [!note] T\n> \$\$x\$\$\n> - [ ] task';
      final doc = NoteDocument.parse(src);
      final body = doc.blocks.whereType<CalloutBlock>().single.body;
      final inner = NoteDocument.parse(
        body.text,
        frontmatter: false,
        lineMap: body.lines,
      );
      expect(inner.blocks.whereType<MathBlock>().single.tex, 'x');
      expect(inner.blocks.whereType<TextBlock>().last.lines, [2]);
    });
  });
}
