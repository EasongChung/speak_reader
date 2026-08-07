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

    test('[#3] 句子跨行合并: 自动折行的两行合成一句, rects 每行一个', () {
      // 上行贴满版心右边界(与最长行等宽)、行末无符号、下行无缩进无符号 → 合并
      // 行距 20 < 1.8×12=21.6, 属同段
      final chars = <Map<Object?, Object?>>[
        ...line('上行文字', y: 20),
        ...line('下行文字', y: 40),
      ];
      final sentences = buildSentences(chars);

      expect(sentences, hasLength(1));
      expect(sentences.single.text, '上行文字下行文字');
      expect(sentences.single.rects, hasLength(2));
    });

    test('[#3] 跨行句在终止标点处断开, 不吞下一句', () {
      final chars = <Map<Object?, Object?>>[
        ...line('上行结束。', y: 20),
        ...line('下一句在此', y: 40),
      ];
      final sentences = buildSentences(chars);

      expect(sentences.map((s) => s.text).toList(), ['上行结束。', '下一句在此']);
    });

    test('[#3] 段落间隙(空行)仍是硬边界, 无标点也断句', () {
      // 行距 40 > 21.6 → 视为跨段, 强制断句
      final chars = <Map<Object?, Object?>>[
        ...line('第一段', y: 20),
        ...line('第二段', y: 60),
      ];
      final sentences = buildSentences(chars);

      expect(sentences.map((s) => s.text).toList(), ['第一段', '第二段']);
    });

    test('[#3] 拉丁文跨行补空格, CJK 不补', () {
      final latin = <Map<Object?, Object?>>[
        ...line('abc', y: 20),
        ...line('def', y: 32),
      ];
      expect(buildSentences(latin).single.text, 'abc def');

      final cjk = <Map<Object?, Object?>>[
        ...line('中文', y: 20),
        ...line('续行', y: 32),
      ];
      expect(buildSentences(cjk).single.text, '中文续行');
    });

    test('[#3-fix][判据1] 上行远离右边界(段末短行) → 不与下行合并', () {
      // 第 1 行仅 2 字(x 到 20), 第 2 行 8 字(x 到 80) → 版心右边界 80
      // 上行距边界 60 ≫ 2 字符(20) → 判为段落末尾短行, 断句
      final chars = <Map<Object?, Object?>>[
        ...line('短行', y: 20),
        ...line('这是很长的下一行', y: 32),
      ];
      final sentences = buildSentences(chars);

      expect(sentences.map((s) => s.text).toList(), ['短行', '这是很长的下一行']);
    });

    test('[#3-fix][判据2] 上行行末带逗号(人工换行) → 不合并', () {
      final chars = <Map<Object?, Object?>>[
        ...line('前半句内容，', y: 20),
        ...line('后半句内容。', y: 32),
      ];
      final sentences = buildSentences(chars);

      expect(sentences.map((s) => s.text).toList(), ['前半句内容，', '后半句内容。']);
    });

    test('[#3-fix][判据3] 下一行有缩进(新段首行) → 不合并', () {
      // 两行等宽, 但下行左起 20(=2 字符缩进) → 判为新段首行
      final chars = <Map<Object?, Object?>>[
        ...line('上一段结尾文字', y: 20),
        ...line('新段落开头文字', y: 32, startX: 20),
      ];
      final sentences = buildSentences(chars);

      expect(sentences.map((s) => s.text).toList(), ['上一段结尾文字', '新段落开头文字']);
    });

    test('[#3-fix][判据4] 下一行以项目符号开头 → 不合并', () {
      final chars = <Map<Object?, Object?>>[
        ...line('列表引导文字', y: 20),
        ...line('•列表第一项', y: 32),
      ];
      final sentences = buildSentences(chars);

      expect(sentences.map((s) => s.text).toList(), ['列表引导文字', '•列表第一项']);
    });

    test('[#3-fix][判据4] 下一行以 1. 序号开头 → 不合并', () {
      final chars = <Map<Object?, Object?>>[
        ...line('下面分条说明', y: 20),
        ...line('1.第一条内容', y: 32),
      ];
      final sentences = buildSentences(chars);

      expect(sentences.map((s) => s.text).toList(), ['下面分条说明', '1.第一条内容']);
    });

    test('行尾无标点也成句(段落末尾收束)', () {
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
