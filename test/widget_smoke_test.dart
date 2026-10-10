import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:rmoca/app_state.dart';
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
    dir = await Directory.systemTemp.createTemp('rmoca_widget');
    final store = await LocalStore.openAt(dir);
    app = AppState(store, SettingsRepository());
  });

  tearDown(() => dir.delete(recursive: true));

  /// Lets real file I/O complete and the UI catch up.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
  }

  Widget wrap(Widget child) => ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(home: child, routes: {'/settings': (_) => const SizedBox()}),
      );

  testWidgets('home lists notes', (tester) async {
    await tester.runAsync(() async {
      await app.store.writeText('hello.md', '# Hello\n\nworld');
      await app.refreshNotes();
    });
    await tester.pumpWidget(wrap(const HomeScreen()));
    await tester.pump();
    expect(find.text('hello'), findsOneWidget);
    expect(find.text('새 메모'), findsOneWidget);
  });

  testWidgets('markdown note renders preview', (tester) async {
    await tester.runAsync(() => app.store.writeText('a.md', '# Title\n\n**bold**'));
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
}
