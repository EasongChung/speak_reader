package com.example.speak_reader

import android.content.Context
import android.net.Uri
import android.util.Log
import java.io.BufferedInputStream
import java.io.File
import java.util.zip.ZipInputStream

/**
 * `G4.3` 从外部存储导入 slimt 模型文件。
 *
 * ## 为什么必须复制而不能直接引用
 *
 * slimt 的 `Model` 构造走 mmap 读**真实文件路径**(`Io.hh:51 MmapFile`),
 * 不认 Android 的 `content://` URI。所以外部存储的模型无论用哪种权限方案,
 * 都必须先复制到 app 私有目录才能加载 —— 没有「引用直达」这条路。
 *
 * ## 为什么用 SAF 文件选择器选 zip
 *
 * `docs/13` §G4.3(2026-08-07 用户确认方案 1): SAF **零权限声明**, 且 API 21+
 * 行为一致, 不必处理分区存储在 28 / 29+ / 31+ 的三套规则。MediaStore 方案
 * 在 API 28 上仍需 `READ_EXTERNAL_STORAGE` 运行时弹窗, 且要写两套代码路径。
 *
 * 分发形态是**按语向分别打包**的 zip(见 `models/firefox-translations` 目录的
 * MANIFEST.json): 用户下载所需语向的 zip 后, 在此经系统文件选择器选中,
 * [importZip] 解压并把文件按语向归类到私有目录。zip 是一次性读取,
 * 不需要 `takePersistableUriPermission`。
 *
 * ## 模型组识别
 *
 * bergamot/firefox-translations 模型的命名形如:
 * ```
 *   model.zhen.intgemm.alphas.bin
 *   vocab.zhen.spm
 *   lex.50.50.zhen.s2t.bin
 * ```
 * 即三类文件靠中间的**语向片段**关联。故以语向为组 id 聚合,
 * 而非按文件名前缀 —— 三个文件的前缀分别是 model/vocab/lex, 并不共享。
 *
 * 部分语向是**双词表档**(如 en-zh 的 cjk_split_vocab), 词表拆成两个文件:
 * ```
 *   srcvocab.enzh.spm    源侧: 文本 -> id
 *   trgvocab.enzh.spm    目标侧: 生成的 id -> 文本
 * ```
 * 两表共享同一张 Wemb 却是不同 id 空间, 不可互换(详见 [classify])。
 */
object ModelImporter {
    private const val TAG = "ModelImporter"

    /** 私有目录下存放已导入模型的子目录名。 */
    private const val MODELS_DIR = "offline_models"

    /**
     * 一组可加载的模型文件。
     *
     * 刻意用 Map 而非 data class 跨 MethodChannel 传递: Flutter 的
     * StandardMessageCodec 只认基本类型与集合, 且 data class 在 release
     * 构建下有被 Proguard 裁剪的风险(docs/13 §G4.3 记录的坑)。
     *
     * [model]/[vocabulary]/[shortlist] 存 (文件名, 私有目录绝对路径)。
     */
    private class ModelGroup(val id: String) {
        var model: Pair<String, String>? = null
        var vocabulary: Pair<String, String>? = null
        var targetVocabulary: Pair<String, String>? = null
        var shortlist: Pair<String, String>? = null

        /**
         * shortlist 与目标侧词表都是可选项, 模型与源侧词表缺一不可。
         *
         * [targetVocabulary] 不计入: 单词表档(如 zh-en)本就没有它,
         * 计入会把这类模型误判为不完整。
         */
        val isComplete: Boolean
            get() = model != null && vocabulary != null

        fun toMap(): Map<String, Any> = hashMapOf(
            "id" to id,
            "modelName" to (model?.first ?: ""),
            "vocabularyName" to (vocabulary?.first ?: ""),
            "targetVocabularyName" to (targetVocabulary?.first ?: ""),
            "shortlistName" to (shortlist?.first ?: ""),
            "hasShortlist" to (shortlist != null),
            "hasTargetVocabulary" to (targetVocabulary != null),
        )
    }

