import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:rmoca/app_state.dart';
import 'package:rmoca/main.dart';
import 'package:rmoca/services/local_store.dart';
import 'package:rmoca/services/settings_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A tour of the app on a real device (phone, tablet, simulator, desktop).
/// With `--dart-define=SCREENSHOTS=true` under `flutter drive` it saves a
/// screenshot of every screen (see test_driver/integration_test.dart).
const _screenshots = bool.fromEnvironment('SCREENSHOTS');

const _rich = r'''---
tags: [데모]
---
# rmoca 둘러보기

**굵게**, *기울임*, ==형광펜==, `코드`, [[할 일]] 링크와 #태그.

> [!tip] 콜아웃
> 오프라인에서도 모두 보입니다.

- [x] 마크다운 메모
- [ ] 펜으로 그리기
- [ ] Git 동기화

| 항목 | 수량 |
| --- | --: |
| 사과 | 3 |
| 배 | 12 |

인라인 수식 $e^{i\pi} + 1 = 0$, 블록 수식:

$$
\int_0^1 x^2\,dx = \frac{1}{3}
$$

```mermaid
flowchart LR
  A[메모 작성] --> B{온라인?}
  B -->|예| C[동기화]
  B -->|아니오| D[로컬 저장]
```

```python
print("안녕")
```
''';

const _drawing = '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 240" width="400" height="240">
<rect width="400" height="240" fill="#fffdf6"/>
<path d="M40 180 C 100 40, 180 40, 240 160 S 340 200, 370 60" fill="none" stroke="#2563eb" stroke-width="6" stroke-linecap="round"/>
<circle cx="120" cy="110" r="30" fill="none" stroke="#ef4444" stroke-width="5"/>
</svg>
''';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  var shot = 0;
  final mobile = Platform.isAndroid || Platform.isIOS;

  /// Desktop: the plugin cannot capture the screen, so render the app's
  /// root layer ourselves and hand the PNGs to the driver at the end.
  final desktopShots = <String, String>{};
  final root = GlobalKey();

  Future<void> settle(WidgetTester tester, [int frames = 30]) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> screenshot(WidgetTester tester, String name) async {
    await settle(tester);
    if (!_screenshots) return;
    if (Platform.isAndroid && shot == 0) {
      await binding.convertFlutterSurfaceToImage();
      await tester.pump();
    }
    shot++;
    final id = '${shot.toString().padLeft(2, '0')}-$name';
    if (mobile) {
      await binding.takeScreenshot(id);
      return;
    }
    final boundary =
        root.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final png = await tester.runAsync(() async {
      final image = await boundary.toImage(
        pixelRatio: tester.view.devicePixelRatio,
      );
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    });
    desktopShots[id] = base64Encode(png!);
  }

  Future<void> back(WidgetTester tester) async {
    final button = find.byTooltip('Back');
    if (button.evaluate().isNotEmpty) {
      await tester.tap(button.first);
    } else {
      await tester.pageBack();
    }
    await settle(tester);
  }

  testWidgets('app tour', (tester) async {
    await initializeDateFormatting('ko');
    // Fresh settings: no sync target, so nothing but the sample notes.
    SharedPreferences.setMockInitialValues({});
    final dir = await Directory.systemTemp.createTemp('rmoca_tour');
    final store = await LocalStore.openAt(dir);
    await store.writeText('rmoca 둘러보기.md', _rich);
    await store.writeText(
      '할 일.md',
      '# 할 일\n\n- [ ] 장보기\n- [ ] [[rmoca 둘러보기]] 읽기\n',
    );
    await store.writeText(
      '공부/수학.md',
      r'# 수학'
          '\n\n'
          r'$$\sum_{k=1}^n k = \frac{n(n+1)}{2}$$'
          '\n',
    );
    await store.writeText('그림.svg', _drawing);
    final app = AppState(store, SettingsRepository());
    await app.init();
    await app.setEasyEditing(true);

    await tester.pumpWidget(
      RepaintBoundary(
        key: root,
        child: ChangeNotifierProvider.value(
          value: app,
          child: const RmocaApp(),
        ),
      ),
    );
    await screenshot(tester, 'home');

    // A rich note in reading mode.
    await tester.tap(find.text('rmoca 둘러보기').first);
    await screenshot(tester, 'note');

    // Easy (block) editing: tap a block to edit just that block.
    await tester.tap(find.byTooltip('쉬운 편집 (블록)'));
    await settle(tester);
    await tester.tap(find.text('콜아웃').first);
    await screenshot(tester, 'easy-edit');

    // The block menu (also opened by typing / on an empty line).
    await tester.tap(find.byTooltip('블록 넣기 (/)'));
    await screenshot(tester, 'block-menu');
    await tester.tapAt(const Offset(10, 10));
    await settle(tester);
    await tester.tap(find.text('완료'));
    await settle(tester);

    // Markdown source.
    await tester.tap(find.byTooltip('마크다운 편집'));
    await screenshot(tester, 'markdown');

    // Back to the list (on tablets the note was in the side pane).
    if (find.byTooltip('닫기').evaluate().isNotEmpty) {
      await tester.tap(find.byTooltip('닫기'));
      await settle(tester);
    } else {
      await back(tester);
    }

    // Drawing editor.
    await tester.tap(find.text('그림').first);
    await screenshot(tester, 'drawing');
    await back(tester);

    // Settings.
    final settings = find.text('설정');
    if (settings.evaluate().isNotEmpty) {
      await tester.tap(settings.first);
    } else {
      await tester.tap(find.byTooltip('더보기'));
      await settle(tester);
      await tester.tap(find.text('설정').last);
    }
    await settle(tester);
    await tester.tap(find.text('Git 서버 (HTTPS)'));
    await screenshot(tester, 'settings');

    expect(tester.takeException(), isNull);
    if (desktopShots.isNotEmpty) {
      binding.reportData = {'desktop_screenshots': desktopShots};
    }
  });
}
