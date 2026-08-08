# 语音朗读 (Speak Reader)

一款安卓 App:把**拍照/扫描的图片、Word、PDF、TXT** 里的文字提取出来,用**手机语音朗读**出来。

## 功能
- 📷 **拍照识别**:相机拍下文字,离线 OCR 自动识别(支持中文)
- 🖼️ **相册选图**:从相册选图片识别文字
- 📄 **文档导入**:Word(.docx)、PDF、TXT
- 🔊 **语音朗读**:系统内置 TTS,离线可用
  - 播放 / 暂停 / 停止 / 跳到下一句
  - 语速、音调可调
  - 当前朗读句高亮 + 自动滚动
  - 点击任意句子从该句开始读
- ✏️ **文字纠错**:识别结果可编辑
- 🕘 **历史记录**:导入过的内容自动保存,可重新打开、左滑删除

## 技术栈
- Flutter (Dart)
- `flutter_tts` —— 系统语音朗读
- `google_mlkit_text_recognition` —— 离线 OCR
- `docx_to_text` / `syncfusion_flutter_pdf` —— 文档解析
- `image_picker` / `file_picker` / `permission_handler` / `shared_preferences`

---

## 一、构建方式

生成可安装的 APK 需要 Flutter 与 Android 构建环境。下面提供两种方式，任选其一：

- **方式 A**：在本机安装 Flutter 构建
- **方式 B**：通过云端 GitHub Actions 打包（免装本地环境）

---

## 二、方式 A:本机安装 Flutter 构建

### 1. 安装 Flutter SDK
- 下载:https://docs.flutter.dev/get-started/install/windows
- 解压到如 `C:\src\flutter`,把 `C:\src\flutter\bin` 加入系统 PATH。

### 2. 安装 Android 环境
- 安装 **Android Studio**(含 Android SDK)。
- 打开 Android Studio → SDK Manager,安装 Android SDK Platform 34 + 命令行工具。

### 3. 检查环境
```bash
flutter doctor
```
按提示补齐缺失项;首次需执行:
```bash
flutter doctor --android-licenses   # 同意许可
```

### 4. 构建 APK
在项目目录 `speak_reader` 下:
```bash
flutter pub get
flutter build apk --release
```
生成的安装包在:
```
speak_reader/build/app/outputs/flutter-apk/app-release.apk
```
把这个文件传到安卓手机安装即可。

> 想直接连手机调试运行:开启手机「USB 调试」,连上电脑后 `flutter run`。

---

## 三、方式 B:云端打包 APK(免装任何环境)

项目已内置 GitHub Actions 配置(`.github/workflows/build-apk.yml`)。

1. 将本项目推送到你的 GitHub 仓库:
   ```bash
   cd speak_reader
   git init
   git add .
   git commit -m "语音朗读 App"
   git branch -M main
   git remote add origin <你的仓库地址>
   git push -u origin main
   ```
2. 推送后 Actions 自动开始构建(也可在仓库 Actions 页手动触发 "Build Android APK")。
3. 构建完成后,进入该次运行的 **Artifacts**,下载 `speak-reader-apk`,解压得到 APK。

---

## 四、首次使用说明
- 第一次拍照/识别时,系统会申请**相机、存储权限**,请允许。
- 首次 OCR 时,ML Kit 会**联网下载中文识别模型**(仅一次,之后离线可用)。
- 若手机没有中文 TTS 声音:进入「系统设置 → 语言与输入法 → 文字转语音输出」,
  安装/选择支持中文的引擎(如 Google 语音服务),即可正常朗读。

---

## 五、目录结构
```
speak_reader/
├── pubspec.yaml
├── android/                     Android 工程与权限配置
├── .github/workflows/           云端打包配置
└── lib/
    ├── main.dart                入口 + 主题
    ├── models/document.dart     文档数据模型
    ├── services/
    │   ├── tts_service.dart     朗读(分句/进度/语速)
    │   ├── ocr_service.dart     图片 OCR
    │   ├── import_service.dart  docx/pdf/txt 解析
    │   └── storage_service.dart 历史记录
    ├── pages/
    │   ├── home_page.dart       首页 + 导入 + 历史
    │   └── reader_page.dart     阅读 + 朗读控制
    └── widgets/import_sheet.dart 导入方式弹窗
```

## 六、备注
- `.doc`(旧版 Word)不被支持,请在电脑上另存为 `.docx` 再导入。
- Release 版目前用 debug 签名以便直接安装;正式上架请在 `android/app/build.gradle` 配置你自己的签名。
