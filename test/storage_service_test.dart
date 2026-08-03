import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:speak_reader/models/document.dart';
import 'package:speak_reader/services/storage_service.dart';

/// 测试用:把文档目录固定到临时目录, 避免真实设备目录。
class _FakePathProvider extends PathProviderPlatform {
  final String root;
  _FakePathProvider(this.root);

  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

Document _doc(String id, {String? originalPath}) => Document(
      id: id,
      title: '标题$id',
      content: '内容 of $id',
      source: DocSource.manual,
      createdAt: 0,
      originalFilePath: originalPath,
      originalFileMime: originalPath == null ? null : 'image/jpeg',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  late StorageService storage;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('sr_storage_test_');
    PathProviderPlatform.instance = _FakePathProvider(tempRoot.path);
    SharedPreferences.setMockInitialValues({});
    storage = StorageService();
  });

  tearDown(() async {
    try {
      await tempRoot.delete(recursive: true);
    } catch (_) {}
  });

  test('upsert 串行化:并发写入不丢记录', () async {
    final futures = <Future<List<Document>>>[];
    for (var i = 0; i < 20; i++) {
      futures.add(storage.upsert(_doc('id$i')));
    }
    final results = await Future.wait(futures);
    final all = await storage.loadAll();
    expect(all.length, 20);
    expect(results.last.length, 20);
    expect(all.map((d) => d.id).toSet().length, 20);
  });

  test('loadAll 跳过损坏记录', () async {
    SharedPreferences.setMockInitialValues({
      'documents': [
        '{"id":"good","title":"t","content":"c","source":"manual","createdAt":0}',
        'not-json',
        '{"id":123}',
      ],
    });
    final all = await StorageService().loadAll();
    expect(all.length, 1);
    expect(all.single.id, 'good');
  });

  test('upsert 同 id 覆盖且置顶', () async {
    await storage.upsert(_doc('a'));
    await storage.upsert(_doc('b'));
    await storage.upsert(_doc('a', originalPath: 'x.jpg'));
    final all = await storage.loadAll();
    expect(all.length, 2);
    expect(all.first.id, 'a');
    expect(all.first.originalFilePath, 'x.jpg');
  });

  test('copyOriginal 复制到受控目录且无 .part 残留', () async {
    final src = File(p.join(tempRoot.path, 'src.jpg'));
    await src.writeAsBytes([1, 2, 3, 4, 5]);
    final managed = await storage.copyOriginal(src.path, 'jpg');

    expect(await File(managed).exists(), true);
    final originals = await storage.getOriginalsDir();
    expect(p.equals(p.dirname(managed), originals.path), true);
    // .part 临时文件不应残留(原子写入)
    final parts =
        originals.listSync().where((e) => e.path.endsWith('.part')).toList();
    expect(parts, isEmpty);
    // 源文件只读, 不应被删除
    expect(await src.exists(), true);
  });

  test('copyOriginal 拒绝不存在的源文件', () async {
    expect(
      () => storage.copyOriginal('${tempRoot.path}/nope.jpg', 'jpg'),
      throwsA(isA<Exception>()),
    );
  });

  test('delete 移除记录并删除不再被引用的原件', () async {
    final src = File(p.join(tempRoot.path, 'src.jpg'));
    await src.writeAsBytes([1, 2, 3]);
    final managed = await storage.copyOriginal(src.path, 'jpg');
    await storage.upsert(_doc('a', originalPath: managed));
    await storage.upsert(_doc('b'));

    final after = await storage.delete('a');
    expect(after.length, 1);
    expect(after.single.id, 'b');
    expect(await File(managed).exists(), false); // 原件已删
  });

  test('delete 保留仍被其他记录引用的原件', () async {
    final src = File(p.join(tempRoot.path, 'src.jpg'));
    await src.writeAsBytes([1, 2, 3]);
    final managed = await storage.copyOriginal(src.path, 'jpg');
    await storage.upsert(_doc('a', originalPath: managed));
    await storage.upsert(_doc('b', originalPath: managed));

    await storage.delete('a');
    expect(await File(managed).exists(), true); // b 仍引用, 不删
    await storage.delete('b');
    expect(await File(managed).exists(), false); // 无引用后删除
  });

  test('delete 不存在的 id 无副作用', () async {
    await storage.upsert(_doc('a'));
    final after = await storage.delete('missing');
    expect(after.length, 1);
    expect(after.single.id, 'a');
  });

  test('deleteManagedOriginal 拒绝 originals 之外的路径', () async {
    final outside = File(p.join(tempRoot.path, 'outside.jpg'));
    await outside.writeAsBytes([1]);
    await storage.deleteManagedOriginal(outside.path);
    expect(await outside.exists(), true); // 未被误删
  });

  test('deleteManagedOriginal 拒绝目录与链接', () async {
    final dir = Directory(p.join(tempRoot.path, 'sub'));
    await dir.create();
    await storage.deleteManagedOriginal(dir.path);
    expect(await dir.exists(), true);
  });

  test('clear 清空记录并删除所有受控原件', () async {
    final src = File(p.join(tempRoot.path, 'src.jpg'));
    await src.writeAsBytes([1]);
    final managed = await storage.copyOriginal(src.path, 'jpg');
    await storage.upsert(_doc('a', originalPath: managed));

    await storage.clear();
    expect(await storage.loadAll(), isEmpty);
    expect(await File(managed).exists(), false);
  });
}
