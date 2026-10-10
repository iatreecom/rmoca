import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_state.dart' show DrawingMode, SortMode;
import '../models/sync_settings.dart';

/// Keeps sync settings in shared preferences and the token in the OS
/// keychain / keystore.
class SettingsRepository {
  static const _secure = FlutterSecureStorage(
    // The data protection keychain needs a signed keychain-sharing
    // entitlement; the login keychain works for unsigned dev builds too.
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );
  static const _tokenKey = 'github_token';

  Future<SyncSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    String token = '';
    try {
      token =
          await _secure
              .read(key: _tokenKey)
              .timeout(const Duration(seconds: 5)) ??
          '';
    } catch (_) {
      // Keychain unavailable; the user can enter the token again.
    }
    return SyncSettings(
      owner: prefs.getString('owner') ?? '',
      repo: prefs.getString('repo') ?? '',
      branch: prefs.getString('branch') ?? 'main',
      folder: prefs.getString('folder') ?? '',
      apiBaseUrl: prefs.getString('apiBaseUrl') ?? 'https://api.github.com',
      autoSync: prefs.getBool('autoSync') ?? true,
      deviceName: prefs.getString('deviceName') ?? _defaultDeviceName(),
      token: token,
    );
  }

  Future<void> save(SyncSettings s) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('owner', s.owner);
    await prefs.setString('repo', s.repo);
    await prefs.setString('branch', s.branch);
    await prefs.setString('folder', s.folder);
    await prefs.setString('apiBaseUrl', s.apiBaseUrl);
    await prefs.setBool('autoSync', s.autoSync);
    await prefs.setString('deviceName', s.deviceName);
    if (s.token.isEmpty) {
      await _secure.delete(key: _tokenKey);
    } else {
      await _secure.write(key: _tokenKey, value: s.token);
    }
  }

  Future<DrawingMode> loadDrawingMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('drawingMode') == DrawingMode.embedded.name
        ? DrawingMode.embedded
        : DrawingMode.file;
  }

  Future<void> saveDrawingMode(DrawingMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('drawingMode', mode.name);
  }

  Future<SortMode> loadSortMode() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString('sortMode');
    return SortMode.values.where((m) => m.name == name).firstOrNull ??
        SortMode.modifiedDesc;
  }

  Future<void> saveSortMode(SortMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('sortMode', mode.name);
  }

  static String _defaultDeviceName() {
    try {
      final host = Platform.localHostname.split('.').first;
      if (host.isNotEmpty && host != 'localhost') return host;
    } catch (_) {
      // Not available on every platform.
    }
    return Platform.operatingSystem;
  }
}
