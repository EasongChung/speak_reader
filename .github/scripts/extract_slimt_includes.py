#!/usr/bin/env python3
"""从 CMake 导出的 compile_commands.json 抽出 slimt 本体 TU 的头文件搜索口径。

用途(G4.3): JNI 适配层 slimt_jni.cpp 是独立 clang++ 调用编译的, 不走 slimt
自己的 CMake 工程, 因此拿不到 slimt 的 target include 目录。而它 include 了
slimt 的公共头, 公共头链(Frontend.hh -> Model.hh -> Vocabulary.hh:9)会把
内置 sentencepiece 的 sentencepiece_processor.h 拽进 TU —— 那个头位于
3rd-party/sentencepiece/src/, 属 slimt 的**私有** include 目录。

手工维护 -I 清单会随上游目录调整而过期(本项目已有同型教训), 故改为直接
抄 slimt 某个 .cc 的实际编译参数, 与 slimt 本体逐字节同源, 上游零改动。

输出: 每行一个参数(-I/-isystem/-D), 供 bash mapfile 读取。
退出码: 0 成功; 1 未找到可用 TU 或 JSON 不可解析。
"""

import json
import shlex
import sys

# 只取这三类: 头文件搜索路径与预处理宏。刻意**不**继承 -O/-f/-march 等
# 代码生成选项 —— 那些由调用方按 JNI 层自身需要显式指定(如 -fvisibility=default,
# slimt 顶层设的是 hidden, 直接继承会让 JNI 入口不导出)。
_PREFIXES = ("-I", "-isystem", "-D")
# 需要「下一个参数是值」的分离式写法
_SEPARATE = {"-I", "-isystem", "-D"}


def extract(args):
    """从一条编译命令的参数表里挑出 include/define 参数, 保持原有顺序。"""
    picked = []
    i = 0
    while i < len(args):
        arg = args[i]
        if arg in _SEPARATE:
            # 分离式: -I /path
            if i + 1 < len(args):
                picked += [arg, args[i + 1]]
            i += 2
            continue
        if arg.startswith(_PREFIXES):
            # 紧凑式: -I/path
            picked.append(arg)
        i += 1
    return picked


def is_slimt_own(path):
    """判定是否 slimt 本体的源文件(而非 3rd-party 子模块的)。

    只有本体 TU 的口径才同时涵盖 slimt 公共头 + 其私有依赖(sentencepiece
    等); 3rd-party 自己的 TU 看不到 slimt 的 include 目录。
    """
    normalized = path.replace("\\", "/")
    if "3rd-party" in normalized:
        return False
    if not normalized.endswith((".cc", ".cpp")):
        return False
    return "/slimt/" in normalized


def main(argv):
    if len(argv) != 2:
        print("用法: extract_slimt_includes.py <compile_commands.json>",
              file=sys.stderr)
        return 1

    try:
        with open(argv[1], encoding="utf-8") as handle:
            database = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"无法读取 {argv[1]}: {exc}", file=sys.stderr)
        return 1

    for entry in database:
        if not is_slimt_own(entry.get("file", "")):
            continue
        # CMake 可能给 arguments(列表)或 command(单字符串), 两种都要认
        args = entry.get("arguments")
        if not args:
            args = shlex.split(entry.get("command", ""))
        picked = extract(args)
        if picked:
            print("\n".join(picked))
            return 0

    print("compile_commands.json 里没有可用的 slimt 本体 TU", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
