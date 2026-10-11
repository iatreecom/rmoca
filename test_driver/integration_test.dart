import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

/// Saves screenshots taken by the integration test to `screenshots/`:
/// on phones and simulators through the plugin, on desktop as data the
/// test reports at the end.
Future<void> main() => integrationDriver(
  onScreenshot: (name, bytes, [args]) async {
    await _save(name, bytes);
    return true;
  },
  responseDataCallback: (data) async {
    final shots = data?['desktop_screenshots'];
    if (shots is Map) {
      for (final e in shots.entries) {
        await _save('${e.key}', base64Decode('${e.value}'));
      }
    }
  },
);

Future<void> _save(String name, List<int> bytes) async {
  final file = File('screenshots/$name.png');
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes);
}
