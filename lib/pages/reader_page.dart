import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_pdfview/flutter_pdfview.dart';

import '../models/document.dart';
import '../services/audio_export_service.dart'
    show AudioExportService, CancellationException;
import '../services/llama_cpp_engine.dart';
import '../services/tts_service.dart';
import '../services/storage_service.dart';
import '../services/settings_service.dart';
import '../services/translation_service.dart';
// [v2.4.0] 移除: offline_translation_service(ML Kit 已删除)

class ReaderPage extends StatefulWidget {
  final Document document;
  const ReaderPage({super.key, required this.document});

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  final _tts = TtsService();
  final _storage = StorageService();
  final _settingsService = SettingsService();
  final _translation = TranslationService();
  // [v2.4.0] 移除: _offlineTranslation
  final _audioExport = AudioExportService();
  final _scrollController = ScrollController();

  late Document _doc;
  AppSettings _settings = AppSettings();

  int _currentToken = -1;
  TtsState _state = TtsState.stopped;
  bool _editing = false;
  // [v2.4.0] 原文模式: 有原始图片时默认 true
  bool _originalMode = false;
  bool _translating = false;
  bool _exporting = false;
  bool _exportCancelled = false;
  // [v2.4.0] 句子折叠翻译: 已展开译文的 token index → 译文文本
  final Map<int, String> _translations = {};
  // [v2.4.0] 底部文本面板的刷新回调(StatefulBuilder setSheet)
  VoidCallback? _sheetRebuild;
  int _contentRevision = 0;
  int _translationRequest = 0;
  late TextEditingController _editController;
  // [v2.5.0] PDF 原文渲染状态
  PDFViewController? _pdfController;
  int _pdfPageCount = 0;
  int _pdfCurrentPage = 0;
  bool _pdfReady = false;
  String? _pdfError;

  // [v2.5.1] 多页面文件按页显示
  List<String>? get _pageTexts => _doc.pageTexts;
  bool get _isMultiPage => _doc.isMultiPage;

  /// [v2.5.1] 当前应显示的文本: 多页文件取当前 PDF 页, 否则全文。
  String get _displayText {
    final pages = _pageTexts;
    if (pages == null || pages.isEmpty) return _doc.content;
    final i = _pdfCurrentPage.clamp(0, pages.length - 1);
    return pages[i];
  }

  final _tokenKeys = <int, GlobalKey>{};
  // [v2.5.3] 顶部「更多」抽屉按钮: 用 GlobalKey 打开 endDrawer,
  // 修复 Scaffold.of(context) 在 AppBar actions 中找不到 Scaffold 的问题
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    _doc = widget.document;
    _editController = TextEditingController(text: _doc.content);

    _tts.onTokenChanged = (i) {
      if (!mounted) return;
      setState(() => _currentToken = i);
      // [v2.5.2] 「查看文本」弹窗内高亮跟随朗读(弹窗为 StatefulBuilder,
      // 需单独触发 setSheet 才会重建)
      _sheetRebuild?.call();
      _autoScrollTo(i);
    };
    _tts.onStateChanged = (s) {
      if (mounted) setState(() => _state = s);
    };
    _tts.onComplete = () {
      if (mounted) setState(() => _currentToken = -1);
    };

