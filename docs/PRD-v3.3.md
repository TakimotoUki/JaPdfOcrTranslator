# JaPdfOcrTranslator v3.3 增量 PRD

| 项 | 值 |
|---|---|
| 文档版本 | v3.3 增量 PRD |
| 基线版本 | v3.2（`JaPdfOcrTranslator-Swift`，Swift 6 + SwiftUI，macOS 26 Liquid Glass） |
| 新目录 | `JaPdfOcrTranslator-Swift-v33`（v3.2 原目录只读，不修改） |
| 作者 | 许清楚（产品经理） |
| 主要参考 | `wenyi-0.4.0`（trans-novel）翻译流水线 |
| 语言 | 中文 |

---

## 1. 版本目标

> **一句话**：把"写死六步、术语表二选一都不理想"的翻译 skill，升级为**带全书理解、术语库动态驱动、可断点续跑、可观测**的工程化流水线。

核心价值：

| # | 价值 | 说明 |
|---|---|---|
| V1 | **术语一致性有兜底** | 用户有表 → 严格执行；用户无表 → 自动建表。任何情况下都不再出现"零术语约束"的裸奔翻译 |
| V2 | **术语表随翻译动态演进** | 每块翻译**之前**先更新该块术语，翻译时只注入本块命中词条，既保证一致又不撑爆上下文 |
| V3 | **全书理解先行** | 借鉴 wenyi：先预扫成章节梗概 + 全书概览 + 风格指南，再逐块翻译，消除"早期章节盲译" |
| V4 | **可中断可续跑** | 状态目录逐块落盘，中断后重跑只补未完成部分，不重复烧 token / 不重复等 6 小时 |
| V5 | **过程可观测** | 应用不再只是"盯着 PDF 文件出现"，而能看到阶段、块进度、术语条数、冲突数 |

---

## 2. 变更范围

### 2.1 保留不变（本次不动）

| 模块 | 文件 | 说明 |
|---|---|---|
| OCR / 文本抽取 | `Core/OcrEngine.swift`、`Core/TextExtractor.swift` | PDF/docx → 日文 txt 链路完全不变 |
| Python 引导 | `Core/PythonBootstrap.swift` | venv / reportlab 依赖策略不变 |
| skill 同步与自愈 | `Core/SkillRegistry.swift` | SHA-256 树签名 + 非破坏性 merge 机制保留（仅 `requiredScripts` 清单扩充） |
| deep link 协议 | `buildTaskURL()` | `workbuddy://task?action=start&prompt=&cwd=&skills=` 不变 |
| PDF 排版引擎 | `PDF/PdfBuilder.swift`、`scripts/build_pdf.py` | 排版风格、封面、双语模式不变 |
| 三份产物 | 中文 / 日文 / 双语 PDF | 交付形态不变 |
| 整体 UI 框架 | `MainView` 的 SectionCard 布局 | 只增卡片、不重构 |

### 2.2 本次改动

| 层 | 对象 | 改动性质 |
|---|---|---|
| skill 文档 | `Resources/skills/jp-txt2pdf-translator/SKILL.md` | **重写工作流**：六步 → 九阶段 |
| skill 脚本 | `scripts/` | 新增 6 个脚本；增强 `split_text.py` |
| skill 参考 | `references/` | 新增 `glossary_policy.md`、`style_guide_template.md` |
| Swift 模型 | `Models/Glossary.swift` | 两栏 CSV → 结构化术语库（向后兼容） |
| Swift 模型 | `Models/Settings.swift` | 新增 8 个设置项 |
| Swift 后端 | `Translate/WorkBuddyBackend.swift` | `buildPrompt()` 重写；轮询从"看 PDF"→"看 status.json" |
| Swift 后端 | `Translate/DeepSeekTranslator.swift` | 六步 → 与 skill 对齐的多阶段编排 |
| Swift 提示词 | `Translate/TranslationPrompts.swift` | 删除硬编码"不要生成自动术语表" |
| Swift UI | `UI/GlossaryEditorView.swift` | 编辑器增强（类型 / 来源 / 冲突 / 导入） |
| Swift UI | `UI/MainView.swift`、`UI/SettingsView.swift` | 新增进度详情卡片 + 流水线开关组 |

---

## 3. 用户故事

