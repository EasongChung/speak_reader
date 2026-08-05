import 'dart:math' as math;
import 'dart:ui';

// 坐标系与 PDFBox `extractTextPositions` 一致（页面点，原点在 CropBox 左上角，
// y 向下）。本文所有矩形均为页面坐标，经 `PDFViewController.setHighlights`
// 由原生侧绘制。

/// 一个句子的几何与文本。
///
/// 分句规则与 `TtsService._splitSentences` 对齐：以 `。！？!?；;` 及换行为
/// 硬边界。因现有实现把 `\n` 也视作边界，**句子不跨行**，故 [rects] 通常只有
/// 一个行段矩形；保留列表以兼容未来跨行句。
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

/// 句子终止标点（与 `TtsService` 的正则 `(?<=[。！？!?；;\n])` 对齐）。
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

/// 字符坐标 → 句子列表（行内按终止标点切句）。
///
/// [chars] 需为 `extractTextPositions` 返回的 `chars`（阅读顺序）。
/// 说明：现有 `TtsService` 把换行也当硬边界，**句子不跨行**，这里对每行独立
/// 切句，与朗读语义保持一致。
List<SentenceBox> buildSentences(List<Map<Object?, Object?>> chars) {
  if (chars.isEmpty) return const [];
  final result = <SentenceBox>[];
  for (final line in _buildLines(chars)) {
    final sb = StringBuffer();
    var left = double.infinity;
    var right = double.negativeInfinity;

    void flush() {
      if (sb.isNotEmpty && right >= left) {
        result.add(SentenceBox(
          text: sb.toString(),
          rects: [Rect.fromLTRB(left, line.top, right, line.bottom)],
        ));
      }
      sb.clear();
      left = double.infinity;
      right = double.negativeInfinity;
    }

    for (final c in line.chars) {
      final ch = c['c'].toString();
      left = math.min(left, _x(c));
      right = math.max(right, _x(c) + _w(c));
      sb.write(ch);
      if (_sentenceTerms.contains(ch)) flush();
    }
    flush(); // 行尾亦为边界（对应 TtsService 的 \n）
  }
  return result;
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
  return _hit<SentenceBox>(
      sentences, (s) => s.union, point, snapEm * math.max(est, 1));
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
