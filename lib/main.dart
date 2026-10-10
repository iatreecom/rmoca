import 'dart:async';

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

class RmocaApp extends StatefulWidget {
  const RmocaApp({super.key});

  @override
  State<RmocaApp> createState() => _RmocaAppState();
}

class _RmocaAppState extends State<RmocaApp> {
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  StreamSubscription<String>? _messages;

  @override
  void initState() {
    super.initState();
    // Sync notices show on whichever screen is open.
    _messages = context.read<AppState>().messages.listen(
      (text) => _messenger.currentState?.showSnackBar(
        SnackBar(content: Text(text), duration: const Duration(seconds: 6)),
      ),
    );
  }

  @override
  void dispose() {
    _messages?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness b) => ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF3D5AFE),
        brightness: b,
      ),
      useMaterial3: true,
    );
    return MaterialApp(
      scaffoldMessengerKey: _messenger,
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
