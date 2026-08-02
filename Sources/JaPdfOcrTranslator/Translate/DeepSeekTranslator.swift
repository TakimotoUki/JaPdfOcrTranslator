import Foundation

/// DeepSeek 后端 — v3.3 九阶段阶段化编排（T05-e / T08 迁移）。
///
/// 与 WorkBuddy 后端共用同一套 Python 引擎与 `state/` 契约；LLM 调用统一走
/// `llm_tool.py`（经 `LLMToolClient`，T07），因此术语预抽 / 命中裁剪 / 回抽的
/// 硬时序天然满足 F33-02。每块五步严格按 ①②③④⑤ 顺序，`abortCheck` 在每步之间。
final class DeepSeekTranslator: Translator {
    private let settings: Settings

    init(settings: Settings) { self.settings = settings }

    func translate(
        jpTxt: URL, outDir: URL, glossary: Glossary, bilingual: Bool,
        skillInfo: SkillInfo?, customPrompt: String,
        abortCheck: @Sendable @escaping () -> Bool,
        onProgress: @Sendable @escaping (String) -> Void
    ) async throws -> TranslateOutcome {
        let logger = getLogger("translate.deepseek")
        let outDir = outDir.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: jpTxt.path) else {
            throw AppError.translator("待翻译的日文 txt 不存在：\n  \(jpTxt.path)")
        }
        // T08：LLM 配置统一走 Settings.toLLMConfig()（含 v3.2 回退）。
        let llmConfig = settings.toLLMConfig()
        // D10：需要 key 的 provider 无 key 启动即抛，不静默。
        if llmConfig.requiresAPIKey && !llmConfig.hasConfiguredAPIKey {
            throw AppError.deepseek(
                "未配置 \(llmConfig.provider) API Key。\n"
                + "请填写 API Key，或设置环境变量 \(llmConfig.resolvedAPIKeyEnv)。")
        }
        guard llmConfig.tiers["strong"]?.model.isEmpty == false else {
            throw AppError.llmConfig("请至少填写 Strong 档模型名。")
        }

        let stem = jpTxt.deletingPathExtension().lastPathComponent
        let paths = Paths.pdfPaths(outDir: outDir, stem: stem, bilingual: false)   // DS 强制 bilingual=false
        let pdfs = [paths.zh, paths.ja]

        let stateDir = outDir.appendingPathComponent("state")
        let scriptsDir = Paths.builtinSkillScriptsDir()
        let python = settings.pythonInterpreterPath.trimmingCharacters(in: .whitespaces).isEmpty
            ? "python3" : settings.pythonInterpreterPath
        let exec = PipelineExecutor(python: python, scriptsDir: scriptsDir,
                                    stateDir: stateDir, outDir: outDir)
        let llm = LLMToolClient(python: python, scriptURL: scriptsDir, stateDir: stateDir)

        let params = settings.toRunParams(hasUserGlossary: !glossary.isEmpty,
                                          userGlossarySHA: Settings.userGlossarySHA(path: settings.glossaryPath))
        let policyText = GlossaryPolicy(rawValue: params.glossaryPolicy)?.promptText ?? ""

        // ── S0 初始化（含续跑判定）──
        onProgress("S0 初始化 state…")
        let initResult = try exec.stateInit(input: jpTxt, backend: "deepseek", params: params)
        if !initResult.resumable, let reason = initResult.reason, reason != "initialized" {
            throw AppError.pipeline("无法启动/续跑任务：\(reason)\n请归档旧状态后重试。")
        }
        // config.json.llm 快照（不含 api_key，供事后取证；T08）。
        try exec.writeConfigLLMBlock(RunConfig.LLMBlock.fromConfig(llmConfig))
        try exec.setStage("S0", name: "初始化", finish: true)

        // ── S1 切分 ──
        onProgress("S1 切分与结构分析…")
        let total = try exec.splitText(input: jpTxt, target: settings.maxCharsPerChunk, maxp: 8000)
        try exec.setStage("S1", name: "切分与结构分析", finish: true)
        logger.info("S1 完成：\(total) 块")

        // ── S2 全书预扫（按 config 计划）──
        var synopsisText = ""
        if params.enablePrescan, let config = StateStore(root: stateDir).readConfig(),
           config.pathMode != "simple", config.prescanMode != "off" {
            onProgress("S2 全书预扫…")
            synopsisText = try await runPrescan(exec: exec, llm: llm, config: llmConfig,
                                                runConfig: StateStore(root: stateDir).readConfig(),
                                                abortCheck: abortCheck, onProgress: onProgress)
            try exec.setStage("S2", name: "全书预扫", finish: true)
        } else {
            try exec.setStage("S2", name: "全书预扫", skip: true, reason: "prescan 关闭或 simple 路径")
        }

