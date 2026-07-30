import 'package:flutter_test/flutter_test.dart';
import 'package:speak_reader/services/tts_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TtsService sentence splitting', () {
    test('keeps every normal-mode token within the engine limit', () {
      final service = TtsService();
      service.setText('a' * (TtsService.maxSpeakLength * 2 + 17));

      expect(service.tokens, hasLength(3));
      expect(
        service.tokens.every(
          (token) =>
              token.isNotEmpty && token.length <= TtsService.maxSpeakLength,
        ),
        isTrue,
      );
      expect(service.tokens.join(), 'a' * 257);
    });

    test('splits common Chinese and English sentence punctuation', () {
      final service = TtsService();
      service.setText('第一句。Second sentence!第三句；Fourth?');

      expect(
        service.tokens,
        ['第一句。', 'Second sentence!', '第三句；', 'Fourth?'],
      );
    });

    test('empty input produces no tokens', () {
      final service = TtsService();
      service.setText('  \n  ');

      expect(service.tokens, isEmpty);
    });
  });
}
