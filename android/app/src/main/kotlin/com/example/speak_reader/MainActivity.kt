package com.example.speak_reader

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import com.tom_roush.pdfbox.pdmodel.PDDocument
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File

class MainActivity : FlutterActivity() {
    // [v2.6.3] PDF 页面渲染通道: 供 OCR 补充识别把当前页渲染成 PNG
    // [G1] 复用同一通道新增字符坐标提取与描框校验
    private val pdfRenderChannel = "com.example.speak_reader/pdf_render"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
                        if (path.isNullOrEmpty()) {
                            result.error("bad_args", "path is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val png = debugAnnotatePage(path, pageIndex, scale.toFloat())
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
     *   "chars":      [{"c":String,"x":Double,"y":Double,"w":Double,"h":Double}, ...]
     * }
     * ```
     *
     * 坐标未做 CropBox 平移与旋转补偿, 原样上报, 由 Gate 1 实测确定映射公式,
     * 避免在未验证前把猜测写死在原生侧。
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
     * 目的是一眼看出坐标是否贴合文字, 从而在 Gate 2 之前独立验证坐标正确性,
     * 不依赖任何 Flutter 侧叠加层。仅供开发校验入口调用, 不参与正式功能。
     */
    private fun debugAnnotatePage(path: String, pageIndex: Int, scale: Float): ByteArray? {
        val file = File(path)
        if (!file.exists()) return null
        val data = extractTextPositions(path, pageIndex) ?: return null

        @Suppress("UNCHECKED_CAST")
        val chars = data["chars"] as List<Map<String, Any>>
        val pageHeight = (data["pageHeight"] as Double).toFloat()
        val cropX = (data["cropX"] as Double).toFloat()
        val cropY = (data["cropY"] as Double).toFloat()

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

                // PdfRenderer 按 CropBox 出图, page.width/height 单位即 PDF 点,
                // 故位图像素 = (PDF 点 - CropBox 原点) * 像素缩放比。
                val sx = width.toFloat() / page.width
                val sy = height.toFloat() / page.height

                val canvas = Canvas(bitmap)
                val boxPaint = Paint().apply {
                    style = Paint.Style.STROKE
                    strokeWidth = 1f
                    color = Color.RED
                    isAntiAlias = true
                }
                for (c in chars) {
                    val x = (c["x"] as Double).toFloat() - cropX
                    val y = (c["y"] as Double).toFloat() - cropY
                    val w = (c["w"] as Double).toFloat()
                    val h = (c["h"] as Double).toFloat()
                    // yDirAdj 为字形下沿, 上沿 = y - h
                    canvas.drawRect(x * sx, (y - h) * sy, (x + w) * sx, y * sy, boxPaint)
                }

                // 左上角打印页面几何元信息, 便于一次实测钉死映射公式
                val textPaint = Paint().apply {
                    color = Color.BLUE
                    textSize = 11f * scale
                    isAntiAlias = true
                }
                val info = "chars=${chars.size} render=${page.width}x${page.height} " +
                    "crop=($cropX,$cropY) h=$pageHeight rot=${data["rotation"]}"
                canvas.drawText(info, 4f * scale, 14f * scale, textPaint)

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
}
