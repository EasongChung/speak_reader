import 'package:flutter_test/flutter_test.dart';
import 'package:speak_reader/services/settings_service.dart';

void main() {
  group('AppSettings.translationReady', () {
    test('requires URL, API key, and model', () {
      expect(
        AppSettings(baseUrl: 'https://example.com', apiKey: 'key', model: 'm')
            .translationReady,
        isTrue,
      );
      expect(
          AppSettings(baseUrl: '', apiKey: 'key', model: 'm').translationReady,
          isFalse);
      expect(
        AppSettings(baseUrl: 'https://example.com', apiKey: '', model: 'm')
            .translationReady,
        isFalse,
      );
      expect(
        AppSettings(
          baseUrl: 'https://example.com',
          apiKey: 'key',
          model: '   ',
        ).translationReady,
        isFalse,
      );
    });
  });
}
