package com.example.speak_reader

import android.os.Build
import android.util.Log

/**
 * `G4.3` slimt 离线翻译原生库的 Kotlin 侧入口。
 *
 * ## 为什么可用性判定放在这里
 *
 * `docs/13` §G4.3 已定(2026-08-07 用户确认): 判定与 [System.loadLibrary]
 * **同址**才不会漂移。本项目已两次栽在「同一约定的两个消费者只改一侧」
 * (见 `08` 通用教训 1), 故 SDK_INT 判定不放 Dart 侧。
 *
 * ## 两个条件缺一即不可用
 *
 * 1. `SDK_INT >= 28`(Android 9 Pie)。`libslimt.so` 的编译档是 android-28,
 *    因为 slimt `Aligned.cc:51` 用了 `aligned_alloc` —— C11 函数, Android
 *    Bionic 从 API 28 才提供。而本项目 `minSdk` 是 21(build.gradle:67),
 *    保持不动, 故 21~27 机型装得上但加载不了。
 * 2. [System.loadLibrary] 真的成功。**版本号只是必要条件**: ABI 不符、
 *    `.so` 未打进 APK、jniLibs 被裁剪都会让加载失败。不能只信版本号。
 *
 * 两者皆不满足时, 上层静默回落到在线翻译链路, 不弹错。
 */
object SlimtBridge {
    private const val TAG = "SlimtBridge"

    /** `.so` 的编译档。与 `.github/workflows/g4-slimt-android.yml` 的 ANDROID_PLATFORM 一致。 */
    private const val MIN_API = Build.VERSION_CODES.P // 28 = Android 9

    /**
     * 库加载结果。null 表示尚未尝试。
     *
     * 用三态而非 Boolean + 标志位: 加载只尝试一次, 失败后不重试 ——
     * 失败原因(ABI/缺文件)都是不会在同一进程内自愈的。
     */
    @Volatile
    private var loaded: Boolean? = null

    /** 加载失败原因, 供日志与调试用; 成功时为 null。 */
    @Volatile
    private var loadError: String? = null

    /**
     * 离线翻译是否可用。首次调用会尝试加载原生库, 结果缓存。
     *
     * 线程安全: synchronized 保证 loadLibrary 只走一次。
     */
    @Synchronized
    fun isAvailable(): Boolean {
        loaded?.let { return it }

        if (Build.VERSION.SDK_INT < MIN_API) {
            loadError = "系统版本过低: API ${Build.VERSION.SDK_INT} < $MIN_API"
            Log.i(TAG, "离线翻译不可用 —— $loadError")
            loaded = false
            return false
        }

        // NEEDED 段只有 liblog/libm/libdl/libc 四个系统库(G4.2 实测),
        // sentencepiece/pcre2/ruy 与 STL 全部静态链入, 故无需预加载任何依赖。
        return try {
            System.loadLibrary("slimt_jni")
            loadError = null
            loaded = true
            Log.i(TAG, "libslimt_jni.so 加载成功")
            true
        } catch (e: UnsatisfiedLinkError) {
            loadError = e.message ?: "UnsatisfiedLinkError"
            Log.w(TAG, "libslimt_jni.so 加载失败, 回落在线翻译", e)
            loaded = false
            false
        } catch (e: SecurityException) {
            loadError = e.message ?: "SecurityException"
            Log.w(TAG, "libslimt_jni.so 加载被拒, 回落在线翻译", e)
            loaded = false
            false
        }
    }

    /** 不可用原因; 可用或尚未判定时为 null。供设置页副标题与日志用。 */
    fun unavailableReason(): String? = loadError

    /**
     * 加载一组模型文件。
     *
     * [id] 模型组标识(如 `"zhen"`), 与 [translate] 对应。
     * [modelPath]/[vocabularyPath] 必填, [shortlistPath]/[ssplitPath] 可为空串。
     * 各路径必须是**真实文件路径** —— slimt 用 mmap 读文件, 不认 content:// URI。
     * [preset] 模型结构预设: `"base"`(默认) / `"tiny"` / `"nano"`。
     *
     * @throws RuntimeException 加载失败(文件损坏、结构不匹配等)
     */
    fun load(
        id: String,
        modelPath: String,
        vocabularyPath: String,
        shortlistPath: String,
        ssplitPath: String,
        preset: String,
    ) = nativeLoad(id, modelPath, vocabularyPath, shortlistPath, ssplitPath, preset)

    /**
     * 翻译。[id] 必须先经 [load] 加载。
     *
     * @throws RuntimeException 模型未加载或推理失败
     */
    fun translate(id: String, text: String): String = nativeTranslate(id, text)

    /** 释放指定模型组; id 不存在时静默返回。 */
    fun unload(id: String) = nativeUnload(id)

    /** 释放全部模型组并清空译文缓存。 */
    fun unloadAll() = nativeUnloadAll()

    /** 已加载的模型组 id, 逗号分隔; 无则空串。 */
    fun loadedIds(): String = nativeLoadedIds()

    // JNI 声明。函数名与 slimt_jni.cpp 中的
    // Java_com_example_speak_1reader_SlimtBridge_* 一一对应
    // (包名里的下划线在 JNI 命名规则中转义为 _1)。
    private external fun nativeLoad(
        id: String,
        modelPath: String,
        vocabularyPath: String,
        shortlistPath: String,
        ssplitPath: String,
        preset: String,
    )

    private external fun nativeTranslate(id: String, text: String): String

    private external fun nativeUnload(id: String)

    private external fun nativeUnloadAll()

    private external fun nativeLoadedIds(): String
}
