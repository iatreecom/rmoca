import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';

import '../markdown/tex.dart';
import '../theme.dart';

/// LaTeX formula, inline or display. Unsupported input shows the source
/// (with the parser's message on hover) instead of failing silently.
class MathView extends StatelessWidget {
  const MathView(this.tex, {super.key, this.display = false, this.style});

  final String tex;
  final bool display;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base =
        (style ??
                (display ? theme.textTheme.bodyLarge : null) ??
                const TextStyle())
            .copyWith(color: style?.color ?? theme.colorScheme.onSurface);
    final n = TexNormalizer.normalize(tex);
    final math = Math.tex(
      n.tex,
      mathStyle: display ? MathStyle.display : MathStyle.text,
      textStyle: display
          ? base.copyWith(fontSize: (base.fontSize ?? 16) * 1.1)
          : base,
      onErrorFallback: (e) => Tooltip(
        message: e.message,
        child: Text(
          display ? '\$\$${tex.trim()}\$\$' : '\$$tex\$',
          style: base.copyWith(
            fontFamily: monoFont,
            fontFamilyFallback: monoFallback,
            color: theme.colorScheme.error,
            decoration: TextDecoration.underline,
            decorationStyle: TextDecorationStyle.wavy,
            decorationColor: theme.colorScheme.error.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
    if (!display) return math;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: math,
              ),
            ),
          ),
          for (final tag in n.tags)
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Text('($tag)', style: base),
            ),
        ],
      ),
    );
  }
}
