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

  Document({
    required this.id,
    required this.title,
    required this.content,
    required this.source,
    required this.createdAt,
    this.originalFilePath,   // [v2.4.0] 可选参数，向下兼容
    this.originalFileMime,   // [v2.4.0] 可选参数，向下兼容
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
  bool get hasOriginal => originalFilePath != null && originalFilePath!.isNotEmpty;
  bool get isImageOriginal =>
      hasOriginal && (originalFileMime?.startsWith('image/') ?? false);
  bool get isPdfOriginal =>
      hasOriginal && originalFileMime == 'application/pdf';

  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'content': content,
        'source': source.name,
        'createdAt': createdAt,
        // [v2.4.0] 原文文件信息
        'originalFilePath': originalFilePath,
        'originalFileMime': originalFileMime,
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
      );

  String toJson() => jsonEncode(toMap());

  factory Document.fromJson(String source) =>
      Document.fromMap(jsonDecode(source) as Map<String, dynamic>);
}
