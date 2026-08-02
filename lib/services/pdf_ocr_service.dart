import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:pdf_render/pdf_render.dart';

import 'llama_cpp_engine.dart';

/// [v2.5.0] 单页 OCR 实际使用的通道。
enum OcrChannel {
  online('在线'),
  offline('离线'),
  failed('失败');

  const OcrChannel(this.label);
  final String label;
}

/// [v2.5.0] 扫描版 PDF 逐页 OCR 结果。
class PdfOcrResult {
  const PdfOcrResult({
    required this.text,
    required this.totalPages,
    required this.recognizedPages,
    required this.failedPages,
    required this.cancelled,
    this.pages, // [v2.5.1]
  });

  /// 合并后的全文(按页面顺序拼接)。
  final String text;

  final int totalPages;

  /// 成功识别页数(含断点续批的已识别页)。
  final int recognizedPages;

  /// 失败/空结果被跳过的页数。
  final int failedPages;

  /// 用户取消(中断)时为 true, 已识别结果已落盘, 可再次导入续批。
  final bool cancelled;

  /// [v2.5.1] 按页文本(索引=页码-1, 识别失败/空的页为空字符串), 供阅读页按页显示。
  final List<String>? pages;
}

/// [v2.5.0] 扫描版 PDF(无文本层)逐页渲染 + OCR 批处理。
///
/// 通道与节流策略(2026-08-01 决策):
/// - **在线优先**: 每页优先提交 [onlineOcr](在线视觉模型), 失败/未配置才用
///   [offlineEngine](多模态 GGUF) 兜底该页
/// - **按页提交**: 逐页串行(在途请求恒为 1), 每 [windowSize](默认 3) 页一个
///   节流检查点, 避免短时间大量提交触发 API 限速 / 本地模型连续推理卡顿
/// - **在线降级**: 在线连续失败 >= [onlineFailLimit](默认 3) 次 → 后续页直接
///   走离线, 减少无效请求
/// - **缓存策略**: 每成功一页即写入 checkpoint(`{cacheDir}/ocr_pdf/<指纹>.json`),
///   同一 PDF 已识别页不重复提交(断点续批), 全部完成自动清理
/// - 渲染: pdf_render 限制最长边(默认 1440px, RGBA 约 8MB/页), RGBA → image 编码
///   PNG → 临时文件 → 通道识别
class PdfOcrService {
  const PdfOcrService();

  /// 在线连续失败达到该值后, 自动降级为仅离线。
  static const int onlineFailLimit = 3;

  /// 临时目录: {appDir}/cache/ocr_pdf。
  static Future<Directory> _tempDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/cache/ocr_pdf');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 扫描 [pdfPath] 并返回合并文本。
  ///
  /// [onlineOcr] 在线通道(每页一次调用); [offlineEngine] 离线兜底通道;
  /// 两者至少其一可用, 否则抛 [StateError]。
  /// [onProgress] 每次进度变化回调(已完成页/总页/失败页/该页通道);
  /// [isCancelled] 返回 true 时尽快中断(已识别结果保留, 可续批)。
  Future<PdfOcrResult> scanPdf(
    String pdfPath, {
    Future<String> Function(String imagePath)? onlineOcr,
    LlamaCppEngine? offlineEngine,
    int windowSize = 3,
    int maxSide = 1440,
    void Function(int recognized, int total, int failed, OcrChannel channel)?
        onProgress,
    bool Function()? isCancelled,
  }) async {
    final offlineReady =
        offlineEngine != null && offlineEngine.isLoaded && offlineEngine.canOcr;
    if (onlineOcr == null && !offlineReady) {
      throw StateError('识别扫描件需配置在线视觉 API,'
          '或在「设置 → 本地模型」加载多模态 GGUF 模型');
    }

    final sourceFile = File(pdfPath);
    if (!await sourceFile.exists()) throw Exception('PDF 文件不存在');
    // 源文件指纹: 路径 + 大小(路径变化或文件替换都会重扫)
    final srcHash =
        '${sourceFile.path.hashCode & 0x7FFFFFFFFFFFFFFF}_${sourceFile.lengthSync()}';

    final PdfDocument doc = await PdfDocument.openFile(pdfPath);
    final total = doc.pageCount;
    if (total <= 0) {
      await doc.dispose();
      throw Exception('PDF 没有页面');
    }

    // 断点续批: 读取临时 checkpoint, 已识别页不重做(页级缓存)
    final tempDir = await _tempDir();
    final checkpointFile = File('${tempDir.path}/$srcHash.json');
    final results = <int, String>{};
    await _loadCheckpoint(checkpointFile, results);

    var failed = 0;
    var cancelled = false;
    var onlineStreak = 0; // 在线连续失败次数
    var onlineDown = false; // 在线通道已降级(仅离线)
    try {
      onProgress?.call(results.length, total, failed, OcrChannel.online);

      for (var start = 0; start < total; start += windowSize) {
        if (isCancelled?.call() ?? false) {
          cancelled = true;
          break;
        }
        final end = min(start + windowSize, total);
        for (var i = start; i < end; i++) {
          if (isCancelled?.call() ?? false) {
            cancelled = true;
            break;
          }
          // 缓存命中(断点续批): 不重复提交
          if (results.containsKey(i)) continue;

          final outcome = await _renderAndRecognize(
            doc,
            i,
            tempDir,
            onlineOcr,
            offlineReady ? offlineEngine : null,
            maxSide,
            onlineDown,
          );
          final text = outcome.$1;
          final channel = outcome.$2;

          if (text != null && text.trim().isNotEmpty) {
            results[i] = text.trim();
            // 每页成功即落盘, 保证取消/中断后可续
            await _saveCheckpoint(
                checkpointFile, sourceFile.path, total, results);
            if (channel == OcrChannel.online) onlineStreak = 0;
          } else {
            failed++;
            // 该页在线未产出(失败/兜底失败) → 记一次在线失败, 达到阈值降级
            if (onlineOcr != null && !onlineDown) {
              onlineStreak++;
              if (onlineStreak >= onlineFailLimit) onlineDown = true;
            }
          }
          onProgress?.call(results.length, total, failed, channel);
        }
      }

      final text = _joinPages(results);
      return PdfOcrResult(
        text: text,
        totalPages: total,
        recognizedPages: results.length,
        failedPages: failed,
        cancelled: cancelled,
        // [v2.5.1] 按页序输出(未识别页为空串), 供阅读页按页显示
        pages: List<String>.generate(total, (i) => results[i]?.trim() ?? ''),
      );
    } finally {
      // 全部页处理完成 → 清理 checkpoint; 否则(中断/失败)保留供续批
      if (results.length >= total) {
        try {
          if (await checkpointFile.exists()) await checkpointFile.delete();
        } catch (_) {}
      }
      try {
        await doc.dispose();
      } catch (_) {}
    }
  }

