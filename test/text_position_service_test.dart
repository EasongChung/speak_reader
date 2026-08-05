import 'package:flutter_test/flutter_test.dart';
import 'package:speak_reader/services/text_position_service.dart';

/// 构造一个字符坐标 Map(与 `extractTextPositions` 返回的 `chars` 元素同构)。
///
/// 竖直范围沿用 Gate 1 定论: `top = y - 0.88*fs` / `bottom = y + 0.12*fs`,
/// 故 [y] 为**基线**而非字顶。
Map<Object?, Object?> ch(
  String c, {
  required double x,
  required double y,
  double fs = 10,
  double? w,
}) =>
    <Object?, Object?>{
      'c': c,
      'x': x,
      'y': y,
      'w': w ?? fs,
      'fs': fs,
    };

/// 按阅读顺序把一串字符排成一行(等宽推进), 返回字符 Map 列表。
List<Map<Object?, Object?>> line(
  String text, {
  required double y,
  double startX = 0,
  double fs = 10,
}) {
  final out = <Map<Object?, Object?>>[];
  var x = startX;
  for (final c in text.split('')) {
    out.add(ch(c, x: x, y: y, fs: fs));
    x += fs;
  }
  return out;
}

void main() {
  group('buildSentences', () {
    test('行内按终止标点切句, 标点归入前句', () {
      final chars = line('你好。世界！', y: 20);
      final sentences = buildSentences(chars);

      expect(sentences.map((s) => s.text).toList(), ['你好。', '世界！']);
    });

    test('句子外接框覆盖该句全部字符, 竖直范围为 em 框', () {
      // fs=10, 基线 y=20 → top=20-8.8=11.2, bottom=20+1.2=21.2
      final chars = line('你好。', y: 20);
      final union = buildSentences(chars).single.union;

      expect(union.left, 0);
      expect(union.right, 30); // 3 字 × 10
      expect(union.top, closeTo(11.2, 1e-6));
      expect(union.bottom, closeTo(21.2, 1e-6));
    });

    test('句子不跨行: 与 TtsService 把 \\n 视作硬边界的规则一致', () {
      // 无标点的两行, 应切成两句而非合并成一句
      final chars = <Map<Object?, Object?>>[
        ...line('上行', y: 20),
        ...line('下行', y: 40),
      ];
      final sentences = buildSentences(chars);

      expect(sentences.map((s) => s.text).toList(), ['上行', '下行']);
    });

    test('行尾无标点也成句(对应 TtsService 的换行边界)', () {
      final sentences = buildSentences(line('无标点结尾', y: 20));

      expect(sentences.single.text, '无标点结尾');
    });

    test('空输入返回空列表', () {
      expect(buildSentences(const []), isEmpty);
    });
  });

  group('buildParagraphs', () {
    test('行间距正常时归为同一段', () {
      // fs=10 → charH=12; 行距 12 < 1.8×12=21.6, 不分段
      final chars = <Map<Object?, Object?>>[
        ...line('第一行', y: 20),
        ...line('第二行', y: 32),
      ];
      final paragraphs = buildParagraphs(chars);

      expect(paragraphs, hasLength(1));
      expect(paragraphs.single.rects, hasLength(2));
    });

    test('出现空行(大间隙)时切分为两段', () {
      // 行距 40 > 21.6, 分段
      final chars = <Map<Object?, Object?>>[
        ...line('第一段', y: 20),
        ...line('第二段', y: 60),
      ];
      final paragraphs = buildParagraphs(chars);

      expect(paragraphs, hasLength(2));
      expect(paragraphs[0].text.trim(), '第一段');
      expect(paragraphs[1].text.trim(), '第二段');
    });

    test('空输入返回空列表', () {
      expect(buildParagraphs(const []), isEmpty);
    });
  });

  group('hitSentence', () {
    late List<SentenceBox> sentences;

    setUp(() {
      sentences = buildSentences(line('你好。世界！', y: 20));
    });

    test('点落在句框内 → 命中该句', () {
      // 第 2 句 '世界！' 覆盖 x∈[30,60]
      final hit = hitSentence(sentences, const Offset(40, 16));

      expect(hit?.text, '世界！');
    });

    test('点略微偏离 → 吸附最近句(容忍真机点击偏移)', () {
      // y=30 在 em 框(11.2~21.2)之下约 9pt, 仍在吸附阈值内
      final hit = hitSentence(sentences, const Offset(10, 30));

      expect(hit?.text, '你好。');
    });

    test('点距所有句子过远 → 返回 null 交由调用方兜底', () {
      final hit = hitSentence(sentences, const Offset(10, 500));

      expect(hit, isNull);
    });

    test('空句子列表返回 null', () {
      expect(hitSentence(const [], Offset.zero), isNull);
    });
  });

  group('hitParagraph', () {
    test('点落在段内 → 命中该段', () {
      final paragraphs = buildParagraphs(<Map<Object?, Object?>>[
        ...line('第一段', y: 20),
        ...line('第二段', y: 60),
      ]);
      final hit = hitParagraph(paragraphs, const Offset(10, 56));

      expect(hit?.text.trim(), '第二段');
    });

    test('点距所有段落过远 → 返回 null', () {
      final paragraphs = buildParagraphs(line('唯一段', y: 20));

      expect(hitParagraph(paragraphs, const Offset(10, 800)), isNull);
    });

    test('空段落列表返回 null', () {
      expect(hitParagraph(const [], Offset.zero), isNull);
    });

    test('[G2.5.1] 段落吸附阈值基于行高(1.5em), 远距离不误吸附', () {
      // 单行 fs=10 → 行高 12, 阈值 1.5×12=18
      final paragraphs = buildParagraphs(line('短段', y: 20));
      // 段在 11.2~21.2, 点在 y=50 → 距离 28.8 > 18 → null
      expect(hitParagraph(paragraphs, const Offset(10, 50)), isNull);
    });

    test('[G2.5.1] 多行段落的阈值基于行高中位数, 不是整段高度', () {
      // 3 行, 每行高 12
      final paragraphs = buildParagraphs(<Map<Object?, Object?>>[
        ...line('第一行', y: 20),
        ...line('第二行', y: 40),
        ...line('第三行', y: 60),
      ]);
      // 行高中位数 12, 阈值 1.5×12=18
      // 段在 11.2~69.2, 点在 y=100 → 距离 30.8 > 18 → null
      // (若误用整段高度 ≈58, 阈值会变成 1.5×58=87, 误命中)
      expect(hitParagraph(paragraphs, const Offset(10, 100)), isNull);
    });
  });
}