| # | 场景 | 用户故事 |
|---|---|---|
| US-1 | 术语表·有 | 作为**已在软件内维护了人名地名对照的用户**，我希望我填的每一条译名都被**逐字执行、绝不被模型改写**，这样系列作品的角色名才能跨书统一 |
| US-2 | 术语表·无 | 作为**第一次翻一本陌生小说的用户**，我没精力事先建表，我希望软件**自动建立并持续维护术语表**，这样全书人名不会前后打架 |
| US-3 | 术语表·混合 | 作为**只填了主角名的用户**，我希望我填的部分锁死，**其余新出现的专名由软件自动补齐**，而不是二选一 |
| US-4 | 术语表·产出 | 作为用户，我希望翻译结束后能**看到软件自动生成的术语表并一键收编为我的自定义表**，下次翻续集直接复用 |
| US-5 | 翻译质量 | 作为读长篇小说的用户，我希望翻译第 1 章时译者**已经知道结局和人物关系**，避免伏笔被译错 |
| US-6 | 翻译质量 | 作为用户，我希望译文**标点统一为简体中文全角**，不残留日式 `「」` 和半角符号 |
| US-7 | 质量校验 | 作为用户，我希望软件能自动查出**日文残留、段落数不匹配、术语命中却译名不符**这类硬错误，而不是只靠模型自觉 |
| US-8 | 可观测 | 作为等待中的用户，我希望进度区显示**"阶段 4/9 · 第 12/48 块 · 术语 137 条 · 冲突 2"**，而不是"已等待 3271s，仍在处理…" |
| US-9 | 断点续跑 | 作为**翻到一半断电 / 手滑中止的用户**，我希望重新点开始时**从第 13 块继续**，前 12 块不重译 |
| US-10 | 报告 | 作为用户，我希望拿到 PDF 的同时拿到一份**翻译报告**（块数、字数、术语数、冲突、QA 问题清单） |
| US-11 | 成本控制 | 作为在意时长/费用的用户，我希望能在设置里**关掉预扫、QA、润色**，回到快速模式 |

---

## 4. 需求池

> 优先级：**P0 必须有**（缺则 v3.3 不成立）｜**P1 应该有**｜**P2 锦上添花**
> 后端列：**WB** = WorkBuddy 后端（skill 约束 Agent）｜**DS** = DeepSeek 后端（应用内编排）

### 4.1 P0 —— 必须完整覆盖用户三点原话需求

| 编号 | 需求描述 | 后端 | 验收标准 |
|---|---|---|---|
| **F33-01** | **术语表来源决策**：按 §5 决策矩阵确定术语表来源与权限。用户在软件内编辑过（非空）→ 用户表为最高权威；否则 → 自动生成术语表 | WB+DS | 三种情形分别造样例运行：①有表 → 产物 `glossary.json` 中用户词条 `origin=user, locked=true` 且 target 与用户输入逐字相等；②无表 → 运行结束存在非空自动术语表且条目 ≥ 1；③有表+自动补充 → 用户词条零改动 且 新增词条 `origin=auto` |
| **F33-02** | **逐块译前术语更新**：翻译第 N 块**之前**，必须先对第 N 块源文做术语预抽取并写入术语库（新增/确认），再进入翻译 | WB+DS | `state/events.jsonl` 中每个块必须出现 `glossary_pre_extract{chunk:N}` 且其时间戳 **早于** 同块 `chunk_translated{chunk:N}`；缺失任一块则判定不通过 |
| **F33-03** | **翻译严格遵循术语表**：翻译第 N 块时，注入"本块命中词条"子集；模型必须对命中词条使用固定译名 | WB+DS | 用 20 条术语的对照集跑校验脚本 `qa_consistency.py --check terminology`，命中词条译名符合率 ≥ 98%；违例条目全部进 QA 报告 |
| **F33-04** | **结构化术语库**：术语库落盘为 `state/glossary.json`（字段：source/target/reading/type/gender/aliases/note/origin/locked/first_chunk/status）+ 冲突表 `state/glossary_conflicts.json`。同 source 不同 target → **保留现值 + 记冲突**，绝不静默覆盖 | WB+DS | 构造同名不同译冲突用例，运行后现值不变且冲突表出现该记录；用户 locked 词条永不进冲突流程（自动值直接丢弃并记 `rejected_by_lock`） |
| **F33-05** | **术语表策略指令下发**：删除 `Glossary.toPromptBlock()` 与 `buildPrompt()` 中硬编码的「不要生成自动术语表」，改为按决策矩阵动态生成策略段 | WB+DS | 全仓库 grep `不要生成自动术语表` 命中数 = 0；三种情形下生成的 prompt 分别含对应策略文本 |
| **F33-06** | **skill 工作流重写**：`SKILL.md` 从写死六步改为 §6 的九阶段流水线，含术语库阶段、预扫阶段、状态目录约定 | WB | `SKILL.md` 含九个阶段小节 + 每阶段"必须产出的文件"清单；`SkillRegistry.requiredScripts` 同步扩充并通过 `verify()` |
| **F33-07** | **状态目录与断点续跑**：所有中间产物写入 `<workdir>/state/`；每块译完立即落盘；重跑跳过已完成块 | WB+DS | 翻译到第 5/10 块中止 → 重新开始 → 日志出现 `chunk_skipped{1..5}`，仅 6–10 块被翻译；最终 PDF 与不中断跑结果段落数一致 |
| **F33-08** | **术语表编辑器可用性**：`GlossaryEditorView` 支持类型/备注列、来源标记、锁定标记、行选中删除、搜索过滤 | App | 能创建含 type/note 的词条并保存；重开编辑器字段无丢失；旧两栏 CSV 可正常加载（向后兼容） |
| **F33-09** | **进度可观测**：WB 后端轮询 `state/status.json` 而非仅轮询 PDF；主界面显示阶段名 + 块进度 + 术语数 | WB+DS | 翻译过程中主界面进度文案至少每 30s 刷新一次且包含 `阶段 x/9`、`第 i/N 块`；`status.json` 缺失时降级为 v3.2 的等待秒数文案（不崩溃） |