        // ── S3 样本分析与风格定调 ──
        var styleGuideText = ""
        if params.enableStyleAnalysis {
            onProgress("S3 样本分析与风格定调…")
            try exec.sampleText(n: 3, chars: 3000)
            let samplePack = (try? String(contentsOf: stateDir.appendingPathComponent("samples/sample_pack.md"), encoding: .utf8)) ?? ""
            styleGuideText = try llmText(llm: llm, config: llmConfig, tier: "cheap",
                                         stage: "S3_style",
                                         system: "你是日文小说翻译的风格分析师。",
                                         user: TranslationPrompts.stylePrompt(samplePack: samplePack),
                                         abortCheck: abortCheck)
            try exec.writeStateFile("style_guide.md", text: styleGuideText)
            try exec.appendStateEvent(type: "style_guide_written", stage: "S3", chunk: nil,
                                      json: "{\"chars\":\(styleGuideText.count)}")
            try exec.setStage("S3", name: "样本分析与风格定调", finish: true)
        } else {
            try exec.setStage("S3", name: "样本分析与风格定调", skip: true, reason: "style_analysis 关闭")
        }

        // 初始术语表（无词也要留证据）
        try exec.glossaryInit(policy: params.glossaryPolicy,
                              userCSV: settings.glossaryPath.isEmpty ? nil : URL(fileURLWithPath: settings.glossaryPath))

        // ── S4 逐块翻译（五步硬时序）──
        onProgress("S4 逐块翻译…")
        try exec.setStage("S4", name: "逐块翻译")
        let pending = try exec.pendingChunks()
        logger.info("S4 待译块：\(pending)")
        let glossarySummary = try await glossarySummary(exec: exec)

        for n in pending {
            if abortCheck() { throw AppError.abort }
            onProgress("S4 翻译第 \(n)/\(total) 块…")
            let source = exec.readChunk(n, zh: false)
            guard !source.trimmingCharacters(in: .whitespaces).isEmpty else {
                try exec.markChunk(n, value: "skipped", reason: "policy")
                continue
            }

            // ① 译前预抽（独立 LLM 调用；off 模式以空数组调用留证据）
            var preTerms = "{\"terms\":[]}"
            if params.preExtractMode == "always"
                || (params.preExtractMode == "firstNChunks" && n <= params.preExtractFirstN) {
                let pre = try llmJSON(llm: llm, config: llmConfig, tier: "cheap",
                                      stage: "S4_pre_extract",
                                      system: "你是术语抽取器，只输出 JSON。",
                                      user: TranslationPrompts.preExtractPrompt(chunk: source, glossarySummary: glossarySummary),
                                      abortCheck: abortCheck)
                if let terms = pre["terms"] {
                    preTerms = "{\"terms\":" + jsonArrayText(terms) + "}"
                }
            }
            try exec.glossaryUpsert(termsJSON: preTerms, chunk: n, phase: "pre")

            // ② 命中裁剪
            let hitsBlock = try exec.glossaryHitsMarkdown(chunk: n)

            // ③ 翻译
            var systemParts = [policyText]
            if !styleGuideText.isEmpty { systemParts.append("【风格指南】\n" + styleGuideText) }
            if !synopsisText.isEmpty { systemParts.append("【全书梗概】\n" + synopsisText) }
            if !hitsBlock.isEmpty { systemParts.append(hitsBlock) }
            let system = systemParts.joined(separator: "\n\n")
            let zh = try llmText(llm: llm, config: llmConfig, tier: "strong",
                                 stage: "S4_translate",
                                 system: system,
                                 user: TranslationPrompts.buildTranslationUserPrompt(source),
                                 abortCheck: abortCheck)
            try exec.writeChunk(n, zh: true, text: zh)

            // ④ 译后回抽
            let post = try llmJSON(llm: llm, config: llmConfig, tier: "cheap",
                                   stage: "S4_post_extract",
                                   system: "你是术语回抽器，只输出 JSON。",
                                   user: TranslationPrompts.postExtractPrompt(source: source, translation: zh, glossarySummary: glossarySummary),
                                   abortCheck: abortCheck)
            if let terms = post["terms"] {
                let postTerms = "{\"terms\":" + jsonArrayText(terms) + "}"
                try exec.glossaryUpsert(termsJSON: postTerms, chunk: n, phase: "post")
            }

            // ⑤ 落盘
            try exec.markChunk(n, value: "done", zhChars: zh.count)
        }
        try exec.setStage("S4", name: "逐块翻译", finish: true)

        // ── S5 跨块边界修复 ──
        onProgress("S5 跨块边界修复…")
        try exec.checkBoundaries()
        try await fixBoundaries(exec: exec, llm: llm, config: llmConfig,
                                abortCheck: abortCheck, onProgress: onProgress)
        try exec.setStage("S5", name: "跨块边界修复", finish: true)

