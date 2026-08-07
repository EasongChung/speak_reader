import 'dart:math' as math;
import 'dart:ui';

import 'line_merge_rules.dart';

// 坐标系与 PDFBox `extractTextPositions` 一致（页面点，原点在 CropBox 左上角，
// y 向下）。本文所有矩形均为页面坐标，经 `PDFViewController.setHighlights`
// 由原生侧绘制。

/// 一个句子的几何与文本。
///
/// 分句规则与 `TtsService._splitSentences` 对齐：以 `。！？!?；;` 为硬边界。
/// **句子可以跨行**（v2.6.x #3），但仅当换行处经 `canMergeLines` 判定为排版
/// 自动折行时才合并；合并成立时 [rects] 含多个矩形（每行一个）。
class SentenceBox {
  SentenceBox({required this.text, required this.rects});

  final String text;
  final List<Rect> rects;

  /// 环绕整句的外接框。
  Rect get union {
    if (rects.isEmpty) return Rect.zero;
    var r = rects.first;
    for (final rect in rects.skip(1)) {
      r = r.expandToInclude(rect);
    }
    return r;
  }
}

/// 一个段落的几何与文本（句子定位失败时的兜底高亮单位）。
class ParagraphBox {
  ParagraphBox({required this.text, required this.rects});

  final String text;
  final List<Rect> rects;

  /// 环绕整段的外接框。
  Rect get union {
    if (rects.isEmpty) return Rect.zero;
    var r = rects.first;
    for (final rect in rects.skip(1)) {
      r = r.expandToInclude(rect);
    }
    return r;
  }
}

/// 一行字符。
class _Line {
  _Line(this.text, this.top, this.bottom, this.chars);

  final String text;
  final double top;
  final double bottom;
  final List<Map<Object?, Object?>> chars;

  double get xMin => chars
      .map<double>((c) => (c['x'] as num).toDouble())
      .reduce((a, b) => a < b ? a : b);

  double get xMax => chars
      .map<double>(
          (c) => (c['x'] as num).toDouble() + (c['w'] as num).toDouble())
      .reduce((a, b) => a > b ? a : b);
}

/// 句子终止标点（与 `TtsService` 的正则 `(?<=[。！？!?；;])` 对齐，
/// v2.6.x #3 起换行改由 `canMergeLines` 逐处判定，不再是无条件硬边界）。
const String _sentenceTerms = '。！？!?；;';

double _fs(Map<Object?, Object?> c) =>
    (c['fs'] as num).toDouble().clamp(0.1, 500.0);
double _x(Map<Object?, Object?> c) => (c['x'] as num).toDouble();
double _w(Map<Object?, Object?> c) => (c['w'] as num).toDouble();
double _y(Map<Object?, Object?> c) => (c['y'] as num).toDouble();

/// 字符 → 行（需为 PDFBox 阅读顺序）。
List<_Line> _buildLines(List<Map<Object?, Object?>> chars) {
  final raw = <List<Map<Object?, Object?>>>[];
  for (final c in chars) {
    if (raw.isEmpty) {
      raw.add([c]);
      continue;
    }
    final prev = raw.last.last;
    final sameLine =
        (_y(c) - _y(prev)).abs() <= 0.55 * (_fs(prev) + _fs(c)) / 2 &&
            (_x(c) - _x(prev)) > -_fs(c) * 0.3;
    sameLine ? raw.last.add(c) : raw.add([c]);
  }

  return raw.where((l) => l.isNotEmpty).map((l) {
    final top = _y(l.first) - 0.88 * _fs(l.first);
    final bottom = _y(l.first) + 0.12 * _fs(l.first);
    final buf = StringBuffer();
    for (final c in l) {
      buf.write(c['c']);
    }
    return _Line(buf.toString(), top, bottom, l);
  }).toList();
}

