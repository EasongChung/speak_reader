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

    test('[#3] 自动折行的两行合并成一句', () {
      final service = TtsService();
      // 两行等长(均贴版心右边界)、行末无符号、下行无缩进无符号 → 合并
      service.setText('这是上面一行文字\n这是下面一行文字。');

      expect(service.tokens, ['这是上面一行文字这是下面一行文字。']);
    });

    test('[#3] punctuation terminates even across lines', () {
      final service = TtsService();
      service.setText('句子一。\n句子二！');

      expect(service.tokens, ['句子一。', '句子二！']);
    });

    test('[#3-fix][判据1] 上行远离右边界(段末短行) → 不合并', () {
      final service = TtsService();
      service.setText('短行\n这是很长很长的下一行文字');

      expect(service.tokens, ['短行', '这是很长很长的下一行文字']);
    });

    test('[#3-fix][判据2] 上行行末带逗号(人工换行) → 不合并', () {
      final service = TtsService();
      service.setText('前半句的内容，\n后半句的内容。');

      expect(service.tokens, ['前半句的内容，', '后半句的内容。']);
    });

    test('[#3-fix][判据3] 下一行有缩进 → 不合并', () {
      final service = TtsService();
      service.setText('上一段的结尾文字\n  新段落的开头文字');

      expect(service.tokens, ['上一段的结尾文字', '新段落的开头文字']);
    });

    test('[#3-fix][判据4] 下一行以序号开头 → 不合并', () {
      final service = TtsService();
      service.setText('下面分条来说明\n1. 第一条的内容');

      expect(service.tokens, ['下面分条来说明', '1. 第一条的内容']);
    });

    test('[#3-fix] 空行是段落硬边界', () {
      final service = TtsService();
      service.setText('第一段的内容文字\n\n第二段的内容文字');

      expect(service.tokens, ['第一段的内容文字', '第二段的内容文字']);
    });

    test('[#3-fix] 拉丁文折行补空格, CJK 不补', () {
      final service = TtsService();
      service.setText('aaaaaaaa\nbbbbbbbb');
      expect(service.tokens, ['aaaaaaaa bbbbbbbb']);

      service.setText('中文的上面一行\n中文的下面一行');
      expect(service.tokens, ['中文的上面一行中文的下面一行']);
    });
  });
}