        // ── S6 确定性质检 ──
        onProgress("S6 确定性质检…")
        try await fixAlignment(exec: exec, llm: llm, config: llmConfig, abortCheck: abortCheck, onProgress: onProgress)
        try exec.normalizePunct()
        try exec.setStage("S6", name: "确定性质检", finish: true)

        // ── S7 一致性 QA ──
        onProgress("S7 一致性 QA…")
        try await fixQA(exec: exec, llm: llm, config: llmConfig, abortCheck: abortCheck, onProgress: onProgress)
        try exec.resolveConflicts()
        try exec.setStage("S7", name: "一致性 QA", finish: true)

        // ── S8 合并与交付 ──
        onProgress("S8 合并与交付…")
        let translationFull = outDir.appendingPathComponent("state/translation_full.txt")
        let originalFull = outDir.appendingPathComponent("state/original_full.txt")
        try exec.mergeChunks(out: translationFull, pattern: "chunk_*_zh.txt", exclude: nil)
        try exec.mergeChunks(out: originalFull, pattern: "chunk_*.txt", exclude: "*_zh.txt")
        try exec.makeReport()
        try exec.buildPDF(input: translationFull, output: paths.zh, title: stem)
        try exec.buildPDF(input: originalFull, output: paths.ja, title: stem)
        let exportURL = stateDir.appendingPathComponent("glossary_export.csv")
        try exec.glossaryExport(out: exportURL, format: "csv5", origin: "auto")
        try exec.finishRun(message: "全流程完成")

        // ── 合规核验 ──
        let (compliance, _) = try exec.verify(check: "all")
        logger.info("F33-02 合规：\(compliance.compliant)")

