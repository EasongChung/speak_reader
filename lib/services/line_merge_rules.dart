/// 行间「自动换行」判定规则。
///
/// 句子跨行合并（v2.6.x #3）最初是**无条件**的：只要不跨段落间隙就把下一行
/// 接到当前句尾。实测出现大量误合并——段落末尾的短行会粘上下一段首行、
/// 行末带逗号的人工换行被当成自动换行、缩进的新段首被吞进上一句。
///
/// 本文件把「什么样的换行才是排版自动折行」抽成单一判据 [canMergeLines]，
/// 供两处消费者共用：
///
/// - `text_position_service.buildSentences`：几何侧，度量单位是 PDF 点
/// - `TtsService._splitSentences`：文本侧，无几何信息，**以字符数当坐标**
///   （`charW = 1`，块宽 = 段内最长行字符数，缩进 = 行首空白数）
///
/// 两侧必须走同一函数：朗读单元与高亮单元一旦异源，就会重演 G2.5.1
/// 「只改一侧」的错位缺陷。
library;

/// 行末出现即判定为**人工换行**的字符（标点、括号、引号、连接符）。
///
/// 自动折行只会断在词与词之间，行末不会遗留任何标点；反过来说，行末带标点
/// 说明这里是作者主动断行（列表项、诗行、表格单元等），不应与下一行合并。
///
/// 注意 `-` 也在内：拉丁文断词连字符（`inter-` / `national`）目前**不做特例**，
/// 按从严原则不合并。若后续要支持，应在此处开口子并同步补测。
const String _lineEndBreakers = '。！？!?；;，,、：:）)】]》>」』"”\'’…—-～~／/\\|';

/// 行首出现即判定为**新单元开始**的字符（标点、项目符号、序号标记）。
///
/// 自动折行的续行首字符一定是正文内容；出现项目符号或收尾标点说明这是
/// 一个新的列表项 / 新段落，不应接到上一句尾部。
const String _lineStartBreakers = '。！？!?；;，,、：:（(【[《<「『"“\'‘•·◦▪▸●○※§#*+-—…'
    '①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳'
    '⒈⒉⒊⒋⒌⒍⒎⒏⒐⒑'
    'ⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩ';

/// 行首形如 `1.` `1)` `(1)` `一、` `IV.` 的序号前缀。
///
/// 单字符集合拦不住多字符序号——`1.` 的首字符是数字，能通过 [_lineStartBreakers]
/// 检查，故额外用正则兜一层。序号必须带 `.` `、` `)` 等显式分隔符才算数。
final RegExp _lineStartOrdinal = RegExp(
  r'^(?:'
  r'\(?\d+[.)、．]'
  r'|[一二三四五六七八九十百千]+[、.．)]'
  r'|[IVXLC]+[.)、]'
  r')',
);

/// 判定「上一行行尾」与「下一行行首」是否属于同一句的自动折行。
///
/// 四条判据全部满足才允许合并（任一不满足即断句）：
///
/// 1. **行末贴右边界**——`blockRight - prevRight <= endSlackChars * charW`。
///    自动折行是因为排不下才换行，行末必然接近版心右边界；段落最后一行
///    通常留有大片空白。
/// 2. **行末无符号**——见 [_lineEndBreakers]。
/// 3. **下一行无缩进**——`nextLeft - blockLeft <= indentSlackChars * charW`。
///    首行缩进（中文常见 2 字符）说明这是新段落。
/// 4. **行首无符号/序号**——见 [_lineStartBreakers] 与 [_lineStartOrdinal]。
///
/// 度量参数（[prevRight] / [blockRight] / [nextLeft] / [blockLeft] / [charW]）
/// 必须同一单位：几何侧统一用 PDF 点，文本侧统一用字符数。
///
/// [blockLeft] / [blockRight] 应按**段落块内**统计，不要用整页：多栏排版、
/// 页眉页脚会把边界撑到不可用。
///
/// [endSlackChars] 默认 2（用户指定的「行末文字在行边界 2 个字符范围」）。
/// [indentSlackChars] 默认 0.5，仅容忍字距抖动，不容忍真实缩进。
bool canMergeLines({
  required double prevRight,
  required double blockRight,
  required double nextLeft,
  required double blockLeft,
  required double charW,
  required String prevLastChar,
  required String nextFirstChar,
  String nextLineText = '',
  double endSlackChars = 2.0,
  double indentSlackChars = 0.5,
}) {
  if (prevLastChar.isEmpty || nextFirstChar.isEmpty) return false;
  final w = charW > 0 ? charW : 1.0;

  // 1) 行末必须贴近版心右边界（排不下才折行）
  if (blockRight - prevRight > endSlackChars * w) return false;

  // 2) 行末不得有任何标点/符号
  if (_lineEndBreakers.contains(prevLastChar)) return false;

  // 3) 下一行不得有缩进
  if (nextLeft - blockLeft > indentSlackChars * w) return false;

  // 4) 下一行行首不得是标点、项目符号或序号
  if (_lineStartBreakers.contains(nextFirstChar)) return false;
  if (nextLineText.isNotEmpty && _lineStartOrdinal.hasMatch(nextLineText)) {
    return false;
  }

  return true;
}

/// 跨行拼接时是否需要补一个空格。
///
/// 拉丁文的折行处原本是词间空格，直接相连会粘成一个词；CJK 不需要。
/// 两侧任一为 CJK 即不补。
bool needsSpaceBetween(String prevLastChar, String nextFirstChar) =>
    !isCjk(prevLastChar) && !isCjk(nextFirstChar);

/// 首字符是否为 CJK（含中日韩统一表意文字、兼容表意文字、中文标点、全角符号）。
bool isCjk(String s) {
  if (s.isEmpty) return false;
  final cp = s.codeUnitAt(0);
  return (cp >= 0x3000 && cp <= 0x303F) || // CJK 标点
      (cp >= 0x3400 && cp <= 0x4DBF) || // 扩展 A
      (cp >= 0x4E00 && cp <= 0x9FFF) || // 基本区
      (cp >= 0xF900 && cp <= 0xFAFF) || // 兼容表意
      (cp >= 0xFF00 && cp <= 0xFFEF); // 全角
}
