import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

/// Thrown when a locked note is opened with the wrong password.
class WrongPasswordException implements Exception {
  @override
  String toString() => '암호가 맞지 않습니다';
}

/// An unlocked note's key, kept in memory so saving does not need the
/// password again.
class NoteKey {
  NoteKey(this.key, this.salt, this.iterations);

  final SecretKey key;
  final List<int> salt;
  final int iterations;
}

/// Password-locked notes. The file stays markdown so other apps show a
/// short explanation, and the text is AES-256-GCM encrypted with a key
/// derived from the password (PBKDF2-HMAC-SHA256). Only ciphertext is
/// written to disk, synced and kept in version history.
class NoteCrypto {
  static const _fence = 'rmoca-encrypted';
  static const defaultIterations = 150000;

  static final _block = RegExp('```$_fence\\n([A-Za-z0-9+/=\\s]+?)\\n```');
  static final _aes = AesGcm.with256bits();

  static bool isLocked(String text) => _block.hasMatch(text);

  static Future<NoteKey> newKey(
    String password, {
    int iterations = defaultIterations,
  }) async {
    final rnd = Random.secure();
    final salt = List<int>.generate(16, (_) => rnd.nextInt(256));
    return NoteKey(await _derive(password, salt, iterations), salt, iterations);
  }

  /// PBKDF2 is deliberately slow; run it off the UI thread.
  static Future<SecretKey> _derive(
    String password,
    List<int> salt,
    int iterations,
  ) async {
    final bytes = await Isolate.run(() async {
      final key = await Pbkdf2(
        macAlgorithm: Hmac.sha256(),
        iterations: iterations,
        bits: 256,
      ).deriveKeyFromPassword(password: password, nonce: salt);
      return key.extractBytes();
    });
    return SecretKey(bytes);
  }

  /// Decrypts with a key remembered from an earlier unlock; null if the
  /// note was locked again with another password since.
  static Future<String?> unlockWithKey(String file, NoteKey key) async {
    final env = _envelope(file);
    if (base64.encode(env.salt) != base64.encode(key.salt)) return null;
    try {
      return utf8.decode(await _aes.decrypt(env.box, secretKey: key.key));
    } on SecretBoxAuthenticationError {
      return null;
    }
  }

  static ({List<int> salt, int iterations, SecretBox box}) _envelope(
    String file,
  ) {
    final m = _block.firstMatch(file);
    if (m == null) throw const FormatException('Not a locked note');
    final json = jsonDecode(
      utf8.decode(base64.decode(m[1]!.replaceAll(RegExp(r'\s'), ''))),
    ) as Map<String, dynamic>;
    return (
      salt: base64.decode(json['salt'] as String),
      iterations: json['iter'] as int,
      box: SecretBox(
        base64.decode(json['ct'] as String),
        nonce: base64.decode(json['nonce'] as String),
        mac: Mac(base64.decode(json['mac'] as String)),
      ),
    );
  }

  /// The locked file for [plain].
  static Future<String> lock(String plain, NoteKey key) async {
    final box = await _aes.encrypt(utf8.encode(plain), secretKey: key.key);
    final payload = base64.encode(
      utf8.encode(
        jsonEncode({
          'v': 1,
          'kdf': 'pbkdf2-sha256',
          'iter': key.iterations,
          'salt': base64.encode(key.salt),
          'nonce': base64.encode(box.nonce),
          'ct': base64.encode(box.cipherText),
          'mac': base64.encode(box.mac.bytes),
        }),
      ),
    );
    // Wrap long base64 so diffs and git stay readable.
    final wrapped = [
      for (var i = 0; i < payload.length; i += 76)
        payload.substring(i, min(i + 76, payload.length)),
    ].join('\n');
    return '# 🔒 잠긴 메모\n\n'
        '이 메모는 rmoca에서 암호로 잠겨 있습니다. rmoca 앱에서 암호를 입력해 열 수 있습니다.\n\n'
        '```$_fence\n$wrapped\n```\n';
  }

  /// Decrypts a locked file with [password]; also returns the key so the
  /// note can be saved again without asking.
  static Future<(String, NoteKey)> unlock(String file, String password) async {
    final env = _envelope(file);
    final key = NoteKey(
      await _derive(password, env.salt, env.iterations),
      env.salt,
      env.iterations,
    );
    try {
      final plain = await _aes.decrypt(env.box, secretKey: key.key);
      return (utf8.decode(plain), key);
    } on SecretBoxAuthenticationError {
      throw WrongPasswordException();
    }
  }
}
