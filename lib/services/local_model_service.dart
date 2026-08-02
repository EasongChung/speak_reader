import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/local_model.dart';

/// [v2.5.1] 本地模型扫描与目录管理。
///
/// 模型约定目录: 内置存储 `~/Android/media/<pkg>/models/`
/// (无外部存储时回退 `getApplicationDocumentsDirectory()/models/`)
/// - Android 11+ 分区存储收紧, `Android/data/<pkg>/files/` 用户文件管理器
///   无法写入; `Android/media/<pkg>/` 为应用专属 media 目录, 用户可访问写入
/// - 每个 `.gguf` 文件视为一个可用模型
/// - 同目录的 `.mmproj` 作为视觉投影文件, 使模型具备多模态(OCR)能力
/// - 模型不内置 APK, 用户可自行下载放入该目录; 也可使用设置页
///   「扫描下载目录」直接记录外部路径加载(scan 来源, 不复制文件)
class LocalModelService {
  /// [v2.5.1] 用户扫描目录的持久化键。
  static const _scanDirKey = 'model_scan_dir';

  /// 模型目录(不存在时创建)。
  ///
  /// [v2.5.1] 优先手机内置存储 `~/Android/media/<pkg>/models/`
  /// (由 `getExternalStorageDirectories()` 返回的
  ///  `.../Android/data/<pkg>/files` 推导替换而来, 用户文件管理器可访问写入),
  /// 推导/创建失败时回退应用内部文档目录。
  Future<Directory> getModelsDir() async {
    final media = await _mediaModelsDir();
    if (media != null) return media;

    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(appDir.path, 'models'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// [v2.5.1] 内置存储应用专属 media 模型目录, 推导失败返回 null。
  ///
  /// `getExternalStorageDirectories()` 返回 `.../Android/data/<pkg>/files`,
  /// 替换为 `.../Android/media/<pkg>/models` 即为用户文件管理器可访问的
  /// 应用专属 media 目录(Android 11+ 下用户可在此放置模型, 无需权限)。
  Future<Directory?> _mediaModelsDir() async {
    try {
      final dirs = await getExternalStorageDirectories();
      if (dirs == null || dirs.isEmpty) return null;
      final mediaPath = dirs.first.path
          .replaceFirst('/Android/data/', '/Android/media/')
          .replaceFirst(RegExp(r'/files$'), '/models');
      if (mediaPath == dirs.first.path) return null; // 路径推导失败
      final dir = Directory(mediaPath);
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    } catch (_) {
      // 平台不支持/未实现/创建失败时回退内部目录
    }
    return null;
  }

  /// 扫描模型目录, 返回可用模型清单(按文件名排序)。
  ///
  /// 多模态判定: 同目录存在 `.mmproj` 且文件名与该 `.gguf` 家族名匹配,
  /// 或目录中恰好只有一个 `.gguf` 时匹配唯一 `.mmproj`。
  /// [v2.5.1] 额外并入「扫描下载目录」记录到的模型(scan 来源, 去重)。
  Future<List<LocalModelInfo>> listModels() async {
    final managed = await _listManagedModels();
    final seen = <String>{for (final m in managed) m.path};
    final all = [...managed];

    // [v2.5.1] 并入「扫描下载目录」模型(记录路径直接加载, 不复制文件)
    final scanModels = await scanDownloadDir();
    for (final m in scanModels) {
      if (seen.add(m.path)) all.add(m);
    }

    all.sort((a, b) {
      final byName = p.basename(a.path).compareTo(p.basename(b.path));
      if (byName != 0) return byName;
      return a.source.index.compareTo(b.source.index);
    });
    return all;
  }

  /// 仅扫描应用模型目录(managed 来源)。
  Future<List<LocalModelInfo>> _listManagedModels() async {
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

  // ---------------- [v2.5.1] 扫描下载目录 ----------------

  /// 读取用户扫描目录记录(不存在/已失效时返回 null)。
  Future<String?> getScanDir() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final path = prefs.getString(_scanDirKey);
      if (path == null || path.isEmpty) return null;
      if (!await Directory(path).exists()) return null;
      return path;
    } catch (_) {
      return null;
    }
  }

  /// 记录用户扫描目录(用于「扫描下载目录」; 传 null/空清除记录)。
  Future<void> setScanDir(String? path) async {
    final prefs = await SharedPreferences.getInstance();
    if (path == null || path.isEmpty) {
      await prefs.remove(_scanDirKey);
    } else {
      await prefs.setString(_scanDirKey, path);
    }
  }

  /// [v2.5.1] 扫描「下载目录」中的模型文件, 返回 scan 来源模型清单。
  ///
  /// 依次扫描(去重):
  /// 1. 系统 Download 目录(内置存储根/Download, 权限允许时尽力扫描, 失败跳过)
  /// 2. 用户通过目录选择器授权的扫描目录([getScanDir], 持久化自动重扫)
  /// 返回路径指向原文件, 不复制文件, 供加载时直接读取。
  Future<List<LocalModelInfo>> scanDownloadDir() async {
    final models = <LocalModelInfo>[];
    final seen = <String>{};

    Future<void> addFrom(Directory dir) async {
      final found = await _scanDirModels(dir);
      for (final m in found) {
        if (seen.add(m.path)) models.add(m);
      }
    }

    // 1) 系统 Download(尽力而为, 无权限/失败静默跳过)
    try {
      final root = await getExternalStorageDirectory();
      if (root != null) {
        final download = Directory(p.join(root.path, 'Download'));
        if (await download.exists()) await addFrom(download);
      }
    } catch (_) {}

    // 2) 用户授权的扫描目录(持久化记录, 每次自动重扫)
    final scanDir = await getScanDir();
    if (scanDir != null) {
      try {
        await addFrom(Directory(scanDir));
      } catch (_) {}
    }

    return models;
  }

  /// [v2.5.1] 递归(最多 [depth] 层)扫描目录中的 .gguf/.mmproj 并组装模型。
  Future<List<LocalModelInfo>> _scanDirModels(
    Directory dir, {
    int depth = 2,
  }) async {
    final files = <File>[];
    await _collectModelFiles(dir, files, depth);
    if (files.isEmpty) return const [];

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
        source: LocalModelSource.scan, // [v2.5.1] 记录外部路径直接加载
      ));
    }
    return models;
  }

  /// [v2.5.1] 递归收集目录(及 [depth]-1 层子目录)中的模型文件。
  Future<void> _collectModelFiles(
      Directory dir, List<File> out, int depth) async {
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File) {
          final ext = p.extension(entity.path).toLowerCase();
          if (ext == '.gguf' || ext == '.mmproj') out.add(entity);
        } else if (entity is Directory && depth > 1) {
          await _collectModelFiles(entity, out, depth - 1);
        }
      }
    } catch (_) {
      // 无权限/不可读目录: 跳过
    }
  }

  // ---------------- 存储占用 / 删除 ----------------

  /// 应用模型目录的存储占用(scan 来源不计入)。
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

  /// 删除模型(及其配套 .mmproj)。仅允许删除模型目录直接子文件。
  /// [v2.5.1] 扫描来源的模型不可在应用内删除。
  Future<void> deleteModel(LocalModelInfo model) async {
    if (!model.canDelete) {
      throw StateError('扫描来源的模型不可在应用内删除');
    }
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
