import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'tts_service.dart';

/// 音频导出服务：把文本离线合成为 WAV 文件并落盘。
///
/// 每次导出使用独占暂存目录，最终通过原子 rename 发布到稳定路径。
/// 稳定路径基于文档 ID 和模式，不依赖标题唯一性。
/// 导出被主动取消（页面销毁时触发）。
class CancellationException implements Exception {
  final String message;
  const CancellationException([this.message = '导出已取消']);
  @override
  String toString() => 'CancellationException: $message';
}

class AudioExportService {
  static const _dirName = 'speak_reader_audio';
  static const _maxChunk = 2000;
  static final Random _random = Random.secure();

  String? customDir;

  Future<Directory> outputDir() async {
    if (customDir != null && customDir!.trim().isNotEmpty) {
      final d = Directory(customDir!);
      if (await _writableDir(d)) return d;
    }
    final base = await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, _dirName));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<String> outputDirPath() async => (await outputDir()).path;

  Future<bool> isDirWritable(String path) async =>
      _writableDir(Directory(path));

  Future<bool> _writableDir(Directory d) async {
    try {
      if (!await d.exists()) await d.create(recursive: true);
      final probeDir = await d.createTemp('.sr_probe_');
      await probeDir.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 导出文档为 WAV。
  /// [stableId] 用于稳定文件名（自动导出覆盖更新使用同一 ID）。
  /// [cancel] 每次异步操作后检查；返回 true 时中止导出并抛 CancellationException。
  Future<String> exportDocument(
    TtsService tts,
    String text, {
    required bool dictation,
    required double rate,
    int repeatCount = 1,
    double gapSeconds = 0,
    double repeatGapSeconds = 0,
    String? baseName,
    String? stableId,
    bool stableName = false,
    void Function(double progress)? onProgress,
    bool Function()? cancel,
  }) async {
    final clean = text.trim();
    if (clean.isEmpty) throw Exception('没有可朗读的内容');
    _checkCancel(cancel);

    final dir = await outputDir();
    _checkCancel(cancel);
    final jobDir = await dir.createTemp('.sr_job_');

    try {
      _checkCancel(cancel);
      final suffix = dictation ? '_听写' : '';
      final finalName = stableName && stableId != null
          ? '$stableId$suffix.wav'
          : '${_sanitize(baseName)}$suffix'
              '_${_timestamp()}_${_randomToken()}.wav';
      final finalPath = p.join(dir.path, finalName);
      final candidatePath = p.join(jobDir.path, 'output.wav');

      if (dictation) {
        await _exportDictation(tts, clean, candidatePath, jobDir,
            rate: rate,
            repeatCount: repeatCount,
            gapSeconds: gapSeconds,
            repeatGapSeconds: repeatGapSeconds,
            onProgress: onProgress,
            cancel: cancel);
      } else {
        await _exportRegular(tts, clean, candidatePath, jobDir,
            rate: rate, onProgress: onProgress, cancel: cancel);
      }

      // 必须 await：否则 finally 会先删除 jobDir，使 _publish 的候选 WAV 丢失。
      return await _publish(candidatePath, finalPath);
    } finally {
      try {
        if (await jobDir.exists()) await jobDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<String> _publish(String candidatePath, String finalPath) async {
    final candidate = File(candidatePath);
    final finalFile = File(finalPath);
    if (await finalFile.exists()) {
      // 自动导出覆盖场景：exclusive rename 不支持覆盖，先移旧文件再 rename。
      final backup = '${finalPath}.bak_${_randomToken()}';
      await finalFile.rename(backup);
      try {
        return (await candidate.rename(finalPath)).path;
      } catch (_) {
        // 回滚: 先保原始异常不丢失
        try {
          await File(backup).rename(finalPath);
        } catch (_) {
          // 回滚也失败时(如磁盘满),不覆盖原始异常
        }
        rethrow;
      } finally {
        try {
          final b = File(backup);
          if (await b.exists()) await b.delete();
        } catch (_) {}
      }
    }
    return (await candidate.rename(finalPath)).path;
  }

  static void _checkCancel(bool Function()? cancel) {
    if (cancel != null && cancel()) throw const CancellationException();
  }

  // ---------- 常规模式 ----------
  Future<void> _exportRegular(
    TtsService tts,
    String text,
    String candidatePath,
    Directory jobDir, {
    required double rate,
    void Function(double)? onProgress,
    bool Function()? cancel,
  }) async {
    final chunks = _chunkText(text, _maxChunk);
    if (chunks.length == 1) {
      onProgress?.call(0.2);
      final ok = await tts.synthToFile(chunks.first, candidatePath, rate: rate);
      if (!ok) throw Exception('合成失败，当前 TTS 引擎可能不支持离线合成到文件');
      onProgress?.call(1.0);
      return;
    }

    final chunkPaths = <String>[];
    try {
      for (var i = 0; i < chunks.length; i++) {
        _checkCancel(cancel);
        final tmp = p.join(jobDir.path, 'chunk_$i.wav');
        final ok = await tts.synthToFile(chunks[i], tmp, rate: rate);
        _checkCancel(cancel);
        if (!ok) throw Exception('第 ${i + 1} 段合成失败');
        chunkPaths.add(tmp);
        onProgress?.call(0.1 + 0.8 * (i + 1) / chunks.length);
      }
      _checkCancel(cancel);
      if (!await _concatWav(chunkPaths, candidatePath)) {
        throw Exception('音频拼接失败');
      }
      onProgress?.call(1.0);
    } finally {
      for (final chunkPath in chunkPaths) {
        try {
          final f = File(chunkPath);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
  }

  // ---------- 听写模式 ----------
  Future<void> _exportDictation(
    TtsService tts,
    String text,
    String candidatePath,
    Directory jobDir, {
    required double rate,
    required int repeatCount,
    required double gapSeconds,
    double repeatGapSeconds = 0,
    void Function(double)? onProgress,
    bool Function()? cancel,
  }) async {
    final tokens = tts.tokenizeForDictation(text);
    if (tokens.isEmpty) throw Exception('没有可朗读的词');
    final reps = repeatCount < 1 ? 1 : repeatCount;

    final tokenWavs = <String>[];
    try {
      for (var i = 0; i < tokens.length; i++) {
        _checkCancel(cancel);
        final tmp = p.join(jobDir.path, 'tok_$i.wav');
        final ok = await tts.synthToFile(tokens[i], tmp, rate: rate);
        _checkCancel(cancel);
        if (!ok) throw Exception('第 ${i + 1} 个词合成失败');
        tokenWavs.add(tmp);
        onProgress?.call(0.1 + 0.7 * (i + 1) / tokens.length);
      }

      _checkCancel(cancel);
      final firstInfo = _parseWav(await File(tokenWavs.first).readAsBytes());
      if (firstInfo == null) throw Exception('音频解析失败');
      final wordSilence =
          gapSeconds > 0 ? _silencePcm(firstInfo, gapSeconds) : Uint8List(0);
      final repeatSilence = repeatGapSeconds > 0
          ? _silencePcm(firstInfo, repeatGapSeconds)
          : Uint8List(0);

      final pcm = BytesBuilder();
      for (var i = 0; i < tokens.length; i++) {
        _checkCancel(cancel);
        final info = _parseWav(await File(tokenWavs[i]).readAsBytes());
        if (info == null) throw Exception('第 ${i + 1} 个词解析失败');
        if (i > 0) {
          if (info.sampleRate != firstInfo.sampleRate ||
              info.channels != firstInfo.channels ||
              info.bitsPerSample != firstInfo.bitsPerSample) {
            throw Exception('第 ${i + 1} 个词音频格式不一致');
          }
        }
        for (var r = 0; r < reps; r++) {
          _checkCancel(cancel);
          pcm.add(info.data);
          if (repeatSilence.isNotEmpty && r < reps - 1) {
            pcm.add(repeatSilence);
          }
        }
        if (wordSilence.isNotEmpty && i < tokens.length - 1) {
          pcm.add(wordSilence);
        }
        onProgress?.call(0.8 + 0.15 * (i + 1) / tokens.length);
      }

      await _writeWav(candidatePath, firstInfo, pcm.toBytes());
      onProgress?.call(1.0);
    } finally {
      for (final wav in tokenWavs) {
        try {
          final f = File(wav);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
  }

  // ---------- 列表与分享 ----------
  Future<List<File>> listFiles() async {
    try {
      final dir = await outputDir();
      final entities = await dir.list().toList();
      final files = entities
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.wav'))
          .where((f) => !p.basename(f.path).startsWith('.'))
          .toList();

      // [v2.5.0] statSync → await stat: 大量文件时避免同步 IO 阻塞 UI 线程
      final withTime = <(File, DateTime)>[];
      for (final f in files) {
        try {
          final st = await f.stat();
          withTime.add((f, st.modified));
        } catch (_) {
          // 单文件 stat 失败则跳过, 不因个别文件拖垮整个列表
        }
      }
      withTime.sort((a, b) => b.$2.compareTo(a.$2));
      return [for (final e in withTime) e.$1];
    } catch (_) {
      return [];
    }
  }

  Future<void> shareFile(String path) async {
    final result = await Share.shareXFiles(
      [XFile(path)],
      text: '语音朗读导出的音频',
    );
    if (result.status == ShareResultStatus.unavailable) {
      throw Exception('系统没有可用的分享目标');
    }
  }

  Future<void> deleteFile(String path) async {
    final f = File(path);
    if (await f.exists()) await f.delete();
  }

  // ---------- 文本分块 ----------
  List<String> _chunkText(String text, int max) {
    if (text.length <= max) return [text];
    final result = <String>[];
    final sentences = text.split(RegExp(r'(?<=[。！？!?；;\n])'));
    var buf = '';
    for (final s in sentences) {
      if ((buf + s).length > max && buf.isNotEmpty) {
        result.add(buf);
        buf = s;
      } else {
        buf += s;
      }
      while (buf.length > max) {
        result.add(buf.substring(0, max));
        buf = buf.substring(max);
      }
    }
    if (buf.trim().isNotEmpty) result.add(buf);
    return result;
  }

  String _sanitize(String? s) {
    final cleaned =
        (s ?? '').replaceAll(RegExp(r'[\\/:*?"<>|\r\n\t]'), '_').trim();
    return cleaned.isEmpty
        ? '朗读'
        : cleaned.substring(0, cleaned.length.clamp(0, 40));
  }

  String _timestamp() {
    final d = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}${two(d.month)}${two(d.day)}_'
        '${two(d.hour)}${two(d.minute)}${two(d.second)}';
  }

  String _randomToken() => List<int>.generate(8, (_) => _random.nextInt(256))
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();

  // ---------- WAV 处理 ----------
  Uint8List _silencePcm(_WavInfo info, double seconds) {
    final bytesPerSample = info.bitsPerSample ~/ 8;
    final frames = (info.sampleRate * seconds).round();
    final len = frames * info.channels * bytesPerSample;
    return Uint8List(len);
  }

  Future<bool> _concatWav(List<String> paths, String outPath) async {
    if (paths.isEmpty) return false;
    _WavInfo? ref;
    final data = BytesBuilder();
    for (final p in paths) {
      final info = _parseWav(await File(p).readAsBytes());
      if (info == null) return false;
      ref ??= info;
      if (info.sampleRate != ref.sampleRate ||
          info.channels != ref.channels ||
          info.bitsPerSample != ref.bitsPerSample) {
        return false;
      }
      data.add(info.data);
    }
    if (ref == null) return false;
    await _writeWav(outPath, ref, data.toBytes());
    return true;
  }

  Future<void> _writeWav(
      String outPath, _WavInfo fmt, Uint8List dataBytes) async {
    final out = File(outPath);
    final sink = out.openWrite();
    try {
      final sr = fmt.sampleRate, ch = fmt.channels, bps = fmt.bitsPerSample;
      final byteRate = sr * ch * bps ~/ 8;
      final blockAlign = ch * bps ~/ 8;
      final dataSize = dataBytes.length;
      sink.add(_ascii('RIFF'));
      sink.add(_int32(36 + dataSize));
      sink.add(_ascii('WAVE'));
      sink.add(_ascii('fmt '));
      sink.add(_int32(16));
      sink.add(_int16(1)); // PCM
      sink.add(_int16(ch));
      sink.add(_int32(sr));
      sink.add(_int32(byteRate));
      sink.add(_int16(blockAlign));
      sink.add(_int16(bps));
      sink.add(_ascii('data'));
      sink.add(_int32(dataSize));
      sink.add(dataBytes);
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  _WavInfo? _parseWav(Uint8List bytes) {
    if (bytes.length < 44) return null;
    if (_str(bytes, 0, 4) != 'RIFF' || _str(bytes, 8, 4) != 'WAVE') return null;

    int offset = 12;
    int? sampleRate, channels, bits;
    int? audioFormat;
    Uint8List? data;
    while (offset + 8 <= bytes.length) {
      final id = _str(bytes, offset, 4);
      final size = _le32(bytes, offset + 4);
      final bodyStart = offset + 8;
      if (id == 'fmt ') {
        if (bodyStart + 16 > bytes.length) return null;
        audioFormat = _le16(bytes, bodyStart);
        if (audioFormat != 1) return null;
        channels = _le16(bytes, bodyStart + 2);
        sampleRate = _le32(bytes, bodyStart + 4);
        bits = _le16(bytes, bodyStart + 14);
      } else if (id == 'data') {
        final end = bodyStart + size;
        data = Uint8List.sublistView(
          bytes,
          bodyStart,
          end > bytes.length ? bytes.length : end,
        );
      }
      offset = bodyStart + size + (size.isOdd ? 1 : 0);
      if (id == 'data' && data != null) break;
    }
    if (sampleRate == null ||
        channels == null ||
        bits == null ||
        data == null) {
      return null;
    }
    return _WavInfo(sampleRate, channels, bits, data);
  }

  static String _str(Uint8List b, int start, int len) =>
      String.fromCharCodes(b.sublist(start, start + len));
  static int _le16(Uint8List b, int offset) => b[offset] | (b[offset + 1] << 8);
  static int _le32(Uint8List b, int offset) =>
      b[offset] |
      (b[offset + 1] << 8) |
      (b[offset + 2] << 16) |
      (b[offset + 3] << 24);
  static List<int> _ascii(String s) => s.codeUnits;
  static List<int> _int32(int v) =>
      [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff];
  static List<int> _int16(int v) => [v & 0xff, (v >> 8) & 0xff];
}

class _WavInfo {
  final int sampleRate;
  final int channels;
  final int bitsPerSample;
  final Uint8List data;
  _WavInfo(this.sampleRate, this.channels, this.bitsPerSample, this.data);
}
