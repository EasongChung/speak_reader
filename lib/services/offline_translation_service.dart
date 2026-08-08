import 'package:flutter/services.dart';

/// [G4.3] 一组可加载的离线模型文件（扫描结果）。
class OfflineModelGroup {
  const OfflineModelGroup({
    required this.id,
    required this.modelName,
    required this.vocabularyName,
    required this.shortlistName,
    required this.hasShortlist,
  });

  /// 语向标识，如 `zhen` / `enzh`。
  final String id;
  final String modelName;
  final String vocabularyName;

  /// shortlist 是可选项，缺失时为空串。
  final String shortlistName;
  final bool hasShortlist;

  factory OfflineModelGroup.fromMap(Map<Object?, Object?> map) {
    return OfflineModelGroup(
      id: (map['id'] as String?) ?? '',
      modelName: (map['modelName'] as String?) ?? '',
      vocabularyName: (map['vocabularyName'] as String?) ?? '',
      shortlistName: (map['shortlistName'] as String?) ?? '',
      hasShortlist: (map['hasShortlist'] as bool?) ?? false,
    );
  }

  /// 是否可加载：必须同时有权重与词表。
  ///
  /// shortlist 是可选项，缺了只影响速度不影响能否工作，故不计入。
  /// 与原生侧 `ModelImporter.import` 的判据一致（那里缺这两样会抛异常）。
  bool get isComplete => modelName.isNotEmpty && vocabularyName.isNotEmpty;

  /// 语向的可读形式，如 `zhen` → `中文 → 英文`；无法识别时回退 id 本身。
  String get displayName {
    if (id.length != 4) return id;
    final from = _langLabel(id.substring(0, 2));
    final to = _langLabel(id.substring(2, 4));
    if (from == null || to == null) return id;
    return '$from → $to';
  }

  static String? _langLabel(String code) => const {
        'zh': '中文',
        'en': '英文',
        'ja': '日文',
        'ko': '韩文',
        'de': '德文',
        'fr': '法文',
        'es': '西班牙文',
        'ru': '俄文',
        'it': '意大利文',
        'pt': '葡萄牙文',
      }[code];
}

/// [G4.3] 离线翻译服务（slimt 原生库的 Dart 侧封装）。
///
/// ## 可用性判定不在这里
///
/// `isAvailable` 直接问原生侧，**不在 Dart 侧判版本号**。`docs/13` §G4.3
/// 已定（2026-08-07 用户确认）：判定与 `System.loadLibrary` 同址才不会漂移。
/// 本项目已两次栽在「同一约定的两个消费者只改一侧」。
///
/// 判定结果在本类缓存一次 —— 同一进程内不会自愈，重复问没有意义。
///
/// ## 失败一律上抛
///
/// 本类不做「失败回落在线」，回落由调用方（G4.5 的 `TranslationService`）
/// 决定。这样离线通道的错误在 PoC 阶段可见，不会被静默吞掉。
class OfflineTranslationService {
  static const MethodChannel _channel =
      MethodChannel('com.example.speak_reader/offline_translate');

  /// 可用性缓存。null 表示尚未查询。
  static bool? _available;

  /// 不可用原因缓存。
  static String? _reason;

  /// 离线翻译是否可用（Android 9 以上且原生库加载成功）。
  ///
  /// 非 Android 平台或通道缺失时返回 false，不抛异常。
  static Future<bool> isAvailable() async {
    final cached = _available;
    if (cached != null) return cached;
    try {
      final result = await _channel.invokeMethod<bool>('isOfflineAvailable');
      _available = result ?? false;
    } on MissingPluginException {
      // 非 Android 平台：通道未注册，等同不可用。
      _available = false;
    } on PlatformException {
      _available = false;
    }
    return _available!;
  }

  /// 不可用原因（供设置页副标题展示）；可用时为 null。
  static Future<String?> unavailableReason() async {
    if (await isAvailable()) return null;
    final cached = _reason;
    if (cached != null) return cached;
    try {
      _reason = await _channel.invokeMethod<String>('unavailableReason');
    } on PlatformException {
      _reason = '离线翻译不可用';
    } on MissingPluginException {
      _reason = '当前平台不支持离线翻译';
    }
    return _reason ?? '离线翻译不可用';
  }

