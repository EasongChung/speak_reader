import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/local_model.dart';
import '../services/audio_export_service.dart';
import '../services/llama_cpp_engine.dart';
import '../services/local_model_service.dart';
import '../services/settings_service.dart';
import '../services/translation_service.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _service = SettingsService();
  final _translation = TranslationService();
  final _audioExport = AudioExportService();
  // [v2.5.0] 本地模型(离线推理)
  final _localModels = LocalModelService();
  final _engine = LlamaCppEngine.instance;

  AppSettings _s = AppSettings();
  bool _loaded = false;
  bool _obscureKey = true;
  bool _testing = false;
  String? _outputDir;
  int _loadRequest = 0;
  int _directoryRequest = 0;
  int _testRequest = 0;
  // [v2.5.0] 本地模型状态
  List<LocalModelInfo> _models = const [];
  String _modelsDir = '';
  int _modelsTotalSize = 0;
  bool _modelsLoading = false;
  int _modelRequest = 0;
  // [v2.5.1] 扫描下载目录状态
  bool _scanningModels = false;
  int _scanRequest = 0;
  // [v2.5.2] 「所有文件访问」权限状态(读取 Download/外部目录 .gguf 必需)
  bool _storageAccess = false;

  late TextEditingController _baseCtrl;
  late TextEditingController _keyCtrl;
  late TextEditingController _modelCtrl;

  @override
  void initState() {
    super.initState();
    _baseCtrl = TextEditingController();
    _keyCtrl = TextEditingController();
    _modelCtrl = TextEditingController();
    _load();
    // [v2.5.0] 首次进入设置页即扫描本地模型
    _refreshModels();
  }

  Future<void> _load() async {
    final request = ++_loadRequest;
    try {
      final settings = await _service.load();
      if (!mounted || request != _loadRequest) return;
      _audioExport.customDir = settings.customOutputDir;
      final outputDir = await _audioExport.outputDirPath();
      if (!mounted || request != _loadRequest) return;
      setState(() {
        _s = settings;
        _outputDir = outputDir;
        _baseCtrl.text = settings.baseUrl;
        _keyCtrl.text = settings.apiKey;
        _modelCtrl.text = settings.model;
        _loaded = true;
      });
    } catch (e) {
      if (!mounted || request != _loadRequest) return;
      setState(() => _loaded = true);
      _toast('加载设置失败:$e');
    }
  }

  @override
  void dispose() {
    _baseCtrl.dispose();
    _keyCtrl.dispose();
    _modelCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    try {
      await _persist();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已保存')));
      }
    } catch (e) {
      if (mounted) _toast('保存失败: $e');
    }
  }

  /// 持久化当前设置（冻结文本框内容为快照后串行保存）。
  Future<void> _persist() async {
    final snapshot = _s.copyWith(
      baseUrl: _baseCtrl.text,
      apiKey: _keyCtrl.text,
      model: _modelCtrl.text,
    );
    await _service.save(snapshot);
    _s = snapshot;
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _pickOutputDir() async {
    final request = ++_directoryRequest;
    try {
      final dir = await FilePicker.platform.getDirectoryPath();
      if (dir == null || !mounted || request != _directoryRequest) return;
      final writable = await _audioExport.isDirWritable(dir);
      if (!mounted || request != _directoryRequest) return;
      if (!writable) {
        _toast('该目录不可写(可能受系统限制),已保留原目录');
        return;
      }
      _s = _s.copyWith(customOutputDir: dir);
      _audioExport.customDir = dir;
      _outputDir = dir;
      await _persist();
      _toast('导出目录已设为:$dir');
    } catch (e) {
      if (mounted && request == _directoryRequest) {
        _toast('选择目录失败:$e');
      }
    }
  }

  Future<void> _resetOutputDir() async {
    final request = ++_directoryRequest;
    try {
      _outputDir = await _audioExport.outputDirPath();
    } catch (_) {}
    if (!mounted || request != _directoryRequest) return;
    _s = _s.copyWith(clearCustomOutputDir: true);
    _audioExport.customDir = null;
    try {
      await _persist();
    } catch (e) {
      _toast('保存失败:$e');
      return;
    }
    if (mounted && request == _directoryRequest) setState(() {});
    _toast('已恢复默认目录');
  }

  Future<void> _testConnection() async {
    if (_testing) return;
    setState(() => _testing = true);
    final request = ++_testRequest;
    final snapshot = _s.copyWith(
      baseUrl: _baseCtrl.text,
      apiKey: _keyCtrl.text,
      model: _modelCtrl.text,
    );
    try {
      await _service.save(snapshot);
      if (!mounted || request != _testRequest) return;
      _s = snapshot;
      final r =
          await _translation.translate('Hello, world.', settings: snapshot);
      if (mounted && request == _testRequest) {
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('连接成功 ✅'),
            content: Text('测试翻译结果:\n$r'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('好的')),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted && request == _testRequest) {
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('连接失败 ❌'),
            content: Text('$e'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('好的')),
            ],
          ),
        );
      }
    } finally {
      if (mounted && request == _testRequest) {
        setState(() => _testing = false);
      }
    }
  }

  // ================= [v2.5.0] 本地模型(离线推理) =================

  /// 刷新模型清单与存储占用。
  Future<void> _refreshModels() async {
    final request = ++_modelRequest;
    setState(() => _modelsLoading = true);
    try {
      final models = await _localModels.listModels();
      final total = await _localModels.getTotalSize();
      final dir = await _localModels.getModelsDir();
      // [v2.5.2] 同步检测「所有文件访问」权限(影响 Download/外部目录模型读取)
      final storage = await _hasAllFilesAccess();
      if (!mounted || request != _modelRequest) return;
      setState(() {
        _models = models;
        _modelsTotalSize = total;
        _modelsDir = dir.path;
        _storageAccess = storage;
      });
    } catch (e) {
      if (mounted && request == _modelRequest) _toast('扫描模型失败:$e');
    } finally {
      if (mounted && request == _modelRequest) {
        setState(() => _modelsLoading = false);
      }
    }
  }

  /// [v2.5.2] 是否已授予「所有文件访问」(Android 11+ 读取 Download/外部 .gguf 必需)。
  Future<bool> _hasAllFilesAccess() async {
    try {
      return await Permission.manageExternalStorage.isGranted;
    } catch (_) {
      return false; // 旧版 Android/不支持的设备视为未授权, 不影响主流程
    }
  }

  /// [v2.5.2] 请求「所有文件访问」权限, 授权成功后刷新模型清单。
  Future<void> _requestStorageAccess() async {
    final status = await Permission.manageExternalStorage.request();
    final granted = status.isGranted;
    if (!mounted) return;
    setState(() => _storageAccess = granted);
    if (granted) {
      _toast('已获得「所有文件访问」权限');
      await _refreshModels();
    } else if (status.isPermanentlyDenied) {
      _toast('权限被永久拒绝,请在系统设置中手动开启「所有文件访问」');
      await openAppSettings();
    } else {
      _toast('未授权「所有文件访问」, Download 目录中的模型仍无法读取');
    }
  }

  /// [v2.5.1] 清除扫描目录记录并刷新模型清单。
  Future<void> _clearScanDir() async {
    await _localModels.setScanDir(null);
    await _refreshModels();
    if (mounted) _toast('已清除扫描目录记录');
  }

  /// [v2.5.1] 扫描「下载目录」模型并记录路径直接加载。
  ///
  /// 优先直扫系统 Download 目录(权限允许时); 未发现任何模型时,
  /// 弹系统目录选择器让用户授权一次下载目录, 记录路径后每次进设置页自动重扫。
  Future<void> _scanDownloadModels() async {
    if (_scanningModels) return;
    final request = ++_scanRequest;
    setState(() => _scanningModels = true);
    try {
      final found = await _localModels.scanDownloadDir();
      if (found.isEmpty && mounted && request == _scanRequest) {
        // 直扫无果 → 目录选择器授权(兼容 Android 11+ 分区存储)
        final dir = await FilePicker.platform.getDirectoryPath();
        if (dir == null || !mounted || request != _scanRequest) return;
        await _localModels.setScanDir(dir);
      }
      await _refreshModels();
      if (mounted && request == _scanRequest) {
        _toast(found.isEmpty
            ? '未在所选目录发现模型文件'
            : '发现 ${found.length} 个模型(来自下载目录, 已记录路径)');
      }
    } catch (e) {
      if (mounted && request == _scanRequest) _toast('扫描失败:$e');
    } finally {
      if (mounted && request == _scanRequest) {
        setState(() => _scanningModels = false);
      }
    }
  }

  /// 加载模型到推理引擎(>3GB 先二次确认, 失败提示回退在线)。
  Future<void> _loadModel(LocalModelInfo model) async {
    if (_engine.isLoaded && _engine.loadedModelName == model.fileName) {
      _toast('该模型已加载:${model.fileName}');
      return;
    }
    // Sprint 6.5 内存保护: 大模型加载前二次确认
    if (model.isLarge) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('大模型提醒'),
          content: Text(
            '${model.fileName} 体积约 ${model.sizeLabel}，'
            '加载后可能占用大量内存(建议 ≥8GB 内存设备)。\n\n继续加载吗?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('继续加载'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }

    _toast('正在加载模型,请稍候…(首次加载可能较慢)');
    try {
      await _engine.load(model);
      if (!mounted) return;
      setState(() {});
      _toast('模型已加载:${model.fileName}');
    } catch (e) {
      if (mounted) _toast('$e');
    }
  }

  /// 卸载当前模型。
  Future<void> _unloadModel() async {
    try {
      await _engine.dispose();
    } catch (_) {}
    if (!mounted) return;
    setState(() {});
    _toast('已卸载模型');
  }

  /// 删除模型文件(及配套 .mmproj), 若正被加载先卸载。
  Future<void> _deleteModel(LocalModelInfo model) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除模型'),
        content: Text('确定删除 ${model.fileName} 吗?\n'
            '${model.mmprojPath != null ? "将同时删除配套的 .mmproj 文件。" : ""}'
            '此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    if (_engine.loadedModelName == model.fileName) {
      await _engine.dispose();
    }
    try {
      await _localModels.deleteModel(model);
      await _refreshModels();
      if (mounted) _toast('已删除:${model.fileName}');
    } catch (e) {
      if (mounted) _toast('删除失败:$e');
    }
  }

  /// 单条模型展示卡片。
  Widget _buildModelTile(LocalModelInfo m) {
    final loaded = _engine.isLoaded && _engine.loadedModelName == m.fileName;
    // [v2.5.1] 扫描来源模型带标签
    final fromScan = m.source == LocalModelSource.scan;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: Icon(
          m.canOcr ? Icons.auto_awesome : Icons.memory,
          color: m.canOcr ? Colors.deepPurple : Colors.blueGrey,
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(m.fileName,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            if (fromScan) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text('下载目录',
                    style: TextStyle(fontSize: 10, color: Colors.orange)),
              ),
            ],
          ],
        ),
        subtitle: Text(
          '${m.sizeLabel} · ${m.canOcr ? "多模态(可离线翻译+OCR)" : "文本(可离线翻译)"}'
          '${fromScan ? "\n来自下载目录, 记录路径直接加载(未复制文件)" : ""}',
          style: const TextStyle(fontSize: 12),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loaded)
              const Padding(
                padding: EdgeInsets.only(right: 8),
                child: Text('已加载',
                    style: TextStyle(color: Colors.green, fontSize: 12)),
              ),
            IconButton(
              icon: Icon(loaded ? Icons.refresh : Icons.play_arrow),
              tooltip: loaded ? '重新加载' : '加载模型',
              onPressed: () => _loadModel(m),
            ),
            // [v2.5.1] 扫描来源模型不提供应用内删除
            if (m.canDelete)
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: '删除',
                onPressed: () => _deleteModel(m),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('保存'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionTitle('翻译 / 图片识别 API(OpenAI 兼容)'),
          const Text(
            '支持 OpenAI / DeepSeek / 通义千问 / 智谱 / Kimi 等。\n'
            '填对方的接口地址(到 /v1 为止)、密钥、模型名。\n'
            '📷 拍照/选图的文字识别用视觉大模型完成,'
            '请填写支持图片输入的模型(如 gpt-4o、qwen-vl-max、glm-4v)。',
            style: TextStyle(color: Colors.grey, fontSize: 13),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _baseCtrl,
            decoration: const InputDecoration(
              labelText: '接口地址 (baseURL)',
              hintText: 'https://api.deepseek.com/v1',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _keyCtrl,
            obscureText: _obscureKey,
            decoration: InputDecoration(
              labelText: 'API 密钥 (Key)',
              hintText: 'sk-...',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon:
                    Icon(_obscureKey ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _obscureKey = !_obscureKey),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _modelCtrl,
            decoration: const InputDecoration(
              labelText: '模型名 (model)',
              hintText: 'gpt-4o-mini / deepseek-chat / qwen-plus',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _testing ? null : _testConnection,
            icon: _testing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.wifi_tethering),
            label: Text(_testing ? '测试中…' : '测试连接'),
          ),
          // [v2.5.0] 翻译通道策略
          const SizedBox(height: 12),
          Row(
            children: [
              const Text('翻译通道'),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<TranslationStrategy>(
                  // Flutter 3.29 使用 value；新 SDK 建议 initialValue。
                  // ignore: deprecated_member_use
                  value: _s.translationStrategy,
                  decoration: const InputDecoration(
                      isDense: true, border: OutlineInputBorder()),
                  items: [
                    for (final s in TranslationStrategy.values)
                      DropdownMenuItem(value: s, child: Text(s.label)),
                  ],
                  onChanged: (v) async {
                    if (v == null) return;
                    setState(() => _s.translationStrategy = v);
                    await _persist();
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            '「自动」:有网优先在线,失败自动切离线 GGUF;'
            '「仅离线」需先到下方本地模型分区加载模型。',
            style: TextStyle(color: Colors.grey, fontSize: 13),
          ),
          const Divider(height: 40),

          // ================= [v2.5.0] 本地模型(离线推理) =================
          _sectionTitle('本地模型(离线翻译 / 离线 OCR)'),
          Text(
            '在手机安装 GGUF 模型后,即使断网也能离线翻译与图片识别。\n'
            '模型不内置 APK,可自行下载放入:\n'
            '$_modelsDir\n'
            '(该目录为应用专属 media 目录,文件管理器可直接访问写入;'
            '也可点下方「扫描下载目录」直接加载 Download 中的模型,免去手动放置;\n'
            '读取 Download/外部目录中的 .gguf 需开启「所有文件访问」权限)\n'
            '已安装: ${_models.length} 个, 占用 ${_formatBytes(_modelsTotalSize)}',
            style: TextStyle(color: Colors.grey, fontSize: 13),
          ),
          const SizedBox(height: 8),
          // [v2.5.2] 未授予「所有文件访问」时的提示横幅
          if (!_storageAccess) ...[
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              color: Theme.of(context)
                  .colorScheme
                  .errorContainer
                  .withValues(alpha: 0.35),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded, size: 20),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        '读取 Download/扫描目录中的 .gguf 模型需授权'
                        '「所有文件访问」,请先授权后重试。',
                        style: TextStyle(fontSize: 13),
                      ),
                    ),
                    FilledButton(
                      onPressed: _requestStorageAccess,
                      child: const Text('立即授权'),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (_modelsLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_models.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text('未安装本地模型。推荐:',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  SizedBox(height: 4),
                  Text(
                      '• 离线翻译: MiniCPM5-1B-Q4_K_M.gguf (约 0.8GB, 4GB 内存设备可用)\n'
                      '• 离线翻译+OCR: MiniCPM-V 4.6 (gguf + mmproj)\n'
                      '• 高端: gemma-4-E2B-it (gguf + mmproj, 建议 8GB+ 内存)\n'
                      '下载后放入上述目录点「刷新」,或点下方「扫描下载目录」直接加载 Download 中的模型。',
                      style: TextStyle(color: Colors.grey, fontSize: 13)),
                ],
              ),
            )
          else
            for (final m in _models) _buildModelTile(m),
          Row(
            children: [
              TextButton.icon(
                onPressed: _modelsLoading ? null : _refreshModels,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('刷新'),
              ),
              if (_engine.isLoaded)
                TextButton.icon(
                  onPressed: _unloadModel,
                  icon: const Icon(Icons.stop_circle_outlined, size: 18),
                  label: Text('卸载:${_engine.loadedModelName}',
                      style: const TextStyle(fontSize: 12)),
                ),
              const Spacer(),
              if (_engine.isLoaded)
                Text('已加载 ${_engine.loadedModelName}',
                    style: const TextStyle(color: Colors.green, fontSize: 12)),
            ],
          ),
          // [v2.5.1] 扫描下载目录: 记录路径直接加载, 免去手动放置
          Row(
            children: [
              TextButton.icon(
                onPressed: _scanningModels ? null : _scanDownloadModels,
                icon: _scanningModels
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.folder_open, size: 18),
                label: Text(_scanningModels ? '扫描中…' : '扫描下载目录'),
              ),
              TextButton.icon(
                onPressed: _scanningModels ? null : _clearScanDir,
                icon: const Icon(Icons.link_off, size: 18),
                label: const Text('清除扫描记录'),
              ),
            ],
          ),
          const Text(
            '「扫描下载目录」优先查找系统 Download 中的 .gguf 模型;'
            '若权限不足会提示选择一次目录,路径会被记住并在每次进入本页自动重扫。',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
          const Divider(height: 40),

          // [v2.4.0] 移除: 翻译方式 SwitchListTile(ML Kit 已删除)

          _sectionTitle('朗读参数'),
          _slider(
            '常规模式·语速',
            _s.speechRate,
            0.1,
            1.0,
            (v) => setState(() => _s.speechRate = v),
            '${(_s.speechRate * 100).round()}%',
          ),
          const Divider(height: 24),
          _sectionTitle('听写模式'),
          _slider(
            '听写·单词语速(部分单词读太快可调慢)',
            _s.dictationRate,
            0.1,
            1.0,
            (v) => setState(() => _s.dictationRate = v),
            '${(_s.dictationRate * 100).round()}%',
          ),
          _stepper(
            '每个词重复遍数',
            _s.repeatCount,
            1,
            10,
            (v) => setState(() => _s.repeatCount = v),
          ),
          _slider(
            '每词重复之间的间隔(重复≥2遍时生效)',
            _s.repeatGapSeconds,
            0.0,
            5.0,
            (v) => setState(() => _s.repeatGapSeconds = v),
            '${_s.repeatGapSeconds.toStringAsFixed(1)} 秒',
          ),
          _slider(
            '听写·词间停顿(留书写时间)',
            _s.dictationGapSeconds,
            0.5,
            10.0,
            (v) => setState(() => _s.dictationGapSeconds = v),
            '${_s.dictationGapSeconds.toStringAsFixed(1)} 秒',
          ),
          SwitchListTile(
            title: const Text('整篇读完后循环'),
            value: _s.loop,
            onChanged: (v) => setState(() => _s.loop = v),
            contentPadding: EdgeInsets.zero,
          ),
          const SizedBox(height: 8),
          const Text(
            '提示:这些是默认值,阅读页里也能随时快速调整。',
            style: TextStyle(color: Colors.grey, fontSize: 13),
          ),
          const SizedBox(height: 24),

          // ================= 音频导出 =================
          const Divider(height: 40),
          _sectionTitle('音频导出'),
          SwitchListTile(
            title: const Text('朗读时自动生成音频文件'),
            subtitle: const Text('开启后,进入阅读页时后台自动导出一份 WAV'),
            value: _s.autoExportAudio,
            onChanged: (v) async {
              setState(() => _s.autoExportAudio = v);
              await _persist();
            },
            contentPadding: EdgeInsets.zero,
          ),
          Row(
            children: [
              const Text('格式'),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<AudioFormat>(
                  // Flutter 3.29 使用 value；新 SDK 建议 initialValue。
                  // ignore: deprecated_member_use
                  value: _s.audioFormat,
                  decoration: const InputDecoration(
                      isDense: true, border: OutlineInputBorder()),
                  items: [
                    for (final f in AudioFormat.values)
                      DropdownMenuItem(value: f, child: Text(f.label)),
                  ],
                  onChanged: (v) async {
                    if (v == null) return;
                    setState(() => _s.audioFormat = v);
                    await _persist();
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickOutputDir,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('选择导出目录'),
                ),
              ),
              if (_s.customOutputDir != null) ...[
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _resetOutputDir,
                  child: const Text('恢复默认'),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '当前输出目录:\n$_outputDir\n'
            '${_s.customOutputDir != null ? "(自定义)" : "(默认:应用私有目录,无需权限)"}\n'
            '文件可用系统文件管理器查看;阅读页也可手动"导出音频"并分享。\n'
            '若所选目录不可写会自动回退默认目录。MP3 暂不支持(Android 离线 TTS 仅产出 WAV)。',
            style: const TextStyle(color: Colors.grey, fontSize: 13),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _sectionTitle(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(t,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
      );

  Widget _slider(String label, double value, double min, double max,
      ValueChanged<double> onChanged, String valueText) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label),
            Text(valueText, style: const TextStyle(color: Colors.grey)),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: ((max - min) / 0.1).round(),
          onChanged: onChanged,
        ),
      ],
    );
  }

  /// [v2.5.0] 字节数格式化。
  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    return '${(mb / 1024).toStringAsFixed(2)} GB';
  }

  Widget _stepper(
      String label, int value, int min, int max, ValueChanged<int> onChanged) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label),
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.remove_circle_outline),
              onPressed: value > min ? () => onChanged(value - 1) : null,
            ),
            Text('$value', style: const TextStyle(fontSize: 16)),
            IconButton(
              icon: const Icon(Icons.add_circle_outline),
              onPressed: value < max ? () => onChanged(value + 1) : null,
            ),
          ],
        ),
      ],
    );
  }
}