### 4.2 P1 —— 应该有

| 编号 | 需求描述 | 后端 | 验收标准 |
|---|---|---|---|
| F33-10 | **全书预扫**：逐块生成中文梗概（≤200 字/块）→ 归并出全书概览（≤500 字），作为恒定前缀注入每块翻译 | WB+DS | `state/digests/chunk_NNN.md` 数量 = 块数；`state/book_synopsis.md` 非空且 ≤500 字；可通过设置关闭 |
| F33-11 | **样本分析与风格指南**：抽取首/中/末样本 → 产出 `style_guide.md`（体裁/语气/叙事人称/句式节奏/语域/对话风格）+ 初始术语表 | WB+DS | `state/style_guide.md` 含 6 个字段小节；初始术语表条目 ≥ 5（正常小说） |
| F33-12 | **段落对齐质控**：逐块校验译文段落数与原文段落数一致；不一致则标记该块待复核 | WB+DS | `check_alignment.py` 对故意缺段的样例返回非零退出码并列出块号与差值 |
| F33-13 | **标点规范化**：译文统一为简体中文大陆全角标点（`，。！？：；、""''……——`），清除日式 `「」『』` 与半角标点 | WB+DS | `normalize_punct.py` 处理后样例中日式括号残留 = 0；围栏代码块内标点不被改动 |
| F33-14 | **一致性 QA 与报告**：收尾扫描（日文残留 / 术语违例 / 段落缺失 / 占位符与数字对齐 / 标点） → `state/report.md` | WB+DS | 生成 `report.md`，含块数、原文与译文字数、术语条数、冲突数、QA 问题列表（分类计数）；随 PDF 一并交付 |
| F33-15 | **自动术语表收编**：运行结束提示"发现 N 条自动术语，导入为我的术语表？"，一键写入用户术语表 | App | 点击导入后 `settings.glossaryPath` 指向的文件包含这 N 条，且 `origin` 转为 `user` |
| F33-16 | **术语冲突查看与裁决**：编辑器内展示冲突列表（现值 / 候选值 / 出现块），用户可一键选定最终译名 | App | 裁决后 `glossary.json` 该条 `status=ok`、target 为用户所选，冲突表对应记录标记 resolved |
| F33-17 | **DeepSeek 后端阶段对齐**：DS 后端在应用内真实编排 预扫 → 分析 → 逐块（预抽/翻译/回抽）→ 对齐校验 → 标点 → QA → PDF | DS | DS 后端 `state/` 目录结构与 WB 后端一致；F33-02 的事件顺序校验对 DS 同样通过 |
| F33-18 | **流水线开关设置项**：预扫 / 风格分析 / 自动术语补充 / 术语注入范围 / 标点规范化 / QA / 续跑 / 每块字符上限 | App | 设置页出现对应控件；关闭某阶段后 `state/` 中该阶段产物不生成且日志出现 `stage_skipped` |

### 4.3 P2 —— 锦上添花

| 编号 | 需求描述 | 后端 | 验收标准 |
|---|---|---|---|
| F33-19 | **润色阶段**（可选，默认关）：不改段数、不改语义，提升中文流畅度 | WB+DS | 开启后段落数不变；关闭时零额外开销 |
| F33-20 | **术语表频次统计**：编辑器显示每条术语在全书出现次数，支持按频次排序 | App | 频次列与 `qa_consistency.py` 统计值一致 |
| F33-21 | **报告 PDF 附录**：可选把术语表 + 报告作为附录并入中文 PDF 末尾 | WB+DS | 开启后 PDF 末尾出现"译者附录"章节 |
| F33-22 | **抽样回译校验**：按比例抽段回译日文与原文比对，标记疑似误译 | DS | 抽样比例可配；产出 `state/backtranslate.json` |
| F33-23 | **术语表跨书复用库**：把术语表存到应用级库，按作品/系列归档 | App | 可在新任务中选择历史术语表 |

---

## 5. 术语表决策矩阵（P0 核心）

### 5.1 判定输入

| 变量 | 取值 | 来源 |
|---|---|---|
| `hasUserGlossary` | 用户术语表存在且解析后条目数 ≥ 1 | `settings.glossaryPath` 指向文件 |
| `autoGlossaryEnabled` | 是否允许自动补充/生成 | `settings.autoGlossaryEnabled`，**默认 true** |

### 5.2 行为矩阵

