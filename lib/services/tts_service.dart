import 'dart:io' show File;
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// 朗读状态
enum TtsState { stopped, playing, paused }

/// 语音朗读服务:支持两种模式。
///
/// - **常规模式**(dictationMode=false):连续朗读,按句切分、句级高亮,
///   用 [speechRate] 调整单词本身语速(回归第一版行为)。
/// - **听写模式**(dictationMode=true):把文本切成词组(英文按单词、
///   中文按短句),**过滤掉纯标点**,逐个播报;每词可重复 N 遍、
///   词间留 [dictationGapSeconds] 书写停顿,可整篇循环。
///
/// 两种模式共用一套 token 列表 [tokens] 与索引高亮机制。
/// 音色使用系统默认(音色选择功能已移除)。
class TtsService {
  final FlutterTts _tts = FlutterTts();

  List<String> _tokens = [];
  int _currentIndex = 0;
  TtsState _state = TtsState.stopped;

  // 播放代次:每次 stop/pause/playFrom 自增,用于取消正在进行的循环
  int _playToken = 0;

  bool dictationMode = false;

  // 常规模式参数
  double speechRate = 0.5; // [v2.6.0] 0.1~3.0 (部分引擎 100% 仍偏慢,放宽到 300%)

  // 听写模式参数
  int repeatCount = 2;
  double dictationGapSeconds = 2.0;
  double dictationRate = 0.4; // 听写单词语速(部分单词读太快,独立于常规语速) 0.1~3.0
  double repeatGapSeconds = 0.6; // 同一词多遍重复之间的间隔(可配置)
  bool loop = false;

  void Function(int index)? onTokenChanged;
  void Function(TtsState state)? onStateChanged;
  VoidCallback? onComplete;

  TtsState get state => _state;
  int get currentIndex => _currentIndex;
  List<String> get tokens => List.unmodifiable(_tokens);

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    await _tts.setSpeechRate(speechRate);
    await _tts.setVolume(1.0);
    await _tts.awaitSpeakCompletion(true);
    await _tts.awaitSynthCompletion(true);

