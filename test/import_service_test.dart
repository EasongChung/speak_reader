import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:speak_reader/services/import_service.dart';

void main() {
  group('ImportService TXT decoding', () {
    test('imports valid UTF-8 text', () async {
      final directory = await Directory.systemTemp.createTemp('speak_reader_');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}${Platform.pathSeparator}valid.txt');
      await file.writeAsString('有效文本');

      final result = await ImportService().importFile(file.path);

      expect(result.content, '有效文本');
    });

    test('rejects non-UTF-8 bytes instead of returning mojibake', () async {
      final directory = await Directory.systemTemp.createTemp('speak_reader_');
      addTearDown(() => directory.delete(recursive: true));
      final file =
          File('${directory.path}${Platform.pathSeparator}invalid.txt');
      await file.writeAsBytes([0x81, 0x81, 0x81], flush: true);

      expect(
        () => ImportService().importFile(file.path),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('UTF-8'),
          ),
        ),
      );
    });
  });
}
