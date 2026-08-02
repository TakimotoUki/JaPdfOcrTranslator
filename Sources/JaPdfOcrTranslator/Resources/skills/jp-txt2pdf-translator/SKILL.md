---
name: jp-txt2pdf-translator
description: "将用户提供的 txt 格式日语书籍/论文完整、忠实地翻译为简体中文，并输出排版美观的完整中文 PDF 译文。内置九阶段流水线（初始化→切分→全书预扫→风格定调→逐块翻译→跨块修复→质检→一致性QA→合并交付），全程以 state/ 目录为中间状态契约：术语库唯一写路径 glossary_tool.py（含锁定词条与冲突裁决）、断点续跑（state_tool.py pending + 输入/参数双哈希判定）、事件流可取证（events.jsonl）、术语符合率与段落对齐质检。当用户提供日文 .txt 要整本/整篇翻译、需保留格式、要术语一致、要 PDF 中文译文、或上次任务中断需续跑时使用。关键词：日译中、日语翻译、书籍翻译、论文翻译、txt 翻译、OCR 文本、长文分段、术语表、九阶段、断点续跑、一致性QA、PDF 译文、保格式。"
version: 3.3.0
agent_created: true
---

# JP TXT → PDF Translator（日文 txt 书籍/论文 → 忠实中文 + 美观 PDF）

## 环境与约定

每次执行前先在心里固化三个变量：

- `$PY` —— Python 解释器。由调用方注入；脚本层零第三方依赖（仅 `build_pdf.py` 需要 `reportlab`，由调用方预装）。
- `$SKILL` —— 本 skill 的脚本目录，即 `.../jp-txt2pdf-translator/scripts`。
- `$STATE` —— **调用方 prompt 给出的绝对路径**，即 `<outDir>/state`。所有中间产物一律写进 `$STATE`。

**硬性约定（违反会造成孤儿文件 B1）**：

1. **`$STATE` 必须由调用方 prompt 以绝对路径给出**；不要自己猜一个相对路径。
2. **所有中间产物一律写 `$STATE`，禁止写进 skill 目录**。skill 目录是只读模板，只有 `$SKILL/*.py` 脚本本身。
3. 每个脚本都接受 `--state $STATE`（或 `--out $STATE`）；写文件永远用脚本，不用 shell 重定向到 `$STATE` 之外。
4. 翻译细则贯穿全程，动手前先读 `references/translation_guide.md`；遇到术语表策略问题先读 `references/glossary_policy.md`；S3 写风格指南前先读 `references/style_guide_template.md`。

## 启动必做（先于任何阶段）

1. **断点续跑**：第一步永远是
   ```bash
   $PY $SKILL/state_tool.py pending --state $STATE
   ```
   - 若返回的 `pending` 非空：说明上次任务中断，**已完成块不得重译**，只处理 `pending` 列表里的块；
   - 对因策略跳过、无需处理的块调 `$PY $SKILL/state_tool.py mark-chunk --state $STATE --chunk N --value skipped --reason resume`；
   - 若 `pending` 为空且 `status.finished == true`：任务已完成，直接跳到「收尾交付」复核产物即可。
2. **读取流水线配置**（决定哪些阶段要跑）：
   ```bash
   $PY -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1],encoding="utf-8")), ensure_ascii=False, indent=2))' "$STATE/config.json"
   ```
   关注 `path_mode`、`prescan_mode`、`prescan_sample_indices`、`stages`、`params` 五个键，**照抄 config，不要自行判断**：
   - `path_mode == "simple"` → **跳过 S2**，S3 并入 S4（不单独做风格定调）；
   - `prescan_mode == "sampled"` → 只对 `prescan_sample_indices` 里的块做梗概；
   - `stages` 数组列出本次实际要执行的阶段，未列出的阶段直接跳过。

## 九阶段总览

| 阶段 | 名称 | 关键产物 | 可跳过 |
|:---:|---|---|:---:|
| S0 | 初始化 | `config.json`、`status.json` | 否 |
| S1 | 切分与结构分析 | `structure.json`、`manifest.json`、`chunks/` | 否 |
| S2 | 全书预扫 | `book_synopsis.md` | 是 |
| S3 | 样本分析与风格定调 | `samples/sample_pack.md`、`style_guide.md` | 是 |
| S4 | 逐块翻译 | `chunks/chunk_NNN_zh.txt` | 否 |
| S5 | 跨块边界修复 | `boundary_report.json` | 是 |
| S6 | 确定性质检 | `alignment_report.json` | 是 |
| S7 | 一致性 QA | `qa_issues.json` | 是 |
| S8 | 合并与交付 | `translation_full.txt`、`original_full.txt`、`report.md`、PDF | 否 |

