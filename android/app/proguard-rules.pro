# [v2.4.0] ProGuard rules for speak_reader
# 已经删除 google_mlkit_* 和 syncfusion_flutter_pdf, 规则已清理

# Flutter engine native bindings
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# flutter_tts
-keepclassmembers class flutter_tts.** { *; }

# pdfx (pdfium native)
-keep class org.pdftron.** { *; }

# docx_to_text
-keep class docx_to_text.** { *; }

# keep 所有原生插件入口
-keep class * extends io.flutter.plugin.common.MethodCallHandler { *; }