| 情形 | hasUserGlossary | autoGlossaryEnabled | 术语库初始内容 | 自动新增 | 自动修改用户词条 | 冲突处理 | 注入 prompt 的策略文本（要点） | 结束时提示 |
|---|:---:|:---:|---|:---:|:---:|---|---|---|
| **A · 纯用户表** | ✅ | ❌ | 仅用户词条，全部 `locked=true` | **禁止** | **禁止** | 模型若用了别的译名 → 计为 QA 违例，不改表 | "术语表由用户提供，**逐字严格执行**；表中未列的专名，沿用前文首次译法，**不得另起译名**；**不要新增术语条目**" | 列出"疑似应入表但未入表"的候选（只读建议） |
| **B · 用户表 + 自动补充**（**默认**） | ✅ | ✅ | 用户词条 `locked=true` + 预扫产生的自动词条 `locked=false` | **允许**（仅限 source 不在用户表中） | **禁止** | 自动值与 locked 词条冲突 → 直接丢弃并记 `rejected_by_lock`；两条 auto 冲突 → 保留现值 + 记冲突 | "【锁定词条】必须逐字执行，优先级最高，**任何情况下不得改写**；【自动词条】为软件维护，遇新专名请补入；两者冲突时**无条件服从锁定词条**" | 提示导入 N 条自动词条（F33-15） |
| **C · 纯自动**（用户无表，**默认**） | ❌ | ✅ | 空 → 由样本分析阶段建立初始表 | **允许** | n/a | 保留现值 + 记冲突，收尾在报告中列出 | "用户未提供术语表，你必须**自行建立并持续维护**术语表；同一专名全书必须使用同一译名；每块翻译前先更新本块术语" | 提示导入全部自动词条 |
| **D · 无约束**（降级逃生口） | ❌ | ❌ | 空，不建表 | ❌ | n/a | 不做术语 QA | "本次不维护术语表"（等价 v3.2 行为） | UI 显示黄色风险提示"未启用术语一致性保障" |

> **默认路径说明**：`autoGlossaryEnabled` 默认 **true**，因此用户实际只会遇到 **B**（有表）或 **C**（无表）——这正是用户原话"有表用表、无表自动生成"的直译。A / D 需要用户主动去设置里关闭自动补充，属显式选择。

### 5.3 逐块动态更新时序（F33-02 / F33-03）

```
对每个 chunk_NNN：
  ① 【译前·预抽】读 chunk_NNN.txt 源文
     → 识别其中的专名/称呼/固定表达
     → 与 glossary.json 比对：
         · 已存在(locked)   → 采用其 target，不改
         · 已存在(auto)     → 采用其 target，可补 alias/note
         · 不存在           → 决定译名并 upsert(origin=auto, first_chunk=NNN)
     → 写事件 glossary_pre_extract{chunk:NNN, added:x, hit:y}
  ② 【命中裁剪】从 glossary.json 中筛出 source/alias 在本块出现的词条
     → 生成本块专属 glossary 子集（glossary_scope=chunk 时；full 时注入全表）
  ③ 【翻译】注入顺序（静态→动态，利于前缀缓存）：
     风格指南 → 全书概览 → 本块梗概 → 本块术语子集 → 前文译文尾部 → 待译原文
  ④ 【译后·回抽】用「原文 + 译文」比对，确认实际采用译名、抽取称呼变体
     → upsert；不一致则记冲突
     → 写事件 glossary_post_extract{chunk:NNN}
  ⑤ 【落盘】chunk_NNN_zh.txt + status.json 更新 → 可断点续跑
```

**硬性约束**：① 必须早于 ③。这是 F33-02 的唯一验收依据。

---

## 6. skill 新工作流阶段清单

### 6.1 设计前提（现实约束）

| 约束 | 后果 |
|---|---|
| skill = 给 LLM Agent 读的 markdown + 辅助 python 脚本 | **没有 LLM API 编排层**，无法实现多轮工具调用循环、并发调度、模型档位切换 |
| 所有"智能"步骤由 WorkBuddy Agent 自己顺序执行 | 阶段必须**线性、可自检、失败可恢复**；不能依赖代码级 retry |
| 脚本只做**确定性**工作 | 文本处理、切分、合并、正则校验、统计、JSON 读写、报告生成 |
| Agent 行为只能靠文档约束 + 产物存在性检查 | 每个阶段必须定义"必须产出的文件"，下一阶段开头先校验上一阶段产物 |

### 6.2 阶段清单（九阶段）

