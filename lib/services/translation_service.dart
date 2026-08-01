import 'dart:convert';
import 'package:http/http.dart' as http;

import 'llama_cpp_engine.dart';
import 'settings_service.dart';
import 'translation_cache.dart';

/// 翻译服务:在线 OpenAI 兼容 chat/completions + 离线 GGUF 兜底。
///
/// 通道策略(设置页可切换):
/// - auto:      在线优先, 在线失败/未配置/无网 → 离线(需已加载本地模型)
/// - onlineOnly: 仅在线(等价于 v2.4.0 行为)
/// - offlineOnly: 仅离线(无模型则明确提示)
/// 所有通道共享句子级缓存(TranslationCache), 命中即返回, 不重复推理/调用。
class TranslationService {
  /// 把 [text] 翻译为 [targetLang](默认中文)。失败抛出带中文说明的异常。
  Future<String> translate(
    String text, {
    required AppSettings settings,
    String targetLang = '中文',
  }) async {
    if (text.trim().isEmpty) {
      throw Exception('没有可翻译的内容');
    }
    // 句子级缓存: 所有通道共享, 命中即返回
    final cached = await TranslationCache.get(text, targetLang: targetLang);
    if (cached != null) return cached;

    final result = await _translateByStrategy(text, settings, targetLang);
    if (result.trim().isNotEmpty) {
      await TranslationCache.put(text, result, targetLang: targetLang);
    }
    return result;
  }

  Future<String> _translateByStrategy(
    String text,
    AppSettings settings,
    String targetLang,
  ) async {
    switch (settings.translationStrategy) {
      case TranslationStrategy.offlineOnly:
        return _translateOffline(text);
      case TranslationStrategy.onlineOnly:
        return _translateOnline(text, settings, targetLang);
      case TranslationStrategy.auto:
        // 在线优先, 失败/未配置 → 离线兜底
        try {
          return await _translateOnline(text, settings, targetLang);
        } catch (e) {
          if (LlamaCppEngine.instance.isLoaded) {
            return _translateOffline(text);
          }
          rethrow;
        }
    }
  }

  /// [v2.5.0] 离线通道: 需已加载本地 GGUF 模型(设置页加载), 失败抛明确提示。
  Future<String> _translateOffline(String text) async {
    final engine = LlamaCppEngine.instance;
    if (!engine.isLoaded) {
      throw Exception('离线翻译需先到「设置 → 本地模型」加载 GGUF 模型');
    }
    try {
      final result = await engine.translate(text);
      if (result.trim().isEmpty) {
        throw Exception('离线翻译未产出内容,请检查模型是否匹配');
      }
      return result;
    } on StateError catch (e) {
      throw Exception('离线翻译失败:${e.message}');
    }
  }

  /// 在线通道: 调用 OpenAI 兼容 chat/completions。
  Future<String> _translateOnline(
    String text,
    AppSettings settings,
    String targetLang,
  ) async {
    if (!settings.translationReady) {
      throw Exception('未配置翻译 API,请先到「设置」填写接口地址和密钥');
    }

    final url =
        Uri.parse('${_normalizeBase(settings.baseUrl)}/chat/completions');
    final body = jsonEncode({
      'model': settings.model,
      'messages': [
        {
          'role': 'system',
          'content': '你是专业翻译。把用户输入的内容准确、通顺地翻译成$targetLang,'
              '只输出译文,不要解释、不要加引号。'
        },
        {'role': 'user', 'content': text},
      ],
      'temperature': 0.3,
    });

    http.Response resp;
    try {
      resp = await http
          .post(
            url,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ${settings.apiKey}',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 60));
    } catch (e) {
      throw Exception('网络请求失败:$e');
    }

    if (resp.statusCode != 200) {
      final snippet = utf8.decode(resp.bodyBytes, allowMalformed: true);
      throw Exception('接口返回错误 ${resp.statusCode}:'
          '${snippet.length > 200 ? snippet.substring(0, 200) : snippet}');
    }

    try {
      final data =
          jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final choices = data['choices'] as List?;
      final content =
          (choices?.first as Map?)?['message']?['content'] as String?;
      if (content == null || content.trim().isEmpty) {
        throw Exception('接口未返回译文');
      }
      return content.trim();
    } catch (e) {
      throw Exception('解析译文失败:$e');
    }
  }

  /// 去掉结尾多余的斜杠,避免拼出双斜杠
  String _normalizeBase(String base) {
    var b = base.trim();
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    return b;
  }
}