    _init();
    // [v2.4.0] 有原始图片时默认进入原文模式
    // [v2.5.2] 默认原文扩展到所有保留原文件的文档(图片/PDF/docx);
    // 弱排版文本(TXT/MD)不保留原文件(hasOriginal=false), 自动走文本模式
    if (_doc.hasOriginal) {
      _originalMode = true;
    }
  }

  Future<void> _init() async {
    final settings = await _settingsService.load();
    if (!mounted) return;

    _settings = settings;
    // 把设置里的参数灌进 TTS 引擎
    _tts.speechRate = settings.speechRate;
    _tts.repeatCount = settings.repeatCount;
    _tts.dictationGapSeconds = settings.dictationGapSeconds;
    _tts.repeatGapSeconds = settings.repeatGapSeconds;
    _tts.dictationRate = settings.dictationRate;
    _tts.loop = settings.loop;
    _audioExport.customDir = settings.customOutputDir;
    await _tts.init();
    if (!mounted) return;

    _tts.setText(_displayText); // [v2.5.1] 多页文件按当前页切句
    setState(() {});
    // 开启了"自动生成音频"时,后台静默导出一份(不阻断朗读)
    if (settings.autoExportAudio) {
      _exportAudio(auto: true);
    }
  }

  @override
  void dispose() {
    _translationRequest++;
    _exportCancelled = true;
    _sheetRebuild = null;
    _tts.onTokenChanged = null;
    _tts.onStateChanged = null;
    _tts.onComplete = null;
    _tts.dispose();
    // [v2.4.0] 移除: _offlineTranslation.dispose()
    // [v2.5.0] PDF 原生视图由组件自行回收, 仅清理状态引用
    _pdfController = null;
    _scrollController.dispose();
    _editController.dispose();
    super.dispose();
  }

  void _autoScrollTo(int index) {
    final ctx = _tokenKeys[index]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 250),
        alignment: 0.3,
      );
    }
  }

  // ---------------- 朗读控制 ----------------

  Future<void> _togglePlay() async {
    if (_exporting) {
      _toast('音频生成中,请稍候');
      return;
    }
    switch (_state) {
      case TtsState.playing:
        await _tts.pause();
        break;
      case TtsState.paused:
        await _tts.resume();
        break;
      case TtsState.stopped:
        await _tts.play();
        break;
    }
  }

  Future<void> _stop() => _tts.stop();

  Future<void> _toggleDictation(bool v) async {
    await _tts.stop();
    if (!mounted) return;
    setState(() {
      // 切换模式需按新模式重新切分文本
      _tts.setModeAndText(v, _displayText); // [v2.5.1] 多页按当前页
      _contentRevision++;
      _translationRequest++;
      _translating = false;
      _currentToken = -1;
      _tokenKeys.clear();
      _translations.clear(); // [v2.4.0] 切换模式时译文索引失效
    });
    _sheetRebuild?.call();
  }

  // ---------------- 音频导出 ----------------

  Future<void> _exportAudio({bool auto = false}) async {
    if (!mounted || _exporting) return;
    if (_doc.content.trim().isEmpty) {
      if (!auto) _toast('没有可朗读的内容');
      return;
    }
    setState(() => _exporting = true);

    final progress = ValueNotifier<double>(0.0);
    if (!auto) {
      // 手动导出:停止朗读并显示进度(不可被返回键关闭,避免误 pop 阅读页)
      await _tts.stop();
      if (mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => PopScope(
            canPop: false,
            child: AlertDialog(
              title: const Text('正在生成音频…'),
              content: ValueListenableBuilder<double>(
                valueListenable: progress,
                builder: (_, v, __) =>
                    LinearProgressIndicator(value: v <= 0 ? null : v),
              ),
            ),
          ),
        );
      }
    }

    try {
      final dictation = _tts.dictationMode;
      final path = await _audioExport.exportDocument(
        _tts,
        _displayText, // [v2.5.1] 多页文件导出当前页
        dictation: dictation,
        rate: dictation ? _tts.dictationRate : _tts.speechRate,
        repeatCount: _tts.repeatCount,
        gapSeconds: _tts.dictationGapSeconds,
        repeatGapSeconds: _tts.repeatGapSeconds,
        baseName: _doc.title,
        stableId: _doc.id,
        stableName: auto,
        cancel: () => _exportCancelled,
        onProgress: (p) => progress.value = p,
      );
      if (!auto && mounted) Navigator.of(context).pop(); // 关进度框
      if (auto) {
        _toastWithAction(
            '已生成音频:${_basename(path)}', '分享', () => _sharePath(path));
      } else if (mounted) {
        _showExportResult(path);
      }
    } on CancellationException {
      if (!auto && mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!auto && mounted) Navigator.of(context).pop();
      if (auto) {
        debugPrint('auto export failed: $e');
      } else {
        _toast('导出失败:$e');
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  void _showExportResult(String path) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('音频已生成 ✅'),
        content: Text('文件:\n$path\n\n可用"分享/打开"发送到微信、文件管理等。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.share, size: 18),
            label: const Text('分享/打开'),
            onPressed: () {
              Navigator.of(context).pop();
              _sharePath(path);
            },
          ),
        ],
      ),
    );
  }

  Future<void> _sharePath(String path) async {
    try {
      await _audioExport.shareFile(path);
    } catch (e) {
      _toast('分享失败:$e');
    }
  }

  Future<void> _showAudioFilesSheet() async {
    final files = await _audioExport.listFiles();
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (context, setSheet) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('已生成的音频',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                if (files.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                        child: Text('还没有音频文件\n可在设置开启自动生成,或点导出按钮手动生成',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.grey))),
                  )
                else
                  ConstrainedBox(
                    constraints: BoxConstraints(
                        maxHeight: MediaQuery.of(context).size.height * 0.5),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: files.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final f = files[i];
                        final name = _basename(f.path);
                        return ListTile(
                          leading: const Icon(Icons.audio_file),
                          title: Text(name,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(_fileSize(f)),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.share),
                                tooltip: '分享/打开',
                                onPressed: () => _sharePath(f.path),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline),
                                tooltip: '删除',
                                onPressed: () async {
                                  await _audioExport.deleteFile(f.path);
                                  files.removeAt(i);
                                  setSheet(() {});
                                },
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    );
  }

  String _basename(String path) => path.split('/').last;

  String _fileSize(File f) {
    try {
      final kb = f.lengthSync() / 1024;
      return kb > 1024
          ? '${(kb / 1024).toStringAsFixed(1)} MB'
          : '${kb.toStringAsFixed(0)} KB';
    } catch (_) {
      return '';
    }
  }

  void _toastWithAction(String msg, String actionLabel, VoidCallback onAction) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 6),
        action: SnackBarAction(label: actionLabel, onPressed: onAction),
      ),
    );
  }

  // ---------------- 翻译 ----------------

  /// [v2.4.0] 翻译当前高亮句子,在本句下方折叠展开/收起译文
  Future<void> _translate() async {
    // 确定要翻译的句子索引: 优先高亮,否则第一句
    int? candidateIndex;
    if (_currentToken >= 0 && _currentToken < _tts.tokens.length) {
      candidateIndex = _currentToken;
    } else if (_tts.tokens.isNotEmpty) {
      candidateIndex = 0;
    }
    if (candidateIndex == null || _tts.tokens[candidateIndex].trim().isEmpty) {
      _toast('没有可翻译的内容');
      return;
    }

    final int index = candidateIndex;
    final sentence = _tts.tokens[index];

    // 已展开 → 折叠(收起译文)
    if (_translations.containsKey(index)) {
      setState(() => _translations.remove(index));
      _sheetRebuild?.call();
      return;
    }

    // [v2.5.0] 在线/离线双通道前置检查
    final engine = LlamaCppEngine.instance;
    final hasOnline = _settings.translationReady;
    final hasOffline = engine.isLoaded;
    if (!hasOnline && !hasOffline) {
      _toast('请先到「设置」配置翻译 API,或在本地模型分区加载 GGUF 模型');
      return;
    }
    // 确定走离线通道时给出提示
    if (hasOffline &&
        (!hasOnline ||
            _settings.translationStrategy == TranslationStrategy.offlineOnly)) {
      _toast('离线翻译中…');
    }

    final request = ++_translationRequest;
    final revision = _contentRevision;
    setState(() => _translating = true);
    try {
      final result =
          await _translation.translate(sentence, settings: _settings);
      if (!mounted ||
          request != _translationRequest ||
          revision != _contentRevision ||
          index >= _tts.tokens.length ||
          _tts.tokens[index] != sentence) {
        return;
      }
      setState(() => _translations[index] = result);
      _sheetRebuild?.call();
    } catch (e) {
      if (mounted && request == _translationRequest) {
        _toast('翻译失败:$e');
      }
    } finally {
      if (mounted && request == _translationRequest) {
        setState(() => _translating = false);
      }
    }
  }

  // ---------------- 编辑 ----------------

  Future<void> _toggleEdit() async {
    if (_editing) {
      await _tts.stop();
      if (!mounted) return;
      setState(() {
        // [v2.5.1] 多页文件: 仅更新当前页文本并重建全文
        final pages = _doc.pageTexts;
        if (pages != null && pages.isNotEmpty) {
          final i = _pdfCurrentPage.clamp(0, pages.length - 1);
          pages[i] = _editController.text;
          _doc.content = pages.join('\n\n').trim();
        } else {
          _doc.content = _editController.text;
        }
        _editing = false;
        _contentRevision++;
        _translationRequest++;
        _translating = false;
        _translations.clear();
        _tokenKeys.clear();
      });
      _tts.setText(_displayText); // [v2.5.1] 保存后按当前页重新切句
      _sheetRebuild?.call();
      await _storage.upsert(_doc);
      if (!mounted) return;
      _toast('已保存');
      // 内容变了,若开启了自动导出则重新生成音频
      if (_settings.autoExportAudio) _exportAudio(auto: true);
    } else {
      await _tts.stop();
      if (!mounted) return;
      _editController.text = _displayText; // [v2.5.1] 多页编辑当前页
      setState(() => _editing = true);
    }
  }

  Future<void> _renameDialog() async {
    final controller = TextEditingController(text: _doc.title);
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '输入标题'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('确定')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      setState(() => _doc.title = name);
      await _storage.upsert(_doc);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey, // [v2.5.3] 供「更多」抽屉按钮打开 endDrawer
      appBar: AppBar(
        title: GestureDetector(
          onTap: (_originalMode || _editing) ? null : _renameDialog,
          child: Text(_doc.title, overflow: TextOverflow.ellipsis),
        ),
        actions: _buildAppBarActions(),
      ),
      // [v2.5.1] 文本模式顶部操作收纳抽屉(需求: 顶部仅保留切换原文 + 更多)
      endDrawer: _buildReaderDrawer(),
      body: _originalMode
          ? _buildOriginalReader()
          : (_editing ? _buildEditor() : _buildReader()),
      bottomNavigationBar: _editing ? null : _buildControls(),
    );
  }

  /// [v2.4.0] 根据模式构建 AppBar 按钮
  /// [v2.5.1] 文本模式顶部仅保留「原文」切换 + 「更多(抽屉)」, 其余操作收纳抽屉
  List<Widget> _buildAppBarActions() {
    if (_originalMode) {
      // [v2.4.0] 原文模式: 仅「文本模式」切换
      return [
        IconButton(
          icon: const Icon(Icons.text_fields),
          tooltip: '文本模式',
          onPressed: () => setState(() => _originalMode = false),
        ),
      ];
    }
    // [v2.5.1] 文本模式: 顶部仅「原文」切换(有原文时) + 「更多」按钮
    return [
      if (_doc.hasOriginal && !_editing) // [v2.4.0] 有原文时显示切换按钮
        IconButton(
          icon: const Icon(Icons.image),
          tooltip: '原文',
          onPressed: () => setState(() {
            _originalMode = true;
            // [v2.5.0] 重新进入原文模式时重置 PDF 渲染状态(避免残留旧错误)
            // [v2.5.1] 保留 _pdfCurrentPage: 与文本模式共享页码
            _pdfController = null;
            _pdfPageCount = 0;
            _pdfReady = false;
            _pdfError = null;
          }),
        ),
      IconButton(
        icon: const Icon(Icons.more_vert),
        tooltip: '更多',
        // [v2.5.3] 用 Scaffold GlobalKey 打开抽屉:
        // Scaffold.of(context) 在 AppBar actions 中向上找不到 Scaffold, 导致抽屉不弹出
        onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
      ),
    ];
  }

  /// [v2.5.1] 文本模式操作收纳抽屉。
  Widget _buildReaderDrawer() {
    final editing = _editing;
    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Text(
                editing ? '编辑文字' : '更多操作',
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
            if (editing) ...[
              ListTile(
                leading: const Icon(Icons.check),
                title: const Text('保存'),
                onTap: () {
                  Navigator.of(context).pop();
                  _toggleEdit();
                },
              ),
              ListTile(
                leading: const Icon(Icons.close),
                title: const Text('取消编辑'),
                onTap: () {
                  Navigator.of(context).pop();
                  if (!mounted) return;
                  setState(() {
                    _editing = false;
                    _editController.text = _displayText;
                  });
                },
              ),
            ] else ...[
              ListTile(
                leading: _translating
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.translate),
                title: const Text('翻译当前句子'),
                onTap: _translating
                    ? null
                    : () {
                        Navigator.of(context).pop();
                        _translate();
                      },
              ),
              ListTile(
                leading: const Icon(Icons.library_music),
                title: const Text('已生成音频'),
                onTap: _exporting
                    ? null
                    : () {
                        Navigator.of(context).pop();
                        _showAudioFilesSheet();
                      },
              ),
              ListTile(
                leading: _exporting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.download_for_offline),
                title: const Text('导出音频'),
                onTap: _exporting
                    ? null
                    : () {
                        Navigator.of(context).pop();
                        _exportAudio(auto: false);
                      },
              ),
              ListTile(
                leading: const Icon(Icons.edit),
                title: const Text('编辑文字'),
                onTap: () {
                  Navigator.of(context).pop();
                  _toggleEdit();
                },
              ),
            ],
            const Divider(),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('关闭'),
              onTap: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEditor() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: TextField(
        controller: _editController,
        maxLines: null,
        expands: true,
        textAlignVertical: TextAlignVertical.top,
        decoration: const InputDecoration(
          border: OutlineInputBorder(),
          hintText: '在此纠正识别的文字…',
        ),
      ),
    );
  }

  // [v2.4.0] 原文阅读模式: 全屏图片(可缩放) + 浮动「查看文本」按钮
  Widget _buildOriginalReader() {
    if (_doc.isImageOriginal) {
      final screenWidth = MediaQuery.of(context).size.width;
      return Stack(
        children: [
          InteractiveViewer(
            minScale: 0.5,
            maxScale: 5.0,
            child: Center(
              child: Image.file(
                File(_doc.originalFilePath!),
                fit: BoxFit.contain,
                cacheWidth: (screenWidth * 2).toInt(),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 24,
            child: Center(
              child: FloatingActionButton.extended(
                heroTag: 'view_text',
                icon: const Icon(Icons.text_fields),
                label: const Text('查看文本'),
                onPressed: _showTextSheet,
              ),
            ),
          ),
        ],
      );
    }
    if (_doc.isPdfOriginal) {
      return _buildPdfOriginalReader();
    }
    // [v2.4.0] 无原始文件时降级显示
    return _buildReader();
  }

  /// [v2.5.0] PDF 原文真实渲染(flutter_pdfview): 翻页/缩放/页码/超大文件防御/错误降级
  Widget _buildPdfOriginalReader() {
    // 超大 PDF 防御: 页数超过 200 提示改用文本模式, 避免原生渲染卡顿/内存过高
    if (_pdfPageCount > 200) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.picture_as_pdf, size: 80, color: Colors.red),
            const SizedBox(height: 16),
            Text('PDF 页数过多', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                '此 PDF 共 $_pdfPageCount 页，原样渲染可能卡顿或内存不足。\n建议使用「查看文本」阅读已识别的文字。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ),
            const SizedBox(height: 24),
            FloatingActionButton.extended(
              heroTag: 'view_text',
              icon: const Icon(Icons.text_fields),
              label: const Text('查看文本'),
              onPressed: _showTextSheet,
            ),
          ],
        ),
      );
    }
    // 坏 PDF / 加密 PDF: 渲染失败给出明确错误 + 查看文本降级入口
    if (_pdfError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 80, color: Colors.red),
            const SizedBox(height: 16),
            Text('PDF 打开失败', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _pdfError!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ),
            const SizedBox(height: 24),
            FloatingActionButton.extended(
              heroTag: 'view_text',
              icon: const Icon(Icons.text_fields),
              label: const Text('查看文本'),
              onPressed: _showTextSheet,
            ),
          ],
        ),
      );
    }
    return Stack(
      children: [
        Positioned.fill(
          child: PDFView(
            filePath: _doc.originalFilePath!,
            enableSwipe: true,
            swipeHorizontal: true,
            autoSpacing: true,
            pageFling: false,
            defaultPage: _pdfCurrentPage, // [v2.5.1] 从文本模式切回时恢复页码
            onRender: (pages) {
              if (!mounted) return;
              final pageCount = pages ?? 0;
              setState(() {
                _pdfPageCount = pageCount;
                _pdfReady = true;
              });
              // 超大 PDF 即时提醒(此时 UI 分支会切换为防御提示)
              if (pageCount > 200) {
                _toast('PDF 共 $pageCount 页，已切换为文本模式');
              }
            },
            onError: (error) {
              if (!mounted) return;
              setState(() => _pdfError = error.toString());
            },
            onPageError: (page, error) {
              // 单页渲染失败(如个别损坏页): 记录日志不打断整体阅读
              debugPrint('[v2.5.0] PDF 第 $page 页渲染失败: $error');
            },
            onPageChanged: (page, total) {
              if (!mounted) return;
              // [v2.5.2] 原文翻页联动「查看文本」弹窗与文本阅读内容
              _syncPage(page ?? _pdfCurrentPage);
            },
            onViewCreated: (vc) {
              _pdfController = vc;
            },
          ),
        ),
        // 渲染中: 显示加载指示器
        if (!_pdfReady) const Center(child: CircularProgressIndicator()),
        // [v2.5.3] 底部控制: 目录按钮独立定位在控制组左侧(left:16),
        // 控制组仅 [‹][页码][›] 三键独立居中(页码在屏幕中线)
        if (_pdfReady) ...[
          // 目录按钮(仅多页面文件显示): 独立位于左下, 与控制组同底边
          if (_pdfPageCount > 1)
            Positioned(
              left: 16,
              bottom: 24,
              child: FloatingActionButton.small(
                heroTag: 'pdf_toc',
                onPressed: _showPdfToc,
                child: const Icon(Icons.menu),
              ),
            ),
          // 控制组: [‹][页码][›] 三键居中(页码按钮在屏幕中线)
          Positioned(
            left: 0,
            right: 0,
            bottom: 24,
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FloatingActionButton.small(
                    heroTag: 'pdf_prev',
                    onPressed: _pdfCurrentPage > 0
                        ? () => _pdfController?.setPage(_pdfCurrentPage - 1)
                        : null,
                    child: const Icon(Icons.chevron_left),
                  ),
                  const SizedBox(width: 12),
                  FloatingActionButton.extended(
                    heroTag: 'view_text',
                    icon: const Icon(Icons.text_fields, size: 18),
                    label: Text('${_pdfCurrentPage + 1} / $_pdfPageCount'),
                    onPressed: _showTextSheet,
                  ),
                  const SizedBox(width: 12),
                  FloatingActionButton.small(
                    heroTag: 'pdf_next',
                    onPressed: _pdfCurrentPage < _pdfPageCount - 1
                        ? () => _pdfController?.setPage(_pdfCurrentPage + 1)
                        : null,
                    child: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// [v2.4.0] 底部弹出文本面板: 可点击句子 → 朗读, 点击翻译折叠展开译文
  void _showTextSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (context, setSheet) {
          // [v2.4.0] 保存 setSheet 以便翻译完成后刷新面板
          _sheetRebuild = () {
            if (mounted) setSheet(() {});
          };
          return DraggableScrollableSheet(
            initialChildSize: 0.55,
            minChildSize: 0.3,
            maxChildSize: 0.85,
            expand: false,
            builder: (context, scrollController) {
              return Column(
                children: [
                  // 拖拽手柄
                  Container(
                    margin: const EdgeInsets.symmetric(vertical: 8),
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey[400],
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: Row(
                      children: [
                        const Icon(Icons.text_fields, size: 18),
                        const SizedBox(width: 8),
                        const Text('识别的文字',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.bold)),
                        const Spacer(),
                        TextButton.icon(
                          icon: const Icon(Icons.close, size: 18),
                          label: const Text('关闭'),
                          onPressed: () {
                            _sheetRebuild = null;
                            Navigator.of(context).pop();
                          },
                        ),
                      ],
                    ),
                  ),
                  // [v2.5.1] 多页文件: 弹窗内页导航
                  if (_isMultiPage) _buildSheetPageNav(),
                  const Divider(height: 1),
                  Expanded(
                    child: _buildTokenText(scrollController),
                  ),
                ],
              );
            },
          );
        },
      ),
    ).then((_) {
      // [v2.4.0] 面板关闭后清理引用
      _sheetRebuild = null;
    });
  }

  /// [v2.5.1] 文本弹窗内的页导航(多页文件, 参照原文翻页按钮)。
  Widget _buildSheetPageNav() {
    final total = _pageTexts?.length ?? 0;
    if (total <= 1) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.chevron_left),
            tooltip: '上一页',
            onPressed: _pdfCurrentPage > 0 ? () => _changePage(-1) : null,
          ),
          TextButton(
            onPressed: _showPdfToc,
            child: Text('第 ${_pdfCurrentPage + 1} / $total 页',
                style: const TextStyle(fontSize: 14)),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.chevron_right),
            tooltip: '下一页',
            onPressed:
                _pdfCurrentPage < total - 1 ? () => _changePage(1) : null,
          ),
        ],
      ),
    );
  }

  /// [v2.5.2] 统一翻页同步: 更新页码并重新切分当前页文本, 联动
  /// 「查看文本」弹窗与文本阅读(原文翻页/目录跳页/文本翻页共用)。
  void _syncPage(int page) {
    final total = _pageTexts?.length ?? 0;
    if (total <= 1) return;
    final next = page.clamp(0, total - 1);
    if (next == _pdfCurrentPage) return;
    _tts.stop();
    if (!mounted) return;
    setState(() {
      _pdfCurrentPage = next;
      _contentRevision++;
      _translationRequest++;
      _translating = false;
      _currentToken = -1;
      _tokenKeys.clear();
      _translations.clear(); // 页码变化后旧译文索引失效
      _tts.setText(_displayText);
    });
    _sheetRebuild?.call();
  }

  /// [v2.5.1] 文本模式切换页面(多页文件): 重新切分当前页文本。
  void _changePage(int delta) {
    final total = _pageTexts?.length ?? 0;
    if (total <= 1) return;
    _syncPage(_pdfCurrentPage + delta);
  }

  /// [v2.5.1] PDF 目录弹窗(仅多页): 列出页码 + 每页文本摘要, 点击跳页。
  void _showPdfToc() {
    final pages = _pageTexts;
    showModalBottomSheet(
      context: context,
      builder: (_) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text('目录',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ),
          for (int i = 0; i < _pdfPageCount; i++)
            ListTile(
              dense: true,
              selected: i == _pdfCurrentPage,
              leading: Text('${i + 1}',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              title: Text(
                (pages != null &&
                        i < pages.length &&
                        pages[i].trim().isNotEmpty)
                    ? _previewLine(pages[i])
                    : '第 ${i + 1} 页',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: i == _pdfCurrentPage
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.onSurface,
                ),
              ),
              onTap: () {
                _pdfController?.setPage(i);
                Navigator.of(context).pop();
              },
            ),
        ],
      ),
    );
  }

  /// [v2.5.1] 一行文本预览(压缩空白, 截断 40 字)。
  String _previewLine(String text) {
    final s = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s.length <= 40 ? s : '${s.substring(0, 40)}…';
  }

  /// [v2.4.0] 可交互 token 文本: 点击朗读, 点击翻译在本句下方折叠译文
  /// [v2.5.2] [bottomPadding]: 多页文本模式为底部悬浮页导航预留空间
  Widget _buildTokenText(
      [ScrollController? scrollController, double bottomPadding = 24]) {
    final tokens = _tts.tokens;
    if (tokens.isEmpty) {
      return const Center(child: Text('没有可朗读的内容'));
    }
    final baseStyle = TextStyle(
      fontSize: 20,
      height: 1.9,
      color: Theme.of(context).colorScheme.onSurface,
    );
    return SingleChildScrollView(
      controller: scrollController,
      padding: EdgeInsets.fromLTRB(16, 16, 16, bottomPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (int i = 0; i < tokens.length; i++)
            _buildTokenWithTranslation(i, tokens[i], baseStyle),
        ],
      ),
    );
  }

  /// [v2.4.0] 单个 token 行 + 折叠译文(若有)
  Widget _buildTokenWithTranslation(
      int index, String tokenText, TextStyle baseStyle) {
    final isHighlighted = index == _currentToken;
    final hasTranslation = _translations.containsKey(index);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: () => _tts.playFrom(index),
          child: Container(
            key: _tokenKeys.putIfAbsent(index, () => GlobalKey()),
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
            decoration: BoxDecoration(
              color: isHighlighted
                  ? Theme.of(context).colorScheme.primary
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              tokenText,
              style: isHighlighted
                  ? baseStyle.copyWith(
                      color: Theme.of(context).colorScheme.onPrimary,
                      fontWeight: FontWeight.bold)
                  : baseStyle,
            ),
          ),
        ),
        // [v2.4.0] 折叠展开的译文
        if (hasTranslation)
          Container(
            margin: const EdgeInsets.only(top: 4, bottom: 8, left: 4),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              _translations[index]!,
              style: TextStyle(
                fontSize: 16,
                height: 1.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildReader() {
    if (_tts.tokens.isEmpty) {
      return const Center(child: Text('没有可朗读的内容'));
    }
    // [v2.5.2] 多页文件: 底部悬浮页导航(复刻原文模式 FAB 设计, 定位一致),
    // 文本区预留底部空间避免遮挡
    return Stack(
      children: [
        Positioned.fill(
          child: Column(
            children: [
              Expanded(
                child: _buildTokenText(
                  _scrollController,
                  _isMultiPage ? 96 : 24,
                ),
              ),
            ],
          ),
        ),
        if (_isMultiPage) _buildFloatingPageNav(),
      ],
    );
  }

  /// [v2.5.3] 文本模式悬浮页导航: 目录按钮独立定位在控制组左侧(left:16),
  /// 控制组仅 [‹][页码][›] 三键独立居中(页码在屏幕中线), 与原文控制条同构。
  Widget _buildFloatingPageNav() {
    final total = _pageTexts?.length ?? 0;
    if (total <= 1) return const SizedBox.shrink();
    return Stack(
      children: [
        // 目录按钮: 独立位于左下, 与控制组同底边
        Positioned(
          left: 16,
          bottom: 24,
          child: FloatingActionButton.small(
            heroTag: 'text_toc',
            onPressed: _showPdfToc,
            child: const Icon(Icons.menu),
          ),
        ),
        // 控制组: [‹][页码][›] 三键居中(页码按钮在屏幕中线)
        Positioned(
          left: 0,
          right: 0,
          bottom: 24,
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FloatingActionButton.small(
                  heroTag: 'text_prev',
                  onPressed: _pdfCurrentPage > 0 ? () => _changePage(-1) : null,
                  child: const Icon(Icons.chevron_left),
                ),
                const SizedBox(width: 12),
                FloatingActionButton.extended(
                  heroTag: 'text_page',
                  label: Text('${_pdfCurrentPage + 1} / $total'),
                  onPressed: _showPdfToc,
                ),
                const SizedBox(width: 12),
                FloatingActionButton.small(
                  heroTag: 'text_next',
                  onPressed:
                      _pdfCurrentPage < total - 1 ? () => _changePage(1) : null,
                  child: const Icon(Icons.chevron_right),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildControls() {
    final playing = _state == TtsState.playing;
    final dictation = _tts.dictationMode;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 听写模式开关
            Row(
              children: [
                const Icon(Icons.spellcheck, size: 20),
                const SizedBox(width: 8),
                const Text('听写模式'),
                const Spacer(),
                Switch(value: dictation, onChanged: _toggleDictation),
              ],
            ),
            // 常规模式:语速滑块;听写模式:书写停顿滑块
            Row(
              children: [
                Icon(dictation ? Icons.more_horiz : Icons.speed, size: 20),
                const SizedBox(width: 8),
                Text(dictation ? '书写停顿' : '语速'),
                Expanded(
                  child: dictation
                      ? Slider(
                          value: _tts.dictationGapSeconds.clamp(0.5, 10.0),
                          min: 0.5,
                          max: 10.0,
                          divisions: 19,
                          label:
                              '${_tts.dictationGapSeconds.toStringAsFixed(1)}s',
                          onChanged: (v) =>
                              setState(() => _tts.dictationGapSeconds = v),
                        )
                      : Slider(
                          value: _tts.speechRate.clamp(0.1, 1.0),
                          min: 0.1,
                          max: 1.0,
                          divisions: 9,
                          label: '${(_tts.speechRate * 100).round()}%',
                          onChanged: (v) =>
                              setState(() => _tts.setSpeechRate(v)),
                        ),
                ),
              ],
            ),
            // 听写模式:单词语速滑块
            if (dictation)
              Row(
                children: [
                  const Icon(Icons.speed, size: 20),
                  const SizedBox(width: 8),
                  const Text('单词语速'),
                  Expanded(
                    child: Slider(
                      value: _tts.dictationRate.clamp(0.1, 1.0),
                      min: 0.1,
                      max: 1.0,
                      divisions: 9,
                      label: '${(_tts.dictationRate * 100).round()}%',
                      onChanged: (v) =>
                          setState(() => _tts.setDictationRate(v)),
                    ),
                  ),
                ],
              ),
            // 听写模式:重复遍数
            if (dictation)
              Row(
                children: [
                  const Icon(Icons.repeat, size: 20),
                  const SizedBox(width: 8),
                  const Text('每词重复'),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline),
                    onPressed: _tts.repeatCount > 1
                        ? () => setState(() => _tts.repeatCount--)
                        : null,
                  ),
                  Text('${_tts.repeatCount} 遍',
                      style: const TextStyle(fontSize: 16)),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    onPressed: _tts.repeatCount < 10
                        ? () => setState(() => _tts.repeatCount++)
                        : null,
                  ),
                ],
              ),
            // 听写模式:每词重复之间的间隔(重复≥2遍时才有意义)
            if (dictation && _tts.repeatCount > 1)
              Row(
                children: [
                  const Icon(Icons.hourglass_bottom, size: 20),
                  const SizedBox(width: 8),
                  const Text('重复间隔'),
                  Expanded(
                    child: Slider(
                      value: _tts.repeatGapSeconds.clamp(0.0, 5.0),
                      min: 0.0,
                      max: 5.0,
                      divisions: 25,
                      label: '${_tts.repeatGapSeconds.toStringAsFixed(1)}s',
                      onChanged: (v) =>
                          setState(() => _tts.repeatGapSeconds = v),
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 2),
            // 播放按钮组
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton.filledTonal(
                  iconSize: 30,
                  onPressed: _stop,
                  icon: const Icon(Icons.stop),
                ),
                const SizedBox(width: 24),
                FloatingActionButton.large(
                  onPressed: _togglePlay,
                  child:
                      Icon(playing ? Icons.pause : Icons.play_arrow, size: 40),
                ),
                const SizedBox(width: 24),
                IconButton.filledTonal(
                  iconSize: 30,
                  onPressed: () {
                    final next = _currentToken + 1;
                    if (next < _tts.tokens.length) {
                      _tts.playFrom(next);
                    }
                  },
                  icon: const Icon(Icons.skip_next),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
