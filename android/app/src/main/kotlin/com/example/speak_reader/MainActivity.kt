package com.example.speak_reader

import android.app.Activity
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.Build
import android.os.ParcelFileDescriptor
import com.tom_roush.pdfbox.pdmodel.PDDocument
import io.endigo.plugins.pdfviewflutter.PDFViewFactory
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File

class MainActivity : FlutterActivity() {
    // [v2.6.3] PDF 页面渲染通道: 供 OCR 补充识别把当前页渲染成 PNG
    // [G1] 复用同一通道新增字符坐标提取与描框校验
    private val pdfRenderChannel = "com.example.speak_reader/pdf_render"

    // [G2] PDF 平台视图注册名, 与 lib/vendor/flutter_pdfview 中的 _kViewType 一致
    private val pdfViewType = "speak_reader/pdfview"

    // [G4.3] 离线翻译通道: 原生库可用性判定 + SAF 模型导入 + 翻译
    private val offlineTranslateChannel = "com.example.speak_reader/offline_translate"

    // [G4.3] SAF 模型包(zip)文件选择的请求码。用 onActivityResult 而非
    // ActivityResultContracts: FlutterActivity 不是 ComponentActivity 的子类,
    // 拿不到 registerForActivityResult。
    private val pickModelZipRequest = 0x51A1

