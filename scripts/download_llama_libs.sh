#!/usr/bin/env bash
# [v2.5.0] 下载 llama_cpp_dart 0.2.2 的 Android 预编译原生库(arm64-v8a)
#
# 背景:
#   llama_cpp_dart 是纯 Dart FFI 绑定, 原生库(liiba llama.cpp + mtmd 多模态 + OpenCL)
#   由上游 netdur/llama_cpp_dart 以 GitHub release 预编译分发, 不需要 CI 现场编译 C++.
#   v0.2.0 release 的 jni-opencl.zip 含 CPU + OpenCL + mtmd(视觉) 的 arm64-v8a so 文件.
#
# 用法:
#   在项目根(speak_reader/)执行:  bash scripts/download_llama_libs.sh
#   或由 CI(workflow) 在 flutter build 前调用.
#
# 产物:
#   android/app/src/main/jniLibs/arm64-v8a/*.so  (已加入 .gitignore, 不入库)
set -euo pipefail

RELEASE_TAG="v0.2.0"
ZIP_NAME="jni-opencl.zip"
ZIP_URL="https://github.com/netdur/llama_cpp_dart/releases/download/${RELEASE_TAG}/${ZIP_NAME}"
# 由 `sha256sum <zip>` 计算, 防止供应链篡改
ZIP_SHA256="8aeb36d4d8ba045082f852798dce60b80c3ea0481fb01fd7f759c7f3e43c28ec"
DEST="android/app/src/main/jniLibs"

# 定位项目根(脚本位于 <root>/scripts/ 下)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

if [ ! -f android/app/build.gradle ]; then
  echo "ERROR: 未找到 android/app/build.gradle, 请在项目根(speak_reader/)运行本脚本"
  exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

echo "==> 下载 ${ZIP_NAME} (${RELEASE_TAG})"
curl -fsSL -o "${WORK_DIR}/${ZIP_NAME}" "${ZIP_URL}"

echo "==> 校验 sha256"
echo "${ZIP_SHA256}  ${WORK_DIR}/${ZIP_NAME}" | sha256sum -c -

echo "==> 解压 arm64-v8a 原生库"
mkdir -p "${WORK_DIR}/unzip"
unzip -o -q "${WORK_DIR}/${ZIP_NAME}" -d "${WORK_DIR}/unzip"

if [ ! -d "${WORK_DIR}/unzip/jni/arm64-v8a" ]; then
  echo "ERROR: zip 中未找到 jni/arm64-v8a/ 目录"
  exit 1
fi

rm -rf "${DEST}/arm64-v8a"
mkdir -p "${DEST}/arm64-v8a"
cp "${WORK_DIR}"/unzip/jni/arm64-v8a/*.so "${DEST}/arm64-v8a/"

echo "==> 完成, 已安装 so 文件:"
ls -lh "${DEST}/arm64-v8a/"
