import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:speak_reader/services/audio_export_service.dart';
import 'package:speak_reader/services/tts_service.dart';

/// 生成最小合法 PCM WAV(16bit 单声道)。
Uint8List _wav(int sampleRate, int channels, int bits, int dataLen) {
  final b = BytesBuilder();
  void i32(int v) =>
      b.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);
  void i16(int v) => b.add([v & 0xff, (v >> 8) & 0xff]);
  b.add([0x52, 0x49, 0x46, 0x46]); // 'RIFF'
  i32(36 + dataLen);
  b.add([0x57, 0x41, 0x56, 0x45]); // 'WAVE'
  b.add([0x66, 0x6d, 0x74, 0x20]); // 'fmt '
  i32(16);
  i16(1); // PCM
  i16(channels);
  i32(sampleRate);
  i32(sampleRate * channels * bits ~/ 8);
  i16(channels * bits ~/ 8);
  i16(bits);
  b.add([0x64, 0x61, 0x74, 0x61]); // 'data'
  i32(dataLen);
  b.add(Uint8List(dataLen));
  return b.toBytes();
}

/// fake TTS: 直接写一个与文本长度成比例的 WAV, 可注入每次合成的副作用。
class _FakeTts extends TtsService {
  final void Function(String text)? onSynth;
  _FakeTts({this.onSynth});

  @override
  Future<bool> synthToFile(String text, String fullPath, {double? rate}) async {
    onSynth?.call(text);
    await File(fullPath)
        .writeAsBytes(_wav(16000, 1, 16, text.length * 10 + 100));
    return true;
  }
}

int _expectedLen(String text) => 44 + (text.length * 10 + 100);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory outDir;
  late AudioExportService svc;

  setUp(() async {
    outDir = await Directory.systemTemp.createTemp('sr_audio_test_');
    svc = AudioExportService()..customDir = outDir.path;
  });

  tearDown(() async {
    try {
      await outDir.delete(recursive: true);
    } catch (_) {}
  });

  test('常规模式导出生成合法 WAV', () async {
    final path = await svc.exportDocument(
      _FakeTts(),
      'hello world',
      dictation: false,
      rate: 0.5,
    );
    final file = File(path);
    expect(await file.exists(), true);
    expect(await file.length(), _expectedLen('hello world'));
    final bytes = await file.readAsBytes();
    expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');
    // 发布位置在输出目录
    expect(p.equals(p.dirname(path), outDir.path), true);
  });

  test('空文本抛异常', () async {
    expect(
      () => svc.exportDocument(_FakeTts(), '   ', dictation: false, rate: 0.5),
      throwsA(isA<Exception>()),
    );
  });

  test('取消令牌:开始即取消立即抛 CancellationException', () async {
    expect(
      () => svc.exportDocument(_FakeTts(), 'hello',
          dictation: false, rate: 0.5, cancel: () => true),
      throwsA(isA<CancellationException>()),
    );
  });

  test('取消令牌:合成中途取消并清理暂存目录', () async {
    var cancelled = false;
    var call = 0;
    final tts = _FakeTts(onSynth: (_) {
      call++;
      if (call == 1) cancelled = true;
    });
    await expectLater(
      () => svc.exportDocument(
        tts,
        'a b c d e f g h i j',
        dictation: true,
        rate: 0.4,
        repeatCount: 1,
        gapSeconds: 0,
        cancel: () => cancelled,
      ),
      throwsA(isA<CancellationException>()),
    );
    // 暂存 job 目录应被清理
    final leftovers = outDir
        .listSync()
        .where((e) => p.basename(e.path).startsWith('.sr_job_'))
        .toList();
    expect(leftovers, isEmpty);
  });

  test('听写模式:多 token 合成并拼接为单个 WAV', () async {
    final path = await svc.exportDocument(
      _FakeTts(),
      'hello world',
      dictation: true,
      rate: 0.4,
      repeatCount: 1,
      gapSeconds: 0,
    );
    final file = File(path);
    expect(await file.exists(), true);
    // 两个 token(hello/world) 各 150 字节数据, 44 头 = 344
    expect(await file.length(), 44 + 150 * 2);
    final bytes = await file.readAsBytes();
    expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
  });

  test('stableName:相同 stableId 二次导出覆盖, 只留最新文件', () async {
    final p1 = await svc.exportDocument(
      _FakeTts(),
      'first',
      dictation: false,
      rate: 0.5,
      stableName: true,
      stableId: 'doc_1',
    );
    final p2 = await svc.exportDocument(
      _FakeTts(),
      'second',
      dictation: false,
      rate: 0.5,
      stableName: true,
      stableId: 'doc_1',
    );
    expect(p1, p2);
    final wavs = outDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.wav'))
        .toList();
    expect(wavs.length, 1);
    // 内容已更新为第二次
    expect(await File(p2).length(), _expectedLen('second'));
  });

  test('listFiles 只返回非隐藏 wav', () async {
    await svc.exportDocument(_FakeTts(), 'first',
        dictation: false, rate: 0.5, stableName: true, stableId: 'doc_1');
    await svc.exportDocument(_FakeTts(), 'second',
        dictation: false, rate: 0.5, stableName: true, stableId: 'doc_2');
    final files = await svc.listFiles();
    expect(files.length, 2);
    expect(files.every((f) => f.path.toLowerCase().endsWith('.wav')), true);
  });
}