| 阶段 | 名称 | 执行者 | 输入 | 必须产出 | 对应 wenyi | 采纳判定 |
|:---:|---|---|---|---|---|---|
| **S0** | 环境与状态初始化 | 脚本 `state_tool.py init` | 用户 txt、策略参数 | `state/status.json`、`state/config.json` | （wenyi 的 RunStore） | 🆕 新增 |
| **S1** | 分段整理 + 结构切分 | 脚本 `split_text.py`（增强） | 日文 txt | `state/chunks/chunk_NNN.txt`、`state/structure.json`（章节边界/段落索引/字符数） | 解析章节、段落 | 🔧 改造（无 EPUB / 无目录锚点） |
| **S2** | 全书预扫（梗概 + 概览） | **Agent** + 脚本 `reduce_digests.py` | 各块源文 | `state/digests/chunk_NNN.md`、`state/book_synopsis.md` | 预扫整书生成章节梗概+全书概览 | ✅ 采纳（串行；长书用脚本分组做 map-reduce 打包） |
| **S3** | 样本分析（风格 + 初始术语） | **Agent** + 脚本 `sample_text.py` | 首/中/末抽样 | `state/style_guide.md`、`state/glossary.json`（初始） | 分析样章建立初始术语表和风格指南 | ✅ 采纳 |
| **S4** | 逐块翻译（译前预抽 → 命中注入 → 翻译 → 译后回抽） | **Agent** + 脚本 `glossary_tool.py` | 块源文 + 术语库 + 梗概 + 概览 + 风格 | `state/chunks/chunk_NNN_zh.txt`、`state/glossary.json`（滚动更新）、`state/events.jsonl` | 按章按批翻译 + 实时抽取更新术语 | ✅ **强化采纳**（wenyi 是译后抽取；本版按用户要求增加**译前预抽**） |
| **S5** | 边界修复（跨块截断句） | 脚本 `check_boundaries.py` + **Agent** | 相邻块 | 修正后的 `chunk_NNN_zh.txt` | （wenyi 用段级对齐，无此问题） | ♻️ 保留 v3.2 已有能力 |
| **S6** | 确定性质控 | 脚本 `check_alignment.py`、`normalize_punct.py` | 原译文对 | `state/alignment_report.json`、标点规范化后的译文 | 段数对齐 + 标点规范化 | 🔧 改造（段落级近似对齐，非 JSON 数组等长强约束） |
| **S7** | 一致性 QA + 全篇复核 | 脚本 `qa_consistency.py` + **Agent** | 全文 + 最终术语库 | `state/qa_issues.json`、修正后的译文 | 全书一致性 QA（取证式 Review 已裁剪） | 🔧 大幅简化 |
| **S8** | 合并 · 排版 · 报告 · 交付 | 脚本 `merge.py`、`build_pdf.py`、`make_report.py` | 全部译文块 | 三份 PDF、`state/report.md`、`state/glossary_export.csv` | 生成报告 + 回填组装 | ✅ 采纳（报告为新增） |

### 6.3 从 wenyi 借鉴 / 裁剪对照

| wenyi 能力 | 本版处理 | 理由 |
|---|:---:|---|
| 读取输入（EPUB/FB2/PDF/MD/HTML） | ❌ 裁剪 | 输入侧由 Swift 应用的 OCR/抽取链路负责，skill 只吃 txt |
| 解析章节 / 段落 / EPUB 目录 | 🔧 降级 | 只做 txt 章节标题识别 + 段落索引，无目录锚点回填 |
| 识别源语言 | ❌ 裁剪 | 场景固定 ja→zh |
| **预扫章节梗概 + 全书概览** | ✅ **采纳（S2）** | 直接对应用户"参考 wenyi 优化流程"，收益最高 |
| **样章分析 → 风格指南 + 初始术语表** | ✅ **采纳（S3）** | 同上 |
| **按批翻译 + 滚动上下文** | ✅ **采纳（S4）** | 前文译文尾部注入，保证跨块衔接 |
| **实时术语抽取更新 + 按章命中注入** | ✅ **强化采纳（S4）** | 用户明确要求；并加上 wenyi 没有的**译前预抽** |
| **术语冲突不静默覆盖 + 冲突表** | ✅ 采纳（F33-04） | wenyi `upsert_term` 语义直接搬 |
| **首次出现译法校准**（新术语沿用历史首译） | 🔧 简化采纳 | 由 Agent 在译后回抽时人工判断；不做 wenyi 的独立 LLM 校准调用 |
| 段数对齐（JSON 数组等长 + 逐段兜底） | 🔧 改造（S6） | Agent 输出自由文本，改为段落数近似校验 + 标记复核 |
| 标点规范化 | ✅ 采纳（S6） | 纯规则，脚本最合适 |
| 润色（强档全书重翻） | ⬇️ 降级为 P2 可选 | WB 后端时长翻倍、DS 后端费用翻倍，默认关 |
| 取证式 Agent Review Loop | ❌ 裁剪 | 需要工具调用协议 + 多轮取证 + 有界循环，skill 无编排层 |
| 跨块冲突仲裁 / 影子修订 / 盲复审 | ❌ 裁剪 | 需要不可变影子快照 + 多轮 diff 管理，成本远超收益 |
| 回译抽检 | ⬇️ P2（仅 DS 后端） | 需要程序化抽样与比对 |
| 全书一致性 QA | 🔧 简化采纳（S7） | 可规则化部分（日文残留/术语违例/占位符/数字/标点）走脚本，语义部分交 Agent |
| 生成报告 | ✅ 采纳（S8） | 纯汇总，脚本可做 |
| **断点续跑（状态目录）** | ✅ **采纳（S0/S4）** | 6 小时轮询场景下价值极大 |
| 模型档位（strong/cheap/fast） | ❌ 裁剪 | WB 后端由 WorkBuddy 统一选模型；DS 后端单模型 |
| 并发（预扫 / 审校并发） | ❌ 裁剪 | Agent 串行执行 |

### 6.4 脚本清单

