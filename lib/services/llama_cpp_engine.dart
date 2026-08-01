import 'package:llama_cpp_dart/llama_cpp_dart.dart';

import '../models/local_model.dart';
import 'inference_engine.dart';

/// [v2.5.0] llama_cpp_dart 0.2.2 引擎实现。
///
/// - 模型在后台 typed_isolate 常驻(LlamaParent), 避免阻塞 UI 且不重复加载
/// - 翻译: 文本 prompt → sendPrompt;  OCR: 图像 + <image> 标记 → sendPromptWithImages
/// - 加载失败/超时抛异常, 由上层通道回退在线服务
class LlamaCppEngine implements InferenceEngine {
  LlamaCppEngine._();

  /// 全局单例(阅读页翻译 + 首页 OCR 共享, 避免重复加载模型)
  static final LlamaCppEngine instance = LlamaCppEngine._();

  LlamaParent? _parent;
  LocalModelInfo? _model;

  @override
  bool get isLoaded => _parent != null && _parent!.status == LlamaStatus.ready;

  @override
  String? get loadedModelName => _model?.fileName;

  /// 是否已加载多模态模型(可 OCR)。
  bool get canOcr => _model?.canOcr ?? false;

  @override
  Future<void> load(LocalModelInfo model) async {
    // 已是目标模型且就绪: 直接返回
    if (isLoaded && _model?.path == model.path) return;
    await dispose();

    final contextParams = ContextParams()
      ..nCtx = 4096
      ..nPredict = 512
      ..nBatch = 512;
    final samplerParams = SamplerParams()
      ..temp = 0.3 // 翻译/OCR 用低温度, 减少随机杂讯
      ..topK = 40
      ..topP = 0.9
      ..penaltyRepeat = 1.1;

    final loadCommand = LlamaLoad(
      path: model.path,
      mmprojPath: model.mmprojPath,
      modelParams: ModelParams()..nGpuLayers = 0, // CPU 优先, 稳定不 OOM
      contextParams: contextParams,
      samplingParams: samplerParams,
    );

    final parent = LlamaParent(loadCommand);
    await parent.init();
    _parent = parent;
    _model = model;

    // 等待模型就绪(1B~3B 加载约 2~10 秒)
    const timeout = Duration(seconds: 90);
    final deadline = DateTime.now().add(timeout);
    while (parent.status != LlamaStatus.ready) {
      if (parent.status == LlamaStatus.error) {
        final msg = '模型加载失败(${model.fileName}), 已回退在线通道';
        await dispose();
        throw Exception(msg);
      }
      if (DateTime.now().isAfter(deadline)) {
        await dispose();
        throw Exception('模型加载超时(${model.fileName}), 已回退在线通道');
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  @override
  Future<String> translate(String text) async {
    final parent = _requireReady();
    final prompt = _buildTranslatePrompt(text);
    final result = await parent.sendPrompt(prompt);
    return _cleanOutput(result);
  }

  @override
  Future<String> ocrImage(String imagePath) async {
    final parent = _requireReady();
    if (_model?.mmprojPath == null) {
      throw StateError('当前模型不支持图片识别(缺少 .mmproj)');
    }
    final prompt = _buildOcrPrompt();
    final images = [LlamaImage.fromFile(imagePath)];
    final result = await parent.sendPromptWithImages(prompt, images);
    return _cleanOutput(result);
  }

  @override
  Future<void> dispose() async {
    final parent = _parent;
    _parent = null;
    _model = null;
    if (parent != null) {
      try {
        await parent.dispose();
      } catch (_) {
        // 释放失败不影响后续重新加载
      }
    }
  }

  LlamaParent _requireReady() {
    final parent = _parent;
    if (parent == null || parent.status != LlamaStatus.ready) {
      throw StateError('模型未就绪, 请先在「设置 → 本地模型」加载');
    }
    return parent;
  }

  /// [v2.5.0] 翻译提示词模板(英文→简体中文, 只输出译文)。
  String _buildTranslatePrompt(String text) {
    final trimmed = text.trim();
    return '请把下面的文本翻译成简体中文，只输出译文本身，'
        '不要包含任何解释、前缀或多余内容。\n\n'
        '原文：\n$trimmed\n\n译文：';
  }

  /// [v2.5.0] OCR 提示词模板(<image> 标记数量须与 images 数量一致)。
  String _buildOcrPrompt() {
    return '请识别这张图片中的所有文字，只输出识别到的文字内容，'
        '保持原有段落顺序，不要添加任何解释。\n\n<image>';
  }

  /// 清理模型输出: 去空白与常见杂讯。
  String _cleanOutput(String raw) {
    var s = raw.trim();
    // 截断模型可能自问自答的尾部
    final cut = ['译文：', '翻译：', '<|endoftext|>', '<|eot_id|>', '</s>'];
    for (final c in cut) {
      final idx = s.indexOf(c);
      if (idx >= 0 && idx < s.length - c.length) {
        s = s.substring(0, idx).trim();
      }
    }
    return s;
  }
}
