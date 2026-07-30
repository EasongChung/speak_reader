import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/document.dart';
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
    final docs = await _storage.loadAll();
    if (mounted) setState(() => _docs = docs);
  }

  // ---------------- 导入流程 ----------------

  Future<void> _onImport() async {
    final choice = await ImportSheet.show(context);
    if (choice == null) return;
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
      if (shot == null) return;
      // [v2.4.0] 保存原始文件到私有目录
      final origPath = await _saveOriginalFile(shot.path, 'jpg');
      await _runOcr(shot.path, DocSource.camera,
          originalPath: origPath, originalFileMime: 'image/jpeg');
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
      if (img == null) return;
      // [v2.4.0] 保存原始文件到私有目录
      final ext = img.path.toLowerCase().endsWith('.png') ? 'png' : 'jpg';
      final mime = ext == 'png' ? 'image/png' : 'image/jpeg';
      final origPath = await _saveOriginalFile(img.path, ext);
      await _runOcr(img.path, DocSource.gallery,
          originalPath: origPath, originalFileMime: mime);
    } catch (e) {
      _toast('选图失败:$e');
    }
  }

  Future<void> _runOcr(
    String path,
    DocSource source, {
    // [v2.4.0] 原文文件信息（可选参数，向下兼容）
    String? originalPath,
    String? originalFileMime,
  }) async {
    _setLoading(true);
    try {
      final settings = await _settingsService.load();
      if (!settings.translationReady) {
        _toast('图片识别需要先到「设置」配置 API(支持视觉的模型,如 gpt-4o、qwen-vl)');
        return;
      }
      final text = await _visionOcr.recognizeFile(path, settings: settings);
      if (text.trim().isEmpty) {
        _toast('未识别到文字,请换一张更清晰的图片');
        return;
      }
      final doc = _newDoc(
        title: source == DocSource.camera ? '拍照识别' : '相册识别',
        content: text,
        source: source,
        // [v2.4.0] 传递原文文件信息
        originalFilePath: originalPath,
        originalFileMime: originalFileMime,
      );
      await _openAndSave(doc);
    } catch (e) {
      _toast('识别失败:$e');
    } finally {
      _setLoading(false);
    }
  }

  Future<void> _importFromFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['docx', 'pdf', 'txt', 'md'],
      );
      final path = result?.files.single.path;
      if (path == null) return;

      _setLoading(true);
      // [v2.4.0] PDF 导入时保存原始文件
      String? origPath;
      String? origMime;
      if (path.toLowerCase().endsWith('.pdf')) {
        origPath = await _saveOriginalFile(path, 'pdf');
        origMime = 'application/pdf';
      }
      final imported = await _import.importFile(path);
      if (imported.content.trim().isEmpty) {
        _toast('文档中没有可朗读的文字');
        return;
      }
      final doc = _newDoc(
        title: imported.title,
        content: imported.content,
        source: imported.source,
        // [v2.4.0] 传递原文文件信息
        originalFilePath: origPath,
        originalFileMime: origMime,
      );
      await _openAndSave(doc);
    } catch (e) {
      _toast('导入失败:$e');
    } finally {
      _setLoading(false);
    }
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
      id: now.microsecondsSinceEpoch.toString(),
      title: title,
      content: content,
      source: source,
      createdAt: now.millisecondsSinceEpoch,
      originalFilePath: originalFilePath,
      originalFileMime: originalFileMime,
    );
  }

  // [v2.4.0] 保存原始文件副本到应用私有目录，返回目标路径
  Future<String> _saveOriginalFile(String sourcePath, String ext) async {
    final dir = await _storage.getOriginalsDir();
    final destPath = '${dir.path}/${DateTime.now().microsecondsSinceEpoch}.$ext';
    await File(sourcePath).copy(destPath);
    return destPath;
  }

  Future<void> _openAndSave(Document doc) async {
    await _storage.upsert(doc);
    await _refresh();
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ReaderPage(document: doc)),
    );
    // 从阅读页返回后可能编辑过标题/内容,刷新列表
    await _refresh();
  }

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

  Future<void> _deleteDoc(Document doc) async {
    await _storage.delete(doc.id);
    await _refresh();
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
            onDismissed: (_) => _deleteDoc(doc),
            child: ListTile(
              leading: CircleAvatar(child: Text(doc.source.label)),
              title: Text(doc.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
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