    /**
     * 从 zip 模型包解压并导入模型组。
     *
     * zip 是**按语向分别打包**的(见 MANIFEST.json): 每个 zip 内含一个语向的
     * 三件套(model/vocab/lex, 可能带该语向的子目录)。本方法遍历 zip 条目,
     * 跳过目录与 `.gz`, 用 [classify] 按文件名识别类别与语向, 写入私有目录
     * `offline_models/<groupId>/`。
     *
     * 返回已导入的组列表(每项含 id / 各文件名 / hasShortlist), 供 Dart 侧
     * 展示; 空 zip 或无可识别文件时返回空列表, 由调用方判定。
     */
    fun importZip(context: Context, zipUri: Uri): List<Map<String, Any>> {
        val groups = LinkedHashMap<String, ModelGroup>()

        val input = context.contentResolver.openInputStream(zipUri)
            ?: throw IllegalStateException("无法读取: $zipUri")
        input.use { ins ->
            ZipInputStream(BufferedInputStream(ins)).use { zis ->
                var entry = zis.nextEntry
                while (entry != null) {
                    val name = entry.name
                    if (!entry.isDirectory) {
                        // zip 内文件名可能带语向子目录前缀(如 en-zh/…), 取 basename 再分类
                        val base = name.substringAfterLast('/')
                        val kind = classify(base)
                        if (kind != null) {
                            val group = groups.getOrPut(kind.second) { ModelGroup(kind.second) }
                            val dest = File(
                                context.filesDir, "$MODELS_DIR/${kind.second}/$base",
                            )
                            writeEntry(zis, dest)
                            when (kind.first) {
                                Kind.MODEL ->
                                    if (group.model == null) group.model = base to dest.absolutePath
                                Kind.VOCABULARY ->
                                    if (group.vocabulary == null)
                                        group.vocabulary = base to dest.absolutePath
                                Kind.TARGET_VOCABULARY ->
                                    if (group.targetVocabulary == null)
                                        group.targetVocabulary = base to dest.absolutePath
                                Kind.SHORTLIST ->
                                    if (group.shortlist == null)
                                        group.shortlist = base to dest.absolutePath
                            }
                        }
                    }
                    entry = zis.nextEntry
                }
            }
        }

        val complete = groups.values.filter { it.isComplete }
        Log.i(TAG, "zip 内识别 ${groups.size} 组, 其中 ${complete.size} 组完整")
        return complete.map { it.toMap() }
    }

    /** 把 zip 流的当前条目写入 [dest]; 已存在同名非空文件则跳过。 */
    private fun writeEntry(zis: ZipInputStream, dest: File) {
        if (dest.exists() && dest.length() > 0L) return  // 复用既有文件
        val parent = dest.parentFile
        if (parent != null && !parent.exists()) parent.mkdirs()
        dest.outputStream().use { outs -> zis.copyTo(outs) }
    }

    /** 已导入到私有目录的模型组 id 列表。 */
    fun importedGroups(context: Context): List<String> {
        val root = File(context.filesDir, MODELS_DIR)
        val children = root.listFiles() ?: return emptyList()
        return children.filter { it.isDirectory }.map { it.name }.sorted()
    }

    /**
     * `G4.4` 取**已导入**模型组在私有目录中的真实路径。
     *
     * 不碰 SAF: 已导入的文件就在 app 私有目录里, 加载时再要求用户重新授权
     * 是没有道理的 —— 授权可能早已被系统回收, 而文件仍然好好地在那儿。
     *
     * 文件名不做假设(不同语向的文件名不同), 仍走 [classify] 识别类别,
     * 与 [importZip] 同源。目录不存在或缺必需文件时返回空 Map,
     * 由调用方判定 —— 这里不抛异常, 因为「没导入」是正常状态而非错误。
     *
     * 返回键: modelPath / vocabularyPath / shortlistPath / targetVocabularyPath。
     * 后两者可为空串(分别对应无 shortlist、单词表档)。
     */
    fun importedPaths(context: Context, groupId: String): Map<String, String> {
        val target = File(context.filesDir, "$MODELS_DIR/$groupId")
        val files = target.listFiles() ?: return emptyMap()

        val result = hashMapOf(
            "modelPath" to "",
            "vocabularyPath" to "",
            "shortlistPath" to "",
            "targetVocabularyPath" to "",
        )
        for (file in files) {
            if (!file.isFile || file.length() <= 0L) continue
            val kind = classify(file.name) ?: continue
            // 语向必须匹配: 私有目录理论上只有本组文件, 但导入中断等异常
            // 可能留下残片, 放行会让 slimt 加载到错误方向的权重。
            if (kind.second != groupId) continue
            val key = when (kind.first) {
                Kind.MODEL -> "modelPath"
                Kind.VOCABULARY -> "vocabularyPath"
                Kind.TARGET_VOCABULARY -> "targetVocabularyPath"
                Kind.SHORTLIST -> "shortlistPath"
            }
            if (result[key].isNullOrEmpty()) result[key] = file.absolutePath
        }

        if (result["modelPath"].isNullOrEmpty() || result["vocabularyPath"].isNullOrEmpty()) {
            return emptyMap()
        }
        return result
    }

