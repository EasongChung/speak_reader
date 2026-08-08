# Firefox Translations 离线翻译模型

本目录管理 G4 离线翻译(slimt)所用的**中英双向**模型,来自 **Mozilla
Firefox Translations** 项目。

> **模型权重不在仓库里。** 目录下只有清单、校验和与下载脚本;
> 权重按需从下方各源取回。原因见「为什么不入库」一节。

## 取模型

```bash
# Linux / macOS / Git Bash
bash fetch_models.sh

# Windows PowerShell
.\fetch_models.ps1
```

**按语向分别下载**: 每个语向一个 zip 包。默认下载全部语向, 可用
`MODEL_GROUPS` 指定只取所需语向。每个语向先尝试整包, 失败回退逐文件上游。
已存在且校验通过的文件直接跳过, 故可重复执行、断点续跑。

```bash
bash fetch_models.sh /path/to/dir            # 指定目标目录
MODEL_GROUPS="zhen" bash fetch_models.sh     # 只下载指定语向(逗号分隔)
VERIFY_ONLY=1 bash fetch_models.sh           # 只校验已有文件, 不下载
sha256sum -c SHA256SUMS                      # 手工校验(在本目录下执行)
```

## 分发源

| 优先级 | 源 | 说明 |
|---|---|---|
| 1 | GitHub Release | tag `models-firefox-translations-v1`,**按语向分别打包**,每个语向一个 zip(见 MANIFEST 各 group 的 archive 字段) |
| 2 | 上游 | HF 镜像(zh-en)与 Mozilla GCS(en-zh),最终回退 |

Release 按语向分别打包: 每个语向一个 zip(内含该语向的解压后模型文件),
下载所需语向解压即可导入。包名约定 `models-<name>-<dir>-v<version>.zip`。

## 文件

```
firefox-translations/
├── MANIFEST.json      清单: 字节数、SHA-256、各源 URL
├── SHA256SUMS         解压后文件的 SHA-256
├── fetch_models.sh    下载器(bash)
├── fetch_models.ps1   下载器(PowerShell)
├── .gitignore         挡住权重文件
├── zh-en/  (中 → 英, id=zhen, 单词表档)   ← 下载后生成
│   ├── model.zhen.intgemm.alphas.bin   intgemm 量化权重 (59,504,955 B)
│   ├── vocab.zhen.spm                  sentencepiece 词表 (1,359,697 B)
│   └── lex.50.50.zhen.s2t.bin          shortlist 词汇表 (9,220,016 B)
└── en-zh/  (英 → 中, id=enzh, 单词表档)   ← 下载后生成
    ├── model.enzh.intgemm.alphas.bin   intgemm 量化权重 (59,504,955 B)
    ├── vocab.enzh.spm                  sentencepiece 词表 (1,358,432 B)
    └── lex.50.50.enzh.s2t.bin          shortlist 词汇表 (6,298,264 B)
```

解压后合计 137,246,319 字节(约 131 MB)。

## 为什么不入库

GitHub 免费额度的 **Git LFS 存储与流量各 1 GB**。这组模型 131 MB,
会占去 12.8% 存储;而**每次 `git clone` 都消耗约 131 MB 流量**——
月配额仅够约 7 次克隆。

关键不在够不够,而在**超额后果**:额度耗尽时 GitHub 会**停用该仓库的
LFS 读写**(不是自动计费放行),届时 `git clone` 会在 checkout 阶段直接
失败。把模型放进 LFS,会让「下载兜底」本身变成单点故障——与入库的初衷
正好相反。

改为清单 + 多源分发后:仓库保持轻量(本目录纯文本约 19 KB),
克隆不再触发大流量,任一源失效仍有另两个可用。

## 来源

- 官方仓库(mozilla/firefox-translations-models,已归档):
  https://github.com/mozilla/firefox-translations-models
- Hugging Face 镜像(mukowaty/firefox-translations):
  https://huggingface.co/mukowaty/firefox-translations
  - zh-en 取自 `zh-en/` 目录
- Mozilla 官方 GCS 分发点:
  https://storage.googleapis.com/moz-fx-translations-data--303e-prod-translations-data/models/en-zh/
  - en-zh 取自 `cjk_hplt2_lr0003_70x30_cF8zUnvoQluf7YmUggAnfg/exported/`

⚠️ en-zh **刻意不用** HF 镜像那一版——它是 `srcvocab`/`trgvocab` 双词表,
而 slimt 的 `Package` 只接受单个 `vocabulary` 字段(G4.1 实测)。
GCS 这一版是单词表,才是可用的。

## 许可

**Mozilla Public License 2.0 (MPL-2.0)**

- 详情: https://www.mozilla.org/MPL/2.0/
- 模型不带附加限制,MPL-2.0 允许随产品分发。
- MPL-2.0 要求对**修改过的文件**提供源代码;本项目分发的模型与上游
  **逐字节一致,未做任何修改**,故无此义务。
- Release 附件与上游同放了 `LICENSE-MPL-2.0.txt` 与写明出处的
  `README.txt`,满足再分发时随附许可声明的要求。

## SHA-256 校验

以下为**解压后**文件的哈希,各源通用。上游的 `.gz` 是其自行压缩的
产物,字节与我方不同(gzip 时间戳与压缩级别差异),但解压后内容一致。

| 文件 | SHA-256 |
|---|---|
| zh-en/model.zhen.intgemm.alphas.bin | `3535442962ec8f4a553cc19b206befcac689ee9cddaea44fa91e21527fc30ac2` |
| zh-en/vocab.zhen.spm | `dff594318ab7d8b7b60b844ab98ebe6b932ae8045fab15235404c787715965b3` |
| zh-en/lex.50.50.zhen.s2t.bin | `cdcad3592dc2bc4676c34c4d37203f7649ee989195cf083cbb60f1ea011f976b` |
| en-zh/model.enzh.intgemm.alphas.bin | `31ba296821cfffcf4713176ed6f331eb1faf3f8fe433f454a37e722b5f8c4b17` |
| en-zh/vocab.enzh.spm | `1ffaf806d8a17446675e04c99472ea716f7519d2a53ff826a1df8fa9bbcdf941` |
| en-zh/lex.50.50.enzh.s2t.bin | `06fbe7ddd8ca547d47a68c104c5a84577e44b29de935a0e4eb5957603d746ec3` |

## 使用

模型经 App 内 SAF 目录选择导入(会复制进 app 私有目录),或由构建流程
预置进 APK。slimt 用 mmap 读真实文件路径,不认 `content://` URI。