| 脚本 | 状态 | 职责（**纯确定性**） |
|---|:---:|---|
| `split_text.py` | 🔧 增强 | 追加输出 `structure.json`（章节边界、段落索引、每块字符数） |
| `check_boundaries.py` | ♻️ 保留 | 跨块截断句检测 |
| `merge.py` | ♻️ 保留 | 按序合并 |
| `build_pdf.py` | ♻️ 保留 | 排版出 PDF |
| **`glossary_tool.py`** | 🆕 **核心** | 子命令：`init` / `upsert`（含冲突与 locked 语义）/ `hits --chunk`（命中裁剪）/ `render`（渲染为 prompt 块）/ `conflicts` / `resolve` / `export` / `stats` |
| **`state_tool.py`** | 🆕 | `init` / `set-stage` / `mark-chunk` / `pending`（列出待办块）/ `status`（写 `status.json`） |
| **`check_alignment.py`** | 🆕 | 原译文段落数对齐、空块、异常压缩比检测 |
| **`normalize_punct.py`** | 🆕 | 全角化 + 日式括号转换 + 代码围栏保护 |
| **`qa_consistency.py`** | 🆕 | 日文残留扫描、术语命中违例、占位符/数字/编号对齐、标点合规 → `qa_issues.json` |
| **`make_report.py`** | 🆕 | 汇总 `state/` → `report.md` |
| `sample_text.py` / `reduce_digests.py` | 🆕（可合并） | 抽样打包 / 梗概分组打包，避免超长上下文 |

> `SkillRegistry.requiredScripts` 从 4 个扩为完整清单，`verify()` 缺任一即判"未装载"，避免 v3.2 出现过的"只有 SKILL.md"故障复发。

### 6.5 两个后端能落地的程度（务必区分）

| 能力 | WorkBuddy 后端（skill 约束 Agent） | DeepSeek 后端（应用内编排） |
|---|---|---|
| 编排主体 | WorkBuddy Agent 读 `SKILL.md` **自行**顺序执行 | Swift 代码**显式**调用，逐步 await |
| 约束强度 | 🟡 **软约束**：文档规定 + 脚本硬校验 + 产物存在性检查 | 🟢 **硬约束**：代码强制，可 assert / retry / 回滚 |
| F33-02 译前预抽 | Agent 调 `glossary_tool.py upsert`；应用**事后**核验 `events.jsonl` 顺序 | Swift 显式两次 API 调用（抽取 → 翻译），顺序天然保证 |
| F33-03 命中注入 | 由 Agent 调 `glossary_tool.py hits --chunk N` 取子集 | Swift 侧本地匹配后拼进 system prompt |
| 术语冲突处理 | 脚本内实现，Agent 只负责喂数据 | 同一份逻辑用 Swift 重写（或调同一脚本） |
| 预扫 / 风格分析 | Agent 执行，产物文件校验 | Swift 多次 API 调用 |
| 段数对齐失败重试 | 🟡 只能提示 Agent"发现不一致，请修正"，无强制重试 | 🟢 可自动重试 N 次，仍失败则逐段兜底 |
| 断点续跑 | 依赖 Agent 读 `state_tool.py pending` 后跳过 | Swift 直接读 state 决定循环起点 |
| 双语 PDF | ✅ 支持 | ❌ 不支持（沿用 v3.2 限制，`bilingual` 强制 false） |
| 进度上报 | 依赖 Agent 每阶段调 `state_tool.py set-stage`；应用轮询 `status.json` | Swift 直接 `onProgress` 回调，实时准确 |
| 失败可见性 | 🟡 只有超时（最长 6h）+ 产物缺失 | 🟢 逐次 API 错误可捕获 |

**结论口径**：v3.3 的**质量上限由 skill（WB 后端）定义**，**质量下限由 DeepSeek 后端的代码编排保证**。两者共用同一套 `state/` 目录约定与同一份 `glossary_tool.py` 语义，避免出现两套事实标准。

---

## 7. Swift 应用侧需求

### 7.1 数据模型

| 项 | 现状 | v3.3 |
|---|---|---|
| `Glossary.Entry` | `jp` / `zh` 两字段 | 增 `type`、`note`、`aliases`、`origin`(user/auto)、`locked`、`status`(ok/conflict)、`firstChunk` |
| 持久化格式 | 两栏 CSV | 主存 `glossary.json`；**保留两栏 CSV 导入导出**（向后兼容，缺字段用默认值填充） |
| `toPromptBlock()` | 全表塞入 + 硬编码"不要生成自动术语表" | 按 §5 策略生成；支持 `scope=chunk` 时只渲染命中子集；分组渲染（锁定词条 / 自动词条） |
| 冲突表 | 无 | `glossary_conflicts.json`（source / 现值 / 候选值 / 块号 / 状态） |

### 7.2 设置项（`Models/Settings.swift` 新增）

| 键 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `autoGlossaryEnabled` | Bool | **true** | 是否允许自动生成/补充术语表（决策矩阵开关） |
| `glossaryScope` | String | `chunk` | `chunk`=只注入本块命中词条；`full`=注入全表 |
| `enablePrescan` | Bool | true | S2 全书预扫 |
| `enableStyleAnalysis` | Bool | true | S3 样本分析与风格指南 |
| `enablePunctNormalize` | Bool | true | S6 标点规范化 |
| `enableQA` | Bool | true | S7 一致性 QA |
| `enablePolish` | Bool | **false** | P2 润色（默认关，成本高） |
| `enableResume` | Bool | true | 断点续跑 |
| `maxCharsPerChunk` | Int | 4000 | 每块目标字符数（沿用 `split_text.py --target`） |

