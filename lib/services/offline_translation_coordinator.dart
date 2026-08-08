import 'offline_translation_service.dart';

/// [G4.4] 一次离线翻译的结果（含耗时，供真机评测读数）。
class OfflineTranslateOutcome {
  const OfflineTranslateOutcome({
    required this.text,
    required this.elapsed,
    required this.groupId,
  });

  final String text;
  final Duration elapsed;

  /// 实际使用的模型组，如 `zhen`。
  final String groupId;
}

/// [G4.4] 离线翻译协调器：语向判定 → 惰性加载 → 翻译计时。
///
/// ## 为什么单独一层
///
/// 语向判定与「模型是否已加载」这两件事，设置页（试译）与阅读页（正式翻译）
/// 都要用。若各写一份，就是本项目已栽过两次的「同一约定的两个消费者只改一侧」
/// （见 `docs/08` 通用教训 1）。故收敛到这里，两边只调 [translate]。
///
/// ## 失败语义
///
/// 本层**不吞异常**：加载失败、推理失败一律上抛，由调用方决定是否回落在线。
/// PoC 阶段离线通道的错误必须可见 —— 静默回落会让「离线根本没跑起来」
/// 伪装成「离线跑了但质量一般」，这两者的排查方向完全相反。
///
/// 唯一的「软失败」是 [resolveGroupId] 返回 null（没有对应语向的模型），
/// 那不是错误，是本就没装那个方向的模型。
class OfflineTranslationCoordinator {
  OfflineTranslationCoordinator._();

  static final OfflineTranslationCoordinator instance =
      OfflineTranslationCoordinator._();

  /// 本进程内已调用过 `loadModel` 的组 id。
  ///
  /// 原生侧 `loadedIds()` 才是权威，这里只是避免每次翻译都跨通道查询。
  /// 两者不一致时以原生侧为准 —— [_ensureLoaded] 会在首次使用前对齐一次。
  final Set<String> _loaded = <String>{};

  /// 是否已与原生侧对齐过已加载列表。
  bool _synced = false;

  /// 判定文本的翻译方向，返回模型组 id（如 `zhen`）；没有可用模型时返回 null。
  ///
  /// 判定规则刻意简单：**含 CJK 字符即视作中文源**，否则视作英文源。
  /// 不做语种概率模型 —— PoC 只有 zh↔en 两个方向，复杂判定的收益为零，
  /// 而误判的代价（读者立刻看到方向反了的译文）是显性的、可自查的。
  ///
  /// [availableGroups] 是已导入的组 id 列表（来自 `importedGroups()`）。
  static String? resolveGroupId(String text, List<String> availableGroups) {
    if (text.trim().isEmpty) return null;
    final wanted = _hasCjk(text) ? 'zhen' : 'enzh';
    return availableGroups.contains(wanted) ? wanted : null;
  }

  /// 是否含中日韩统一表意文字。
  ///
  /// 只查基本区 U+4E00–U+9FFF 与扩展 A 区 U+3400–U+4DBF：覆盖现代汉语常用字。
  /// 不含假名/谚文 —— 本 PoC 无日韩模型，把它们判成中文只会选错模型。
  static bool _hasCjk(String text) {
    for (final rune in text.runes) {
      if ((rune >= 0x4E00 && rune <= 0x9FFF) ||
          (rune >= 0x3400 && rune <= 0x4DBF)) {
        return true;
      }
    }
    return false;
  }

  /// 确保 [groupId] 已加载进原生内存；已加载则直接返回。
  ///
  /// 首次调用会先向原生侧同步一次已加载列表 —— 热重载或本类被重建时，
  /// 原生侧的模型仍在内存里，重复 load 会白白多耗一份内存。
  Future<void> _ensureLoaded(String groupId) async {
    if (!_synced) {
      _loaded
        ..clear()
        ..addAll(await OfflineTranslationService.loadedIds());
      _synced = true;
    }
    if (_loaded.contains(groupId)) return;

    // 导入过的模型在 app 私有目录里，走 importedPaths 直接取真实路径。
    // 刻意不重新导入 —— 加载已导入的模型不该依赖用户再次选择 zip。
    final paths = await OfflineTranslationService.importedPaths(groupId);
    final modelPath = paths['modelPath'] ?? '';
    final vocabularyPath = paths['vocabularyPath'] ?? '';
    if (modelPath.isEmpty || vocabularyPath.isEmpty) {
      throw StateError('模型组 $groupId 文件不完整，请重新导入');
    }
    await OfflineTranslationService.loadModel(
      id: groupId,
      modelPath: modelPath,
      vocabularyPath: vocabularyPath,
      shortlistPath: paths['shortlistPath'] ?? '',
      // 单词表档为空串，原生侧据此退化为两侧共用源词表。
      targetVocabularyPath: paths['targetVocabularyPath'] ?? '',
    );
    _loaded.add(groupId);
  }

  /// 离线通道是否具备工作条件：原生库可用**且**至少导入了一组模型。
  ///
  /// 与 `OfflineTranslationService.isAvailable()` 的区别：那个只答「库能不能
  /// 加载」，答 true 时仍可能一个模型都没有。调用方要判的是「能不能翻」，
  /// 少了模型这一半就会走进「加载了个寂寞」的分支。
  Future<bool> isUsable() async {
    if (!await OfflineTranslationService.isAvailable()) return false;
    final groups = await OfflineTranslationService.importedGroups();
    return groups.isNotEmpty;
  }

  /// 离线翻译 [text]，自动判定方向并按需加载模型。
  ///
  /// 返回 null 表示「没有对应语向的模型」，调用方应回落在线。
  /// 其余失败（加载失败、推理失败）一律抛出。
  Future<OfflineTranslateOutcome?> translate(String text) async {
    if (!await OfflineTranslationService.isAvailable()) return null;

    final groups = await OfflineTranslationService.importedGroups();
    final groupId = resolveGroupId(text, groups);
    if (groupId == null) return null;

    await _ensureLoaded(groupId);

    final sw = Stopwatch()..start();
    final result = await OfflineTranslationService.translate(
      id: groupId,
      text: text,
    );
    sw.stop();
    return OfflineTranslateOutcome(
      text: result,
      elapsed: sw.elapsed,
      groupId: groupId,
    );
  }

  /// 释放全部模型并清空本地缓存（设置页删除模型组后调用）。
  Future<void> unloadAll() async {
    await OfflineTranslationService.unloadAll();
    _loaded.clear();
    _synced = false;
  }

  /// 丢弃对已加载列表的记忆，下次翻译重新与原生侧对齐。
  ///
  /// 删除单个模型组后调用 —— 原生侧 `deleteGroup` 会先卸载再删文件，
  /// 本地若继续记着它「已加载」，下次翻译就会跳过加载直接翻，必然失败。
  void invalidate() {
    _loaded.clear();
    _synced = false;
  }
}
