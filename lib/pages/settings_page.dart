import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/audio_export_service.dart';
import '../services/offline_translation_coordinator.dart';
import '../services/offline_translation_service.dart';
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
  String _appVersion = '2.5.1'; // [v2.6.0] 运行时版本号,initState 加载后实时更新
  int _loadRequest = 0;
  int _directoryRequest = 0;
  int _testRequest = 0;

  // ---- [G4.4] 离线翻译状态 ----
  /// null = 尚未探测完成(区块显示加载中)。
  bool? _offlineAvailable;
  String? _offlineReason;

  /// 已导入到私有目录的模型组 id。
  List<String> _importedGroups = const [];
  bool _offlineBusy = false;

  /// 试译读数(耗时 + 译文), 供 G4.4 评测速度与质量。
  String? _probeResult;
  int _offlineRequest = 0;
  late TextEditingController _probeCtrl;

  late TextEditingController _baseCtrl;
  late TextEditingController _keyCtrl;
  late TextEditingController _modelCtrl;

  @override
  void initState() {
    super.initState();
    _baseCtrl = TextEditingController();
    _keyCtrl = TextEditingController();
    _modelCtrl = TextEditingController();
    _probeCtrl = TextEditingController(text: '这是一个测试句子。');
    _load();
    _loadVersion();
    _probeOffline();
  }

  /// [G4.4] 探测离线翻译可用性与已导入模型组。
  ///
  /// 失败一律落到「不可用 + 原因」, 不抛到 UI —— 探测本身失败与
  /// 「设备不支持」对用户是同一件事: 离线用不了。
  Future<void> _probeOffline() async {
    final request = ++_offlineRequest;
    try {
      final available = await OfflineTranslationService.isAvailable();
      final reason = available
          ? null
          : await OfflineTranslationService.unavailableReason();
      final groups = available
          ? await OfflineTranslationService.importedGroups()
          : const <String>[];
      if (!mounted || request != _offlineRequest) return;
      setState(() {
        _offlineAvailable = available;
        _offlineReason = reason;
        _importedGroups = groups;
      });
    } catch (e) {
      if (!mounted || request != _offlineRequest) return;
      setState(() {
        _offlineAvailable = false;
        _offlineReason = '探测失败:$e';
      });
    }
  }

  /// [v2.6.0] 读取运行时版本号(版本名),显示在页面底部;失败则保留默认值。
  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() => _appVersion = info.version);
    } catch (_) {}
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
    _probeCtrl.dispose();
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

          // [G4.4] 离线翻译(slimt)。与 v2.4.0 移除的 ML Kit 无关, 是另一套引擎。
          ..._offlineSection(),

          _sectionTitle('朗读参数'),
          _slider(
            '常规模式·语速(部分引擎偏慢可调至 300%)',
            _s.speechRate,
            0.1,
            3.0, // [v2.6.0] 上限放宽到 300%
            (v) => setState(() => _s.speechRate = v),
            '${(_s.speechRate * 100).round()}%',
          ),
          const Divider(height: 24),
          _sectionTitle('听写模式'),
          _slider(
            '听写·单词语速(部分单词读太快可调慢)',
            _s.dictationRate,
            0.1,
            3.0, // [v2.6.0] 上限放宽到 300%
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

          // [v2.6.0] 版本信息 + 仓库链接(本 fork 与原创仓库)
          const Divider(height: 40),
          Center(
            child: Text('语音朗读 v$_appVersion',
                style: const TextStyle(color: Colors.grey, fontSize: 13)),
          ),
          const SizedBox(height: 8),
          // [v2.6.1] 居中单行「标签 + 图标 + <作者>/<仓库名>」超链接, 省略 URL 避免转行
          _repoLink(Icons.code, '本仓库', 'EasongChung/speak_reader',
              'https://github.com/EasongChung/speak_reader'),
          _repoLink(Icons.star_border, '原创仓库', 'Aceworry/speak_reader',
              'https://github.com/Aceworry/speak_reader'),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  /// [v2.6.0] 单条仓库链接行: 图标 + 短标签 + 网址文本(整行可点击打开)。
  /// [v2.6.1] 标签 + 图标 + <作者>/<仓库名> 超链接, 居中单行不转行。
  Widget _repoLink(IconData icon, String label, String short, String url) {
    return Center(
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _openUrl(url),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label,
                  style: const TextStyle(color: Colors.grey, fontSize: 13)),
              const SizedBox(width: 6),
              Icon(icon, size: 16, color: Colors.grey),
              const SizedBox(width: 6),
              Flexible(
                child: Text(short,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.blueAccent,
                        fontSize: 13,
                        decoration: TextDecoration.underline)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// [v2.6.0] 用系统浏览器打开指定网址(href 超链接)。
  Future<void> _openUrl(String url) async {
    final ok =
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    if (!ok && mounted) _toast('无法打开链接,请手动访问:$url');
  }

  // ---------------- [G4.4] 离线翻译 ----------------

  /// 离线翻译区块。返回 List 以便在 ListView 里用展开运算符插入。
  List<Widget> _offlineSection() {
    final available = _offlineAvailable;
    return [
      _sectionTitle('离线翻译(实验)'),
      if (available == null)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Row(children: [
            SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 12),
            Text('检测中…', style: TextStyle(color: Colors.grey)),
          ]),
        )
      else ...[
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _s.preferOfflineTranslation && available,
          // 不可用时置灰而非隐藏: 让用户知道有这个能力、以及为何用不了。
          onChanged: available
              ? (v) => setState(() => _s.preferOfflineTranslation = v)
              : null,
          title: const Text('优先使用离线翻译'),
          subtitle: Text(
            available
                ? '不联网、不耗 API 额度。模型未覆盖的语向会自动改用在线翻译。'
                : (_offlineReason ?? '当前设备不支持'),
            style: TextStyle(
              fontSize: 12,
              color: available ? Colors.grey : Colors.orange.shade800,
            ),
          ),
        ),
        if (available) ...[
          const SizedBox(height: 4),
          Text(
            _importedGroups.isEmpty
                ? '尚未导入模型。需先下载对应语向的模型包(zip)，'
                    '再选择该 zip 导入(会解压进应用私有目录)。'
                : '已导入:${_importedGroups.map(_groupLabel).join('、')}',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              OutlinedButton.icon(
                onPressed: _offlineBusy ? null : _importOfflineModels,
                icon: _offlineBusy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.archive_outlined),
                label: Text(_offlineBusy ? '导入中…' : '导入模型包(zip)'),
              ),
              for (final id in _importedGroups)
                OutlinedButton.icon(
                  onPressed:
                      _offlineBusy ? null : () => _deleteOfflineGroup(id),
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: Text('删除 ${_groupLabel(id)}'),
                ),
            ],
          ),
          if (_importedGroups.isNotEmpty) ...[
            const SizedBox(height: 12),
            // 试译入口: G4.4 要测速度与质量, 没有读数就只能靠手感。
            TextField(
              controller: _probeCtrl,
              maxLines: 2,
              minLines: 1,
              decoration: const InputDecoration(
                labelText: '试译(中↔英自动判向)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            Row(children: [
              OutlinedButton.icon(
                onPressed: _offlineBusy ? null : _probeTranslate,
                icon: const Icon(Icons.translate),
                label: const Text('离线试译'),
              ),
            ]),
            if (_probeResult != null) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.grey.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SelectableText(
                  _probeResult!,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ],
        ],
      ],
      const Divider(height: 40),
    ];
  }

  /// 语向 id 的可读形式，如 `zhen` → `中→英`。
  String _groupLabel(String id) {
    const labels = {'zhen': '中→英', 'enzh': '英→中'};
    return labels[id] ?? id;
  }

  /// 选 zip 模型包 → 解压导入。
  Future<void> _importOfflineModels() async {
    setState(() => _offlineBusy = true);
    try {
      final zipUri = await OfflineTranslationService.pickModelZip();
      if (zipUri == null) return; // 用户取消
      final imported = await OfflineTranslationService.importModelZip(zipUri);
      if (imported.isEmpty) {
        _toast('该 zip 中没有找到成组的模型文件');
        return;
      }
      // 导入会改变可加载集合, 让协调器重新与原生侧对齐。
      OfflineTranslationCoordinator.instance.invalidate();
      final groups = await OfflineTranslationService.importedGroups();
      if (!mounted) return;
      setState(() => _importedGroups = groups);
      _toast('已导入 ${groups.map(_groupLabel).join('、')}');
    } catch (e) {
      _toast('导入失败:$e');
    } finally {
      if (mounted) setState(() => _offlineBusy = false);
    }
  }

  Future<void> _deleteOfflineGroup(String id) async {
    setState(() => _offlineBusy = true);
    try {
      await OfflineTranslationService.deleteGroup(id);
      // 原生侧 deleteGroup 会先卸载再删文件; 协调器若还记着「已加载」,
      // 下次翻译会跳过加载直接翻, 必然失败。
      OfflineTranslationCoordinator.instance.invalidate();
      final imported = await OfflineTranslationService.importedGroups();
      if (!mounted) return;
      setState(() {
        _importedGroups = imported;
        _probeResult = null;
      });
    } catch (e) {
      _toast('删除失败:$e');
    } finally {
      if (mounted) setState(() => _offlineBusy = false);
    }
  }

  /// 试译并显示耗时 —— G4.4 的速度读数来源。
  Future<void> _probeTranslate() async {
    final text = _probeCtrl.text.trim();
    if (text.isEmpty) {
      _toast('请先输入要翻译的文字');
      return;
    }
    setState(() {
      _offlineBusy = true;
      _probeResult = null;
    });
    try {
      final outcome =
          await OfflineTranslationCoordinator.instance.translate(text);
      if (!mounted) return;
      setState(() {
        _probeResult = outcome == null
            ? '没有匹配该语向的模型(已导入:'
                '${_importedGroups.map(_groupLabel).join('、')})'
            : '[${_groupLabel(outcome.groupId)}] '
                '${outcome.elapsed.inMilliseconds} ms\n${outcome.text}';
      });
    } catch (e) {
      // PoC 阶段离线错误必须可见: 静默回落会让「离线没跑起来」
      // 伪装成「离线跑了但质量一般」, 两者排查方向完全相反。
      if (mounted) setState(() => _probeResult = '离线翻译失败:$e');
    } finally {
      if (mounted) setState(() => _offlineBusy = false);
    }
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
