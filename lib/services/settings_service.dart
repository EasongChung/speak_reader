import 'package:shared_preferences/shared_preferences.dart';

/// 导出音频格式。Android TTS synthesizeToFile 原生只产出 WAV(PCM),
/// MP3 需额外转码依赖(会拖累 CI 构建),故 v2.0.0 仅提供 WAV。
enum AudioFormat {
  wav('WAV (推荐)');

  const AudioFormat(this.label);
  final String label;
  final String ext = 'wav';

  static AudioFormat fromName(String? n) =>
      AudioFormat.values.firstWhere((e) => e.name == n, orElse: () => AudioFormat.wav);
}

/// 应用设置持久化:翻译 API 配置 + 朗读参数默认值。
class AppSettings {
  // 翻译 API(OpenAI 兼容)
  String baseUrl;
  String apiKey;
  String model;

  // [v2.4.0] 移除: preferOfflineTranslation(ML Kit 已删除,纯在线翻译)

  // 朗读参数
  double wordGapSeconds; // 词间间隔(秒)
  int repeatCount; // 听写:每词重复遍数(1~10)
  double dictationGapSeconds; // 听写:词间停顿(秒,0.5~10)
  double repeatGapSeconds; // 听写:同一词重复遍数之间的间隔(秒,0~5)
  bool loop; // 整篇读完是否循环
  double speechRate; // 常规模式语速 0.1~1.0
  double dictationRate; // 听写模式单词语速 0.1~1.0(部分单词读太快,独立调)

  // 音频导出
  bool autoExportAudio; // 后台自动生成音频文件
  AudioFormat audioFormat; // 导出格式
  String? customOutputDir; // 自定义导出目录(null = 应用私有外部存储)

  AppSettings({
    this.baseUrl = 'https://api.openai.com/v1',
    this.apiKey = '',
    this.model = 'gpt-4o-mini',
    // [v2.4.0] 移除 preferOfflineTranslation
    this.wordGapSeconds = 0.3,
    this.repeatCount = 2,
    this.dictationGapSeconds = 2.0,
    this.repeatGapSeconds = 0.6,
    this.loop = false,
    this.speechRate = 0.5,
    this.dictationRate = 0.4,
    this.autoExportAudio = false,
    this.audioFormat = AudioFormat.wav,
    this.customOutputDir,
  });

  bool get translationReady => baseUrl.trim().isNotEmpty && apiKey.trim().isNotEmpty;
}

class SettingsService {
  static const _kBaseUrl = 'cfg_base_url';
  static const _kApiKey = 'cfg_api_key';
  static const _kModel = 'cfg_model';
  // [v2.4.0] 移除: _kPreferOfflineTr
  static const _kWordGap = 'cfg_word_gap';
  static const _kRepeat = 'cfg_repeat';
  static const _kDictGap = 'cfg_dict_gap';
  static const _kRepeatGap = 'cfg_repeat_gap';
  static const _kLoop = 'cfg_loop';
  static const _kRate = 'cfg_rate';
  static const _kDictRate = 'cfg_dict_rate';
  static const _kAutoExport = 'cfg_auto_export';
  static const _kAudioFmt = 'cfg_audio_fmt';
  static const _kOutDir = 'cfg_out_dir';

  Future<AppSettings> load() async {
    final p = await SharedPreferences.getInstance();
    final def = AppSettings();
    return AppSettings(
      baseUrl: p.getString(_kBaseUrl) ?? def.baseUrl,
      apiKey: p.getString(_kApiKey) ?? def.apiKey,
      model: p.getString(_kModel) ?? def.model,
      // [v2.4.0] 移除: preferOfflineTranslation
      wordGapSeconds: p.getDouble(_kWordGap) ?? def.wordGapSeconds,
      repeatCount: p.getInt(_kRepeat) ?? def.repeatCount,
      dictationGapSeconds: p.getDouble(_kDictGap) ?? def.dictationGapSeconds,
      repeatGapSeconds: p.getDouble(_kRepeatGap) ?? def.repeatGapSeconds,
      loop: p.getBool(_kLoop) ?? def.loop,
      speechRate: p.getDouble(_kRate) ?? def.speechRate,
      dictationRate: p.getDouble(_kDictRate) ?? def.dictationRate,
      autoExportAudio: p.getBool(_kAutoExport) ?? def.autoExportAudio,
      audioFormat: AudioFormat.fromName(p.getString(_kAudioFmt)),
      customOutputDir: p.getString(_kOutDir),
    );
  }

  Future<void> save(AppSettings s) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kBaseUrl, s.baseUrl.trim());
    await p.setString(_kApiKey, s.apiKey.trim());
    await p.setString(_kModel, s.model.trim());
    // [v2.4.0] 移除: _kPreferOfflineTr
    await p.setDouble(_kWordGap, s.wordGapSeconds);
    await p.setInt(_kRepeat, s.repeatCount);
    await p.setDouble(_kDictGap, s.dictationGapSeconds);
    await p.setDouble(_kRepeatGap, s.repeatGapSeconds);
    await p.setBool(_kLoop, s.loop);
    await p.setDouble(_kRate, s.speechRate);
    await p.setDouble(_kDictRate, s.dictationRate);
    await p.setBool(_kAutoExport, s.autoExportAudio);
    await p.setString(_kAudioFmt, s.audioFormat.name);
    if (s.customOutputDir == null) {
      await p.remove(_kOutDir);
    } else {
      await p.setString(_kOutDir, s.customOutputDir!);
    }
  }
}