### S0 · 初始化

**输入**：用户选择的日文 txt（绝对路径）、后端类型（`workbuddy` / `deepseek`）、参数对象。

**命令**：
```bash
$PY $SKILL/state_tool.py init --state "$STATE" \
    --input "<日文txt绝对路径>" --backend <workbuddy|deepseek> \
    --params-json '{"glossary_policy":"B","auto_glossary_enabled":true,"glossary_scope":"chunk","pre_extract_mode":"always","pre_extract_first_n":10,"enable_prescan":true,"enable_style_analysis":true,"enable_punct_normalize":true,"enable_qa":true,"enable_polish":false,"enable_resume":true,"max_chars_per_chunk":4000,"max_chars_per_paragraph":8000,"bilingual":false,"user_glossary_sha256":""}'
```
- 参数对象里的键与调用方设置一一对应；`glossary_policy` 由调用方按「有表 × 自动开关」推好（A/B/C/D），不要自行改。
- 若 init 输出 `{"resumable":true,...}` → 续跑，按「启动必做」处理；若退 `4` 且 `reason` 非空 → **不要继续**，把 `reason` 报给调用方（输入或参数已变，需要归档旧状态或改参数）。

**必须产出（文件清单）**：
- `$STATE/config.json`
- `$STATE/status.json`
- `$STATE/events.jsonl`（含 `run_init` 或 `run_resume` 事件）

**进入下一阶段前的自检**：
```bash
test -s "$STATE/config.json" || echo "MISSING config.json"
test -s "$STATE/status.json" || echo "MISSING status.json"
test -s "$STATE/events.jsonl" || echo "MISSING events.jsonl"
```

### S1 · 切分与结构分析

**输入**：`$STATE/config.json`（已由 S0 写入）；日文 txt。

**命令**：
```bash
$PY $SKILL/split_text.py --input "<日文txt绝对路径>" --out "$STATE" --target 4000 --maxp 8000 --format json
$PY $SKILL/state_tool.py set-stage --state "$STATE" --stage S1 --name "切分与结构分析"
$PY $SKILL/state_tool.py set-stage --state "$STATE" --stage S1 --finish
```
- 切分点永远落在段落之间或完整句子之后，绝不拦腰截断句子。
- `--target` 与 `--maxp` 取自 `config.json.params`（`max_chars_per_chunk` / `max_chars_per_paragraph`）。

**必须产出（文件清单）**：
- `$STATE/structure.json`
- `$STATE/manifest.json`（v3.2 兼容）
- `$STATE/chunks/chunk_001.txt`、`chunk_002.txt`、…（每块一个源文文件）

**进入下一阶段前的自检**：
```bash
test -s "$STATE/structure.json" || echo "MISSING structure.json"
test -s "$STATE/manifest.json" || echo "MISSING manifest.json"
test -n "$(ls "$STATE"/chunks/chunk_*.txt 2>/dev/null)" || echo "MISSING chunks/"
```

### S2 · 全书预扫

**输入**：`$STATE/config.json`（`prescan_mode`、`prescan_sample_indices`）；`$STATE/chunks/`。

**命令**：
```bash
# 1) 对每个需预扫的块写 ≤200 字中文梗概到 digests/chunk_NNN.md，并留事件证据：
$PY $SKILL/state_tool.py event --state "$STATE" --type digest_written --chunk N --json '{"chars":<梗概字数>}'
# 2) 归并成包（默认每包 20 条）：
$PY $SKILL/reduce_digests.py --state "$STATE" --group 20
# 3) 依据 digest_pack 通读全书，写全书梗概：
#    ……在编辑器里把梗概写入 $STATE/book_synopsis.md（≤800 字）……
$PY $SKILL/state_tool.py event --state "$STATE" --type synopsis_written --json '{"chars":<字数>,"source":"sampled|full"}'
$PY $SKILL/state_tool.py set-stage --state "$STATE" --stage S2 --finish
```
- `prescan_mode == "sampled"` 时，**只**对 `config.json.prescan_sample_indices` 里的块写梗概；`"off"` 或 `path_mode == "simple"` 时整段跳过本阶段。
- `source` 字段：`sampled` 表示抽样预扫，`full` 表示全书预扫。

