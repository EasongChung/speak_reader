#!/usr/bin/env bash
# G4 离线翻译模型下载器(Linux/macOS/Git Bash)。
#
# 按 MANIFEST.json 的 sources 优先级依次尝试, 每个文件下载后立即校验 SHA-256,
# 校验不过就换下一个源。三个源全失败才判该文件失败。
#
# 为什么模型不进仓库: 见 MANIFEST.json 的 $comment 与 README.md。
#
# 用法:
#   ./fetch_models.sh              # 下载到本脚本所在目录
#   ./fetch_models.sh <目标目录>
#   VERIFY_ONLY=1 ./fetch_models.sh   # 只校验已有文件, 不下载
#
# 依赖: bash 4+, curl, gzip, python3(解析 JSON), sha256sum 或 shasum

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SCRIPT_DIR/MANIFEST.json"
DEST="${1:-$SCRIPT_DIR}"
VERIFY_ONLY="${VERIFY_ONLY:-0}"

[ -f "$MANIFEST" ] || { echo "缺少清单: $MANIFEST" >&2; exit 1; }
command -v curl >/dev/null || { echo "需要 curl" >&2; exit 1; }
command -v gzip >/dev/null || { echo "需要 gzip" >&2; exit 1; }
command -v python3 >/dev/null || { echo "需要 python3 解析清单" >&2; exit 1; }

# sha256sum(coreutils) 与 shasum(macOS) 二选一
if command -v sha256sum >/dev/null; then
  sha256_of() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null; then
  sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
  echo "需要 sha256sum 或 shasum" >&2; exit 1
fi

# 从清单导出「每文件一行」的制表符分隔记录, 避免 bash 里手写 JSON 解析。
# 字段: path  sha256  sha256_gz  url1  url2  url3
read_manifest() {
  python3 - "$MANIFEST" <<'PY'
import json, sys

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
templates = {s["id"]: s.get("url_template") for s in manifest["sources"]}
order = [s["id"] for s in sorted(manifest["sources"], key=lambda s: s["priority"])]

for group in manifest["groups"]:
    for entry in group["files"]:
        urls = []
        for source_id in order:
            if source_id == "upstream":
                urls.append(entry["upstream_url"])
            else:
                urls.append(
                    templates[source_id]
                    .replace("{path}", entry["path"])
                    .replace("{name}", entry["name"])
                )
        # ⚠️ 必须 sys.stdout.write + 显式 "\n", 不能用 print():
        # Windows 上 Python 以文本模式写 stdout 会把 \n 翻成 \r\n, 那个 \r 会
        # 粘在最后一个字段(upstream_url)尾部, curl 收到 "...gz\r" 直接报
        # "URL rejected: Malformed input to a URL function"。前两级源不会暴露
        # 该问题(它们在 \r 之前就已 404, 属正常失败), 只有最后一级兜底会被击中
        # —— 恰恰是三源全挂、最需要它工作的时候。
        sys.stdout.write(
            "\t".join([entry["path"], entry["sha256"], entry["sha256_gz"], *urls]) + "\n"
        )
PY
}

total=0
ok=0
failed=()

while IFS=$'\t' read -r path sha sha_gz url1 url2 url3; do
  # 纵深防御: 上面的 Python 已显式写 \n, 但本脚本或清单仍可能被 Git 以 CRLF
  # 检出、或被 Windows 编辑器改过。URL 尾部带 \r 会让 curl 报 Malformed URL,
  # 且只在最后一级兜底源上暴露 —— 多剥一次, 成本为零。
  url1="${url1%$'\r'}"; url2="${url2%$'\r'}"; url3="${url3%$'\r'}"
  total=$((total + 1))
  target="$DEST/$path"
  mkdir -p "$(dirname "$target")"

  # 已存在且哈希正确 -> 跳过。这让脚本可重复执行, 断点续跑不重下。
  if [ -f "$target" ] && [ "$(sha256_of "$target")" = "$sha" ]; then
    echo "[跳过] $path (已存在且校验通过)"
    ok=$((ok + 1))
    continue
  fi

  if [ "$VERIFY_ONLY" = "1" ]; then
    echo "[缺失/损坏] $path"
    failed+=("$path")
    continue
  fi

  got=0
  for url in "$url1" "$url2" "$url3"; do
    echo "[下载] $path"
    echo "       <- $url"
    if ! curl -fL --retry 3 --retry-delay 2 --progress-bar -o "$target.gz" "$url"; then
      echo "       下载失败, 换下一个源"
      rm -f "$target.gz"
      continue
    fi

    if ! gzip -dc "$target.gz" > "$target" 2>/dev/null; then
      echo "       解压失败, 换下一个源"
      rm -f "$target.gz" "$target"
      continue
    fi
    rm -f "$target.gz"

    actual="$(sha256_of "$target")"
    if [ "$actual" != "$sha" ]; then
      echo "       [校验失败] 期望 $sha"
      echo "                   实际 $actual"
      rm -f "$target"
      continue
    fi

    echo "       [ok] 校验通过"
    got=1
    break
  done

  if [ "$got" = "1" ]; then
    ok=$((ok + 1))
  else
    failed+=("$path")
  fi
done < <(read_manifest)

echo
echo "=== 完成: $ok/$total"
if [ "${#failed[@]}" -gt 0 ]; then
  echo "失败文件:"
  printf '  %s\n' "${failed[@]}"
  echo
  echo "三个源均不可用时, 可手工从上游取(见 MANIFEST.json 的 upstream_url),"
  echo "下载后用 sha256sum -c SHA256SUMS 校验。"
  exit 1
fi
echo "全部文件校验通过, 可直接经 App 的 SAF 目录选择导入。"
