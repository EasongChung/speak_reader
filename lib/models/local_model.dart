/// [v2.5.0] 本地 GGUF 模型类型。
enum LocalModelKind {
  /// 纯文本模型(仅有 .gguf, 可做离线翻译)
  text,

  /// 多模态模型(.gguf + 同名 .mmproj, 可做离线 OCR + 翻译)
  multimodal,
}

/// [v2.5.0] 本地模型信息(由 LocalModelService 扫描应用 models 目录得到)。
class LocalModelInfo {
  /// .gguf 模型的绝对路径
  final String path;

  /// 文件名(用于展示)
  final String fileName;

  /// 模型文件字节数
  final int sizeBytes;

  /// 模型类型
  final LocalModelKind kind;

  /// 配套的视觉投影文件(.mmproj)绝对路径, 多模态模型非空
  final String? mmprojPath;

  const LocalModelInfo({
    required this.path,
    required this.fileName,
    required this.sizeBytes,
    required this.kind,
    this.mmprojPath,
  });

  /// 人类可读的体积
  String get sizeLabel {
    if (sizeBytes < 1024) return '$sizeBytes B';
    final kb = sizeBytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    return '${(mb / 1024).toStringAsFixed(2)} GB';
  }

  /// 大模型(>3GB)加载需二次确认(内存保护, Sprint 6.5)
  bool get isLarge => sizeBytes > 3 * 1024 * 1024 * 1024;

  /// 该模型能否用于离线翻译
  bool get canTranslate => true;

  /// 该模型能否用于离线 OCR(需配套 mmproj)
  bool get canOcr => kind == LocalModelKind.multimodal && mmprojPath != null;
}