/// 字符坐标 → 句子列表（按终止标点切句，**句子可跨行**）。
///
/// [chars] 需为 `extractTextPositions` 返回的 `chars`（阅读顺序）。
///
/// 与 `TtsService._splitSentences` 对齐：换行**不是**无条件边界，但也**不是**
/// 无条件合并——只有经 [canMergeLines] 判定为「排版自动折行」的换行处才把下
/// 一行接到当前句尾（行末贴右边界且无符号、下一行无缩进且行首无符号/序号）。
/// 合并成立时 [SentenceBox.rects] 每行一个矩形。
///
/// **段落间隙仍是硬边界**——行间垂直间隙 > [paraGapEm]×行高（出现空行）时强制
/// 断句，否则无标点文本（标题、列表等）会把整页合成一句。
///
/// 版心左右边界（[canMergeLines] 的 `blockLeft`/`blockRight`）按**段落块内**
/// 统计，不用整页：多栏排版与页眉页脚会把边界撑到不可用。
///
/// 跨行拼接时按语种补空格：两侧均为拉丁字符才插入空格，CJK 不插。
List<SentenceBox> buildSentences(
  List<Map<Object?, Object?>> chars, {
  double paraGapEm = 1.8,
}) {
  if (chars.isEmpty) return const [];
  final charH = _medianFs(chars) * 1.2;
  final charW = _medianFs(chars); // 以字号近似单字宽（CJK 近似等宽）
  final result = <SentenceBox>[];

  // 跨行累积状态
  final sb = StringBuffer();
  final rects = <Rect>[];
  var left = double.infinity;
  var right = double.negativeInfinity;
  var curTop = 0.0;
  var curBottom = 0.0;
  var lastChar = '';

  /// 收束当前行段矩形（句子未必结束）
  void closeRect() {
    if (right >= left) {
      rects.add(Rect.fromLTRB(left, curTop, right, curBottom));
    }
    left = double.infinity;
    right = double.negativeInfinity;
  }

  /// 结束当前句
  void flush() {
    closeRect();
    if (sb.isNotEmpty && rects.isNotEmpty) {
      result.add(SentenceBox(text: sb.toString(), rects: List.of(rects)));
    }
    sb.clear();
    rects.clear();
    lastChar = '';
  }

  // 先按段落间隙把行分块，块内统计版心左右边界供折行判定使用
  for (final block in _splitLineBlocks(_buildLines(chars), paraGapEm * charH)) {
    final blockLeft = block.map((l) => l.xMin).reduce((a, b) => a < b ? a : b);
    final blockRight = block.map((l) => l.xMax).reduce((a, b) => a > b ? a : b);

    for (var i = 0; i < block.length; i++) {
      final line = block[i];
      if (line.chars.isEmpty) continue;

      // 与上一行之间是否为自动折行：不是则先收句（当前行另起一句）
      if (sb.isNotEmpty) {
        final prev = block[i - 1];
        final merge = canMergeLines(
          prevRight: prev.xMax,
          blockRight: blockRight,
          nextLeft: line.xMin,
          blockLeft: blockLeft,
          charW: charW,
          prevLastChar: lastChar,
          nextFirstChar: line.chars.first['c'].toString(),
          nextLineText: line.text,
        );
        if (!merge) {
          flush();
        } else if (needsSpaceBetween(
            lastChar, line.chars.first['c'].toString())) {
          sb.write(' '); // 拉丁文折行处原为词间空格，需补回
        }
      }

      curTop = line.top;
      curBottom = line.bottom;
      for (final c in line.chars) {
        final ch = c['c'].toString();
        left = math.min(left, _x(c));
        right = math.max(right, _x(c) + _w(c));
        sb.write(ch);
        lastChar = ch;
        if (_sentenceTerms.contains(ch)) flush();
      }
      closeRect(); // 行尾收束矩形，句子是否延续由下一轮判定
    }
    flush(); // 块（段落）结束必断句
  }
  return result;
}

/// 按垂直间隙把行序列切成段落块（间隙 > [gap] 即开新块）。
List<List<_Line>> _splitLineBlocks(List<_Line> lines, double gap) {
  final blocks = <List<_Line>>[];
  for (final line in lines) {
    if (blocks.isEmpty || line.top - blocks.last.last.bottom > gap) {
      blocks.add([line]);
    } else {
      blocks.last.add(line);
    }
  }
  return blocks;
}

