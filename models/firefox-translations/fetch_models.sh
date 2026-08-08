#!/usr/bin/env bash
# G4 离线翻译模型下载器(Linux/macOS/Git Bash)。
#
# 按语向分别下载: 每个 group(语向)一个 zip 包。默认下载清单里的全部语向,
# 可用 `MODEL_GROUPS="zhen"` 等只取指定语向。
#
# 每个语向两阶段:
#   1. 整包优先 —— 下载该语向的 zip, 校验压缩包 SHA-256, 解压后校验该组文件。
#   2. 逐文件回退 —— 整包失败时, 从 upstream_url 逐个下载 .gz, 解压后校验。
# 已存在且校验通过的文件跳过, 故可重复执行、断点续跑。
#
# 为什么模型不进仓库: 见 MANIFEST.json 的 $comment 与 README.md。
#
# 用法:
#   ./fetch_models.sh              # 下载全部语向到本脚本所在目录
#   ./fetch_models.sh <目标目录>
#   MODEL_GROUPS="zhen" ./fetch_models.sh     # 只下载指定语向(逗号分隔)
#   VERIFY_ONLY=1 ./fetch_models.sh           # 只校验已有文件, 不下载
#
# 依赖: bash 4+, curl, python3(解析 JSON + 解压 zip), sha256sum 或 shasum;
#       逐文件回退路径额外需要 gzip(整包优先路径不需要)。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SCRIPT_DIR/MANIFEST.json"
DEST="${1:-$SCRIPT_DIR}"
VERIFY_ONLY="${VERIFY_ONLY:-0}"
# 要下载的语向 group id 列表; 空 = 全部
# ⚠️ 不能用 GROUPS 命名: 那是 bash 内置特殊变量(存放用户组 ID), 前缀赋值
# 会被 bash 覆盖成组 ID, 导致误判「该语向已就位」而跳过下载(实测踩坑)。
WANT_GROUPS="${MODEL_GROUPS:-}"

[ -f "$MANIFEST" ] || { echo "缺少清单: $MANIFEST" >&2; exit 1; }
command -v curl >/dev/null || { echo "需要 curl" >&2; exit 1; }
command -v python3 >/dev/null || { echo "需要 python3 解析清单与解压 zip" >&2; exit 1; }

# sha256sum(coreutils) 与 shasum(macOS) 二选一
if command -v sha256sum >/dev/null; then
  sha256_of() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null; then
  sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
  echo "需要 sha256sum 或 shasum" >&2; exit 1
fi

# ── 从清单导出记录(制表符分隔), 避免在 bash 里手写 JSON 解析 ──
# 组行: GROUP <id> <archive_url> <sha256_zip>
read_groups() {
  python3 - "$MANIFEST" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1], encoding="utf-8"))
for g in manifest["groups"]:
    a = g.get("archive")
    url = a.get("url", "") if a else ""
    sha = a.get("sha256_zip", "") if a else ""
    sys.stdout.write("GROUP\t%s\t%s\t%s\n" % (g["id"], url, sha))
PY
}

# 文件行: FILE <group_id> <path> <sha256> <upstream_url>
read_files() {
  python3 - "$MANIFEST" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1], encoding="utf-8"))
for g in manifest["groups"]:
    for entry in g["files"]:
        # ⚠️ 必须 sys.stdout.write + 显式 "\n"(不能用 print()): Windows 上 Python
        # 以文本模式写 stdout 会把 \n 翻成 \r\n, 那个 \r 会粘在最后一个字段
        # (upstream_url)尾部, curl 收到 "...gz\r" 报 "URL rejected: Malformed
        # input to a URL function"。整包路径不会暴露, 但逐文件回退的
        # upstream_url 恰是最需要的兜底 —— 必须在这里处理。
        sys.stdout.write("\t".join([
            g["id"], entry["path"], entry["sha256"], entry["upstream_url"],
        ]) + "\n")
PY
}

# 解析 WANT_GROUPS 为以空格分隔的集合
want_list() {
  if [ -z "$WANT_GROUPS" ]; then
    read_groups | cut -f2   # 第 2 列才是 group id(第 1 列是固定标签 GROUP)
  else
    echo "$WANT_GROUPS" | tr ',' ' '
  fi
}

want_group() {  # $1 = group id, 判断是否在 wanted 列表
  local gid="$1"
  local w
  for w in $(want_list); do
    [ "$w" = "$gid" ] && return 0
  done
  return 1
}

# 取某 group 的 archive 信息
group_archive() {  # $1 = group id, $2 = 字段名(id 后: url=1, sha=2)
  local gid="$1" field="$2"
  local line
  line="$(read_groups | grep -P "^GROUP\t$gid\t")"
  [ -z "$line" ] && return 1
  case "$field" in
    url) echo "$line" | cut -f3 ;;
    sha) echo "$line" | cut -f4 ;;
  esac
}

# 校验某 group 的全部文件是否已就位且正确
verify_group() {  # $1 = group id
  local gid="$1" path sha _url f ok=0
  local bad=0
  while IFS=$'\t' read -r fgid path sha _url; do
    [ "$fgid" = "$gid" ] || continue
    f="$DEST/$path"
    if [ -f "$f" ] && [ "$(sha256_of "$f")" = "$sha" ]; then
      ok=$((ok + 1))
    else
      bad=$((bad + 1))
    fi
  done < <(read_files)
  [ "$ok" -gt 0 ] && [ "$bad" -eq 0 ]
}

