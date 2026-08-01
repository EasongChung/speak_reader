import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// [v2.5.0] 翻译句子级缓存: 内存 LRU + 磁盘文件, 避免重复推理/重复调用 API。
///
/// - 内存: 限制条数(_maxMemory), 超出移除最旧
/// - 磁盘: `{appDir}/cache/translations/<hash>.json`, 存 `{lang,s,t}` 三字段,
///   读取时校验目标语言与原文一致(防哈希碰撞 / 语言切换串译文)
/// - 哈希用 Dart 内置 String.hashCode(基于内容, 跨运行稳定), 配合原文校验足够安全
class TranslationCache {
  TranslationCache._();

  static const int _maxMemory = 200;
  static final Map<String, String> _memory = {};
  static String? _dirPath;

  static Future<String?> get(String sentence, {String targetLang = '中文'}) {
    final s = sentence.trim();
    if (s.isEmpty) return Future.value(null);
    final memKey = _memKey(s, targetLang);
    final cached = _memory[memKey];
    if (cached != null) return Future.value(cached);

    return _readDisk(s, targetLang);
  }

  static Future<void> put(String sentence, String translation,
      {String targetLang = '中文'}) async {
    final s = sentence.trim();
    final t = translation.trim();
    if (s.isEmpty || t.isEmpty) return;

    _putMemory(s, t, targetLang);

    try {
      final file = await _fileFor(s, targetLang);
      await file.writeAsString(
        jsonEncode({'lang': targetLang, 's': s, 't': t}),
        flush: true,
      );
    } catch (_) {
      // 磁盘缓存失败不影响主流程
    }
  }

  static void _putMemory(String s, String t, String lang) {
    _memory[_memKey(s, lang)] = t;
    if (_memory.length > _maxMemory) {
      _memory.remove(_memory.keys.first);
    }
  }

  static Future<String?> _readDisk(String s, String lang) async {
    try {
      final file = await _fileFor(s, lang);
      if (!await file.exists()) return null;
      final data = jsonDecode(await file.readAsString());
      if (data is Map && data['lang'] == lang && data['s'] == s) {
        final t = data['t'] as String?;
        if (t != null && t.isNotEmpty) {
          _putMemory(s, t, lang);
          return t;
        }
      }
    } catch (_) {}
    return null;
  }

  static Future<File> _fileFor(String s, String lang) async {
    final dir = await _dir();
    final hash = _memKey(s, lang).hashCode & 0x7FFFFFFFFFFFFFFF;
    return File('${dir.path}/${hash.toRadixString(16)}.json');
  }

  static Future<Directory> _dir() async {
    if (_dirPath != null) return Directory(_dirPath!);
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/cache/translations');
    if (!await dir.exists()) await dir.create(recursive: true);
    _dirPath = dir.path;
    return dir;
  }

  static String _memKey(String s, String lang) => '$lang\n$s';
}