**必须产出（文件清单）**：
- `$STATE/book_synopsis.md`
- `$STATE/samples/digest_pack_01.md`（及后续序号包）

**进入下一阶段前的自检**：
```bash
test -s "$STATE/book_synopsis.md" || echo "MISSING book_synopsis.md"
test -s "$STATE/samples/digest_pack_01.md" || echo "MISSING digest_pack_01.md"
```

### S3 · 样本分析与风格定调

**输入**：`$STATE/chunks/`；`$STATE/book_synopsis.md`（若 S2 执行过）；`$STATE/config.json`（`prescan_sample_indices`）。

**命令**：
```bash
# 1) 抽样（默认 3 块，每块截取 ≤3000 字符，自动选前/中/后）：
$PY $SKILL/sample_text.py --state "$STATE" --n 3 --chars 3000
# 2) 依据 sample_pack 归纳风格，写风格指南：
#    ……按 references/style_guide_template.md 的六字段模板写入 $STATE/style_guide.md ……
$PY $SKILL/state_tool.py event --state "$STATE" --type style_guide_written --json '{"chars":<字数>}'
# 3) 建立初始术语表（无词也要以空数组调用一次，留下证据）：
printf '%s' '{"terms":[]}' | $PY $SKILL/glossary_tool.py upsert --state "$STATE" --phase post --chunk 0 --stdin
$PY $SKILL/state_tool.py set-stage --state "$STATE" --stage S3 --finish
```

**必须产出（文件清单）**：
- `$STATE/samples/sample_pack.md`
- `$STATE/style_guide.md`
- `$STATE/glossary.json`（含 `glossary_init` 事件后的初始状态）

**进入下一阶段前的自检**：
```bash
test -s "$STATE/samples/sample_pack.md" || echo "MISSING sample_pack.md"
test -s "$STATE/style_guide.md" || echo "MISSING style_guide.md"
test -s "$STATE/glossary.json" || echo "MISSING glossary.json"
```

### S4 · 逐块翻译

**输入**：`$STATE/config.json`（`params.glossary_policy`、`params.pre_extract_mode`、`params.pre_extract_first_n`）；`$STATE/pending` 列表；`$STATE/chunks/chunk_NNN.txt`；`$STATE/style_guide.md`；`$STATE/book_synopsis.md`。

**命令 —— 五步强制流程（每块必须按此顺序执行）**：

> **① `upsert --phase pre` 必须早于 ③ 翻译。即使无新词也要以 `{"terms":[]}` 调用一次。这是本 skill 唯一的硬性时序要求。**

```bash
# ① 译前预抽（独立一步，先于翻译；preExtractMode=off 时也须以空数组调用留证据）
printf '%s' '{"terms":[{"source":"...","target":"...","type":"人物"}]}' \
  | $PY $SKILL/glossary_tool.py upsert --state "$STATE" --chunk N --phase pre --stdin

# ② 命中裁剪：只拿本块要用的术语子集
$PY $SKILL/glossary_tool.py hits --state "$STATE" --chunk N --scope chunk --format md

# ③ 翻译（风格→全书梗概→本块梗概→本块命中术语→前文尾部→原文），
#    把中文译文纯文本写入 $STATE/chunks/chunk_NNN_zh.txt

# ④ 译后回抽：依据译文中实际采用的写法校准
printf '%s' '{"terms":[{"source":"...","target":"...","type":"人物"}]}' \
  | $PY $SKILL/glossary_tool.py upsert --state "$STATE" --chunk N --phase post --stdin

# ⑤ 落盘（zh_chars = 译文字符数）
$PY $SKILL/state_tool.py mark-chunk --state "$STATE" --chunk N --value done --zh-chars <K>
```
- 只处理 `pending` 列表里的块；`preExtractMode == "firstNChunks"` 时只对 `N ≤ preExtractFirstN` 的块做真实预抽，其余块仍以 `{"terms":[]}` 调用留证据。
- 翻译原则见 `references/translation_guide.md`；术语策略与正反例见 `references/glossary_policy.md`。
- 完成后立刻 `set-stage` 到 S5 并继续，不需要等人工确认。

**必须产出（文件清单）**：
- 每个已译块 `$STATE/chunks/chunk_NNN_zh.txt`
- `$STATE/glossary.json` 持续更新（hits/回抽）
- `$STATE/events.jsonl` 含每个块的 `glossary_pre_extract{chunk:N}`（seq 递增）与 `chunk_translated{chunk:N}`

