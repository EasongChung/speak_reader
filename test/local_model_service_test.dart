import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:speak_reader/models/local_model.dart';
import 'package:speak_reader/services/local_model_service.dart';

/// 测试用: 把应用文档目录固定到临时目录, 避免真实设备目录。
/// (LocalModelService.getModelsDir 在外部存储推导失败时回退应用文档目录)
class _FakePathProvider extends PathProviderPlatform {
  final String root;
  _FakePathProvider(this.root);

  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  late LocalModelService service;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('sr_models_test_');
    PathProviderPlatform.instance = _FakePathProvider(tempRoot.path);
    SharedPreferences.setMockInitialValues({});
    service = LocalModelService();
  });

  tearDown(() async {
    try {
      await tempRoot.delete(recursive: true);
    } catch (_) {}
  });

  /// 在模型目录(models)放置一个空文件, 供扫描。
  Future<void> put(String fileName) async {
    final dir = Directory(p.join(tempRoot.path, 'models'));
    await dir.create(recursive: true);
    final f = File(p.join(dir.path, fileName));
    if (!await f.exists()) await f.create();
  }

  test('[v2.5.2] mmproj-<model>-f16.gguf 命名识别为投影而非独立主模型', () async {
    await put('MiniCPM5-1B-Q4_K_M.gguf');
    await put('mmproj-MiniCPM5-1B-f16.gguf');
    await put('llama3-8b-q4_k_m.gguf');

    final models = await service.listModels();
    expect(models.length, 2, reason: 'mmproj-*.gguf 不应被当作独立主模型');

    final mm =
        models.firstWhere((m) => m.fileName == 'MiniCPM5-1B-Q4_K_M.gguf');
    expect(mm.kind, LocalModelKind.multimodal);
    expect(
      p.basename(mm.mmprojPath!),
      'mmproj-MiniCPM5-1B-f16.gguf',
      reason: 'mmproj-*.gguf 应配对为主模型的视觉投影',
    );

    final txt = models.firstWhere((m) => m.fileName == 'llama3-8b-q4_k_m.gguf');
    expect(txt.kind, LocalModelKind.text);
    expect(txt.mmprojPath, isNull);
  });

  test('.mmproj 传统命名仍可正常配对', () async {
    await put('Qwen2-VL-7B-Q4_K_M.gguf');
    await put('mmproj-Qwen2-VL-7B-f16.mmproj');

    final models = await service.listModels();
    expect(models.length, 1);
    final m = models.single;
    expect(m.kind, LocalModelKind.multimodal);
    expect(m.mmprojPath, isNotNull);
    expect(p.extension(m.mmprojPath!), '.mmproj');
  });

  test('家族名不匹配的 mmproj-*.gguf: 多主模型时不配对', () async {
    await put('gemma3-4b-q4.gguf');
    await put('MiniCPM5-1B-Q4_K_M.gguf');
    await put('mmproj-unrelated-f16.gguf'); // 与任何主模型家族名不匹配

    final models = await service.listModels();
    expect(models.length, 2, reason: 'mmproj-*.gguf 不参与主模型列表');
    expect(models.every((m) => m.kind == LocalModelKind.text), isTrue,
        reason: '家族名不匹配时不配对, 且多主模型不触发唯一兜底');
  });

  test('唯一主模型 + 命名不匹配 mmproj: 按 v2.5.1 兜底规则仍配对', () async {
    await put('gemma3-4b-q4.gguf');
    await put('mmproj-unrelated-f16.gguf'); // 家族名不匹配

    final models = await service.listModels();
    expect(models.length, 1);
    expect(models.single.kind, LocalModelKind.multimodal,
        reason: '目录恰有 1 个 gguf + 1 个 mmproj 时任意命名兜底配对(原有设计)');
  });
}
