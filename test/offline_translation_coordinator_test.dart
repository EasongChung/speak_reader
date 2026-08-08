import 'package:flutter_test/flutter_test.dart';
import 'package:speak_reader/services/offline_translation_coordinator.dart';
import 'package:speak_reader/services/offline_translation_service.dart';

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

  group('[G4.4] OfflineModelGroup 双词表解析', () {
    test('双词表档: 目标侧词表被解析出来', () {
      final g = OfflineModelGroup.fromMap(const {
        'id': 'enzh',
        'modelName': 'model.enzh.intgemm.alphas.bin',
        'vocabularyName': 'srcvocab.enzh.spm',
        'targetVocabularyName': 'trgvocab.enzh.spm',
        'shortlistName': 'lex.50.50.enzh.s2t.bin',
        'hasShortlist': true,
        'hasTargetVocabulary': true,
      });
      expect(g.vocabularyName, 'srcvocab.enzh.spm');
      expect(g.targetVocabularyName, 'trgvocab.enzh.spm');
      expect(g.hasTargetVocabulary, isTrue);
      expect(g.isComplete, isTrue);
    });

    test('单词表档: 缺目标侧词表仍算完整', () {
      // zh-en 本就没有 trgvocab, 计入完整性判定会把它误判为坏包。
      final g = OfflineModelGroup.fromMap(const {
        'id': 'zhen',
        'modelName': 'model.zhen.intgemm.alphas.bin',
        'vocabularyName': 'vocab.zhen.spm',
        'shortlistName': 'lex.50.50.zhen.s2t.bin',
        'hasShortlist': true,
      });
      expect(g.targetVocabularyName, isEmpty);
      expect(g.hasTargetVocabulary, isFalse);
      expect(g.isComplete, isTrue);
    });

    test('缺源侧词表则不完整', () {
      final g = OfflineModelGroup.fromMap(const {
        'id': 'enzh',
        'modelName': 'model.enzh.intgemm.alphas.bin',
        'targetVocabularyName': 'trgvocab.enzh.spm',
        'hasTargetVocabulary': true,
      });
      expect(g.isComplete, isFalse);
    });

    test('原生侧漏传新字段时不炸 —— 缺键按单词表档处理', () {
      // 旧版原生库配新 Dart 层时会走到这里, 必须退化而非抛异常。
      final g = OfflineModelGroup.fromMap(const {
        'id': 'zhen',
        'modelName': 'm.bin',
        'vocabularyName': 'v.spm',
      });
      expect(g.targetVocabularyName, isEmpty);
      expect(g.hasTargetVocabulary, isFalse);
      expect(g.hasShortlist, isFalse);
    });
  });
}
