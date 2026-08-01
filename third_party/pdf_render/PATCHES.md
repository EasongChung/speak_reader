# Local patch notes

Base package: `pdf_render` 1.4.12 from pub.dev.

## Flutter 3.29 Android compatibility

`android/src/main/kotlin/jp/espresso3389/pdf_render/PdfRenderPlugin.kt`
removed the unused import:

```kotlin
import io.flutter.plugin.common.PluginRegistry.Registrar
```

The plugin already implements Flutter embedding V2 through `FlutterPlugin` and
does not reference `Registrar` elsewhere. Flutter 3.29 removes the legacy
`Registrar` API, so retaining the import causes Kotlin compilation to fail.
No rendering code or MethodChannel behavior was changed.
