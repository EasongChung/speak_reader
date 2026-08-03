package com.example.speak_reader

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File

class MainActivity : FlutterActivity() {
    // [v2.6.3] PDF 页面渲染通道: 供 OCR 补充识别把当前页渲染成 PNG
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
}
