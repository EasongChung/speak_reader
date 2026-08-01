import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/local_model.dart';

/// [v2.5.0] 本地模型扫描与目录管理。
///
/// 模型约定目录: 内置存储应用外部目录 `.../Android/data/<pkg>/files/models/`
/// (无外部存储时回退 `getApplicationDocumentsDirectory()/models/`)
/// - 每个 `.gguf` 文件视为一个可用模型
/// - 同目录的 `.mmproj` 作为视觉投影文件, 使模型具备多模态(OCR)能力
/// - 模型不内置 APK, 由用户自行下载放入该目录(下载指引见 docs/)
class LocalModelService {
  /// 模型目录(不存在时创建)。
  ///
  /// [v2.5.0] 优先手机内置存储的应用外部目录(用户文件管理器可访问,
  /// 如 `/storage/emulated/0/Android/data/<pkg>/files/models/`),
  /// 无外部存储时回退应用内部文档目录。
  Future<Directory> getModelsDir() async {
    final base =
        await _externalAppDir() ?? await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'models'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// [v2.5.0] 内置存储应用外部目录(Android/data/<pkg>/files)。
  ///
  /// `getExternalStorageDirectories()` 在 Android 上对应 `getExternalFilesDirs(null)`,
  /// 返回 App 专属外部目录, **无需存储权限**, 用户文件管理器可见;
  /// 无外部存储或平台不支持时返回 null。
  Future<Directory?> _externalAppDir() async {
    try {
      final dirs = await getExternalStorageDirectories();
      if (dirs != null && dirs.isNotEmpty) return dirs.first;
    } catch (_) {
      // 平台不支持/未实现时回退内部目录
    }
    return null;
  }

  /// 扫描模型目录, 返回可用模型清单(按文件名排序)。
  ///
  /// 多模态判定: 同目录存在 `.mmproj` 且文件名与该 `.gguf` 家族名匹配,
  /// 或目录中恰好只有一个 `.gguf` 时匹配唯一 `.mmproj`。
  Future<List<LocalModelInfo>> listModels() async {
    final dir = await getModelsDir();
    final files = <File>[];
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final extension = p.extension(entity.path).toLowerCase();
        if (extension == '.gguf' || extension == '.mmproj') {
          files.add(entity);
        }
      }
    } catch (_) {
      return const [];
    }

    final ggufs = files
        .where((f) => p.extension(f.path).toLowerCase() == '.gguf')
        .toList()
      ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    final mmprojs = files
        .where((f) => p.extension(f.path).toLowerCase() == '.mmproj')
        .toList();

    final models = <LocalModelInfo>[];
    for (final f in ggufs) {
      final size = await _safeLength(f);
      final mmprojPath = _matchMmproj(f, mmprojs, ggufs.length);
      models.add(LocalModelInfo(
        path: f.path,
        fileName: p.basename(f.path),
        sizeBytes: size,
        kind: mmprojPath != null
            ? LocalModelKind.multimodal
            : LocalModelKind.text,
        mmprojPath: mmprojPath,
      ));
    }
    return models;
  }

  /// 所有模型 + 孤立 .mmproj 的存储占用。
  Future<int> getTotalSize() async {
    final dir = await getModelsDir();
    var total = 0;
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File) {
          try {
            total += await entity.length();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return total;
  }

  /// 删除模型(及其配套 .mmproj)。仅允许删除 models 目录直接子文件。
  Future<void> deleteModel(LocalModelInfo model) async {
    final dir = await getModelsDir();
    final rootPath = p.normalize(p.absolute(dir.path));

    Future<bool> safe(File f) async {
      final norm = p.normalize(p.absolute(f.path));
      if (!p.equals(p.dirname(norm), rootPath)) return false;
      return await f.exists();
    }

    if (await safe(File(model.path))) {
      await File(model.path).delete();
    }
    final mm = model.mmprojPath;
    if (mm != null && await safe(File(mm))) {
      await File(mm).delete();
    }
  }

  Future<int> _safeLength(File f) async {
    try {
      return await f.length();
    } catch (_) {
      return 0;
    }
  }

  /// 匹配 .gguf 的配套 .mmproj(优先家族名匹配, 其次唯一匹配)。
  String? _matchMmproj(File gguf, List<File> mmprojs, int ggufCount) {
    if (mmprojs.isEmpty) return null;
    final ggufBase = p
        .basenameWithoutExtension(gguf.path)
        .toLowerCase(); // MiniCPM5-1B-Q4_K_M

    for (final m in mmprojs) {
      final mBase = p.basenameWithoutExtension(m.path).toLowerCase();
      // mmproj-* 家族名一般含模型主名(去除量化后缀)
      final ggufFamily = _familyName(ggufBase);
      if (ggufFamily.isNotEmpty && mBase.contains(ggufFamily)) {
        return m.path;
      }
      if (ggufBase.contains(mBase.replaceAll('mmproj-', ''))) {
        return m.path;
      }
    }
    // 目录唯一 gguf + 唯一 mmproj: 视为配套
    if (ggufCount == 1 && mmprojs.length == 1) {
      return mmprojs.single.path;
    }
    return null;
  }

  /// 去除量化后缀等得到家族名, 如 `minicpm5-1b-q4_k_m` → `minicpm5-1b`。
  String _familyName(String base) {
    final parts = base.split('-');
    if (parts.length <= 1) return base;
    // 去掉尾部常见的量化/精度段: q4, q8, f16, q4_k_m, iq4, 数字精度等
    final known = RegExp(r'^(q[248]|q[248]_[km]|iq[1-4]|f16|f32|bf16|gguf)$');
    final fam = <String>[];
    for (final part in parts) {
      if (known.hasMatch(part) ||
          (fam.isNotEmpty && int.tryParse(part) != null)) {
        break;
      }
      fam.add(part);
    }
    return fam.join('-');
  }
}
