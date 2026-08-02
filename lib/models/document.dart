import 'dart:convert';

/// 文本文档的来源类型
enum DocSource {
  camera('拍照'),
  gallery('相册'),
  word('Word'),
  pdf('PDF'),
  txt('文本'),
  manual('手动');

  const DocSource(this.label);
  final String label;

  static DocSource fromName(String? name) {
    return DocSource.values.firstWhere(
      (e) => e.name == name,
      orElse: () => DocSource.manual,
    );
  }
}

/// 一篇导入的文本文档
class Document {
  final String id;
  String title;
  String content;
  final DocSource source;
  final int createdAt; // 毫秒时间戳

  // [v2.4.0] 原文阅读功能: 原始文件路径与 MIME 类型
  final String? originalFilePath;
  final String? originalFileMime;

  // [v2.5.1] 多页面文件(如 PDF)的分页文本, 索引 = 页码-1; null = 无分页信息
  // (单页文件或 v2.5.0 及更早导入的历史数据, 此时阅读页仍按全文显示)
  final List<String>? pageTexts;

  Document({
    required this.id,
    required this.title,
    required this.content,
    required this.source,
    required this.createdAt,
    this.originalFilePath, // [v2.4.0] 可选参数，向下兼容
    this.originalFileMime, // [v2.4.0] 可选参数，向下兼容
    this.pageTexts, // [v2.5.1] 可选参数，向下兼容
  });

  /// 用于列表展示的预览文本(截断)
  String get preview {
    final trimmed = content.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (trimmed.length <= 60) return trimmed;
    return '${trimmed.substring(0, 60)}…';
  }

  String get createdAtText {
    final d = DateTime.fromMillisecondsSinceEpoch(createdAt);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  // [v2.4.0] 原文相关便利属性
  bool get hasOriginal =>
      originalFilePath != null && originalFilePath!.isNotEmpty;
  bool get isImageOriginal =>
      hasOriginal && (originalFileMime?.startsWith('image/') ?? false);
  bool get isPdfOriginal =>
      hasOriginal && originalFileMime == 'application/pdf';

  // [v2.5.1] 是否多页面文件(有分页文本且超过 1 页)
  bool get isMultiPage => pageTexts != null && pageTexts!.length > 1;

  /// [v2.5.1] 取指定页文本(页码-1); 无分页信息/越界时回退全文。
  String pageText(int pageIndex) {
    final pages = pageTexts;
    if (pages == null || pages.isEmpty) return content;
    final i = pageIndex.clamp(0, pages.length - 1);
    return pages[i];
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'content': content,
        'source': source.name,
        'createdAt': createdAt,
        // [v2.4.0] 原文文件信息
        'originalFilePath': originalFilePath,
        'originalFileMime': originalFileMime,
        // [v2.5.1] 分页文本(多页面文件)
        'pageTexts': pageTexts,
      };

  factory Document.fromMap(Map<String, dynamic> map) => Document(
        id: map['id'] as String,
        title: (map['title'] as String?) ?? '未命名',
        content: (map['content'] as String?) ?? '',
        source: DocSource.fromName(map['source'] as String?),
        createdAt: (map['createdAt'] as int?) ??
            DateTime.fromMillisecondsSinceEpoch(0).millisecondsSinceEpoch,
        // [v2.4.0] 原文文件信息（可空，兼容旧数据）
        originalFilePath: map['originalFilePath'] as String?,
        originalFileMime: map['originalFileMime'] as String?,
        // [v2.5.1] 分页文本（可空，兼容旧数据）
        pageTexts: _decodePageTexts(map['pageTexts']),
      );

  /// [v2.5.1] 从持久化数据解析分页文本(容错非 List/损坏数据)。
  static List<String>? _decodePageTexts(Object? raw) {
    if (raw is! List) return null;
    final pages = <String>[];
    for (final e in raw) {
      pages.add(e == null ? '' : '$e');
    }
    return pages.isEmpty ? null : pages;
  }

  String toJson() => jsonEncode(toMap());

  factory Document.fromJson(String source) =>
      Document.fromMap(jsonDecode(source) as Map<String, dynamic>);
}