    /** 删除已导入的模型组; 不存在时静默返回。 */
    fun deleteGroup(context: Context, groupId: String) {
        val target = File(context.filesDir, "$MODELS_DIR/$groupId")
        if (target.exists()) {
            target.deleteRecursively()
            Log.i(TAG, "已删除模型组 $groupId")
        }
    }

    private enum class Kind { MODEL, VOCABULARY, TARGET_VOCABULARY, SHORTLIST }

    /**
     * 判定文件属于哪类模型文件, 并提取其语向片段作为组 id。
     *
     * 命名规则参照 bergamot/firefox-translations 发布物, 与 G4.1 实测所用
     * 一致(见 `13` §8.1):
     * ```
     *   model.zhen.intgemm.alphas.bin  -> MODEL,             id=zhen
     *   vocab.zhen.spm                 -> VOCABULARY,        id=zhen  (单词表档)
     *   srcvocab.enzh.spm              -> VOCABULARY,        id=enzh  (双词表档源侧)
     *   trgvocab.enzh.spm              -> TARGET_VOCABULARY, id=enzh  (双词表档目标侧)
     *   lex.50.50.zhen.s2t.bin         -> SHORTLIST,         id=zhen
     * ```
     * 无法归类或取不到语向时返回 null(调用方跳过该文件)。
     *
     * ⚠️ 判定顺序不可调换: `trgvocab` 必须在通用 `vocab` 之前判。二者都以
     * `vocab` 结尾于同一位置, 若先匹配通用分支, 目标侧词表会被误判为源侧 ——
     * 而两表的 id 空间只有 0.82% 重合(见 MANIFEST 的 vocab_layout_note),
     * **传反不会报错, 只会输出乱码**, 属于最难查的一类故障。
     */
    private fun classify(name: String): Pair<Kind, String>? {
        val lower = name.lowercase()
        // .gz 未解压的不收: slimt 的 mmap 读不了压缩流, 收进来只会在
        // 加载时才失败, 不如扫描阶段就排除。
        if (lower.endsWith(".gz")) return null

        val kind = when {
            lower.startsWith("model.") && lower.endsWith(".bin") -> Kind.MODEL
            // 目标侧先判, 见上方注释。
            lower.startsWith("trgvocab") && lower.endsWith(".spm") ->
                Kind.TARGET_VOCABULARY
            // 源侧: 双词表档的 srcvocab 与单词表档的 vocab 同归此类 ——
            // slimt 的 vocabulary_path 恒为源侧, 单词表档留空 target 即
            // 退化为两侧共用, 与改造前行为一致。
            (lower.startsWith("srcvocab") || lower.startsWith("vocab")) &&
                lower.endsWith(".spm") -> Kind.VOCABULARY
            lower.startsWith("lex.") && lower.endsWith(".bin") -> Kind.SHORTLIST
            else -> return null
        }
        return extractPair(lower)?.let { kind to it }
    }

    /**
     * 从文件名中取语向片段, 如 `zhen` / `enzh`。
     *
     * 判定口径: 用 `.` 切分后, 找**恰好 4 个字母**且能拆成两个已知语言码的段。
     * 不用「第二段」这类位置约定 —— lex 文件名里插了 `50.50` 两段数字,
     * 位置在三类文件间并不一致。
     */
    private fun extractPair(lowerName: String): String? =
        lowerName.split('.').firstOrNull { segment ->
            segment.length == 4 && segment.all { it in 'a'..'z' } &&
                KNOWN_LANGS.contains(segment.substring(0, 2)) &&
                KNOWN_LANGS.contains(segment.substring(2, 4))
        }

    /**
     * 已知语言码。仅用于从文件名中辨认语向片段, 不代表模型可用性 ——
     * 实际能否加载由 slimt 判定。
     *
     * 覆盖 firefox-translations 已发布的语向所涉语言; 遇到新语言码时,
     * 该模型组会被扫描阶段跳过, 补进本表即可。
     */
    private val KNOWN_LANGS = setOf(
        "en", "zh", "de", "fr", "es", "it", "pt", "ru", "ja", "ko",
        "cs", "pl", "nl", "sv", "da", "fi", "nb", "nn", "et", "lt",
        "lv", "bg", "uk", "hu", "ro", "sk", "sl", "el", "tr", "ar",
        "fa", "he", "hi", "id", "vi", "th", "ca", "gl", "eu", "is",
        "mt", "ga", "cy", "sr", "hr", "bs", "mk", "sq", "be", "kk",
    )
}
