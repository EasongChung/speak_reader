import 'dart:math';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/document.dart';
import '../services/llama_cpp_engine.dart';
import '../services/pdf_ocr_service.dart';
import '../services/vision_ocr_service.dart';
import '../services/import_service.dart';
import '../services/storage_service.dart';
import '../services/settings_service.dart';
import '../widgets/import_sheet.dart';
import 'reader_page.dart';
import 'settings_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _storage = StorageService();
  final _visionOcr = VisionOcrService();
  final _import = ImportService();
  final _settingsService = SettingsService();
  final _picker = ImagePicker();

  List<Document> _docs = [];
  bool _loading = false;
  int _refreshGeneration = 0;
  final Random _random = Random.secure();

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _refresh() async {
    final generation = ++_refreshGeneration;
    try {
      final docs = await _storage.loadAll();
      if (mounted && generation == _refreshGeneration) {
        setState(() => _docs = docs);
      }
    } catch (e) {
      _toast('读取历史记录失败:$e');
    }
  }

  // ---------------- 导入流程 ----------------

  Future<void> _onImport() async {
    if (_loading) return;
    final choice = await ImportSheet.show(context);
    if (!mounted || choice == null || _loading) return;
    setState(() => _loading = true);
    try {
      switch (choice) {
        case ImportChoice.camera:
          await _importFromCamera();
          break;
        case ImportChoice.gallery:
          await _importFromGallery();
          break;
        case ImportChoice.file:
          await _importFromFile();
          break;
      }
    } finally {
      _setLoading(false);
    }
  }

  Future<void> _importFromCamera() async {
    if (!await _ensure(Permission.camera, '相机')) return;
    try {
      final XFile? shot = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
        maxWidth: 2200,
        maxHeight: 2200,
      );
      if (shot == null || !mounted) return;
      await _runOcr(
        shot.path,
        DocSource.camera,
        originalExtension: 'jpg',
        originalFileMime: 'image/jpeg',
      );
    } catch (e) {
      _toast('拍照失败:$e');
    }
  }

  Future<void> _importFromGallery() async {
    try {
      final XFile? img = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
        maxWidth: 2200,
        maxHeight: 2200,
      );
      if (img == null || !mounted) return;
      final ext = _imageExtension(img.path);
      await _runOcr(
        img.path,
        DocSource.gallery,
        originalExtension: ext,
        originalFileMime: _imageMime(ext),
      );
    } catch (e) {
      _toast('选图失败:$e');
    }
  }

  /// [v2.5.0] 图片识别: 在线视觉模型优先, 失败/未配置时自动切本地多模态模型兜底。
  Future<void> _runOcr(
    String path,
    DocSource source, {
    required String originalExtension,
    required String originalFileMime,
  }) async {
    try {
      final settings = await _settingsService.load();
      final engine = LlamaCppEngine.instance;
      final hasOnline = settings.translationReady;
      final hasOffline = engine.isLoaded && engine.canOcr;
      if (!mounted) return;
      if (!hasOnline && !hasOffline) {
        _toast('图片识别需先到「设置」配置在线 API(支持视觉的模型,如 gpt-4o、qwen-vl),'
            '或在「本地模型」加载多模态 GGUF 模型离线识别');
        return;
      }

      String? text;
      if (hasOnline) {
        try {
          text = await _visionOcr.recognizeFile(path, settings: settings);
        } catch (e) {
          if (hasOffline) {
            _toast('在线识别失败,已切换本地模型识别');
          } else {
            rethrow;
          }
        }
      }
      if (text == null && hasOffline) {
        if (!mounted) return;
        _toast('离线识别中…');
        text = await engine.ocrImage(path);
      }

      if (!mounted) return;
      if (text == null || text.trim().isEmpty) {
        _toast('未识别到文字,请换一张更清晰的图片');
        return;
      }

      final originalPath = await _storage.copyOriginal(path, originalExtension);
      final doc = _newDoc(
        title: source == DocSource.camera ? '拍照识别' : '相册识别',
        content: text.trim(),
        source: source,
        originalFilePath: originalPath,
        originalFileMime: originalFileMime,
      );
      await _commitAndOpen(doc, rollbackOriginalPath: originalPath);
    } catch (e) {
      _toast('识别失败:$e');
    }
  }

  Future<void> _importFromFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['docx', 'pdf', 'txt', 'md'],
      );
      final path = result?.files.single.path;
      if (path == null || !mounted) return;

      try {
        final imported = await _import.importFile(path);
        if (!mounted) return;
        if (imported.content.trim().isEmpty) {
          _toast('文档中没有可朗读的文字');
          return;
        }

        String? originalPath;
        String? originalMime;
        if (path.toLowerCase().endsWith('.pdf')) {
          originalPath = await _storage.copyOriginal(path, 'pdf');
          originalMime = 'application/pdf';
        }
        final doc = _newDoc(
          title: imported.title,
          content: imported.content,
          source: imported.source,
          originalFilePath: originalPath,
          originalFileMime: originalMime,
        );
        await _commitAndOpen(doc, rollbackOriginalPath: originalPath);
      } on PdfHasNoTextLayerException catch (e) {
        // [v2.5.0] 扫描版 PDF(无文本层): 在线视觉模型优先, 离线多模态兜底
        if (!mounted) return;
        final settings = await _settingsService.load();
        final engine = LlamaCppEngine.instance;
        if (!settings.translationReady &&
            (!engine.isLoaded || !engine.canOcr)) {
          _toast('该 PDF 是扫描件(图片版)。可在「设置」配置在线视觉 API,'
              '或加载多模态 GGUF 模型后识别;也可把页面截图用「拍照/相册」导入');
          return;
        }
        if (!path.toLowerCase().endsWith('.pdf')) {
          _toast(e.message);
          return;
        }
        final scannedDoc = await _importScannedPdf(path);
        if (scannedDoc != null && mounted) {
          await _commitAndOpen(scannedDoc,
              rollbackOriginalPath: scannedDoc.originalFilePath);
        }
      }
    } catch (e) {
      _toast('导入失败:$e');
    }
  }

  /// [v2.5.0] 扫描版 PDF 逐页 OCR(在线视觉优先/离线兜底, 进度对话框 + 取消续批)。
  /// 成功返回生成的文档; 失败/取消返回 null。
  Future<Document?> _importScannedPdf(String pdfPath) async {
    final settings = await _settingsService.load();
    final engine = LlamaCppEngine.instance;
    final hasOnline = settings.translationReady;
    final hasOffline = engine.isLoaded && engine.canOcr;
    if (!mounted) return null;
    if (!hasOnline && !hasOffline) {
      _toast('扫描件识别需在线视觉 API,或在「设置 → 本地模型」加载多模态 GGUF 模型');
      return null;
    }

    final progress = ValueNotifier<String>('准备识别…');
    final cancelled = ValueNotifier<bool>(false);

    // [v2.5.0] 在线通道: 每次用最新设置调用在线视觉模型(逐页提交)
    Future<String> onlineOcr(String imagePath) async {
      final s = await _settingsService.load();
      return _visionOcr.recognizeFile(imagePath, settings: s);
    }

    Future<PdfOcrResult> task() => PdfOcrService().scanPdf(
          pdfPath,
          onlineOcr: hasOnline ? onlineOcr : null,
          offlineEngine: hasOffline ? engine : null,
          windowSize: 3, // [v2.5.0] 每批 3 页节流, 避免短时间大量提交触发限速
          onProgress: (recognized, total, failed, channel) {
            progress.value = failed > 0
                ? '第 $recognized/$total 页(${channel.label},跳过 $failed 页)…'
                : '第 $recognized/$total 页(${channel.label})…';
          },
          isCancelled: () => cancelled.value,
        );

    final taskFuture = task();
    final dialogFuture = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('识别扫描版 PDF'),
          content: ValueListenableBuilder<String>(
            valueListenable: progress,
            builder: (_, text, __) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const LinearProgressIndicator(),
                const SizedBox(height: 12),
                Text(text),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                cancelled.value = true;
                progress.value = '正在取消,已识别页会保留,可再次导入续批…';
              },
              child: const Text('取消'),
            ),
          ],
        ),
      ),
    );

    PdfOcrResult? result;
    String? error;
    try {
      result = await taskFuture;
    } catch (e) {
      error = '$e';
    }
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    await dialogFuture;

    if (error != null) {
      _toast('扫描件识别失败:$error');
      return null;
    }
    if (result == null) return null;
    if (result.cancelled) {
      _toast('已取消识别。再次导入同一 PDF 会自动续批'
          '(已识别 ${result.recognizedPages}/${result.totalPages} 页)');
      return null;
    }
    if (result.text.trim().isEmpty) {
      _toast('未识别到文字。请确认在线 API 支持图片输入或已加载多模态模型,且页面内容清晰');
      return null;
    }

    final originalPath = await _storage.copyOriginal(pdfPath, 'pdf');
    return _newDoc(
      title: '扫描件识别',
      content: result.text.trim(),
      source: DocSource.pdf,
      originalFilePath: originalPath,
      originalFileMime: 'application/pdf',
    );
  }

  Document _newDoc({
    required String title,
    required String content,
    required DocSource source,
    // [v2.4.0] 原文文件信息（可选参数）
    String? originalFilePath,
    String? originalFileMime,
  }) {
    final now = DateTime.now();
    return Document(
      id: '${now.microsecondsSinceEpoch}_${_randomToken()}',
      title: title,
      content: content,
      source: source,
      createdAt: now.millisecondsSinceEpoch,
      originalFilePath: originalFilePath,
      originalFileMime: originalFileMime,
    );
  }

  Future<void> _commitAndOpen(
    Document doc, {
    String? rollbackOriginalPath,
  }) async {
    if (!mounted) {
      if (rollbackOriginalPath != null) {
        await _storage.deleteManagedOriginal(rollbackOriginalPath);
      }
      return;
    }

    List<Document> committedDocs;
    try {
      committedDocs = await _storage.upsert(doc);
    } catch (_) {
      if (rollbackOriginalPath != null) {
        await _storage.deleteManagedOriginal(rollbackOriginalPath);
      }
      rethrow;
    }

    if (!mounted) return;
    setState(() => _docs = committedDocs);
    try {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ReaderPage(document: doc)),
      );
      await _refresh();
    } catch (e) {
      _toast('文档已保存，但打开阅读页失败:$e');
    }
  }

  String _imageExtension(String path) {
    final dot = path.lastIndexOf('.');
    final ext = dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
    return const {'jpg', 'jpeg', 'png', 'webp', 'heic', 'heif'}.contains(ext)
        ? ext
        : 'jpg';
  }

  String _imageMime(String ext) {
    switch (ext) {
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
      case 'heic':
        return 'image/heic';
      case 'heif':
        return 'image/heif';
      default:
        return 'image/jpeg';
    }
  }

  String _randomToken() => List<int>.generate(8, (_) => _random.nextInt(256))
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();

  // ---------------- 权限 ----------------

  Future<bool> _ensure(Permission p, String name) async {
    var status = await p.status;
    if (status.isGranted) return true;
    status = await p.request();
    if (status.isGranted) return true;
    if (status.isPermanentlyDenied) {
      _toast('$name权限被永久拒绝,请到系统设置手动开启');
      await openAppSettings();
    } else {
      _toast('未获得$name权限');
    }
    return false;
  }

  // ---------------- 历史操作 ----------------

  Future<void> _openDoc(Document doc) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ReaderPage(document: doc)),
    );
    await _refresh();
  }

  Future<bool> _deleteDoc(Document doc) async {
    try {
      final docs = await _storage.delete(doc.id);
      if (mounted) setState(() => _docs = docs);
      return true;
    } catch (e) {
      _toast('删除失败:$e');
      return false;
    }
  }

  void _setLoading(bool v) {
    if (mounted) setState(() => _loading = v);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('语音朗读'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: '设置',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsPage()),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          _docs.isEmpty ? _emptyView() : _historyList(),
          if (_loading)
            Container(
              color: Colors.black26,
              child: const Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _loading ? null : _onImport,
        icon: const Icon(Icons.add),
        label: const Text('导入'),
      ),
    );
  }

  Widget _emptyView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.record_voice_over,
              size: 88, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 16),
          const Text('还没有内容', style: TextStyle(fontSize: 18)),
          const SizedBox(height: 8),
          const Text('点击右下角「导入」\n拍照、选图或选择 Word/PDF/TXT 文档',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey)),
        ],
      ),
    );
  }

  Widget _historyList() {
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.separated(
        padding: const EdgeInsets.only(bottom: 88, top: 8),
        itemCount: _docs.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final doc = _docs[i];
          return Dismissible(
            key: ValueKey(doc.id),
            direction: DismissDirection.endToStart,
            background: Container(
              color: Colors.red,
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 20),
              child: const Icon(Icons.delete, color: Colors.white),
            ),
            confirmDismiss: (_) => _deleteDoc(doc),
            child: ListTile(
              leading: CircleAvatar(child: Text(doc.source.label)),
              title:
                  Text(doc.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('${doc.createdAtText}\n${doc.preview}',
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              isThreeLine: true,
              onTap: () => _openDoc(doc),
            ),
          );
        },
      ),
    );
  }
}
