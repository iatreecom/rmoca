import 'package:xml/xml.dart';

/// Makes SVGs from design tools render correctly.
///
/// The SVG renderer understands `style="…"` attributes but not `<style>`
/// elements, which Illustrator, Figma, draw.io and others use for colors.
/// This applies simple CSS rules (tag, `.class`, `#id`, combinations and
/// selector lists) as inline styles, in specificity order, and drops the
/// `<style>` elements.
class SvgCss {
  static final Map<int, String> _cache = {};

  static String prepare(String svg) {
    if (!svg.contains('<style')) return svg;
    final key = svg.hashCode;
    final cached = _cache[key];
    if (cached != null) return cached;
    final result = _inline(svg);
    if (_cache.length > 64) _cache.remove(_cache.keys.first);
    return _cache[key] = result;
  }

  static String _inline(String svg) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(svg);
    } on XmlException {
      return svg;
    }
    final styles = doc.findAllElements('style').toList();
    final rules = <_Rule>[];
    var order = 0;
    for (final style in styles) {
      final css = style.innerText.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
      // Skip @media/@font-face blocks; keep plain rules.
      final plain = css.replaceAll(
        RegExp(r'@[^{]+\{([^{}]*\{[^{}]*\})*[^{}]*\}'),
        '',
      );
      for (final m in RegExp(r'([^{}]+)\{([^{}]*)\}').allMatches(plain)) {
        final decls = m[2]!.trim();
        if (decls.isEmpty) continue;
        for (final raw in m[1]!.split(',')) {
          final selector = raw.trim();
          if (selector.isEmpty || selector.contains(':')) continue;
          // Descendant/child selectors: match on the last part.
          final last = selector.split(RegExp(r'[\s>+~]+')).last;
          final parsed = _Selector.parse(last);
          if (parsed != null) rules.add(_Rule(parsed, decls, order++));
        }
      }
      style.remove();
    }
    if (rules.isEmpty) return doc.toXmlString();
    rules.sort((a, b) {
      final s = a.selector.specificity.compareTo(b.selector.specificity);
      return s != 0 ? s : a.order.compareTo(b.order);
    });
    for (final el in doc.descendants.whereType<XmlElement>()) {
      final matching = rules.where((r) => r.selector.matches(el));
      if (matching.isEmpty) continue;
      final own = el.getAttribute('style');
      final combined = [
        for (final r in matching)
          r.declarations.replaceAll(RegExp(r';\s*$'), ''),
        if (own != null && own.trim().isNotEmpty) own,
      ].join(';');
      el.setAttribute('style', combined);
    }
    return doc.toXmlString();
  }
}

class _Rule {
  _Rule(this.selector, this.declarations, this.order);

  final _Selector selector;
  final String declarations;
  final int order;
}

class _Selector {
  _Selector(this.tag, this.id, this.classes);

  final String? tag;
  final String? id;
  final List<String> classes;

  int get specificity =>
      (id == null ? 0 : 100) + classes.length * 10 + (tag == null ? 0 : 1);

  static _Selector? parse(String s) {
    final m = RegExp(r'^([A-Za-z][\w-]*|\*)?((?:[.#][\w-]+)*)$').firstMatch(s);
    if (m == null) return null;
    final tag = m[1] == null || m[1] == '*' ? null : m[1];
    String? id;
    final classes = <String>[];
    for (final part in RegExp(r'[.#][\w-]+').allMatches(m[2] ?? '')) {
      final v = part[0]!;
      if (v.startsWith('#')) {
        id = v.substring(1);
      } else {
        classes.add(v.substring(1));
      }
    }
    if (tag == null && id == null && classes.isEmpty && m[1] != '*') {
      return null;
    }
    return _Selector(tag, id, classes);
  }

  bool matches(XmlElement el) {
    if (tag != null && el.name.local != tag) return false;
    if (id != null && el.getAttribute('id') != id) return false;
    if (classes.isNotEmpty) {
      final own = (el.getAttribute('class') ?? '').split(RegExp(r'\s+'));
      if (!classes.every(own.contains)) return false;
    }
    return true;
  }
}
