import 'package:flutter_test/flutter_test.dart';
import 'package:rmoca/services/note_crypto.dart';

void main() {
  test('locked notes round-trip and reject wrong passwords', () async {
    final key = await NoteCrypto.newKey('비밀 123', iterations: 1000);
    const plain = '# 일기\n\n오늘은 ✨ 좋은 날\n- [ ] 할 일';
    final file = await NoteCrypto.lock(plain, key);
    expect(NoteCrypto.isLocked(file), isTrue);
    expect(file, isNot(contains('일기')));
    expect(file, startsWith('# 🔒 잠긴 메모'));

    final (opened, key2) = await NoteCrypto.unlock(file, '비밀 123');
    expect(opened, plain);

    // Saving again with the remembered key uses a fresh nonce.
    final again = await NoteCrypto.lock('$plain\n추가', key2);
    expect(again, isNot(file));
    expect((await NoteCrypto.unlock(again, '비밀 123')).$1, '$plain\n추가');

    await expectLater(
      NoteCrypto.unlock(file, 'wrong'),
      throwsA(isA<WrongPasswordException>()),
    );
    expect(NoteCrypto.isLocked('# 그냥 메모'), isFalse);

    // A remembered key opens later saves; another password's file not.
    expect(await NoteCrypto.unlockWithKey(again, key2), '$plain\n추가');
    final other = await NoteCrypto.lock(
      'x',
      await NoteCrypto.newKey('다른 암호', iterations: 1000),
    );
    expect(await NoteCrypto.unlockWithKey(other, key2), isNull);
  });
}