# 尝试整包下载并放置某 group; 成功返回 0, 失败返回 1。
try_group_archive() {  # $1 = group id
  local gid="$1" url sha tmpdir zipfile f
  url="$(group_archive "$gid" url)" || return 1
  [ -n "$url" ] || return 1
  sha="$(group_archive "$gid" sha)"

  tmpdir="$(mktemp -d)" || return 1
  zipfile="$tmpdir/models.zip"

  echo "[下载] $gid 整包"
  echo "       <- $url"
  if ! curl -fL --retry 3 --retry-delay 2 --progress-bar -o "$zipfile" "$url"; then
    echo "       整包下载失败, 回退逐文件"
    rm -rf "$tmpdir"
    return 1
  fi

  if [ -n "$sha" ] && [ "$(sha256_of "$zipfile")" != "$sha" ]; then
    echo "       [压缩包 SHA-256 校验失败], 回退逐文件"
    rm -rf "$tmpdir"
    return 1
  fi

  # 解压到临时目录。用 python3 的 zipfile —— Windows 上不一定有 unzip,
  # 而脚本本就依赖 python3 解析清单, 不额外引入工具。
  if ! python3 - "$zipfile" "$tmpdir" <<'PY'
import os, sys, zipfile
src, dest = sys.argv[1], sys.argv[2]
base = os.path.realpath(dest)
with zipfile.ZipFile(src) as z:
    for info in z.infolist():
        if info.is_dir():
            continue
        target = os.path.join(dest, info.filename)
        # 防 zip slip: 拒绝解压到 dest 之外的条目
        if not os.path.realpath(target).startswith(base + os.sep):
            print("拒绝越界路径: " + info.filename, file=sys.stderr)
            sys.exit(1)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with z.open(info) as fi, open(target, "wb") as fo:
            fo.write(fi.read())
PY
  then
    echo "       整包解压失败, 回退逐文件"
    rm -rf "$tmpdir"
    return 1
  fi

  # 校验该 group 全部文件在包内且正确
  local bad=0
  while IFS=$'\t' read -r fgid path sha _url; do
    [ "$fgid" = "$gid" ] || continue
    path="${path%$'\r'}"
    f="$tmpdir/$path"
    if [ ! -f "$f" ]; then
      echo "       [缺失] $path (压缩包内无此文件)"
      bad=$((bad + 1))
      continue
    fi
    if [ "$(sha256_of "$f")" != "${sha%$'\r'}" ]; then
      echo "       [校验失败] $path"
      bad=$((bad + 1))
    fi
  done < <(read_files)
  if [ "$bad" -gt 0 ]; then
    echo "       整包内容校验失败, 回退逐文件"
    rm -rf "$tmpdir"
    return 1
  fi

  # 全部通过, 放置到目标
  while IFS=$'\t' read -r fgid path _sha _url; do
    [ "$fgid" = "$gid" ] || continue
    path="${path%$'\r'}"
    mkdir -p "$(dirname "$DEST/$path")"
    mv "$tmpdir/$path" "$DEST/$path"
  done < <(read_files)

  rm -rf "$tmpdir"
  echo "$gid 整包下载并校验通过"
  return 0
}

# ── 主流程 ──
total=0
ok=0
failed=()

for gid in $(want_list); do
  total=$((total + 1))

  # 已全部就位 -> 跳过
  if verify_group "$gid"; then
    echo "[跳过] $gid (文件已全部就位且校验通过)"
    ok=$((ok + 1))
    continue
  fi

  if [ "$VERIFY_ONLY" = "1" ]; then
    echo "[缺失/损坏] $gid"
    failed+=("$gid")
    continue
  fi

  # 整包优先
  if try_group_archive "$gid"; then
    ok=$((ok + 1))
    continue
  fi

  # 逐文件回退
  group_failed=()
  while IFS=$'\t' read -r fgid path sha url; do
    [ "$fgid" = "$gid" ] || continue
    url="${url%$'\r'}"
    target="$DEST/$path"
    mkdir -p "$(dirname "$target")"

    if [ -f "$target" ] && [ "$(sha256_of "$target")" = "$sha" ]; then
      continue  # 已在前面整体校验过, 这里仅防并发/重复
    fi

    got=0
    echo "[下载] $path"
    echo "       <- $url"
    if ! curl -fL --retry 3 --retry-delay 2 --progress-bar -o "$target.gz" "$url"; then
      echo "       下载失败"
      rm -f "$target.gz"
    else
      if gzip -dc "$target.gz" > "$target" 2>/dev/null; then
        rm -f "$target.gz"
        if [ "$(sha256_of "$target")" = "$sha" ]; then
          echo "       [ok] 校验通过"
          got=1
        else
          echo "       [校验失败] 期望 $sha"
          echo "                   实际 $(sha256_of "$target")"
          rm -f "$target"
        fi
      else
        echo "       解压失败"
        rm -f "$target.gz" "$target"
      fi
    fi

    if [ "$got" = "1" ]; then
      :
    else
      group_failed+=("$path")
    fi
  done < <(read_files)

  if [ "${#group_failed[@]}" -eq 0 ]; then
    ok=$((ok + 1))
  else
    failed+=("$gid")
  fi
done

echo
echo "=== 完成: $ok/$total 个语向"
if [ "${#failed[@]}" -gt 0 ]; then
  echo "失败语向:"
  printf '  %s\n' "${failed[@]}"
  echo
  echo "整包与上游均不可用时, 可手工从上游取(见 MANIFEST.json 的 upstream_url),"
  echo "下载后用 sha256sum -c SHA256SUMS 校验。"
  exit 1
fi
echo "全部语向文件校验通过, 可直接经 App 导入对应 zip。"
