// [G4.3] slimt 离线翻译的 JNI 适配层。
//
// 结构(docs/13 §G4.3 方案 A —— 单 .so):
//   Dart OfflineTranslationService
//     -> MethodChannel "com.example.speak_reader/offline_translate"
//     -> Kotlin SlimtBridge (external fun)
//     -> 本文件
//     -> libslimt.a(静态链入本 .so)
//
// ⚠️ 为什么是**单** .so 而不是「预编译 libslimt.so + 独立 JNI .so」:
// G4.2 产出的 libslimt.so 的 NEEDED 段里没有 libc++_shared.so, 即 STL 是
// 静态链入的。若 JNI 层另编一个 .so 去链它, JNI 层会带**自己那份**静态 STL,
// 而 slimt 的对外 API 重度使用 std::string / std::vector / std::shared_ptr
// (Blocking::translate 的签名), 这些类型要跨 .so 边界传递 —— 两份静态 STL
// 各有独立的 type_info、异常表与全局状态, 属未定义行为。把 JNI 边界改成纯 C
// **救不了**: 问题出在 JNI 层与 libslimt 之间, 不在 JNI 层与 Java 之间。
// 故本文件与 slimt 一起链成单个 libslimt_jni.so, 全程只有一份 STL。
//
// ⚠️ 模型缓存是必须项不是优化项(docs/13 §G4.3): 不缓存时每次翻译有约 250ms
// 的固定初始化开销, 会让 G4.4 的速度指标因结构问题误判不通过。

#include <jni.h>

#include <android/log.h>

#include <exception>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include "slimt/Frontend.hh"
#include "slimt/Model.hh"
#include "slimt/Response.hh"
#include "slimt/Types.hh"

namespace {

constexpr const char *kTag = "SlimtJni";

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, kTag, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, kTag, __VA_ARGS__)

/// 已加载模型: key 为 Dart 侧传入的模型组 id(如 "zhen")。
std::unordered_map<std::string, std::shared_ptr<slimt::Model>> g_models;

/// 翻译服务。持久化而非每次新建: Blocking 内部持有 TranslationCache,
/// 重建即丢缓存。Blocking::translate 非 const, 故与 g_models 共用一把锁。
std::unique_ptr<slimt::Blocking> g_service;

std::mutex g_mutex;

slimt::Blocking &service() {
  if (!g_service) {
    // Config 默认: max_words=1024, cache_size=1024, workers=1,
    // tgt_length_limit_factor=1.5, wrap_length=128(Frontend.hh:21-27)。
    // Blocking 是同步前端, workers 对其无意义, 保持默认。
    g_service = std::make_unique<slimt::Blocking>(slimt::Config{});
  }
  return *g_service;
}

/// 模型结构预设。G4.1 实测所用的中英 base 模型对应 preset::base()
/// (encoder_layers=6 / decoder_layers=2 / num_heads=8, Model.cc:220)。
/// 留出 tiny/nano 是为了将来换模型时不必改 native 层。
slimt::Model::Config config_for(const std::string &preset) {
  if (preset == "tiny") return slimt::preset::tiny();
  if (preset == "nano") return slimt::preset::nano();
  return slimt::preset::base();
}

/// jstring -> std::string。
///
/// ⚠️ JNI 的 GetStringUTFChars 返回的是 **modified UTF-8**: BMP 内字符与标准
/// UTF-8 一致(中英文均在 BMP 内), 但 BMP 外字符(如 emoji)会被编成 6 字节的
/// surrogate 对, sentencepiece 不认。PoC 阶段的翻译输入不含 emoji, 故不做转换;
/// 若将来要支持, 应在 Kotlin 侧先剔除或改用 GetStringChars 自行转 UTF-8。
std::string to_std_string(JNIEnv *env, jstring value) {
  if (value == nullptr) return {};
  const char *chars = env->GetStringUTFChars(value, nullptr);
  if (chars == nullptr) return {};
  std::string result(chars);
  env->ReleaseStringUTFChars(value, chars);
  return result;
}

/// 抛 Java 异常。JNI 里必须捕获所有 C++ 异常并转成 Java 异常:
/// C++ 异常穿过 JNI 边界是未定义行为, 真机上表现为直接 abort。
void throw_runtime(JNIEnv *env, const std::string &message) {
  jclass clazz = env->FindClass("java/lang/RuntimeException");
  if (clazz != nullptr) {
    env->ThrowNew(clazz, message.c_str());
    env->DeleteLocalRef(clazz);
  }
}

}  // namespace

