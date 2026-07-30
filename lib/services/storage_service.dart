import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/document.dart';

/// 历史记录与受控原件存储。
class StorageService {
  static const _key = 'documents';
  static Future<void> _mutationTail = Future<void>.value();
  static final Random _random = Random.secure();

  Future<T> _exclusive<T>(Future<T> Function() action) async {
    final previous = _mutationTail;
    final release = Completer<void>();
    _mutationTail = release.future;
    await previous;
    try {
      return await action();
    } finally {
      release.complete();
    }
  }

  Future<List<Document>> loadAll() => _exclusive(
      () async => List<Document>.unmodifiable(await _loadAllUnlocked()));

  Future<List<Document>> _loadAllUnlocked() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_key) ?? [];
    final docs = <Document>[];
    for (final json in list) {
      try {
        docs.add(Document.fromJson(json));
      } catch (_) {
        // 损坏记录不进入 UI；后续可由目录对账回收其孤儿原件。
      }
    }
    return docs;
  }

  Future<void> _saveAll(List<Document> docs) async {
    final prefs = await SharedPreferences.getInstance();
    final saved =
        await prefs.setStringList(_key, docs.map((d) => d.toJson()).toList());
    if (!saved) throw Exception('文档历史保存失败');
  }

  /// 新增或更新文档并返回提交后的快照。
  Future<List<Document>> upsert(Document doc) => _exclusive(() async {
        final docs = await _loadAllUnlocked();
        docs.removeWhere((d) => d.id == doc.id);
        docs.insert(0, doc);
        await _saveAll(docs);
        return List<Document>.unmodifiable(docs);
      });

  /// 删除文档及其未被其他记录引用的受控原件。
  Future<List<Document>> delete(String id) => _exclusive(() async {
        final docs = await _loadAllUnlocked();
        Document? removed;
        for (final doc in docs) {
          if (doc.id == id) {
            removed = doc;
            break;
          }
        }
        if (removed == null) return List<Document>.unmodifiable(docs);

        docs.removeWhere((d) => d.id == id);
        File? trashed;
        File? original;
        final originalPath = removed.originalFilePath;
        final stillReferenced = originalPath != null &&
            docs.any((doc) => doc.originalFilePath == originalPath);
        if (!stillReferenced && originalPath != null) {
          original = await _managedFile(originalPath);
          if (original != null && await original.exists()) {
            final trash = File('${original.path}.trash_${_token()}');
            trashed = await original.rename(trash.path);
          }
        }

        try {
          await _saveAll(docs);
        } catch (_) {
          if (trashed != null && original != null && await trashed.exists()) {
            await trashed.rename(original.path);
          }
          rethrow;
        }

        if (trashed != null && await trashed.exists()) {
          try {
            await trashed.delete();
          } catch (_) {
            // 元数据已提交；残留 trash 可由后续目录对账回收。
          }
        }
        return List<Document>.unmodifiable(docs);
      });

  Future<void> clear() => _exclusive(() async {
        final docs = await _loadAllUnlocked();
        final prefs = await SharedPreferences.getInstance();
        final removed = await prefs.remove(_key);
        if (!removed && prefs.containsKey(_key)) {
          throw Exception('文档历史清空失败');
        }
        for (final path
            in docs.map((d) => d.originalFilePath).whereType<String>()) {
          await deleteManagedOriginal(path);
        }
      });

  Future<Directory> getOriginalsDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(appDir.path, 'originals'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 将外部原件复制到受控目录；部分复制不会以正式文件名暴露。
  Future<String> copyOriginal(String sourcePath, String extension) async {
    final source = File(sourcePath);
    if (!await source.exists()) throw Exception('原始文件不存在');
    final dir = await getOriginalsDir();
    final safeExt =
        extension.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (safeExt.isEmpty) throw ArgumentError.value(extension, 'extension');

    final finalFile = File(p.join(dir.path, '${_token()}.$safeExt'));
    final partFile = File('${finalFile.path}.part');
    try {
      await source.copy(partFile.path);
      if (await partFile.length() != await source.length()) {
        throw Exception('原件复制不完整');
      }
      return (await partFile.rename(finalFile.path)).path;
    } catch (_) {
      if (await partFile.exists()) await partFile.delete();
      rethrow;
    }
  }

  /// 仅删除确认属于 originals 直接子目录的普通文件。
  Future<void> deleteManagedOriginal(String path) async {
    final file = await _managedFile(path);
    if (file != null && await file.exists()) await file.delete();
  }

  Future<File?> _managedFile(String candidatePath) async {
    final root = await getOriginalsDir();
    final rootPath = p.normalize(p.absolute(root.path));
    final candidate = p.normalize(p.absolute(candidatePath));
    if (!p.equals(p.dirname(candidate), rootPath)) return null;

    final type = await FileSystemEntity.type(candidate, followLinks: false);
    if (type == FileSystemEntityType.link ||
        type == FileSystemEntityType.directory) {
      return null;
    }
    return File(candidate);
  }

  static String _token() {
    final random = List<int>.generate(12, (_) => _random.nextInt(256))
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${DateTime.now().microsecondsSinceEpoch}_$random';
  }
}
