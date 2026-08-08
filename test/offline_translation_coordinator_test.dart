import 'package:flutter_test/flutter_test.dart';
import 'package:speak_reader/services/offline_translation_coordinator.dart';

void main() {
  group('[G4.4] resolveGroupId 语向判定', () {
    const both = ['zhen', 'enzh'];

    test('含中文 → 选 zhen(中→英)', () {
      expect(
        OfflineTranslationCoordinator.resolveGroupId('这是一个测试句子。', both),
        'zhen',
      );
    });

    test('纯英文 → 选 enzh(英→中)', () {
      expect(
        OfflineTranslationCoordinator.resolveGroupId('This is a test.', both),
        'enzh',
      );
    });

    test('中英混排按中文处理 —— 含 CJK 即视作中文源', () {
      expect(
        OfflineTranslationCoordinator.resolveGroupId('这是 a test 句子', both),
        'zhen',
      );
    });

    test('空白输入返回 null', () {
      expect(
          OfflineTranslationCoordinator.resolveGroupId('   \n ', both), isNull);
    });

    test('只装了 zhen 时,英文输入返回 null(应由调用方回落在线)', () {
      expect(
        OfflineTranslationCoordinator.resolveGroupId('Hello world', ['zhen']),
        isNull,
      );
    });

    test('一组模型都没有时返回 null', () {
      expect(
        OfflineTranslationCoordinator.resolveGroupId('测试', const []),
        isNull,
      );
    });

    test('CJK 扩展 A 区也算中文', () {
      // U+3400 是扩展 A 区首字, 生僻但确属汉字。
      expect(
        OfflineTranslationCoordinator.resolveGroupId('㐀', both),
        'zhen',
      );
    });

    test('日文假名不算中文 —— 无日文模型时按英文源处理', () {
      // 刻意不把假名判成中文: 本 PoC 只有 zh<->en, 判成中文只会选错模型。
      // 这条断言锁住该取舍, 将来若加日文模型必须连同判定一起改。
      expect(
        OfflineTranslationCoordinator.resolveGroupId('ひらがな', both),
        'enzh',
      );
    });

    test('数字与标点不影响判定', () {
      expect(
        OfflineTranslationCoordinator.resolveGroupId('12345 !!!', both),
        'enzh',
      );
    });
  });
}
