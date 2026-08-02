import Foundation

/// WorkBuddy (deep-link driven) backend — v3.3 九阶段编排（T05-d）。
///
/// 分工：
/// - 应用侧（Swift）跑**确定性脚本**：state_tool init / split_text / sample_text / glossary init /
///   check_boundaries / check_alignment / normalize_punct / qa_consistency / merge / make_report /
///   build_pdf / export / finish / verify；
/// - WorkBuddy Agent 负责 **LLM 内容**：S2 全书梗概、S3 风格指南、S4 逐块翻译（含术语预抽/回抽）、
///   S5 跨块截断句修复。Agent 通过深链任务拿到 `$STATE` 与策略段后按 SKILL.md 执行。
final class WorkBuddyTranslator: Translator {
    private let settings: Settings

    init(settings: Settings) { self.settings = settings }

    func translate(
        jpTxt: URL, outDir: URL, glossary: Glossary, bilingual: Bool,
        skillInfo: SkillInfo?, customPrompt: String,
        abortCheck: @Sendable @escaping () -> Bool,
        onProgress: @Sendable @escaping (String) -> Void
    ) async throws -> TranslateOutcome {
        let logger = getLogger("translate.workbuddy")
        let outDir = outDir.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: jpTxt.path) else {
            throw AppError.translator("待翻译的日文 txt 不存在：\n  \(jpTxt.path)")
        }

        let stem = jpTxt.deletingPathExtension().lastPathComponent
        let paths = Paths.pdfPaths(outDir: outDir, stem: stem, bilingual: bilingual)
        var pdfs = [paths.zh, paths.ja]
        if let bi = paths.bi { pdfs.append(bi) }

        let stateDir = outDir.appendingPathComponent("state")
        let scriptsDir = Paths.builtinSkillScriptsDir()
        let python = settings.pythonInterpreterPath.trimmingCharacters(in: .whitespaces).isEmpty
            ? "python3" : settings.pythonInterpreterPath
        let exec = PipelineExecutor(python: python, scriptsDir: scriptsDir,
                                    stateDir: stateDir, outDir: outDir)

        // ── S0 初始化（含续跑判定）──
        onProgress("S0 初始化 state…")
        let params = settings.toRunParams(hasUserGlossary: !glossary.isEmpty,
                                          userGlossarySHA: Settings.userGlossarySHA(path: settings.glossaryPath))
        let initResult = try exec.stateInit(input: jpTxt, backend: "workbuddy", params: params)
        if !initResult.resumable, let reason = initResult.reason, reason != "initialized" {
            throw AppError.pipeline("无法启动/续跑任务：\(reason)\n请归档旧状态后重试。")
        }
        try exec.setStage("S0", name: "初始化", finish: true)

        // ── S1 切分 ──
        onProgress("S1 切分与结构分析…")
        let total = try exec.splitText(input: jpTxt, target: settings.maxCharsPerChunk, maxp: 8000)
        try exec.setStage("S1", name: "切分与结构分析", finish: true)
        logger.info("S1 完成：\(total) 块")

        // ── S3 抽样（S2 由 Agent 完成；S3 的样本由应用侧脚本抽取）──
        onProgress("S3 样本分析与风格定调…")
        try exec.sampleText(n: 3, chars: 3000)
        // 初始术语表（无词也要留证据）
        try exec.glossaryInit(policy: params.glossaryPolicy, userCSV: settings.glossaryPath.isEmpty ? nil : URL(fileURLWithPath: settings.glossaryPath))
        try exec.setStage("S3", name: "样本分析与风格定调", finish: true)

        // ── 深链交给 WorkBuddy Agent（S2 梗概 / S3 风格 / S4 逐块 / S5 修复）──
        let skill = skillInfo?.id ?? settings.selectedSkill
        let policyText = GlossaryPolicy(rawValue: params.glossaryPolicy)?.promptText ?? ""
        logger.info("WB 任务装载：skill=\(skill), policy=\(params.glossaryPolicy), 块数=\(total)")

        let backend = WorkBuddyBackend(settings: settings)
        try backend.ensureLaunched()
        onProgress("已启动 WorkBuddy，正在切换模型…")
        try backend.selectModel(settings.workbuddyModel)

        onProgress("已发送九阶段翻译任务，请在 WorkBuddy 窗口关注进度")
        try backend.startTranslationTask(
            txtPath: jpTxt, stateDir: stateDir, zhPDF: paths.zh, jaPDF: paths.ja, biPDF: paths.bi,
            cwd: jpTxt.deletingLastPathComponent(),
            policyText: policyText, customPrompt: customPrompt,
            skill: skill, action: WB_DEEP_LINK_ACTION
        )

        onProgress("等待 WorkBuddy 完成 S4 逐块翻译…")
        try await backend.waitForCompletion(
            stateDir: stateDir, pdfs: pdfs,
            onProgress: onProgress, abortCheck: abortCheck
        )

        // ── S5 边界报告（Agent 已修复截断句；应用侧只出报告留证）──
        onProgress("S5 跨块边界检查…")
        try exec.checkBoundaries()
        try exec.setStage("S5", name: "跨块边界修复", finish: true)

        // ── S6 确定性质检 ──
        onProgress("S6 确定性质检（对齐 + 标点）…")
        try exec.checkAlignment()
        try exec.normalizePunct()
        try exec.setStage("S6", name: "确定性质检", finish: true)

        // ── S7 一致性 QA ──
        onProgress("S7 一致性 QA…")
        let rate = try exec.runQA(failOn: "error", minTermRate: 0.98)
        logger.info("S7 术语符合率：\(rate)")
        try exec.resolveConflicts()
        try exec.setStage("S7", name: "一致性 QA", finish: true)

        // ── S8 合并与交付 ──
        onProgress("S8 合并与交付…")
        let translationFull = outDir.appendingPathComponent("state/translation_full.txt")
        let originalFull = outDir.appendingPathComponent("state/original_full.txt")
        try exec.mergeChunks(out: translationFull, pattern: "chunk_*_zh.txt", exclude: nil)
        try exec.mergeChunks(out: originalFull, pattern: "chunk_*.txt", exclude: "*_zh.txt")
        try exec.makeReport()

        let title = stem
        try exec.buildPDF(input: translationFull, output: paths.zh, title: title)
        try exec.buildPDF(input: originalFull, output: paths.ja, title: title)
        if let bi = paths.bi {
            try exec.buildPDF(input: translationFull, output: bi, title: title)
        }

        let exportURL = stateDir.appendingPathComponent("glossary_export.csv")
        try exec.glossaryExport(out: exportURL, format: "csv5", origin: "auto")
        try exec.finishRun(message: "全流程完成")

        // ── 事后合规核验（F33-02）──
        let compliance = backend.verifyCompliance(stateDir: stateDir, python: python, scriptsDir: scriptsDir)
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
}
