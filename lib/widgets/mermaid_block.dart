import 'package:flutter/material.dart';
import 'package:mermaid_flutter/mermaid_flutter.dart';

import '../theme.dart';

/// A ```mermaid block, drawn natively (no WebView, works offline) with the
/// app's colors. Wide diagrams shrink to fit; the expand button opens a
/// pan/zoom view.
class MermaidBlock extends StatelessWidget {
  MermaidBlock(String source, {super.key}) : source = normalize(source);

  final String source;

  /// mermaid.js also accepts dotted-link labels without spaces
  /// (`A -.text.-> B`); the native parser needs `A -. text .-> B`.
  static String normalize(String source) => source.replaceAllMapped(
    RegExp(r'-\.(?=\S)([^.\n>]+?)\.(-+>?)'),
    (m) => '-. ${m[1]!.trim()} .${m[2]}',
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final mermaidTheme = MaterialMermaidTheme.fromTheme(theme);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 560),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: MermaidDiagram(
                  source: source,
                  theme: mermaidTheme,
                  errorBuilder: (context, error) =>
                      _MermaidError(source: source, error: error),
                ),
              ),
            ),
          ),
          Positioned(
            top: 4,
            right: 4,
            child: IconButton(
              tooltip: '크게 보기',
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.open_in_full_rounded),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (context) => Dialog.fullscreen(
                  child: Scaffold(
                    appBar: AppBar(
                      title: const Text('다이어그램'),
                      leading: IconButton(
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ),
                    body: MermaidView(source: source, theme: mermaidTheme),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MermaidError extends StatelessWidget {
  const _MermaidError({required this.source, required this.error});

  final String source;
  final Object error;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 640,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline_rounded, size: 18, color: scheme.error),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Mermaid 다이어그램을 그릴 수 없습니다: ${error.toString().split('\n').first}',
                  style: TextStyle(color: scheme.error),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SelectableText(
            source,
            style: TextStyle(
              fontFamily: monoFont,
              fontFamilyFallback: monoFallback,
              fontSize: 13,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
