import 'package:flutter/material.dart';

/// 导入方式
enum ImportChoice { camera, gallery, file }

/// 底部弹窗:选择导入方式
class ImportSheet extends StatelessWidget {
  const ImportSheet({super.key});

  static Future<ImportChoice?> show(BuildContext context) {
    return showModalBottomSheet<ImportChoice>(
      context: context,
      showDragHandle: true,
      builder: (_) => const ImportSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('选择导入方式',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
            _tile(context, Icons.camera_alt, '拍照识别', '用相机拍下文字,自动识别',
                ImportChoice.camera),
            _tile(context, Icons.photo_library, '从相册选图', '选择已有图片进行文字识别',
                ImportChoice.gallery),
            _tile(context, Icons.insert_drive_file, '选择文档',
                '导入 Word / PDF / TXT 文件', ImportChoice.file),
          ],
        ),
      ),
    );
  }

  Widget _tile(BuildContext context, IconData icon, String title,
      String subtitle, ImportChoice choice) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        child:
            Icon(icon, color: Theme.of(context).colorScheme.onPrimaryContainer),
      ),
      title: Text(title),
      subtitle: Text(subtitle),
      onTap: () => Navigator.pop(context, choice),
    );
  }
}
