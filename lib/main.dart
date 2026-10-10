import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'screens/home_screen.dart';
import 'screens/settings_screen.dart';
import 'services/local_store.dart';
import 'services/settings_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await LocalStore.open();
  final app = AppState(store, SettingsRepository());
  await app.init();
  runApp(ChangeNotifierProvider.value(value: app, child: const RmocaApp()));
}

class RmocaApp extends StatelessWidget {
  const RmocaApp({super.key});

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness b) => ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3D5AFE), brightness: b),
          useMaterial3: true,
        );
    return MaterialApp(
      title: 'rmoca',
      debugShowCheckedModeBanner: false,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      routes: {
        '/': (_) => const HomeScreen(),
        '/settings': (_) => const SettingsScreen(),
      },
    );
  }
}