    /** `G4.3` 文件选择结果回调; 选择器打开期间非 null。 */
    private var pendingZipResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // [G2] flutter_pdfview 已 vendoring 进本仓库并从 pubspec 移除, 其原有的
        // 插件自动注册(GeneratedPluginRegistrant)随之失效, 故在此手工注册平台视图。
        // 遗漏此处会导致 PDF 原文视图空白。
        flutterEngine.platformViewsController.registry.registerViewFactory(
            pdfViewType,
            PDFViewFactory(flutterEngine.dartExecutor.binaryMessenger),
        )
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, pdfRenderChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "renderPage" -> {
                        val path = call.argument<String>("path")
                        val pageIndex = call.argument<Int>("pageIndex") ?: 0
                        val scale = call.argument<Double>("scale") ?: 2.0
                        if (path.isNullOrEmpty()) {
                            result.error("bad_args", "path is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val png = renderPage(path, pageIndex, scale.toFloat())
                            if (png == null) {
                                result.error("no_page", "page index out of range", null)
                            } else {
                                result.success(png)
                            }
                        } catch (e: Exception) {
                            result.error("render_failed", e.message, null)
                        }
                    }
                    // [G1] 提取指定页的字符级坐标 + 页面几何元信息
                    "extractTextPositions" -> {
                        val path = call.argument<String>("path")
                        val pageIndex = call.argument<Int>("pageIndex") ?: 0
                        if (path.isNullOrEmpty()) {
                            result.error("bad_args", "path is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val data = extractTextPositions(path, pageIndex)
                            if (data == null) {
                                result.error("no_page", "page index out of range", null)
                            } else {
                                result.success(data)
                            }
                        } catch (e: Exception) {
                            result.error("extract_failed", e.message, null)
                        }
                    }
                    // [G1] 校验用: 在渲染图上描出字符框, 返回带框 PNG
                    "debugAnnotatePage" -> {
                        val path = call.argument<String>("path")
                        val pageIndex = call.argument<Int>("pageIndex") ?: 0
                        val scale = call.argument<Double>("scale") ?: 2.0
                        // 竖直范围方案: em(Gate 1 定论) / font / h(对照)
                        val mode = call.argument<String>("mode") ?: "em"
                        if (path.isNullOrEmpty()) {
                            result.error("bad_args", "path is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val png =
                                debugAnnotatePage(path, pageIndex, scale.toFloat(), mode)
                            if (png == null) {
                                result.error("no_page", "page index out of range", null)
                            } else {
                                result.success(png)
                            }
                        } catch (e: Exception) {
                            result.error("annotate_failed", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // [G4.3] 离线翻译通道。可用性判定在 SlimtBridge 内, 与 loadLibrary 同址。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, offlineTranslateChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // 双条件: SDK_INT >= 28 且 loadLibrary 成功。详见 SlimtBridge。
                    "isOfflineAvailable" -> result.success(SlimtBridge.isAvailable())

                    // 不可用原因, 供设置页副标题展示; 可用时为 null。
                    "unavailableReason" -> result.success(
                        if (SlimtBridge.isAvailable()) {
                            null
                        } else {
                            SlimtBridge.unavailableReason()
                                ?: "当前系统不支持离线翻译（需 Android 9 及以上）"
                        }
                    )

                    // 系统 API 级别, 供 UI 判断是否置灰开关。
                    "sdkInt" -> result.success(Build.VERSION.SDK_INT)

                    // 打开 SAF 文件选择器选模型包(zip)。结果经 onActivityResult 异步回传。
                    "pickModelZip" -> {
                        if (pendingZipResult != null) {
                            result.error("busy", "文件选择器已打开", null)
                            return@setMethodCallHandler
                        }
                        try {
                            pendingZipResult = result
                            startActivityForResult(
                                Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                                    addCategory(Intent.CATEGORY_OPENABLE)
                                    type = "application/zip"
                                },
                                pickModelZipRequest,
                            )
                        } catch (e: Exception) {
                            pendingZipResult = null
                            result.error("pick_failed", e.message, null)
                        }
                    }

                    // 解压 zip 模型包并导入私有目录, 返回已导入的组列表。
                    "importModelZip" -> {
                        val uriString = call.argument<String>("zipUri")
                        if (uriString.isNullOrEmpty()) {
                            result.error("bad_args", "zipUri 必填", null)
                            return@setMethodCallHandler
                        }
                        try {
                            result.success(
                                ModelImporter.importZip(this, Uri.parse(uriString))
                            )
                        } catch (e: Exception) {
                            result.error("import_failed", e.message, null)
                        }
                    }

                    "importedGroups" -> result.success(ModelImporter.importedGroups(this))

                    // [G4.4] 取已导入模型组的真实路径, 不需要 SAF 授权 ——
                    // 文件已在私有目录, 加载时再要求重新授权目录没有道理。
                    // 返回空 Map 表示未导入或文件不全, 由 Dart 侧判定。
                    "importedPaths" -> {
                        val groupId = call.argument<String>("groupId")
                        if (groupId.isNullOrEmpty()) {
                            result.error("bad_args", "groupId is required", null)
                            return@setMethodCallHandler
                        }
                        result.success(ModelImporter.importedPaths(this, groupId))
                    }

                    "deleteGroup" -> {
                        val groupId = call.argument<String>("groupId")
                        if (groupId.isNullOrEmpty()) {
                            result.error("bad_args", "groupId is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            // 先卸载再删文件: 反过来会让 mmap 指向已删除的 inode。
                            SlimtBridge.unload(groupId)
                            ModelImporter.deleteGroup(this, groupId)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("delete_failed", e.message, null)
                        }
                    }

                    "loadModel" -> {
                        val id = call.argument<String>("id")
                        val modelPath = call.argument<String>("modelPath")
                        val vocabularyPath = call.argument<String>("vocabularyPath")
                        val shortlistPath = call.argument<String>("shortlistPath") ?: ""
                        val ssplitPath = call.argument<String>("ssplitPath") ?: ""
                        val preset = call.argument<String>("preset") ?: "base"
                        if (id.isNullOrEmpty() || modelPath.isNullOrEmpty() ||
                            vocabularyPath.isNullOrEmpty()
                        ) {
                            result.error("bad_args", "id/modelPath/vocabularyPath 均必填", null)
                            return@setMethodCallHandler
                        }
                        if (!SlimtBridge.isAvailable()) {
                            result.error("unavailable", "离线翻译不可用", null)
                            return@setMethodCallHandler
                        }
                        try {
                            SlimtBridge.load(
                                id, modelPath, vocabularyPath,
                                shortlistPath, ssplitPath, preset,
                            )
                            result.success(null)
                        } catch (e: Throwable) {
                            result.error("load_failed", e.message, null)
                        }
                    }

                    "translate" -> {
                        val id = call.argument<String>("id")
                        val text = call.argument<String>("text")
                        if (id.isNullOrEmpty() || text == null) {
                            result.error("bad_args", "id 与 text 均必填", null)
                            return@setMethodCallHandler
                        }
                        if (!SlimtBridge.isAvailable()) {
                            result.error("unavailable", "离线翻译不可用", null)
                            return@setMethodCallHandler
                        }
                        try {
                            result.success(SlimtBridge.translate(id, text))
                        } catch (e: Throwable) {
                            // Throwable 而非 Exception: JNI 抛的 UnsatisfiedLinkError
                            // 是 Error 不是 Exception, 漏了会直接崩掉进程。
                            result.error("translate_failed", e.message, null)
                        }
                    }

                    "loadedIds" -> result.success(
                        if (SlimtBridge.isAvailable()) SlimtBridge.loadedIds() else ""
                    )

                    "unloadAll" -> {
                        if (SlimtBridge.isAvailable()) SlimtBridge.unloadAll()
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }
    }

    /**
     * `G4.3` 接收 SAF 模型包(zip)文件选择结果。
     *
     * zip 是一次性读取(解压后即复制进私有目录), 不需要
     * `takePersistableUriPermission` —— 持久授权只对目录场景有意义,
     * 文件场景授权随调用结束即失效, 不持久反而更安全。
     */
    @Deprecated("FlutterActivity 非 ComponentActivity, 无法用 ActivityResultContracts")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != pickModelZipRequest) return

        val callback = pendingZipResult ?: return
        pendingZipResult = null

        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            // 用户取消不是错误, 返回 null 让 Dart 侧安静收场。
            callback.success(null)
            return
        }
        callback.success(uri.toString())
    }

    /// 用系统 PdfRenderer 把指定页渲染成 PNG 字节流; 页不存在返回 null。
    private fun renderPage(path: String, pageIndex: Int, scale: Float): ByteArray? {
        val file = File(path)
        if (!file.exists()) return null
        val fd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
        val renderer = PdfRenderer(fd)
        try {
            if (pageIndex < 0 || pageIndex >= renderer.pageCount) return null
            val page = renderer.openPage(pageIndex)
            try {
                val width = (page.width * scale).toInt().coerceAtLeast(1)
                val height = (page.height * scale).toInt().coerceAtLeast(1)
                val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                // 白底(扫描件/透明背景页面统一渲染为白底, 便于视觉模型识别)
                bitmap.eraseColor(Color.WHITE)
                page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                val out = ByteArrayOutputStream()
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
                bitmap.recycle()
                return out.toByteArray()
            } finally {
                page.close()
            }
        } finally {
            renderer.close()
            fd.close()
        }
    }

    /**
     * [G1] 用 PDFBox 提取指定页的字符级坐标。
     *
     * 返回结构(页不存在返回 null):
     * ```
     * {
     *   "pageWidth":  Double,  // CropBox 宽(PDF 点)
     *   "pageHeight": Double,  // CropBox 高(PDF 点)
     *   "cropX":      Double,  // CropBox 左下角 x(MediaBox 坐标系)
     *   "cropY":      Double,  // CropBox 左下角 y
     *   "rotation":   Int,     // 页面旋转角(0/90/180/270)
     *   "chars": [
     *     {
     *       "c": String,   // 字符
     *       "x": Double,   // 左边界(显示空间)
     *       "y": Double,   // 基线(top-down)
     *       "w": Double,   // 前进宽度
     *       "h": Double,   // getHeightDir(), 仅作对照
     *       "fs":   Double, // 有效字号
     *       "asc":  Double, // 字体 ascent(已缩放, 正值)
     *       "desc": Double, // 字体 descent(已缩放, 负值)
     *     }, ...
     *   ]
     * }
     * ```
     *
     * 竖直范围以 `top = y - asc`、`bottom = y - desc` 计算。Gate 1 首轮实测
     * 已确认 `h`(getHeightDir) 只适配拉丁大写字母, 中文会被截断, 详见
     * [CharBoxStripper] 的类注释。
     */
    private fun extractTextPositions(path: String, pageIndex: Int): Map<String, Any>? {
        val file = File(path)
        if (!file.exists()) return null
        // PDFBoxResourceLoader 已由 flutter_pdf_text 插件在引擎附着时初始化
        val doc = PDDocument.load(file)
        try {
            if (pageIndex < 0 || pageIndex >= doc.numberOfPages) return null
            val page = doc.getPage(pageIndex)
            val cropBox = page.cropBox

            val stripper = CharBoxStripper()
            // PDFTextStripper 页号从 1 开始
            stripper.startPage = pageIndex + 1
            stripper.endPage = pageIndex + 1
            stripper.getText(doc) // 触发 writeString 回调收集坐标

            val chars = ArrayList<Map<String, Any>>(stripper.boxes.size)
            for (b in stripper.boxes) {
                chars.add(
                    hashMapOf(
                        "c" to b.ch,
                        "x" to b.x.toDouble(),
                        "y" to b.y.toDouble(),
                        "w" to b.w.toDouble(),
                        "h" to b.h.toDouble(),
                        "fs" to b.fs.toDouble(),
                        "asc" to b.asc.toDouble(),
                        "desc" to b.desc.toDouble(),
                    )
                )
            }
            return hashMapOf(
                "pageWidth" to cropBox.width.toDouble(),
                "pageHeight" to cropBox.height.toDouble(),
                "cropX" to cropBox.lowerLeftX.toDouble(),
                "cropY" to cropBox.lowerLeftY.toDouble(),
                "rotation" to page.rotation,
                "chars" to chars,
            )
        } finally {
            doc.close()
        }
    }

    /**
     * [G1] 校验用: 把 PDFBox 字符框描到系统渲染图上, 返回带框 PNG。
     *
     * [mode] 决定竖直范围的取法, 三套方案同图对照:
     * - `"em"`   品红: 固定 em 框, 上 0.88 / 下 0.12 —— **Gate 1 定论, 默认**
     * - `"font"` 绿: `top = y - asc`, `bottom = y - desc` —— 字体度量, 随字体跳变
     * - `"h"`    红: `top = y - h`, `bottom = y` —— 首轮方案, 实测仅 0.5 em
     *
     * 保留三套是为了换文档复验时仍能横向对照, 仅供开发校验入口调用。
     */
    private fun debugAnnotatePage(
        path: String,
        pageIndex: Int,
        scale: Float,
        mode: String,
    ): ByteArray? {
        val file = File(path)
        if (!file.exists()) return null
        val data = extractTextPositions(path, pageIndex) ?: return null

        @Suppress("UNCHECKED_CAST")
        val chars = data["chars"] as List<Map<String, Any>>

        val fd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
        val renderer = PdfRenderer(fd)
        try {
            if (pageIndex < 0 || pageIndex >= renderer.pageCount) return null
            val page = renderer.openPage(pageIndex)
            try {
                val width = (page.width * scale).toInt().coerceAtLeast(1)
                val height = (page.height * scale).toInt().coerceAtLeast(1)
                val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                bitmap.eraseColor(Color.WHITE)
                page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)

                // PdfRenderer 与 PDFBox 都以 CropBox 左上角为原点出图(PDFBox 的
                // LegacyPDFStreamEngine 已在内部完成 CropBox 平移), 故此处不再
                // 二次减去 cropX/cropY —— 首轮实测 crop=(0,0) 掩盖了该问题,
                // 待非零 CropBox 的 PDF 复验。
                val sx = width.toFloat() / page.width
                val sy = height.toFloat() / page.height

                val canvas = Canvas(bitmap)
                val boxPaint = Paint().apply {
                    style = Paint.Style.STROKE
                    strokeWidth = 1f
                    isAntiAlias = true
                    color = when (mode) {
                        "h" -> Color.RED
                        "em" -> Color.MAGENTA
                        else -> Color.rgb(0, 160, 0)
                    }
                }
                for (c in chars) {
                    val x = (c["x"] as Double).toFloat()
                    val y = (c["y"] as Double).toFloat()
                    val w = (c["w"] as Double).toFloat()
                    val fs = (c["fs"] as Double).toFloat()
                    val top: Float
                    val bottom: Float
                    when (mode) {
                        // y 为基线, h 为 getHeightDir(): 拉丁大写高
                        "h" -> {
                            top = y - (c["h"] as Double).toFloat()
                            bottom = y
                        }
                        // CJK/拉丁通用 em 框(Gate 1 定论), 比例见 CharBox
                        "em" -> {
                            top = y - CharBox.ASCENT_EM * fs
                            bottom = y + CharBox.DESCENT_EM * fs
                        }
                        // 字体度量: desc 为负值, 故 bottom = y - desc 在基线之下
                        else -> {
                            top = y - (c["asc"] as Double).toFloat()
                            bottom = y - (c["desc"] as Double).toFloat()
                        }
                    }
                    canvas.drawRect(x * sx, top * sy, (x + w) * sx, bottom * sy, boxPaint)
                }

                // 左上角打印页面几何 + 首个字符的原始度量, 便于按数字反推
                val textPaint = Paint().apply {
                    color = Color.BLUE
                    textSize = 10f * scale
                    isAntiAlias = true
                }
                val head = "mode=$mode chars=${chars.size} render=${page.width}x${page.height} " +
                    "crop=(${data["cropX"]},${data["cropY"]}) rot=${data["rotation"]}"
                canvas.drawText(head, 4f * scale, 12f * scale, textPaint)
                val f = chars.firstOrNull()
                if (f != null) {
                    val detail = "c='${f["c"]}' y=${fmt(f["y"])} h=${fmt(f["h"])} " +
                        "fs=${fmt(f["fs"])} asc=${fmt(f["asc"])} desc=${fmt(f["desc"])}"
                    canvas.drawText(detail, 4f * scale, 24f * scale, textPaint)
                }

                val out = ByteArrayOutputStream()
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
                bitmap.recycle()
                return out.toByteArray()
            } finally {
                page.close()
            }
        } finally {
            renderer.close()
            fd.close()
        }
    }

    /** [G1] 校验图上的数值保留两位小数, 避免 Double 默认输出过长 */
    private fun fmt(v: Any?): String =
        if (v is Double) String.format("%.2f", v) else "$v"
}
