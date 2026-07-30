import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/document.dart';

/// 历史记录本地存储服务(基于 shared_preferences)。
///
/// 以 JSON 字符串列表保存所有导入过的文档,最新的在前。
class StorageService {
  static const _key = 'documents';

  Future<List<Document>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_key) ?? [];
    final docs = <Document>[];
    for (final json in list) {
      try {
        docs.add(Document.fromJson(json));
      } catch (_) {
        // 跳过损坏的记录
      }
    }
    return docs;
  }

  Future<void> _saveAll(List<Document> docs) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, docs.map((d) => d.toJson()).toList());
  }

  /// 新增或更新(按 id),并置顶
  Future<void> upsert(Document doc) async {
    final docs = await loadAll();
    docs.removeWhere((d) => d.id == doc.id);
    docs.insert(0, doc);
    await _saveAll(docs);
  }

  Future<void> delete(String id) async {
    final docs = await loadAll();
    docs.removeWhere((d) => d.id == id);
    await _saveAll(docs);
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  // [v2.4.0] 获取原始文件存放目录 {appDocDir}/originals/
  Future<Directory> getOriginalsDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/originals');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }
}