  /// 打开系统目录选择器，返回授权目录的 URI 字符串；用户取消返回 null。
  ///
  /// 授权是持久的（原生侧已 takePersistableUriPermission），URI 应由调用方
  /// 存进设置，下次直接 [scanModels] 无需重新选择。
  static Future<String?> pickModelDirectory() async {
    return _channel.invokeMethod<String>('pickModelDirectory');
  }

  /// 扫描已授权目录中成组的模型文件。只扫一层，不递归。
  static Future<List<OfflineModelGroup>> scanModels(String treeUri) async {
    final raw = await _channel.invokeMethod<List<Object?>>(
      'scanModels',
      {'treeUri': treeUri},
    );
    if (raw == null) return const [];
    return raw
        .whereType<Map<Object?, Object?>>()
        .map(OfflineModelGroup.fromMap)
        .where((g) => g.id.isNotEmpty)
        .toList();
  }

  /// 把模型组复制进 app 私有目录，返回各文件的真实路径。
  ///
  /// 复制是必须的：slimt 用 mmap 读真实路径，不认 `content://` URI。
  /// 已存在同名文件则跳过复制。
  static Future<Map<String, String>> importModel(
    String treeUri,
    String groupId,
  ) async {
    final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
      'importModel',
      {'treeUri': treeUri, 'groupId': groupId},
    );
    if (raw == null) throw Exception('导入模型失败：原生侧返回空结果');
    return raw.map((k, v) => MapEntry(k as String, (v as String?) ?? ''));
  }

  /// 已导入到私有目录的模型组 id。
  static Future<List<String>> importedGroups() async {
    final raw = await _channel.invokeMethod<List<Object?>>('importedGroups');
    return raw?.whereType<String>().toList() ?? const [];
  }

  /// [G4.4] 取已导入模型组在私有目录中的真实路径。
  ///
  /// 与 [importModel] 的区别：本方法**不需要 treeUri**，不碰 SAF。已导入的
  /// 文件就在 app 私有目录里，加载时要求用户重新授权目录是没有道理的 ——
  /// 授权可能早已被系统回收，而文件仍然好好地在那儿。
  ///
  /// 返回空 Map 表示未导入或文件不全（不抛异常：「没导入」是正常状态）。
  static Future<Map<String, String>> importedPaths(String groupId) async {
    final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
      'importedPaths',
      {'groupId': groupId},
    );
    if (raw == null) return const {};
    return raw.map((k, v) => MapEntry(k as String, (v as String?) ?? ''));
  }

  /// 删除已导入的模型组（会先卸载再删文件）。
  static Future<void> deleteGroup(String groupId) async {
    await _channel.invokeMethod<void>('deleteGroup', {'groupId': groupId});
  }

  /// 加载模型组到内存。
  ///
  /// [preset] 为模型结构预设：`base`（默认，对应 firefox-translations 的
  /// base 模型）/ `tiny` / `nano`。
  static Future<void> loadModel({
    required String id,
    required String modelPath,
    required String vocabularyPath,
    String shortlistPath = '',
    String ssplitPath = '',
    String preset = 'base',
  }) async {
    await _channel.invokeMethod<void>('loadModel', {
      'id': id,
      'modelPath': modelPath,
      'vocabularyPath': vocabularyPath,
      'shortlistPath': shortlistPath,
      'ssplitPath': ssplitPath,
      'preset': preset,
    });
  }

  /// 用已加载的 [id] 模型组翻译 [text]。
  ///
  /// 失败抛 [PlatformException]，由调用方决定是否回落在线。
  static Future<String> translate({
    required String id,
    required String text,
  }) async {
    if (text.trim().isEmpty) return '';
    final result = await _channel.invokeMethod<String>(
      'translate',
      {'id': id, 'text': text},
    );
    return result ?? '';
  }

  /// 当前已加载在内存中的模型组 id。
  static Future<List<String>> loadedIds() async {
    final raw = await _channel.invokeMethod<String>('loadedIds');
    if (raw == null || raw.isEmpty) return const [];
    return raw.split(',').where((s) => s.isNotEmpty).toList();
  }

  /// 释放全部已加载模型，回收内存。
  static Future<void> unloadAll() async {
    await _channel.invokeMethod<void>('unloadAll');
  }

  /// 仅供测试：清掉可用性缓存，让下次查询重新走通道。
  static void resetCacheForTest() {
    _available = null;
    _reason = null;
  }
}
