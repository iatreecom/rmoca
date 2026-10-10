import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:rmoca/app_state.dart';
import 'package:rmoca/drawing/stroke.dart';
import 'package:rmoca/drawing/svg_codec.dart';
import 'package:rmoca/screens/drawing_screen.dart';
import 'package:rmoca/screens/home_screen.dart';
import 'package:rmoca/screens/markdown_screen.dart';
import 'package:rmoca/services/local_store.dart';
import 'package:rmoca/services/settings_repository.dart';

void main() {
  late Directory dir;
  late AppState app;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('rmoca_widget');
    final store = await LocalStore.openAt(dir);
    app = AppState(store, SettingsRepository());
  });

  tearDown(() => dir.delete(recursive: true));

  /// Lets real file I/O complete and the UI catch up.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
  }

  Widget wrap(Widget child) => ChangeNotifierProvider.value(
    value: app,
    child: MaterialApp(
      home: child,
      routes: {'/settings': (_) => const SizedBox()},
    ),
  );

  testWidgets('home lists notes', (tester) async {
    await tester.runAsync(() async {
      await app.store.writeText('hello.md', '# Hello\n\nworld');
      await app.refreshNotes();
    });
    await tester.pumpWidget(wrap(const HomeScreen()));
    await tester.pump();
    expect(find.text('hello'), findsOneWidget);
    expect(find.text('새로 만들기'), findsOneWidget);
  });

  testWidgets('markdown note renders preview', (tester) async {
    await tester.runAsync(
      () => app.store.writeText('a.md', '# Title\n\n**bold**'),
    );
    await tester.pumpWidget(wrap(const MarkdownScreen(path: 'a.md')));
    await settle(tester);
    expect(find.text('Title'), findsOneWidget);
  });

  testWidgets('drawing with the pen saves an SVG', (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(wrap(const DrawingScreen(path: 'd.svg')));
    await settle(tester);

    final gesture = await tester.startGesture(const Offset(300, 400));
    for (var i = 1; i <= 10; i++) {
      await gesture.moveTo(Offset(300.0 + i * 20, 400.0 + i * 10));
    }
    await gesture.up();
    await tester.pump();

    // Leaving the screen flushes the pending save.
    await tester.pumpWidget(wrap(const SizedBox()));
    await settle(tester);

    final svg = await tester.runAsync(() => app.store.readText('d.svg'));
    final drawing = SvgCodec.decode(svg!)!;
    expect(drawing.strokes, hasLength(1));
    expect(drawing.strokes.first.points.length, greaterThan(5));
  });

  testWidgets('every screen fits a phone without overflow', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await app.store.writeText(
        '아주 긴 이름의 메모 파일 제목입니다 정말로 깁니다.md',
        '# 제목\n\n본문',
      );
      await app.refreshNotes();
    });

    for (final screen in <Widget>[
      const HomeScreen(),
      const MarkdownScreen(
        path: '아주 긴 이름의 메모 파일 제목입니다 정말로 깁니다.md',
        startEditing: true,
      ),
      const DrawingScreen(path: 'phone.svg'),
    ]) {
      await tester.pumpWidget(wrap(screen));
      await settle(tester);
      expect(tester.takeException(), isNull, reason: '$screen');
    }
  });

  testWidgets('folders: browse into a folder and see its notes', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await app.store.writeText('work/plan.md', '# plan\n\nship it');
      await app.store.writeText('home.md', '# home');
      await app.refreshNotes();
    });
    await tester.pumpWidget(wrap(const HomeScreen()));
    await settle(tester);
    expect(find.text('work'), findsWidgets);
    expect(find.text('plan'), findsNothing);

    await tester.tap(find.text('work').first);
    await settle(tester);
    expect(find.text('plan'), findsOneWidget);
    expect(find.text('home'), findsNothing);
  });

  testWidgets('a drawing embedded in a memo renders in the preview', (
    tester,
  ) async {
    final svg = SvgCodec.encode(
      Drawing(
        strokes: [
          Stroke(
            points: const [PointVector(10, 10), PointVector(60, 60)],
            color: const Color(0xFF000000),
            size: 4,
          ),
        ],
      ),
      embedId: 'd1',
    );
    await tester.runAsync(
      () => app.store.writeText('e.md', '# e\n\ntext\n\n$svg\n'),
    );
    await tester.pumpWidget(wrap(const MarkdownScreen(path: 'e.md')));
    await settle(tester);
    expect(find.byType(SvgPicture), findsOneWidget);
    expect(find.textContaining('<svg'), findsNothing);
  });
}
