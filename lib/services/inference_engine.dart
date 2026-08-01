import '../models/local_model.dart';

/// [v2.5.0] 端侧推理引擎抽象接口。
///
/// 隔离具体绑定(如 llama_cpp_dart / flutter_llama)的差异,
/// 上层(翻译/OCR 通道)只依赖本接口, 切换绑定不影响调用方。
abstract class InferenceEngine {
  /// 引擎是否已加载并就绪。
  bool get isLoaded;

  /// 当前已加载模型的文件名(未加载时为 null)。
  String? get loadedModelName;

  /// 加载指定模型(后台 isolate, 可能耗时数秒)。
  /// 失败时抛异常, 调用方回退在线通道。
  Future<void> load(LocalModelInfo model);

  /// 离线翻译一段文本, 返回译文。
  Future<String> translate(String text);

  /// 离线 OCR: 识别图片中的文字。要求模型为多模态(带 mmproj)。
  Future<String> ocrImage(String imagePath);

  /// 释放模型与资源(可再次 load)。
  Future<void> dispose();
}
