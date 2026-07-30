import 'dart:io';
import 'package:docx_to_text/docx_to_text.dart';
import 'package:pdfx/pdfx.dart';

import '../models/document.dart';

/// 文档解析结果
class ImportResult {
  final String content;
  final DocSource source;
  final String title;
  ImportResult(this.content, this.source, this.title);
}

/// 文档导入服务:解析 .docx / .pdf / .txt 为纯文本。
class ImportService {
  /// 根据文件扩展名解析文本内容
  Future<ImportResult> importFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw Exception('文件不存在');
    }
    final name = _fileName(path);
    final ext = _ext(path);

    switch (ext) {
      case 'docx':
        return ImportResult(await _readDocx(file), DocSource.word, name);
      case 'pdf':
        return ImportResult(await _readPdf(file), DocSource.pdf, name);
      case 'txt':
      case 'text':
      case 'md':
        return ImportResult(await _readTxt(file), DocSource.txt, name);
      case 'doc':
        throw Exception('暂不支持旧版 .doc,请另存为 .docx 后再导入');
      default:
        throw Exception('不支持的文件类型:.$ext');
    }
  }

  Future<String> _readDocx(File file) async {
    final bytes = await file.readAsBytes();
    final text = docxToText(bytes);
    return text.trim();
  }

  Future<String> _readPdf(File file) async {
    try {
      final document = await PdfDocument.openFile(file.path);
      try {
        final pageCount = await document.getPagesCount();
        if (pageCount == 0) throw Exception('PDF 为空');
        final sb = StringBuffer();
        for (int i = 1; i <= pageCount; i++) {
          final page = await document.getPage(i);
          try {
            sb.writeln(await page.getText());
          } finally {
            await page.close();
          }
        }
        final text = sb.toString().trim();
        if (text.isEmpty) {
          throw Exception(
              '该 PDF 可能是扫描件(图片版),没有可提取的文字层。\n'
              '建议:把 PDF 页面截图后用「拍照/相册」导入做文字识别。');
        }
        return text;
      } finally {
        await document.close();
      }
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('无法打开该 PDF:$e');
    }
  }

  Future<String> _readTxt(File file) async {
    // 优先按 UTF-8,失败则回退系统编码
    try {
      return (await file.readAsString()).trim();
    } catch (_) {
      final bytes = await file.readAsBytes();
      return String.fromCharCodes(bytes).trim();
    }
  }

  String _fileName(String path) {
    final parts = path.split(RegExp(r'[/\\]'));
    return parts.isEmpty ? '文档' : parts.last;
  }

  String _ext(String path) {
    final name = _fileName(path);
    final dot = name.lastIndexOf('.');
    if (dot < 0) return '';
    return name.substring(dot + 1).toLowerCase();
  }
}
