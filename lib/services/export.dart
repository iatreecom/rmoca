import 'dart:convert';

import 'package:markdown/markdown.dart' as md;

import '../markdown/embedded_drawings.dart';

/// A standalone HTML page for [markdown] (drawings stay inline as SVG).
String noteToHtml(String title, String markdown) {
  final body = md.markdownToHtml(
    markdown
        // Obsidian-only syntax, made readable in any browser.
        .replaceAllMapped(
          RegExp(r'!?\[\[([^\]|#]+)(?:#[^\]|]*)?(?:\|([^\]]+))?\]\]'),
          (m) => m[2] ?? m[1]!,
        )
        .replaceAllMapped(
          RegExp(r'==([^=\n]+)=='),
          (m) => '<mark>${m[1]}</mark>',
        )
        .replaceAll(RegExp(r'%%[\s\S]*?%%'), ''),
    extensionSet: md.ExtensionSet.gitHubWeb,
    inlineSyntaxes: [md.InlineHtmlSyntax()],
  );
  final safeTitle = const HtmlEscape().convert(title);
  return '''<!doctype html>
<html lang="ko"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$safeTitle</title>
<style>
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","Noto Sans KR",sans-serif;
max-width:760px;margin:40px auto;padding:0 20px;line-height:1.7;color:#1f2328}
pre,code{font-family:Menlo,Consolas,"DejaVu Sans Mono",monospace;background:#f6f8fa;border-radius:6px}
pre{padding:12px;overflow:auto}code{padding:2px 4px}
table{border-collapse:collapse}td,th{border:1px solid #d0d7de;padding:6px 12px}
blockquote{margin:0;padding:0 1em;color:#59636e;border-left:4px solid #d0d7de}
img,svg{max-width:100%;height:auto}mark{background:#fff3a3}
@media (prefers-color-scheme:dark){body{background:#0d1117;color:#e6edf3}
pre,code{background:#161b22}td,th{border-color:#30363d}}
</style></head><body>
$body
</body></html>
''';
}

/// The note's text without embedded drawings (for sharing as plain text).
String shareableText(String markdown) => EmbeddedDrawings.textOnly(markdown);
