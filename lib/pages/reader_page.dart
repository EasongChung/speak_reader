import 'dart:io';

import 'package:flutter/material.dart';

import '../models/document.dart';
import '../services/audio_export_service.dart'
    show AudioExportService, CancellationException;
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

  final _tokenKeys = <int, GlobalKey>{};

  @override
  void initState() {
    super.initState();
    _doc = widget.document;
    _editController = TextEditingController(text: _doc.content);

    _tts.onTokenChanged = (i) {
      if (!mounted) return;
      setState(() => _currentToken = i);
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
    if (_doc.isImageOriginal) {
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

    _tts.setText(_doc.content); // 默认常规模式切句
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
      _tts.setModeAndText(v, _doc.content);
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
        _doc.content,
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

    if (!_settings.translationReady) {
      _toast('请先到「设置」完整配置翻译 API');
      return;
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
        _doc.content = _editController.text;
        _editing = false;
        _contentRevision++;
        _translationRequest++;
        _translating = false;
        _translations.clear();
        _tokenKeys.clear();
      });
      _tts.setText(_doc.content);
      _sheetRebuild?.call();
      await _storage.upsert(_doc);
      if (!mounted) return;
      _toast('已保存');
      // 内容变了,若开启了自动导出则重新生成音频
      if (_settings.autoExportAudio) _exportAudio(auto: true);
    } else {
      await _tts.stop();
      if (!mounted) return;
      _editController.text = _doc.content;
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
      appBar: AppBar(
        title: GestureDetector(
          onTap: (_originalMode || _editing) ? null : _renameDialog,
          child: Text(_doc.title, overflow: TextOverflow.ellipsis),
        ),
        actions: _buildAppBarActions(),
      ),
      body: _originalMode
          ? _buildOriginalReader()
          : (_editing ? _buildEditor() : _buildReader()),
      bottomNavigationBar: _editing ? null : _buildControls(),
    );
  }

  /// [v2.4.0] 根据模式构建 AppBar 按钮
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
    // 文本模式
    final actions = <Widget>[
      if (_doc.hasOriginal && !_editing) // [v2.4.0] 有原文时显示切换按钮
        IconButton(
          icon: const Icon(Icons.image),
          tooltip: '原文',
          onPressed: () => setState(() => _originalMode = true),
        ),
      if (!_editing) ...[
        IconButton(
          icon: const Icon(Icons.library_music),
          tooltip: '已生成音频',
          onPressed: _exporting ? null : _showAudioFilesSheet,
        ),
        IconButton(
          icon: _exporting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.download_for_offline),
          tooltip: '导出音频',
          onPressed: _exporting ? null : () => _exportAudio(auto: false),
        ),
        IconButton(
          icon: _translating
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.translate),
          tooltip: '翻译',
          onPressed: _translating ? null : _translate,
        ),
      ],
      IconButton(
        icon: Icon(_editing ? Icons.check : Icons.edit),
        tooltip: _editing ? '保存' : '编辑文字',
        onPressed: _toggleEdit,
      ),
    ];
    return actions;
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
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.picture_as_pdf, size: 80, color: Colors.red),
            const SizedBox(height: 16),
            Text('PDF 原文', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                '此文档为 PDF 格式，无法直接预览。\n请点击下方按钮查看已识别的文字。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 15,
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
    // [v2.4.0] 无原始文件时降级显示
    return _buildReader();
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

  /// [v2.4.0] 可交互 token 文本: 点击朗读, 点击翻译在本句下方折叠译文
  Widget _buildTokenText([ScrollController? scrollController]) {
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
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
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
    return _buildTokenText(_scrollController);
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
