import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

import 'settings_service.dart';

/// 在线视觉大模型 OCR:把图片交给支持视觉的模型(gpt-4o / qwen-vl / glm-4v 等)
/// 提取文字。复用翻译用的 OpenAI 兼容接口配置。
class VisionOcrService {
  Future<String> recognizeFile(
    String imagePath, {
    required AppSettings settings,
  }) async {
    if (!settings.translationReady) {
      throw Exception('未配置 API,请先到「设置」填写接口地址和密钥');
    }
    final file = File(imagePath);
    if (!await file.exists()) {
      throw Exception('图片文件不存在');
    }

    final bytes = await file.readAsBytes();
    final b64 = base64Encode(bytes);
    final mime = _mime(imagePath);
    final dataUrl = 'data:$mime;base64,$b64';

    final url =
        Uri.parse('${_normalizeBase(settings.baseUrl)}/chat/completions');
    final body = jsonEncode({
      'model': settings.model,
      'messages': [
        {
          'role': 'user',
          'content': [
            {
              'type': 'text',
              'text': '请提取这张图片中的所有文字,按原文排版输出,'
                  '只输出文字内容,不要解释、不要额外说明。'
            },
            {
              'type': 'image_url',
              'image_url': {'url': dataUrl}
            },
          ],
        },
      ],
      'temperature': 0.0,
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
          .timeout(const Duration(seconds: 90));
    } catch (e) {
      throw Exception('网络请求失败:$e');
    }

    if (resp.statusCode != 200) {
      final s = utf8.decode(resp.bodyBytes, allowMalformed: true);
      throw Exception('接口返回错误 ${resp.statusCode}:'
          '${s.length > 200 ? s.substring(0, 200) : s}');
    }

    try {
      final data =
          jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final content = ((data['choices'] as List?)?.first as Map?)?['message']
          ?['content'] as String?;
      if (content == null || content.trim().isEmpty) {
        throw Exception('模型未返回文字(该模型可能不支持图片输入)');
      }
      return content.trim();
    } catch (e) {
      throw Exception('解析结果失败:$e');
    }
  }

  String _mime(String path) {
    final p = path.toLowerCase();
    if (p.endsWith('.png')) return 'image/png';
    if (p.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  String _normalizeBase(String base) {
    var b = base.trim();
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    return b;
  }
}