### 7.3 后端与流程

| 编号 | 需求 | 文件 |
|---|---|---|
| SW-1 | `buildPrompt()` 重写：注入 ①state 目录绝对路径 ②术语表策略段（按矩阵）③九阶段执行要求 ④断点续跑指令（"先跑 `state_tool.py pending`，已完成块不得重译"） | `Translate/WorkBuddyBackend.swift` |
| SW-2 | `waitForOutputs()` 升级为 `waitForCompletion()`：优先轮询 `state/status.json`（阶段/块/术语数/冲突数），PDF 存在性作为最终判据；`status.json` 缺失时**降级**为 v3.2 行为 | 同上 |
| SW-3 | 工作目录复用：同一输入文件 → 复用同一 `<workdir>`，不再每次新建；开始前若检测到未完成 state，弹"继续上次任务 / 从头开始" | `App/AppState.swift`、`Core/Paths.swift` |
| SW-4 | `DeepSeekTranslator` 重构为阶段化编排（S1→S8），与 skill 阶段一一对应；每块译完写 state | `Translate/DeepSeekTranslator.swift` |
| SW-5 | `TranslationPrompts` 删除 `glossaryDirective` / `glossaryAbsentHint` 硬编码，改为 `GlossaryPolicy.promptText(for:)` | `Translate/TranslationPrompts.swift` |
| SW-6 | 交付物扩充：`present_files` / 完成面板同时给出 三份 PDF + `report.md` + `glossary_export.csv` | `App/AppState.swift`、`UI/MainView.swift` |
| SW-7 | `SkillRegistry.requiredScripts` 扩充为完整脚本清单，`checkStatus` 文案列出缺失脚本名 | `Core/SkillRegistry.swift` |

---

## 8. UI 变更示意（文字描述）

### 8.1 主界面 `MainView`

| 区块 | 变更 |
|---|---|
| 「翻译选项」卡片 | 术语表行右侧新增**状态徽标**：`用户表 12 条 · 自动补充开` / `未设置 · 将自动生成` / `未启用术语保障 ⚠️`（黄底），点击直达编辑器 |
| **「进度」卡片（重点改造）** | 从单行文案 → 三行结构：<br>① **阶段条**：`阶段 4/9 · 逐块翻译`（九段式分段进度条，已完成阶段实心）<br>② **块进度**：`第 12 / 48 块` + 线性进度条 + 预估剩余<br>③ **指标行**：`术语 137 条 · 冲突 2 · QA 待查 0`，冲突数 >0 时橙色且可点击跳冲突列表 |
| 「日志」卡片 | 支持按阶段折叠；新增 `state/events.jsonl` 尾随显示开关 |
| 底部状态栏 | skill 状态文案在缺脚本时列出**具体缺失文件名** |
| **新增「上次任务」提示条** | 检测到未完成 state 时，输入区下方出现胶囊条：`检测到未完成任务（已完成 12/48 块）` + `继续` / `重新开始` 两按钮 |

### 8.2 术语表编辑器 `GlossaryEditorView`

| 元素 | 变更 |
|---|---|
| 表格列 | `日语` `中文` → `日语` / `中文` / `类型` / `来源` / `备注`；`来源` 列用图标区分 🔒用户锁定 / 🤖自动 |
| 顶部工具条 | 新增**搜索框**、类型筛选下拉、`仅看冲突` 开关 |
| 按钮区 | 现有 `添加行` `删除选中行` `清空` 之外，新增 `导入 CSV…` / `导出 CSV…` / **`导入本次自动术语（N 条）`** |
| 行选中 | 修复 v3.2「删除选中行」实为"删空行"的问题，改为真实选中删除 |
| **新增「冲突」分区** | 折叠面板：`原文 / 当前译名 / 候选译名 / 出现块 / [采用当前] [采用候选] [手动填写]` |
| 底部说明条 | 按当前决策矩阵显示一句话策略说明，例如"当前策略：**用户表锁定 + 自动补充新词**（情形 B）" |

### 8.3 设置页 `SettingsView`

| 元素 | 变更 |
|---|---|
| **新增「术语表策略」分组** | `自动生成/补充术语表`（Toggle，默认开）、`术语注入范围`（Segmented：本块命中 / 全表）；下方灰字实时显示命中的决策矩阵情形（A/B/C/D）与其后果 |
| **新增「翻译流水线」分组** | 全书预扫 / 样本风格分析 / 标点规范化 / 一致性 QA / 润色（默认关，标注"耗时翻倍"）/ 断点续跑 —— 6 个 Toggle + `每块字符上限` 步进器；顶部提供 `快速` / `标准`（默认） / `精译` 三个预设按钮一键套用 |
| 后端分组 | DeepSeek 分组下增加灰字说明"DeepSeek 后端不支持双语对照 PDF" |

---

## 9. 非目标（本次明确不做）

