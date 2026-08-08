package com.example.speak_reader

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import android.util.Log
import java.io.File

/**
 * [G4.3] 从外部存储导入 slimt 模型文件。
 *
 * ## 为什么必须复制而不能直接引用
 *
 * slimt 的 `Model` 构造走 mmap 读**真实文件路径**(`Io.hh:51 MmapFile`),
 * 不认 Android 的 `content://` URI。所以外部存储的模型无论用哪种权限方案,
 * 都必须先复制到 app 私有目录才能加载 —— 没有「引用直达」这条路。
 *
 * ## 为什么用 SAF 而不是 MediaStore 扫 Download
 *
 * `docs/13` §G4.3(2026-08-07 用户确认方案 1): SAF **零权限声明**, 用户通过
 * 系统目录选择器授权一次, 之后持久可读; 且 API 21+ 行为一致, 不必处理
 * 分区存储在 28 / 29+ / 31+ 的三套规则。MediaStore 方案在 API 28 上仍需
 * `READ_EXTERNAL_STORAGE` 运行时弹窗, 且要写两套代码路径。
 *
 * ## 模型组识别
 *
 * bergamot/firefox-translations 模型的命名形如:
 * ```
 *   model.zhen.intgemm.alphas.bin
 *   vocab.zhen.spm
 *   lex.50.50.zhen.s2t.bin
 * ```
 * 即三类文件靠中间的**语向片段**(zhen/enzh)关联。故以语向为组 id 聚合,
 * 而非按文件名前缀 —— 三个文件的前缀分别是 model/vocab/lex, 并不共享。
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
     */
    private class ModelGroup(val id: String) {
        var model: Pair<String, Uri>? = null
        var vocabulary: Pair<String, Uri>? = null
        var shortlist: Pair<String, Uri>? = null

        /** shortlist 是可选项, 模型与词表缺一不可。 */
        val isComplete: Boolean
            get() = model != null && vocabulary != null

        fun toMap(): Map<String, Any> = hashMapOf(
            "id" to id,
            "modelName" to (model?.first ?: ""),
            "vocabularyName" to (vocabulary?.first ?: ""),
            "shortlistName" to (shortlist?.first ?: ""),
            "hasShortlist" to (shortlist != null),
        )
    }

    /**
     * 扫描 [treeUri] 指向的目录, 返回其中成组的模型文件。
     *
     * 只扫一层, 不递归: 模型文件通常与下载位置同级平铺, 递归会在用户误选
     * 整个存储根目录时扫出成千上万个文件。
     *
     * 返回的每项含 id / 各文件名 / hasShortlist, 供 Dart 侧列表展示。
     */
    fun scan(context: Context, treeUri: Uri): List<Map<String, Any>> {
        val groups = LinkedHashMap<String, ModelGroup>()
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            treeUri,
            DocumentsContract.getTreeDocumentId(treeUri),
        )

        context.contentResolver.query(
            childrenUri,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
            ),
            null,
            null,
            null,
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                val documentId = cursor.getString(0) ?: continue
                val name = cursor.getString(1) ?: continue
                val mime = cursor.getString(2)
                if (mime == DocumentsContract.Document.MIME_TYPE_DIR) continue

                val kind = classify(name) ?: continue
                val pair = kind.second to
                    DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId)
                val group = groups.getOrPut(kind.second) { ModelGroup(kind.second) }
                // 同类文件重复出现时保留首个: 后者多为不同量化档的同名变体,
                // 静默覆盖会让用户不清楚实际加载的是哪个。
                when (kind.first) {
                    Kind.MODEL -> if (group.model == null) group.model = name to pair.second
                    Kind.VOCABULARY ->
                        if (group.vocabulary == null) group.vocabulary = name to pair.second
                    Kind.SHORTLIST ->
                        if (group.shortlist == null) group.shortlist = name to pair.second
                }
            }
        }

        val complete = groups.values.filter { it.isComplete }
        Log.i(TAG, "扫描到 ${groups.size} 组, 其中 ${complete.size} 组完整")
        return complete.map { it.toMap() }
    }

    /**
     * 把 [groupId] 对应的模型文件从 [treeUri] 复制进私有目录。
     *
     * 返回可直接传给 [SlimtBridge.load] 的真实路径; shortlist 缺失时为空串。
     * 已存在同名文件则跳过复制 —— 模型文件动辄数十 MB, 重复导入会明显卡顿。
     */
    fun import(context: Context, treeUri: Uri, groupId: String): Map<String, String> {
        val target = File(context.filesDir, "$MODELS_DIR/$groupId")
        if (!target.exists() && !target.mkdirs()) {
            throw IllegalStateException("无法创建模型目录: ${target.absolutePath}")
        }

        val result = hashMapOf("modelPath" to "", "vocabularyPath" to "", "shortlistPath" to "")
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            treeUri,
            DocumentsContract.getTreeDocumentId(treeUri),
        )

        context.contentResolver.query(
            childrenUri,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
            ),
            null,
            null,
            null,
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                val documentId = cursor.getString(0) ?: continue
                val name = cursor.getString(1) ?: continue
                if (cursor.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR) continue

                val kind = classify(name) ?: continue
                if (kind.second != groupId) continue

                val uri = DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId)
                val dest = File(target, name)
                val key = when (kind.first) {
                    Kind.MODEL -> "modelPath"
                    Kind.VOCABULARY -> "vocabularyPath"
                    Kind.SHORTLIST -> "shortlistPath"
                }
                // 已有同名文件且非空则复用。此处不做内容校验:
                // 模型文件的完整性由 slimt 加载时报错兜底, 逐字节比对
                // 数十 MB 的开销比重新复制还大。
                if (dest.exists() && dest.length() > 0L) {
                    if (result[key].isNullOrEmpty()) result[key] = dest.absolutePath
                    continue
                }
                copy(context, uri, dest)
                if (result[key].isNullOrEmpty()) result[key] = dest.absolutePath
            }
        }

        if (result["modelPath"].isNullOrEmpty() || result["vocabularyPath"].isNullOrEmpty()) {
            throw IllegalStateException("模型组 $groupId 缺少模型文件或词表")
        }
        Log.i(TAG, "模型组 $groupId 已导入至 ${target.absolutePath}")
        return result
    }

    /** 已导入到私有目录的模型组 id 列表。 */
    fun importedGroups(context: Context): List<String> {
        val root = File(context.filesDir, MODELS_DIR)
        val children = root.listFiles() ?: return emptyList()
        return children.filter { it.isDirectory }.map { it.name }.sorted()
    }

    /**
     * [G4.4] 取**已导入**模型组在私有目录中的真实路径。
     *
     * 与 [import] 的区别: 本方法不碰 SAF, 不需要 treeUri。已导入的文件就在
     * app 私有目录里, 加载时再要求用户重新授权目录是没有道理的 —— 授权可能
     * 早已被系统回收, 而文件仍然好好地在那儿。
     *
     * 文件名不做假设(不同语向的文件名不同), 仍走 [classify] 识别类别,
     * 与 [scan]/[import] 同源。目录不存在或缺必需文件时返回空 Map,
     * 由调用方判定 —— 这里不抛异常, 因为「没导入」是正常状态而非错误。
     */
    fun importedPaths(context: Context, groupId: String): Map<String, String> {
        val target = File(context.filesDir, "$MODELS_DIR/$groupId")
        val files = target.listFiles() ?: return emptyMap()

        val result = hashMapOf("modelPath" to "", "vocabularyPath" to "", "shortlistPath" to "")
        for (file in files) {
            if (!file.isFile || file.length() <= 0L) continue
            val kind = classify(file.name) ?: continue
            // 语向必须匹配: 私有目录理论上只有本组文件, 但导入中断等异常
            // 可能留下残片, 放行会让 slimt 加载到错误方向的权重。
            if (kind.second != groupId) continue
            val key = when (kind.first) {
                Kind.MODEL -> "modelPath"
                Kind.VOCABULARY -> "vocabularyPath"
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

    private fun copy(context: Context, source: Uri, dest: File) {
        val input = context.contentResolver.openInputStream(source)
            ?: throw IllegalStateException("无法读取: $source")
        input.use { ins ->
            dest.outputStream().use { outs -> ins.copyTo(outs, DEFAULT_BUFFER_SIZE) }
        }
    }

    private enum class Kind { MODEL, VOCABULARY, SHORTLIST }

    /**
     * 判定文件属于哪类模型文件, 并提取其语向片段作为组 id。
     *
     * 命名规则参照 bergamot/firefox-translations 发布物, 与 G4.1 实测所用
     * 一致(见 `13` §8.1):
     * ```
     *   model.zhen.intgemm.alphas.bin  -> MODEL,      id=zhen
     *   vocab.zhen.spm                 -> VOCABULARY, id=zhen
     *   lex.50.50.zhen.s2t.bin         -> SHORTLIST,  id=zhen
     * ```
     * 无法归类或取不到语向时返回 null(调用方跳过该文件)。
     */
    private fun classify(name: String): Pair<Kind, String>? {
        val lower = name.lowercase()
        // .gz 未解压的不收: slimt 的 mmap 读不了压缩流, 收进来只会在
        // 加载时才失败, 不如扫描阶段就排除。
        if (lower.endsWith(".gz")) return null

        val kind = when {
            lower.startsWith("model.") && lower.endsWith(".bin") -> Kind.MODEL
            lower.startsWith("vocab") && lower.endsWith(".spm") -> Kind.VOCABULARY
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