**进入下一阶段前的自检**：
```bash
$PY $SKILL/state_tool.py verify --state "$STATE" --check pre-extract-order --format json
# 输出 compliant=true 才继续；false 时按 missing_pre_extract 列表补齐预抽后重验
test -s "$STATE/chunks/chunk_001_zh.txt" || echo "MISSING 首个译块"
```

### S5 · 跨块边界修复

**输入**：`$STATE/chunks/`（源文 + 译文）。

**命令**：
```bash
$PY $SKILL/check_boundaries.py --state "$STATE"
# 对报告中标出的「上块结尾未完句 + 下块开头续句」：
#   · 若确是被拦腰截断的句子 → 合并成完整句子重新翻译，修正对应 chunk_NNN_zh.txt；
#   · 每修一处留一条证据：
$PY $SKILL/state_tool.py event --state "$STATE" --type boundary_fixed --chunk N --json '{"pairs":1}'
$PY $SKILL/state_tool.py set-stage --state "$STATE" --stage S5 --finish
```

**必须产出（文件清单）**：
- `$STATE/boundary_report.json`

**进入下一阶段前的自检**：
```bash
test -s "$STATE/boundary_report.json" || echo "MISSING boundary_report.json"
```

### S6 · 确定性质检

**输入**：`$STATE/chunks/`（源文 + 译文对）。

**命令**：
```bash
$PY $SKILL/check_alignment.py --state "$STATE"
# 若退 5（存在段落数不匹配等 error 级问题）：按报告 error_chunks 修正对应译块后重跑，
# 直到退 0 为止。
$PY $SKILL/normalize_punct.py --state "$STATE"
$PY $SKILL/state_tool.py set-stage --state "$STATE" --stage S6 --finish
```
- 对齐要求：译文段落数须与原文一致（细则见 `references/translation_guide.md`）。
- 标点规范与 `normalize_punct.py` 完全一致（`「」→“”`、`『』→‘’`、半角→全角、`...`→`……`、`--`→`——`）；代码围栏内不改。

**必须产出（文件清单）**：
- `$STATE/alignment_report.json`
- 规范化后的 `$STATE/chunks/chunk_NNN_zh.txt`

**进入下一阶段前的自检**：
```bash
test -s "$STATE/alignment_report.json" || echo "MISSING alignment_report.json"
```

### S7 · 一致性 QA

**输入**：`$STATE/chunks/`；`$STATE/glossary.json`；`$STATE/config.json`（`params.glossary_policy`）。

**命令**：
```bash
$PY $SKILL/qa_consistency.py --state "$STATE" --fail-on error --min-term-rate 0.98
# 若退 5：按 qa_issues.json 修正译块（术语违例、日文残留、占位符损坏等）后重跑，直到退 0。
$PY $SKILL/glossary_tool.py conflicts --state "$STATE" --fail-if-open
# 若退 5（存在未决冲突）：用 resolve 裁决（锁定的用户词条不可改，只可裁决自动词条冲突）：
$PY $SKILL/glossary_tool.py resolve --state "$STATE" --source "<source>" --take proposed
$PY $SKILL/state_tool.py set-stage --state "$STATE" --stage S7 --finish
```
- 术语策略 A 下 `qa_consistency` 可能只给只读建议（`emitsSuggestions`），不强制改译块；详见 `references/glossary_policy.md`。

**必须产出（文件清单）**：
- `$STATE/qa_issues.json`
- 修正后的 `$STATE/chunks/chunk_NNN_zh.txt`
- （若发生过裁决）更新后的 `$STATE/glossary_conflicts.json`

**进入下一阶段前的自检**：
```bash
test -s "$STATE/qa_issues.json" || echo "MISSING qa_issues.json"
$PY $SKILL/state_tool.py verify --state "$STATE" --check chunk-complete --format json
```

### S8 · 合并与交付

**输入**：`$STATE/chunks/`；`$STATE/config.json`；`$STATE/status.json`；`$STATE/glossary.json`；各质检报告。

