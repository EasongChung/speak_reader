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
└── en-zh/  (英 → 中, id=enzh, 双词表档)   ← 下载后生成
    ├── model.enzh.intgemm.alphas.bin   intgemm 量化权重 (42,992,955 B)
    ├── srcvocab.enzh.spm               源侧 sentencepiece 词表 (806,952 B)
    ├── trgvocab.enzh.spm               目标侧 sentencepiece 词表 (772,004 B)
    └── lex.50.50.enzh.s2t.bin          shortlist 词汇表 (6,506,248 B)
```

解压后合计 121,162,827 字节(约 116 MB)。

> **en-zh 是双词表档**:两份 `.spm` 共享同一张 `Wemb` 嵌入矩阵,却是**两套不同的
> id 空间**(实测逐 id 仅 0.82% 重合,例如 id 266 在 srcvocab 是 `▁of`、
> 在 trgvocab 却是 `的`)。二者不可互换、不可合并 —— 传反了不会报错,只会
> 输出乱码。App 侧须把 `srcvocab` 给 `vocabulary_path`、`trgvocab` 给
> `target_vocabulary_path`。zh-en 仍是单词表档,`target_vocabulary_path`
> 留空即退化为单词表行为。

## 为什么不入库

GitHub 免费额度的 **Git LFS 存储与流量各 1 GB**。这组模型 116 MB,
会占去 11.6% 存储;而**每次 `git clone` 都消耗约 116 MB 流量**——
月配额仅够约 8 次克隆。

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
  - en-zh 取自 `cjk_split_vocab_e3B-g-FeQSyTW33DUj2Btw/exported/`

### en-zh 为何选 `cjk_split_vocab`

官方 registry 里 en-zh 只有两个变体,**两个都是双词表**:

| | `cjk_split_vocab` | `llmaat_finetune10M_qe8_f2` |
|---|---|---|
| architecture | base | base-memory |
| releaseStatus | None | **Release** |
| decoder 层数 | 2 | 4 |
| 嵌入矩阵 | 单张 `Wemb` | `encoder_Wemb` + `decoder_Wemb` |
| chrf | **35.09** | 33.09 |
| comet22 | 0.8556 | **0.8628** |

标 `Release` 的那版用不了:slimt 硬编码只认单张 `Wemb` 与 2 层 decoder
(`Transformer.cc` 的参数注册、`Model.cc` 的 preset),而 `load_parameters()`
对缺失张量**只打 `[warn]` 不抛错** —— 加载 `llmaat` 不会失败,只会静默留下
未初始化的嵌入与输出层,表现为译文全乱。在 slimt 支持 `base-memory` 架构前
只能用 `cjk_split_vocab`,它的 chrf 反而更高。

⚠️ `releaseStatus=None` 意味着官方可能下架或变更 —— 上一版所用的
`cjk_hplt2_lr0003_70x30_*` 就已从 registry 消失。整包源(GitHub Release)
正是为此兜底:上游没了仍可从 Release 取到逐字节一致的副本。

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
| en-zh/model.enzh.intgemm.alphas.bin | `ce4486f728641a36269a245248dcb53405e76d96d9eba68dcb4172f29521e092` |
| en-zh/srcvocab.enzh.spm | `bd9b65504acc6d9726dd281f7defc2adb7c2c22d0688fe2f84697de25197c8c5` |
| en-zh/trgvocab.enzh.spm | `aded6993c36e440284d11cec3f6b8aef9c0e43188a772d80be342a713adf223d` |
| en-zh/lex.50.50.enzh.s2t.bin | `4a5e5827788060f1d718a8132b69440929387514a045796e9b77f935db68c055` |

## 使用

在 App 设置页选择本目录下载好的 zip 导入(按语向各一个包,内容会解出到
app 私有目录)。slimt 用 mmap 读真实文件路径,不认 `content://` URI,
故必须复制而非直接引用。