/// 字符坐标 → 段落列表（句子定位失败时的兜底）。
///
/// 段 = 相邻若干行；行间垂直间隙 > [paraGapEm]×行高（出现空行）则开新段。
List<ParagraphBox> buildParagraphs(
  List<Map<Object?, Object?>> chars, {
  double paraGapEm = 1.8,
}) {
  if (chars.isEmpty) return const [];
  final charH = _medianFs(chars) * 1.2;
  final paragraphs = <ParagraphBox>[];
  final curRects = <Rect>[];
  final buf = StringBuffer();

  void flush() {
    if (curRects.isEmpty) return;
    paragraphs
        .add(ParagraphBox(text: buf.toString(), rects: List.of(curRects)));
    curRects.clear();
    buf.clear();
  }

  for (final line in _buildLines(chars)) {
    if (curRects.isNotEmpty &&
        line.top - curRects.last.bottom > paraGapEm * charH) {
      flush();
    }
    curRects.add(Rect.fromLTRB(line.xMin, line.top, line.xMax, line.bottom));
    buf.write(line.text);
    buf.write('\n');
  }
  flush();
  return paragraphs;
}

/// 点所在的句子；未包含则吸附最近句（容忍点击偏移）。
///
/// 返回 null 表示距所有句子都太远（调用方可回落到段落兜底）。
///
/// **按 [SentenceBox.rects] 逐个行段判定**，不能用 `union`：跨行句的 union
/// 是横跨多行的大矩形，会把行首/行尾的空白区域也算作命中。
SentenceBox? hitSentence(List<SentenceBox> sentences, Offset point,
    {double snapEm = 4}) {
  if (sentences.isEmpty) return null;
  // 吸附阈值基于真实行高，不是整句框高度（避免跨行长句误扩大吸附范围）
  final lineHeights = sentences
      .expand((s) => s.rects.map((r) => r.height))
      .where((h) => h > 0)
      .toList();
  final est = lineHeights.isNotEmpty
      ? (lineHeights..sort())[lineHeights.length ~/ 2]
      : 12.0;
  return _hitRects<SentenceBox>(
      sentences, (s) => s.rects, point, snapEm * math.max(est, 1));
}

/// 点所在的段落；未包含则吸附最近段（仅容忍段内行距，避免空白误选）。
ParagraphBox? hitParagraph(List<ParagraphBox> paragraphs, Offset point,
    {double snapEm = 1.5}) {
  if (paragraphs.isEmpty) return null;
  // 吸附阈值基于真实行高，不是整段框高度
  final lineHeights = paragraphs
      .expand((p) => p.rects.map((r) => r.height))
      .where((h) => h > 0)
      .toList();
  final est = lineHeights.isNotEmpty
      ? (lineHeights..sort())[lineHeights.length ~/ 2]
      : 12.0;
  return _hit<ParagraphBox>(
      paragraphs, (p) => p.union, point, snapEm * math.max(est, 1));
}

/// 按行段矩形命中：任一 rect 包含则直接命中，否则取到各 rect 的最短距离。
T? _hitRects<T>(
    List<T> items, List<Rect> Function(T) rectsOf, Offset point, double snap) {
  T? best;
  var bestD = double.infinity;
  for (final it in items) {
    for (final r in rectsOf(it)) {
      if (r.contains(point)) return it;
      final d = _distToRect(point, r);
      if (d < bestD) {
        bestD = d;
        best = it;
      }
    }
  }
  return bestD <= snap ? best : null;
}

/// 通用命中：包含优先，否则最近且位于 [snap] 阈值内。
T? _hit<T>(List<T> items, Rect Function(T) unionOf, Offset point, double snap) {
  T? best;
  var bestD = double.infinity;
  for (final it in items) {
    final r = unionOf(it);
    if (r.contains(point)) return it;
    final d = _distToRect(point, r);
    if (d < bestD) {
      bestD = d;
      best = it;
    }
  }
  return bestD <= snap ? best : null;
}

/// 点到矩形的最短距离（矩形内为 0）。
double _distToRect(Offset p, Rect r) {
  if (r.contains(p)) return 0;
  final dx =
      p.dx < r.left ? r.left - p.dx : (p.dx > r.right ? p.dx - r.right : 0);
  final dy =
      p.dy < r.top ? r.top - p.dy : (p.dy > r.bottom ? p.dy - r.bottom : 0);
  return math.sqrt(dx * dx + dy * dy);
}

/// 全页字号的（低置信稳健）中位数。
double _medianFs(List<Map<Object?, Object?>> chars) {
  final fs = chars.map(_fs).toList()..sort();
  return fs.isEmpty ? 12 : fs[fs.length ~/ 2];
}
