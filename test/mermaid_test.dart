import 'package:flutter_test/flutter_test.dart';
import 'package:mermaid_core/mermaid_core.dart';
import 'package:rmoca/widgets/mermaid_block.dart';

void main() {
  const m = Mermaid(measurer: ApproximateTextMeasurer());

  test('dotted labels without spaces are accepted', () {
    final src = MermaidBlock.normalize(
      'flowchart LR\n  D -.연결되면.-> C\n  A -.x.- B',
    );
    expect(src, contains('-. 연결되면 .->'));
    expect(() => m.render(src), returnsNormally);
  });

  test('normalizing leaves ordinary links alone', () {
    const src = 'flowchart LR\n  A --> B\n  B -.-> C\n  C -. y .-> D';
    expect(MermaidBlock.normalize(src), src);
  });

  for (final diagram in {
    'flowchart':
        'flowchart TD\n  A[시작] --> B{조건}\n  B -->|예| C\n  B -->|아니오| D',
    'sequence': 'sequenceDiagram\n  A->>B: 안녕\n  B-->>A: 응답',
    'class': 'classDiagram\n  Animal <|-- Duck',
    'state': 'stateDiagram-v2\n  [*] --> A\n  A --> [*]',
    'pie': 'pie title T\n  "a" : 1\n  "b" : 2',
    'gantt':
        'gantt\n  dateFormat YYYY-MM-DD\n  section S\n  T :a1, 2026-01-01, 3d',
    'er': 'erDiagram\n  A ||--o{ B : has',
    'mindmap': 'mindmap\n  root((메모))\n    a\n    b',
  }.entries) {
    test('renders ${diagram.key}', () {
      expect(() => m.render(diagram.value), returnsNormally);
    });
  }
}