// ⚠️ 函数名里的包名 com.example.speak_reader 含下划线, JNI 命名规则要求
// 转义成 _1, 即 speak_1reader。写成 speak_reader 会静默找不到符号,
// 运行期报 UnsatisfiedLinkError: No implementation found for ...
extern "C" {

/// 加载一组模型文件。已存在同名 id 时先释放旧的再加载。
///
/// 各路径均为 app 私有目录下的**真实文件路径** —— slimt 用 mmap 读文件
/// (Io.hh:51 MmapFile), 不认 Android 的 content:// URI, 故外部存储的模型
/// 必须由 Kotlin 侧先复制进私有目录再传路径进来。
///
/// shortlist / ssplit 允许为空字符串(对应 Package 中的可选项)。
///
/// vocabulary_path 恒为**源侧**词表。target_vocabulary_path 仅在模型使用
/// 分离词表(srcvocab/trgvocab, 如 en-zh 的 cjk_split_vocab)时才需要;
/// 传空字符串即退化为单词表, 编码与解码共用 vocabulary_path。
JNIEXPORT void JNICALL
Java_com_example_speak_1reader_SlimtBridge_nativeLoad(
    JNIEnv *env, jobject /* thiz */, jstring id, jstring model_path,
    jstring vocabulary_path, jstring shortlist_path, jstring ssplit_path,
    jstring preset, jstring target_vocabulary_path) {
  const std::string key = to_std_string(env, id);
  if (key.empty()) {
    throw_runtime(env, "模型 id 不能为空");
    return;
  }

  slimt::Package<std::string> package{
      .model = to_std_string(env, model_path),
      .vocabulary = to_std_string(env, vocabulary_path),
      .shortlist = to_std_string(env, shortlist_path),
      .ssplit = to_std_string(env, ssplit_path),
      .target_vocabulary = to_std_string(env, target_vocabulary_path),
  };
  const std::string preset_name = to_std_string(env, preset);

  if (package.model.empty() || package.vocabulary.empty()) {
    throw_runtime(env, "模型文件与词表路径均不能为空");
    return;
  }

  try {
    auto model = std::make_shared<slimt::Model>(config_for(preset_name),
                                                package);
    {
      std::lock_guard<std::mutex> lock(g_mutex);
      g_models[key] = std::move(model);
    }
    LOGI("已加载模型组 %s (preset=%s, 词表=%s)", key.c_str(),
         preset_name.c_str(),
         package.target_vocabulary.empty() ? "单" : "双(src/trg)");
  } catch (const std::exception &e) {
    throw_runtime(env, std::string("加载模型失败: ") + e.what());
  } catch (...) {
    throw_runtime(env, "加载模型失败: 未知错误");
  }
}

/// 翻译。返回译文; 模型未加载或翻译失败时抛 Java 异常。
JNIEXPORT jstring JNICALL
Java_com_example_speak_1reader_SlimtBridge_nativeTranslate(
    JNIEnv *env, jobject /* thiz */, jstring id, jstring text) {
  const std::string key = to_std_string(env, id);
  const std::string source = to_std_string(env, text);
  if (source.empty()) return env->NewStringUTF("");

  try {
    std::lock_guard<std::mutex> lock(g_mutex);
    auto it = g_models.find(key);
    if (it == g_models.end()) {
      throw_runtime(env, "模型组未加载: " + key);
      return nullptr;
    }

    // alignment=false: 本 PoC 只取译文, 不需要对齐矩阵, 关掉省一次计算。
    slimt::Options options{.alignment = false, .html = false};
    std::vector<slimt::Response> responses =
        service().translate(it->second, {source}, options);
    if (responses.empty()) {
      throw_runtime(env, "翻译返回空结果");
      return nullptr;
    }
    return env->NewStringUTF(responses[0].target.text.c_str());
  } catch (const std::exception &e) {
    throw_runtime(env, std::string("翻译失败: ") + e.what());
    return nullptr;
  } catch (...) {
    throw_runtime(env, "翻译失败: 未知错误");
    return nullptr;
  }
}

/// 释放指定模型组。id 不存在时静默返回(幂等)。
JNIEXPORT void JNICALL
Java_com_example_speak_1reader_SlimtBridge_nativeUnload(
    JNIEnv *env, jobject /* thiz */, jstring id) {
  const std::string key = to_std_string(env, id);
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_models.erase(key) > 0) {
    LOGI("已释放模型组 %s", key.c_str());
  }
}

/// 释放全部模型组, 并重建翻译服务(顺带清空其内部译文缓存)。
JNIEXPORT void JNICALL
Java_com_example_speak_1reader_SlimtBridge_nativeUnloadAll(
    JNIEnv * /* env */, jobject /* thiz */) {
  std::lock_guard<std::mutex> lock(g_mutex);
  g_models.clear();
  g_service.reset();
  LOGW("已释放全部模型组");
}

/// 已加载的模型组 id, 逗号分隔; 无则返回空串。
///
/// 刻意返回 String 而非 String[]: docs/13 §G4.3 记录的 Proguard 坑 ——
/// JNI 返回自定义类型时该类在 Java 侧无引用会被 release 构建裁剪, 报
/// NoSuchMethodError。只返回 String 可从结构上规避。
JNIEXPORT jstring JNICALL
Java_com_example_speak_1reader_SlimtBridge_nativeLoadedIds(
    JNIEnv *env, jobject /* thiz */) {
  std::string joined;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    for (const auto &entry : g_models) {
      if (!joined.empty()) joined.push_back(',');
      joined += entry.first;
    }
  }
  return env->NewStringUTF(joined.c_str());
}

}  // extern "C"
