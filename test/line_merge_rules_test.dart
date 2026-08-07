import 'package:flutter_test/flutter_test.dart';
import 'package:speak_reader/services/line_merge_rules.dart';

/// 以「字符数当坐标」调用 [canMergeLines]（与 `TtsService` 侧同一度量）。
///
/// [blockRight] 默认 20，代表版心右边界在第 20 个字符处。
bool merge(
  String prevLine,
  String nextLine, {
  double blockRight = 20,
  double indent = 0,
}) =>
    canMergeLines(
      prevRight: prevLine.length.toDouble(),
      blockRight: blockRight,
      nextLeft: indent,
      blockLeft: 0,
      charW: 1,
      prevLastChar: prevLine.isEmpty ? '' : prevLine[prevLine.length - 1],
      nextFirstChar: nextLine.isEmpty ? '' : nextLine[0],
      nextLineText: nextLine,
    );

void main() {
  group('canMergeLines 四条判据', () {
    test('四条全满足 → 合并', () {
      // 行末在第 19 字符(距边界 1 < 2)、无符号；下一行无缩进、行首是正文
      expect(merge('a' * 19, '续行内容'), isTrue);
    });

    test('[判据1] 行末远离右边界(段落末尾短行) → 不合并', () {
      // 行末在第 10 字符，距边界 10 > 2
      expect(merge('a' * 10, '下一段首行'), isFalse);
    });

    test('[判据1] 行末距边界恰好 2 字符 → 仍算贴边', () {
      expect(merge('a' * 18, '续行内容'), isTrue);
    });

    test('[判据2] 行末带逗号(人工换行) → 不合并', () {
      expect(merge('${'a' * 18}，', '下一行'), isFalse);
      expect(merge('${'a' * 18},', '下一行'), isFalse);
    });

    test('[判据2] 行末带顿号/冒号/右括号/引号 → 不合并', () {
      for (final c in ['、', '：', '）', '」', '”']) {
        expect(merge('${'a' * 18}$c', '下一行'), isFalse, reason: '行末 $c');
      }
    });

    test('[判据2] 拉丁断词连字符不开特例 → 不合并', () {
      // 从严实现：`inter-` / `national` 读成两段（见 line_merge_rules 注释）
      expect(merge('${'a' * 12}inter-', 'national'), isFalse);
    });

    test('[判据3] 下一行有缩进(新段首行) → 不合并', () {
      expect(merge('a' * 19, '新段落开头', indent: 2), isFalse);
    });

    test('[判据3] 缩进在 0.5 字符抖动内 → 仍算无缩进', () {
      expect(merge('a' * 19, '续行内容', indent: 0.5), isTrue);
    });

    test('[判据4] 下一行以项目符号开头 → 不合并', () {
      for (final c in ['•', '·', '●', '※', '-', '*']) {
        expect(merge('a' * 19, '$c 列表项'), isFalse, reason: '行首 $c');
      }
    });

    test('[判据4] 下一行以圆圈序号开头 → 不合并', () {
      expect(merge('a' * 19, '①第一点'), isFalse);
    });

    test('[判据4] 下一行以标点开头 → 不合并', () {
      expect(merge('a' * 19, '，承接上句'), isFalse);
    });

    test('[判据4] 下一行是 1. / (1) / 一、等带分隔符的序号 → 不合并', () {
      for (final s in ['1. 第一条', '1) 第一条', '(1) 第一条', '一、总则']) {
        expect(merge('a' * 19, s), isFalse, reason: '行首 $s');
      }
    });

    test('空行首/行尾一律不合并', () {
      expect(merge('a' * 19, ''), isFalse);
      expect(merge('', '下一行'), isFalse);
    });
  });

  group('needsSpaceBetween', () {
    test('拉丁 + 拉丁 → 补空格', () {
      expect(needsSpaceBetween('r', 'n'), isTrue);
    });

    test('任一侧为 CJK → 不补', () {
      expect(needsSpaceBetween('文', '字'), isFalse);
      expect(needsSpaceBetween('a', '中'), isFalse);
      expect(needsSpaceBetween('中', 'a'), isFalse);
    });
  });

  group('isCjk', () {
    test('识别基本区汉字与中文标点', () {
      expect(isCjk('中'), isTrue);
      expect(isCjk('。'), isTrue);
      expect(isCjk('，'), isTrue);
    });

    test('拉丁字母与空串不算 CJK', () {
      expect(isCjk('a'), isFalse);
      expect(isCjk(''), isFalse);
    });
  });
}
