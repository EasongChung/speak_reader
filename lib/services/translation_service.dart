import 'dart:convert';
import 'package:http/http.dart' as http;

import 'settings_service.dart';

/// 翻译服务:调用 OpenAI 兼容的 chat/completions 接口。
///
/// 兼容 OpenAI / DeepSeek / 通义千问 / 智谱 / Kimi 等——它们都提供
/// `{baseURL}/chat/completions` 端点与 `Authorization: Bearer {key}` 鉴权。
class TranslationService {
  /// 把 [text] 翻译为 [targetLang](默认中文)。失败抛出带中文说明的异常。
  Future<String> translate(
    String text, {
    required AppSettings settings,
    String targetLang = '中文',
  }) async {
    if (!settings.translationReady) {
      throw Exception('未配置翻译 API,请先到「设置」填写接口地址和密钥');
    }
    if (text.trim().isEmpty) {
      throw Exception('没有可翻译的内容');
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