| # | 不做的事 | 原因 |
|---|---|---|
| N1 | 重写应用架构（引入 SQLite / 数据库层 / 插件系统） | v3.3 是增量版本；术语库用 JSON 文件足够（单本书量级 ≤ 数千条） |
| N2 | 实现 wenyi 的取证式 Agent Review Loop、跨块仲裁、影子修订与盲复审 | 需要完整 LLM 编排层与工具调用协议，skill 宿主不具备；投入产出比过低 |
| N3 | 多源语言支持（en/ko/ru→zh） | 产品定位是日译中；`language.source` 之类配置不引入 |
| N4 | EPUB / FB2 / HTML 输入与输出、目录锚点回填 | 输入侧已由 OCR 链路统一为 txt，输出侧固定 PDF |
| N5 | 模型档位切换（strong/cheap/fast）与并发执行 | WB 后端模型由 WorkBuddy 决定；DS 后端单模型串行 |
| N6 | DeepSeek 后端的双语对照 PDF | 沿用 v3.2 既有限制 |
| N7 | 云端术语库 / 多设备同步 / 协作 | 本地单机工具定位 |
| N8 | 修改 v3.2 目录下任何文件 | v3.2 作为可回滚基线，只读 |
| N9 | 术语表自动回写历史译文 | 与 wenyi 一致：术语表只约束后续翻译，历史一致性交给 QA 报告与人工 |

---

## 10. 待确认问题

| # | 问题 | 影响 | 建议默认 |
|---|---|---|---|
| Q1 | 术语库主存格式选 **JSON** 还是 **SQLite**？ | 影响 Swift 与 Python 双端读写实现与并发安全 | **JSON + 文件锁**（单进程顺序写，量级小，人可读可 diff，Swift/Python 都零依赖） |
| Q2 | 用户术语表锁定后，若模型明显译错（如把人名当普通词），是否允许**建议**改动？ | 影响情形 A/B 的严格程度 | 允许**只读建议**进 QA 报告，绝不自动改表 |
| Q3 | 「每块译前更新术语」中的**预抽取**，是否算作一次独立的 Agent/API 调用？ | 直接影响 DS 后端费用（约 +40–60%）与 WB 后端时长 | 是，独立调用；但提供设置项 `preExtractMode = always / firstNChunks / off`，默认 `always`，让重成本用户可降级 |
| Q4 | 全书预扫（S2）对**超长书**（>200 块）如何控成本？ | 预扫本身可能耗时数小时 | 块数 > 阈值（建议 60）时自动改为**抽样预扫**（均匀抽 30 块做梗概），并在报告中标注 |
| Q5 | 断点续跑的 state 目录**生命周期**？何时清理？ | 磁盘占用 & 用户困惑 | 保留至用户手动清理；设置页提供"清理历史任务缓存"；同一输入 + 同一参数哈希才视为可续跑 |
| Q6 | WB 后端 Agent **不遵守** skill 阶段（跳过预抽）时如何处置？ | F33-02 的强制性 | 应用侧事后校验 `events.jsonl`；不合规 → 结果仍交付但在报告与 UI 顶部标注"⚠️ 流程未完整执行"，不做自动重跑 |
| Q7 | 九阶段是否需要**在 SKILL.md 中给 Agent 可跳过的授权**？ | 短文档（如 1–2 块的论文）跑九阶段过重 | 块数 ≤ 2 时自动走**精简路径**（跳过 S2 预扫，S3 与 S4 合并），由 `state_tool.py init` 依据块数写入 `config.json` 决定 |
| Q8 | 报告 `report.md` 是否需要中文 PDF 化？ | 交付形态 | v3.3 交 markdown；PDF 附录列为 P2（F33-21） |
| Q9 | 术语表 CSV 扩展列后，用户手上的旧两栏 CSV 如何提示？ | 兼容性体验 | 静默兼容加载，保存时升级为多列并在编辑器提示一次"术语表已升级格式" |
| Q10 | v3.3 目录是 **v3.2 全量拷贝后改** 还是 **仅存增量补丁**？ | 影响架构师与工程师的开工方式 | 建议全量拷贝 v3.2 → v3.3 后原地改造（与该项目 v2/v21/v3/v32 的既有惯例一致） |

---

## 附：需求 → 用户原话覆盖检查

| 用户原话 | 覆盖需求 |
|---|---|
| ① 有自定义术语表必须用用户的，否则自动生成 | **F33-01**（决策矩阵 A/B/C/D）、F33-05、F33-08 |
| ① 术语表动态更新，每次分块翻译前必须先更新这一块的术语表 | **F33-02**（事件顺序硬校验）、F33-04 |
| ① 翻译时严格遵循术语表 | **F33-03**（命中注入 + 符合率 ≥98% + 违例进 QA） |
| ② 参考 wenyi 流程继续优化 skill | **F33-06**（九阶段）、F33-10、F33-11、F33-12、F33-13、F33-14、§6.3 借鉴/裁剪对照表 |
| ③ 参照 wenyi 对原软件做优化改进 | **F33-07**（断点续跑）、**F33-09**（可观测）、F33-15~F33-18、§7 Swift 侧需求、§8 UI 变更 |