        return TranslateOutcome(pdfs: pdfs,
                                translationFull: translationFull,
                                originalFull: originalFull,
                                chunksDir: stateDir.appendingPathComponent("chunks"),
                                stateDir: stateDir,
                                reportPath: stateDir.appendingPathComponent("report.md"),
                                glossaryExportPath: exportURL,
                                compliant: compliance.compliant)
    }

    // MARK: - S2 预扫

    private func runPrescan(exec: PipelineExecutor, llm: LLMToolClient, config: LLMConfig,
                            runConfig: RunConfig?,
                            abortCheck: @Sendable @escaping () -> Bool,
                            onProgress: @Sendable @escaping (String) -> Void) async throws -> String {
        let indices: [Int]
        if let runConfig, runConfig.prescanMode == "sampled", !runConfig.prescanSampleIndices.isEmpty {
            indices = runConfig.prescanSampleIndices
        } else {
            indices = Array(1...max(runConfig?.totalChunks ?? 0, 0))
        }
        var digestLines: [String] = []
        for n in indices {
            if abortCheck() { throw AppError.abort }
            onProgress("S2 预扫第 \(n) 块梗概…")
            let source = exec.readChunk(n, zh: false)
            let digest = try llmText(llm: llm, config: config, tier: "cheap",
                                     stage: "S2_digest",
                                     system: "你是日文小说梗概员，只输出中文梗概正文。",
                                     user: TranslationPrompts.digestPrompt(chunk: source),
                                     abortCheck: abortCheck)
            let digestURL = exec.stateDir.appendingPathComponent("digests").appendingPathComponent(String(format: "chunk_%03d.md", n))
            try FileManager.default.createDirectory(at: digestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try digest.write(to: digestURL, atomically: true, encoding: .utf8)
            try exec.appendStateEvent(type: "digest_written", stage: "S2", chunk: n,
                                      json: "{\"chars\":\(digest.count)}")
            digestLines.append("## 第 \(n) 块\n\n" + digest)
        }
        try exec.reduceDigests(group: 20)
        let synopsis = try llmText(llm: llm, config: config, tier: "cheap",
                                   stage: "S2_synopsis",
                                   system: "你是日文小说梗概员，只输出中文梗概正文。",
                                   user: TranslationPrompts.synopsisPrompt(digestPacks: digestLines.joined(separator: "\n\n")),
                                   abortCheck: abortCheck)
        try exec.writeStateFile("book_synopsis.md", text: synopsis)
        try exec.appendStateEvent(type: "synopsis_written", stage: "S2", chunk: nil,
                                  json: "{\"chars\":\(synopsis.count),\"source\":\"\(runConfig?.prescanMode ?? "full")\"}")
        return synopsis
    }

    // MARK: - LLM 助手（T08：经 LLMToolClient，错误映射到 llmRetryExhausted/llmCredential）

    private func llmText(llm: LLMToolClient, config: LLMConfig, tier: String, stage: String,
                         system: String, user: String,
                         abortCheck: @Sendable @escaping () -> Bool) throws -> String {
        if abortCheck() { throw AppError.abort }
        let result = try llm.complete(config: config, system: system, user: user,
                                      tier: tier, stage: stage, jsonMode: false)
        guard !result.text.isEmpty || stage == "ping" else {
            throw AppError.deepseek("llm_tool complete 返回空文本（provider=\(config.provider)）")
        }
        return result.text
    }

    private func llmJSON(llm: LLMToolClient, config: LLMConfig, tier: String, stage: String,
                         system: String, user: String,
                         abortCheck: @Sendable @escaping () -> Bool) throws -> [String: Any] {
        if abortCheck() { throw AppError.abort }
        let result = try llm.completeJSON(config: config, system: system, user: user,
                                          tier: tier, stage: stage)
        guard let value = result.value as? [String: Any] else {
            return [:]
        }
        return value
    }

    private func jsonArrayText(_ value: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: value),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "[]"
    }

    private func glossarySummary(exec: PipelineExecutor) async throws -> String {
        let stats = try exec.glossaryStats()
        return "术语表现状：共 \(stats.terms) 条（锁定 \(stats.locked) · 未决冲突 \(stats.openConflicts)）"
    }

    // MARK: - S5/S6/S7 修复循环

    private func fixBoundaries(exec: PipelineExecutor, llm: LLMToolClient, config: LLMConfig,
                               abortCheck: @Sendable @escaping () -> Bool,
                               onProgress: @Sendable @escaping (String) -> Void) async throws {
        let url = exec.stateDir.appendingPathComponent("boundary_report.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let issues = json["issues"] as? [[String: Any]] ?? []
        var fixed = 0
        for issue in issues {
            if abortCheck() { throw AppError.abort }
            guard let chunk = issue["chunk"] as? Int else { continue }
            let source = exec.readChunk(chunk, zh: false)
            let zh = try llmText(llm: llm, config: config, tier: "strong",
                                 stage: "S6_retranslate",
                                 system: "你是日文小说译者，修复跨块截断句。",
                                 user: TranslationPrompts.buildTranslationUserPrompt(source),
                                 abortCheck: abortCheck)
            try exec.writeChunk(chunk, zh: true, text: zh)
            try exec.appendStateEvent(type: "boundary_fixed", stage: "S5", chunk: chunk,
                                      json: "{\"pairs\":1}")
            fixed += 1
        }
        if fixed > 0 {
            onProgress("S5 已重译 \(fixed) 处截断句")
        }
    }

    private func fixAlignment(exec: PipelineExecutor, llm: LLMToolClient, config: LLMConfig,
                              abortCheck: @Sendable @escaping () -> Bool,
                              onProgress: @Sendable @escaping (String) -> Void) async throws {
        for _ in 0..<3 {
            if abortCheck() { throw AppError.abort }
            try exec.checkAlignment()
            let store = StateStore(root: exec.stateDir)
            guard let report = store.readAlignment(), !report.errorChunks.isEmpty else { return }
            onProgress("S6 对齐修正 \(report.errorChunks.count) 块…")
            for chunk in report.errorChunks {
                if abortCheck() { throw AppError.abort }
                let source = exec.readChunk(chunk, zh: false)
                let zh = try llmText(llm: llm, config: config, tier: "strong",
                                     stage: "S6_retranslate",
                                     system: "你是日文小说译者。译文段落数必须与原文完全一致（不合并、不拆分）。",
                                     user: TranslationPrompts.buildTranslationUserPrompt(source),
                                     abortCheck: abortCheck)
                try exec.writeChunk(chunk, zh: true, text: zh)
            }
        }
        try exec.checkAlignment()
    }

    private func fixQA(exec: PipelineExecutor, llm: LLMToolClient, config: LLMConfig,
                       abortCheck: @Sendable @escaping () -> Bool,
                       onProgress: @Sendable @escaping (String) -> Void) async throws {
        for _ in 0..<3 {
            if abortCheck() { throw AppError.abort }
            _ = try exec.runQA(failOn: "error", minTermRate: 0.98)
            let store = StateStore(root: exec.stateDir)
            guard let report = store.readQAIssues() else { return }
            let errorChunks = Set(report.issues.filter { $0.severity == "error" }.map { $0.chunk })
            if errorChunks.isEmpty { return }
            onProgress("S7 QA 修正 \(errorChunks.count) 块…")
            for chunk in errorChunks.sorted() {
                if abortCheck() { throw AppError.abort }
                let source = exec.readChunk(chunk, zh: false)
                let zh = try llmText(llm: llm, config: config, tier: "strong",
                                     stage: "S7_qa_fix",
                                     system: "你是日文小说译者。请修正上一版译文中的错误（术语/日文残留/占位符/标点）。",
                                     user: TranslationPrompts.buildTranslationUserPrompt(source),
                                     abortCheck: abortCheck)
                try exec.writeChunk(chunk, zh: true, text: zh)
            }
        }
        _ = try exec.runQA(failOn: "error", minTermRate: 0.98)
    }
}
