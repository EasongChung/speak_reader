import 'dart:convert';
import 'dart:io';

import 'package:docx_to_text/docx_to_text.dart';
import 'package:flutter_pdf_text/flutter_pdf_text.dart';

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
      final document = await PDFDoc.fromFile(file);
      if (document.length == 0) {
        throw const FormatException('PDF 为空');
      }

      final text = (await document.text).trim();
      if (text.isEmpty) {
        throw const FormatException(
          '该 PDF 可能是扫描件(图片版),没有可提取的文字层。\n'
          '建议:把 PDF 页面截图后用「拍照/相册」导入做文字识别。',
        );
      }
      return text;
    } on FormatException {
      rethrow;
    } catch (e) {
      throw Exception('无法打开该 PDF:$e');
    }
  }

  Future<String> _readTxt(File file) async {
    final bytes = await file.readAsBytes();
    try {
      return utf8.decode(bytes, allowMalformed: false).trim();
    } on FormatException catch (e) {
      throw FormatException(
        'TXT 不是有效的 UTF-8 文本，请先转换为 UTF-8 编码后再导入。',
        e,
      );
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