  /// 渲染第 [index] 页为 PNG 并按通道识别。返回 (文本, 实际通道)。
  /// 渲染失败 / 全部通道失败时文本为 null。
  Future<(String?, OcrChannel)> _renderAndRecognize(
    PdfDocument doc,
    int index,
    Directory tempDir,
    Future<String> Function(String imagePath)? onlineOcr,
    LlamaCppEngine? offlineEngine,
    int maxSide,
    bool onlineDown,
  ) async {
    String? pngPath;
    try {
      pngPath = await _renderPage(doc, index, tempDir, maxSide);
    } catch (_) {
      return (null, OcrChannel.failed); // 渲染失败
    }
    try {
      // 在线优先(未降级时)
      if (onlineOcr != null && !onlineDown) {
        try {
          final text = await onlineOcr(pngPath);
          return (text, OcrChannel.online);
        } catch (_) {
          // 在线失败 → 离线兜底该页
          if (offlineEngine != null) {
            try {
              final text = await offlineEngine.ocrImage(pngPath);
              return (text, OcrChannel.offline);
            } catch (_) {
              return (null, OcrChannel.failed);
            }
          }
          return (null, OcrChannel.failed);
        }
      }
      // 已降级 / 无在线 → 仅离线
      if (offlineEngine != null) {
        try {
          final text = await offlineEngine.ocrImage(pngPath);
          return (text, OcrChannel.offline);
        } catch (_) {
          return (null, OcrChannel.failed);
        }
      }
      return (null, OcrChannel.failed);
    } finally {
      try {
        final f = File(pngPath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  /// 渲染第 [index] 页为 PNG 临时文件, 返回文件路径。
  Future<String> _renderPage(
    PdfDocument doc,
    int index,
    Directory tempDir,
    int maxSide,
  ) async {
    final pageNo = index + 1;
    final page = await doc.getPage(pageNo);
    final scale = min(1.0, maxSide / max(1.0, max(page.width, page.height)));
    final w = max(1, (page.width * scale).round());
    final h = max(1, (page.height * scale).round());

    final rendered = await page.render(width: w, height: h);
    try {
      // rendered.pixels 为 RGBA Uint8List; fromBytes 需要 ByteBuffer + 偏移
      final pixels = rendered.pixels;
      final image = img.Image.fromBytes(
        width: rendered.width,
        height: rendered.height,
        bytes: pixels.buffer,
        bytesOffset: pixels.offsetInBytes,
        numChannels: 4,
        order: img.ChannelOrder.rgba,
      );
      final pngBytes = img.encodePng(image);
      final pngFile = File('${tempDir.path}/page_$index.png');
      await pngFile.writeAsBytes(pngBytes, flush: true);
      return pngFile.path;
    } finally {
      rendered.dispose();
    }
  }

  /// 读取 checkpoint 到 [results]。
  Future<void> _loadCheckpoint(File file, Map<int, String> results) async {
    try {
      if (!await file.exists()) return;
      final data = jsonDecode(await file.readAsString());
      if (data is Map) {
        final pages = data['pages'];
        if (pages is Map) {
          pages.forEach((k, v) {
            final n = int.tryParse('$k');
            if (n != null && v is String && v.trim().isNotEmpty) {
              results[n] = v;
            }
          });
        }
      }
    } catch (_) {
      // checkpoint 损坏则忽略, 从头识别
    }
  }

  Future<void> _saveCheckpoint(
    File file,
    String srcPath,
    int total,
    Map<int, String> results,
  ) async {
    try {
      await file.writeAsString(
        jsonEncode({'src': srcPath, 'total': total, 'pages': results}),
        flush: true,
      );
    } catch (_) {
      // 断点写入失败不影响本次识别
    }
  }

  /// 按页面顺序拼接文本, 页间空行分隔。
  String _joinPages(Map<int, String> results) {
    if (results.isEmpty) return '';
    final keys = results.keys.toList()..sort();
    final pages = <String>[];
    for (final k in keys) {
      final t = results[k]!.trim();
      if (t.isNotEmpty) pages.add(t);
    }
    return pages.join('\n\n');
  }
}