    _tts.setErrorHandler((msg) {
      debugPrint('TTS error: $msg');
    });
  }

  /// 设置文本;按当前模式切分为 token。
  void setText(String text) {
    _tokens = dictationMode ? _tokenizeWords(text) : _splitSentences(text);
    _currentIndex = 0;
  }

  /// 切换模式后需要重新切分(在 UI 层调用 setText 重新灌入)
  void setModeAndText(bool dictation, String text) {
    dictationMode = dictation;
    setText(text);
  }

  /// 供音频导出复用:按听写规则切词(与朗读一致)。
  List<String> tokenizeForDictation(String text) => _tokenizeWords(text);

  // ---------- 常规模式:按句切分(第一版逻辑) ----------
  static const int maxSpeakLength = 120;

  List<String> _splitSentences(String text) {
    final normalized = text.replaceAll('\r\n', '\n');
    final rawParts = normalized.split(RegExp(r'(?<=[。！？!?；;\n])'));
    final result = <String>[];
    for (final part in rawParts) {
      final sentence = part.trim();
      if (sentence.isEmpty) continue;
      result.addAll(_splitLong(sentence));
    }
    return result;
  }

  List<String> _splitLong(String text) {
    final result = <String>[];
    final segments = text.split(RegExp(r'(?<=[，,、：:])'));
    var buffer = '';

    void flushBuffer() {
      final value = buffer.trim();
      if (value.isNotEmpty) result.add(value);
      buffer = '';
    }

    for (final segment in segments) {
      var remaining = segment.trim();
      if (remaining.isEmpty) continue;

      if (buffer.isNotEmpty &&
          buffer.length + remaining.length > maxSpeakLength) {
        flushBuffer();
      }
      while (remaining.length > maxSpeakLength) {
        result.add(remaining.substring(0, maxSpeakLength));
        remaining = remaining.substring(maxSpeakLength);
      }
      if (remaining.isNotEmpty) buffer += remaining;
    }
    flushBuffer();
    return result;
  }

  // ---------- 听写模式:词组切分,过滤纯标点 ----------
  List<String> _tokenizeWords(String text) {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) return [];

    final tokens = <String>[];
    // 英文词(含数字/连字符/撇号) | 连续中文
    final re = RegExp(r"[A-Za-z0-9][A-Za-z0-9'’\-]*|[一-鿿]+");
    for (final m in re.allMatches(normalized)) {
      final t = m.group(0)!;
      final isCjk = RegExp(r'[一-鿿]').hasMatch(t);
      if (isCjk) {
        tokens.addAll(_splitCjkBySentence(t));
      } else {
        final trimmed = t.trim();
        if (trimmed.isNotEmpty) tokens.add(trimmed);
      }
    }
    // re 已只匹配"英文词"和"中文串",标点与空白天然被排除
    return tokens;
  }

  /// 中文按短句切(不做词典分词):以标点为界,过长再按长度兜底。
  /// 注意:_tokenizeWords 的正则只截取连续中文,标点已不在 t 内,
  /// 因此这里主要处理"很长的一段无标点中文"。
  List<String> _splitCjkBySentence(String s) {
    final out = <String>[];
    // 连续中文串通常无标点(标点已被上层正则排除),按每 8 字兜底成短句
    if (s.length <= 12) {
      out.add(s);
    } else {
      for (var i = 0; i < s.length; i += 8) {
        out.add(s.substring(i, i + 8 > s.length ? s.length : i + 8));
      }
    }
    return out;
  }

  // ---------------- 播放控制 ----------------

  /// 当前生效语速:听写模式用 dictationRate,常规模式用 speechRate。
  double get _effectiveRate => dictationMode ? dictationRate : speechRate;

  Future<void> play() async {
    await init();
    if (_tokens.isEmpty) return;
    if (_currentIndex >= _tokens.length) _currentIndex = 0;
    await _tts.setSpeechRate(_effectiveRate);
    _setState(TtsState.playing);
    _runLoop();
  }

  Future<void> playFrom(int index) async {
    await init();
    if (index < 0 || index >= _tokens.length) return;
    _playToken++;
    await _tts.stop();
    await _tts.setSpeechRate(_effectiveRate);
    _currentIndex = index;
    _setState(TtsState.playing);
    _runLoop();
  }

  Future<void> pause() async {
    if (_state != TtsState.playing) return;
    _playToken++;
    _setState(TtsState.paused);
    await _tts.stop();
  }

  Future<void> resume() async {
    if (_state != TtsState.paused) return;
    await _tts.setSpeechRate(_effectiveRate);
    _setState(TtsState.playing);
    _runLoop();
  }

  Future<void> stop() async {
    _playToken++;
    _setState(TtsState.stopped);
    await _tts.stop();
    _currentIndex = 0;
    onTokenChanged?.call(-1);
  }

  /// 实时调整常规模式语速(播放中立即重读当前句生效)
  Future<void> setSpeechRate(double rate) async {
    speechRate = rate.clamp(0.1, 3.0); // [v2.6.0] 上限放宽到 300%
    await _tts.setSpeechRate(speechRate);
    if (_state == TtsState.playing && !dictationMode) {
      // 重读当前句以应用新语速
      _playToken++;
      final resumeIndex = _currentIndex;
      await _tts.stop();
      _currentIndex = resumeIndex;
      _setState(TtsState.playing);
      _runLoop();
    }
  }

  /// 实时调整听写模式单词语速(播放中从当前词重新生效)
  Future<void> setDictationRate(double rate) async {
    dictationRate = rate.clamp(0.1, 3.0); // [v2.6.0] 上限放宽到 300%
    await _tts.setSpeechRate(dictationRate);
    if (_state == TtsState.playing && dictationMode) {
      _playToken++;
      final resumeIndex = _currentIndex;
      await _tts.stop();
      _currentIndex = resumeIndex;
      _setState(TtsState.playing);
      _runLoop();
    }
  }

  /// 把一段文本离线合成到 [fullPath](WAV/PCM)。
  /// 语速用 [rate](null 时按当前模式的生效语速)。导出前会先停止朗读。
  /// 返回是否成功(文件存在且非空)。
  /// 单次调用受引擎最大输入长度限制,长文本请由上层分块后多次调用再拼接。
  Future<bool> synthToFile(String text, String fullPath, {double? rate}) async {
    await init();
    _playToken++;
    await _tts.stop();
    await _tts.setSpeechRate(rate ?? _effectiveRate);
    try {
      final file = File(fullPath);
      if (await file.exists()) await file.delete();
      final ok = await _tts.synthesizeToFile(text, fullPath).timeout(
            const Duration(seconds: 90),
            onTimeout: () => false,
          );
      if (!ok) return false;
      return await file.exists() && await file.length() > 44;
    } catch (e) {
      debugPrint('synthToFile error: $e');
      return false;
    }
  }

  /// 核心播放循环:常规=逐句连读;听写=逐词组、重复、停顿。
  Future<void> _runLoop() async {
    final myToken = ++_playToken;

    while (_currentIndex < _tokens.length) {
      if (myToken != _playToken) return;
      onTokenChanged?.call(_currentIndex);

      final reps = dictationMode ? (repeatCount < 1 ? 1 : repeatCount) : 1;
      for (var r = 0; r < reps; r++) {
        if (myToken != _playToken) return;
        await _tts.speak(_tokens[_currentIndex]);
        if (myToken != _playToken) return;
        if (r < reps - 1) {
          await _sleep(repeatGapSeconds);
          if (myToken != _playToken) return;
        }
      }

      _currentIndex++;

      // 听写模式在词组间插入书写停顿;常规模式连读(无额外停顿)
      if (dictationMode &&
          dictationGapSeconds > 0 &&
          _currentIndex < _tokens.length) {
        await _sleep(dictationGapSeconds);
        if (myToken != _playToken) return;
      }

      if (_currentIndex >= _tokens.length) {
        if (loop) {
          _currentIndex = 0;
          if (dictationMode && dictationGapSeconds > 0) {
            await _sleep(dictationGapSeconds);
            if (myToken != _playToken) return;
          }
        } else {
          break;
        }
      }
    }

    if (myToken != _playToken) return;
    _setState(TtsState.stopped);
    _currentIndex = 0;
    onTokenChanged?.call(-1);
    onComplete?.call();
  }

  Future<void> _sleep(double seconds) =>
      Future.delayed(Duration(milliseconds: (seconds * 1000).round()));

  void _setState(TtsState s) {
    _state = s;
    onStateChanged?.call(s);
  }

  Future<void> dispose() async {
    _playToken++;
    await _tts.stop();
  }
}
