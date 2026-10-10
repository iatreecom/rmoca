import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rmoca/markdown/html_lite.dart';
import 'package:rmoca/markdown/note_links.dart';
import 'package:rmoca/markdown/svg_css.dart';
import 'package:rmoca/services/media_cache.dart';
import 'package:xml/xml.dart';

void main() {
  group('SvgCss', () {
    test('applies class, id and tag rules in specificity order', () {
      const svg = '''<svg xmlns="http://www.w3.org/2000/svg">
<style>
  rect { fill: #000 }
  .a { fill: #f00; stroke: blue }
  #b { fill: #0f0 }
  g .c, .d { opacity: .5 }
  .x:hover { fill: pink }
</style>
<rect class="a"/><rect id="b" class="a"/><rect/><g><circle class="c"/></g>
<rect class="a" style="fill:#00f"/>
</svg>''';
      final doc = XmlDocument.parse(SvgCss.prepare(svg));
      final els = doc.rootElement.childElements.toList();
      expect(doc.findAllElements('style'), isEmpty);
      String? style(int i) => els[i].getAttribute('style');
      // tag rule, then class rule (later wins).
      expect(style(0), 'fill: #000;fill: #f00; stroke: blue');
      expect(style(1)!.endsWith('fill: #0f0'), isTrue);
      expect(style(2), 'fill: #000');
      expect(els[3].firstElementChild!.getAttribute('style'), 'opacity: .5');
      // An element's own style attribute stays last (highest priority).
      expect(style(4)!.endsWith('fill:#00f'), isTrue);
      expect(SvgCss.prepare(svg), isNot(contains('pink')));
    });

    test('SVG without <style> is returned unchanged', () {
      const svg = '<svg><rect/></svg>';
      expect(SvgCss.prepare(svg), same(svg));
    });
  });

  group('HtmlLite', () {
    test('img, links, emphasis and wrappers become markdown', () {
      const html =
          '<p align="center"><img src="logo.png" width="120" alt="Logo"></p>\n'
          '<b>bold</b> <i>it</i> <mark>hi</mark> <kbd>Ctrl</kbd> <a href="https://x.y">x</a>\n'
          'line<br>break\n'
          '<hr>';
      final md = HtmlLite.toMarkdown(html);
      expect(md.split('\n'), [
        '![Logo|120](<logo.png>)',
        '**bold** *it* ==hi== `Ctrl` [x](<https://x.y>)',
        'line break',
        '---',
      ]);
    });

    test('code is left alone and line count is kept', () {
      const src =
          '```html\n<img src="a.png">\n```\nuse `<b>` tags\n- [ ] <b>task</b>';
      final md = HtmlLite.toMarkdown(src);
      expect(md.split('\n').length, src.split('\n').length);
      expect(md, contains('<img src="a.png">'));
      expect(md, contains('use `<b>` tags'));
      expect(md, contains('- [ ] **task**'));
    });

    test('raw svg data URIs are escaped into a valid link', () {
      final md = HtmlLite.toMarkdown(
        '<img src="data:image/svg+xml;utf8,<svg xmlns=\'http://www.w3.org/2000/svg\'><circle r=\'4\'/></svg>">',
      );
      expect(md, startsWith('![](<data:image/svg+xml;utf8,%3Csvg'));
      expect(md, isNot(contains(' ')));
    });
  });

  test('data URIs decode (base64 and URL-encoded)', () {
    final png = parseDataUri('data:image/png;base64,iVBORw0KGgo=')!;
    expect(png.mime, 'image/png');
    expect(png.bytes.take(4), [0x89, 0x50, 0x4E, 0x47]);
    final svg = parseDataUri('data:image/svg+xml;utf8,%3Csvg%3E%3C/svg%3E')!;
    expect(looksLikeSvg(svg.bytes, mime: svg.mime), isTrue);
    // Raw, unencoded SVG after ;utf8, (common on the web).
    final raw = parseDataUri(
      "data:image/svg+xml;utf8,<svg xmlns='x'><rect/></svg>",
    )!;
    expect(utf8.decode(raw.bytes), "<svg xmlns='x'><rect/></svg>");
    expect(parseDataUri('data:nonsense'), isNull);
  });

  test('remote images are found for offline prefetch', () {
    final links = NoteLinks.extract(
      'n.md',
      '![a](https://ex.com/a.png) <img src="https://ex.com/b.svg"> '
          '![c](local.png) `![d](https://ex.com/code.png)`',
    );
    expect(links.remoteMedia, ['https://ex.com/a.png', 'https://ex.com/b.svg']);
  });

  test('media cache stores downloads and serves them offline', () async {
    final dir = await Directory.systemTemp.createTemp('media');
    addTearDown(() => dir.delete(recursive: true));
    var online = true;
    var requests = 0;
    final client = MockClient((req) async {
      requests++;
      if (!online) throw const SocketException('offline');
      return http.Response.bytes(utf8.encode('<svg/>'), 200);
    });
    final cache = MediaCache(dir, client: client);

    expect(await cache.prefetch(['https://ex.com/a.svg']), 1);
    online = false;
    final bytes = await cache.get('https://ex.com/a.svg');
    expect(utf8.decode(bytes!), '<svg/>');
    expect(requests, 1);

    // Not cached and offline: null, and no hammering on retries.
    expect(await cache.get('https://ex.com/missing.png'), isNull);
    expect(await cache.get('https://ex.com/missing.png'), isNull);
    expect(requests, 2);
    expect(await cache.has('https://ex.com/a.svg'), isTrue);
    expect(Uint8List, isNotNull);
  });
}
