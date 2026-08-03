import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

import '../services/audio_export_service.dart';
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

  AppSettings _s = AppSettings();
  bool _loaded = false;
  bool _obscureKey = true;
  bool _testing = false;
  String? _outputDir;
  int _loadRequest = 0;
  int _directoryRequest = 0;
  int _testRequest = 0;

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