**命令**：
```bash
# 1) 合并译文全文与原文全文
$PY $SKILL/merge.py --indir "$STATE/chunks" --out "$STATE/translation_full.txt" --pattern 'chunk_*_zh.txt' --state "$STATE"
$PY $SKILL/merge.py --indir "$STATE/chunks" --out "$STATE/original_full.txt" --pattern 'chunk_*.txt' --exclude '*_zh.txt' --state "$STATE"
# 2) 汇总报告（七段：规模进度 / 术语表 / 对齐 / QA / 合规 / 降级说明 / 产物）
$PY $SKILL/make_report.py --state "$STATE"
# 3) 生成 PDF（zh 必出；bi 仅 workbuddy 后端且 bilingual=true 时）
$PY $SKILL/build_pdf.py --input "$STATE/translation_full.txt" --output "<输出目录>/<书名>_zh.pdf" --title "<书名>" --author "<作者>" --date "<YYYY-MM-DD>"
# 4) 导出术语表（B/C 结束时把自动词条导出，供用户一键收编）
$PY $SKILL/glossary_tool.py export --state "$STATE" --out "$STATE/glossary_export.csv" --format csv5 --origin auto
# 5) 收尾
$PY $SKILL/state_tool.py status --state "$STATE" --finish --message "全流程完成"
```

**必须产出（文件清单）**：
- `$STATE/translation_full.txt`
- `$STATE/original_full.txt`
- `$STATE/report.md`
- `$STATE/glossary_export.csv`
- 输出 PDF（`<书名>_zh.pdf`；双语对照时另加 `<书名>_bi.pdf`）

**进入下一阶段前的自检**（本阶段即终态）：
```bash
test -s "$STATE/translation_full.txt" || echo "MISSING translation_full.txt"
test -s "$STATE/original_full.txt" || echo "MISSING original_full.txt"
test -s "$STATE/report.md" || echo "MISSING report.md"
test -s "$STATE/glossary_export.csv" || echo "MISSING glossary_export.csv"
```

## 收尾交付

用 `present_files` 交付：生成的 `.pdf`、`$STATE/translation_full.txt`（纯文本备份）、`$STATE/report.md`（质量汇总）。简述：原文块数、译文总字数、S6 对齐结论、S7 术语符合率、F33-02 合规结论、PDF 是否含封面/是否对照。

## Resources

### scripts/（全部 13 个，均为本 skill 自带）
- `_common.py` — 公共库：文件锁 / 原子写 / 事件 / 退出码 / §4.3 匹配。
- `state_tool.py` — state 目录管理：init / set-stage / mark-chunk / pending / status / event / verify / reset。
- `glossary_tool.py` — 术语唯一写路径：init / upsert / hits / render / conflicts / resolve / export / import / stats。
- `split_text.py` — 解码 + 智能分块，产出 `structure.json` / `manifest.json` / `chunks/`。
- `sample_text.py` — 均匀抽样，产出 `samples/sample_pack.md`。
- `reduce_digests.py` — 梗概归并，产出 `samples/digest_pack_*.md`。
- `check_boundaries.py` — S5 辅助：跨块截断句检测（只检测不改文件）。
- `check_alignment.py` — S6 段落对齐，error 级问题退 5。
- `normalize_punct.py` — S6 标点规范化（围栏保护，`--dry-run` 只报数）。
- `qa_consistency.py` — S7 一致性 QA（日文残留 / 术语符合率 / 占位符 / 数字 / 标点 / 段落）。
- `merge.py` — 按编号合并各块为完整全文。
- `make_report.py` — 汇总全部 state 产物 → `report.md`（七段）。
- `build_pdf.py` — 将全文排成美观中文 PDF（reportlab，唯一第三方依赖）。

### references/
- `translation_guide.md` — 翻译细则：术语类型 / SOURCE_ONLY_TYPES、预抽回抽判据、标点规范、段落对齐、格式保真。
- `glossary_policy.md` — 术语策略 A/B/C/D 的 Agent 行为手册（正例 + 反例）。
- `style_guide_template.md` — S3 风格指南六字段模板与填写示例。

## Notes / Boundaries

- 输入限定为 `.txt`。若收到 PDF/图片，请用户先提供 OCR 后的 .txt。
- 分块仅在段落/完整句子之间切分；S5 兜底还原跨块截断句。
- 术语表唯一写路径是 `glossary_tool.py`；锁定词条（`locked=true`，通常来自用户表）**任何情况下不得改写**，冲突只记 `rejected_by_lock` 证据。
- `events.jsonl` 是 F33-02 唯一验收依据：每个已译块必须存在 `glossary_pre_extract{chunk:N}`（`actor=script`，由 `upsert --phase pre` 产生），且先于 `chunk_translated`。`state_tool.py event` 手工补 `glossary_pre_extract` 无效。
- 本 skill 只依赖脚本与 `$STATE`；不读、不写 skill 目录之外的任何文件。
