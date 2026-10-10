import 'package:flutter_math_fork/tex.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmoca/markdown/tex.dart';

void main() {
  const formulas = [
    r'\begin{align} a &= b + c \\ d &= e \end{align}',
    r'\begin{align*} a &= b \end{align*}',
    r'\begin{equation} x = 1 \end{equation}',
    r'\begin{gather} a \\ b \end{gather}',
    r'\begin{multline} a \\ b \end{multline}',
    r'\begin{split} a &= b \\ &= c \end{split}',
    r'\begin{equation}\begin{split} a &= b \\ &= c \end{split}\end{equation}',
    r'\tag{1} x',
    r'\label{eq:1} x = 1',
    r'a = b \nonumber \\',
    r'\newcommand{\R}{\mathbb{R}} \R^n',
    r'\newcommand{\norm}[1]{\left\lVert #1 \right\rVert} \norm{x}',
    r'\def\e{\mathrm{e}} \e^{i\pi} = -1',
    r'\ce{H2O}',
    r'\ce{2H2 + O2 -> 2H2O}',
    r'\ce{SO4^2-}',
    r'x % a comment',
  ];

  for (final f in formulas) {
    test('renders: $f', () {
      final n = TexNormalizer.normalize(f);
      expect(
        () => TexParser(n.tex, const TexParserSettings()).parse(),
        returnsNormally,
        reason: n.tex,
      );
    });
  }

  test('tags are extracted', () {
    final n = TexNormalizer.normalize(r'E = mc^2 \tag{3.1}');
    expect(n.tags, ['3.1']);
    expect(n.tex, 'E = mc^2');
  });

  test('macro with arguments expands', () {
    final n = TexNormalizer.normalize(
      r'\newcommand{\pair}[2]{(#1, #2)} \pair{a}{b}',
    );
    expect(n.tex, '{(a, b)}');
  });
}
