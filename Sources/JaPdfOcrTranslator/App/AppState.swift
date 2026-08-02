import Combine
import CryptoKit
import Foundation
import os.lock
import SwiftUI

/// Cross-isolation abort flag: written on the main actor (Abort button) and read
/// from the background translator's `abortCheck`.
private let abortLock = OSAllocatedUnfairLock<Bool>(initialState: false)

/// Sendable 弱引用盒子：用于在 `@Sendable` 的 detached 闭包中，把进度回调安全回投到主线程。
/// 非 private：SettingsView 的「测试连接」等后台回调也复用它。
final class WeakAppStateBox: @unchecked Sendable {
    weak var state: AppState?
    init(_ state: AppState) { self.state = state }
}

/// Central application state — v3.3 编排（T05-f）。
@MainActor
final class AppState: ObservableObject {
    @Published var settings: Settings = Settings.load()

    // MARK: UI-bound inputs
    @Published var inputPath: String = ""
    @Published var outputDir: String = ""
    @Published var glossaryDisplayPath: String = ""

    // MARK: Job state
    @Published var stage: String = "READY"
    @Published var message: String = "准备就绪"
    @Published var percent: Double = 0
    @Published var logs: [String] = []
    @Published var isRunning: Bool = false
    @Published var canAbort: Bool = false
    @Published var skillStatus: String = "检测中…"
    @Published var confirmRequest: ConfirmRequest?

    // MARK: v3.3 pipeline state（F33-09）
    @Published var pipeline: TranslationState?
    @Published var showResumePrompt = false
    @Published var resumePromptMessage = ""
    @Published var resumeDecision: ResumeDecision?
    @Published var autoTermsToAdopt = 0
    @Published var autoExportPath: String?
    @Published var complianceWarning = false
    // MARK: T10 用量展示
    @Published var llmUsage: LLMUsage?
    @Published var llmProviderForCost: String = "deepseek"

    enum ResumeDecision: String { case resume, archive, cancel }

    // MARK: OCR 环境探测
    @Published var ocrEnvStatus: String = ""
    @Published var ocrEnvChecking: Bool = false

    // MARK: LLM「测试连接」（T08 设置页）
    @Published var llmPingStatus: String = ""
    @Published var llmPingChecking: Bool = false

    /// Read the abort flag (safe from any thread via the module-level lock).
    private var abortRequested: Bool { abortLock.withLock { $0 } }
    private var confirmContinuation: CheckedContinuation<Bool, Never>?
    private var resumeContinuation: CheckedContinuation<ResumeDecision, Never>?

    private let logger = getLogger("app")

    // MARK: - Lifecycle

    func onLaunch() {
        refreshSkillStatus()
        ensureSkillAtStartup()
        glossaryDisplayPath = settings.glossaryPath
    }

    /// F13 startup gate.
    func ensureSkillAtStartup() {
        let info = SkillRegistry.resolveSkill(skillID: settings.selectedSkill, customPath: settings.customSkillPath)
        if !(settings.skillInstalled && SkillRegistry.isSynced(info)) {
            do {
                try SkillRegistry.ensureLoaded(info)
                settings.skillInstalled = true
                settings.save()
                logger.info("skill 已装载/自愈完成：\(info.id)")
            } catch {
                logger.warning("skill 装载失败（不影响启动）：\(error)")
            }
        }
        _ = SkillRegistry.checkStatus(info)
    }

    // MARK: - Skill status

    func refreshSkillStatus() {
        let info = SkillRegistry.resolveSkill(skillID: settings.selectedSkill, customPath: settings.customSkillPath)
        let (_, detail) = SkillRegistry.checkStatus(info)
        skillStatus = detail
    }

    // MARK: - Run / abort

    func startTranslation() {
        guard !isRunning else { return }
        // Validate
        let inputURL = URL(fileURLWithPath: inputPath)
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            setProgress(stage: "ERROR", percent: 0, message: "输入文件不存在：\(inputPath)")
            return
        }
        let ext = inputURL.pathExtension.lowercased()
        guard TextExtractor.supportedExtensions.contains(".\(ext)") else {
            setProgress(stage: "ERROR", percent: 0, message: "不支持的输入类型：.\(ext)")
            return
        }
        guard !outputDir.isEmpty else {
            setProgress(stage: "ERROR", percent: 0, message: "请先选择输出目录。")
            return
        }
        // Backend precheck
        if settings.isAPI {
            let config = settings.toLLMConfig()
            guard !config.resolvedBaseURL.isEmpty else {
                setProgress(stage: "ERROR", percent: 0, message: "请填写大模型 API 地址。")
                return
            }
            guard config.tiers["strong"]?.model.isEmpty == false else {
                setProgress(stage: "ERROR", percent: 0, message: "请填写 API 使用的模型名称。")
                return
            }
        } else {
            let wb = WorkBuddyBackend(settings: settings)
            if !wb.isAvailable() {
                setProgress(stage: "ERROR", percent: 0, message: "未检测到 WorkBuddy 应用，无法驱动翻译。")
                return
            }
        }

        // Persist options
        let backendIsAPI = settings.isAPI
        settings.glossaryPath = glossaryDisplayPath
        settings.save()

        abortLock.withLock { $0 = false }
        isRunning = true
        canAbort = true
        pipeline = nil
        autoTermsToAdopt = 0
        autoExportPath = nil
        complianceWarning = false
        llmUsage = nil
        llmProviderForCost = settings.toLLMConfig().provider
        setProgress(stage: "READY", percent: 0, message: "开始处理")

        Task { await runPipeline(inputURL: inputURL, outputDir: URL(fileURLWithPath: outputDir), backendIsAPI: backendIsAPI) }
    }

    func abort() {
        abortLock.withLock { $0 = true }
    }

    // MARK: - OCR env

    func checkOcrEnv() {
        ocrEnvChecking = true
        ocrEnvStatus = "正在检测 / 准备 Python 运行环境（首次可能需要联网）…"
        let preferred = settings.pythonInterpreterPath
        let box = WeakAppStateBox(self)
        Task.detached(priority: .userInitiated) {
            let result: (Bool, String, String)
            do {
                let python = try await PythonBootstrap.ensureInterpreter(preferred: preferred) { msg in
                    Task { @MainActor in box.state?.ocrEnvStatus = msg }
                }
                result = (true, python, "")
            } catch {
                result = (false, "", error.localizedDescription)
            }
            await MainActor.run {
                if result.0 {
                    box.state?.ocrEnvStatus = "✅ OCR 环境就绪：\((result.1 as NSString).lastPathComponent)"
                } else {
                    box.state?.ocrEnvStatus = "❌ \(result.2)"
                }
                box.state?.ocrEnvChecking = false
            }
        }
    }

    // MARK: - Confirm / resume gates

    private func requestConfirm(_ payload: ConfirmRequest) async -> Bool {
        await withCheckedContinuation { cont in
            self.confirmContinuation = cont
            self.confirmRequest = payload
        }
    }

    func respondToConfirm(confirmed: Bool) {
        confirmRequest = nil
        confirmContinuation?.resume(returning: confirmed)
        confirmContinuation = nil
    }

    private func requestResumeDecision(_ message: String) async -> ResumeDecision {
        resumePromptMessage = message
        showResumePrompt = true
        return await withCheckedContinuation { cont in
            self.resumeContinuation = cont
        }
    }

    /// MainView 的 alert 回调（继续/归档/取消）。
    func resolveResumeDecision(_ decision: ResumeDecision) {
        showResumePrompt = false
        resumeDecision = decision
        resumeContinuation?.resume(returning: decision)
        resumeContinuation = nil
    }

    // MARK: - Pipeline

    private func runPipeline(inputURL: URL, outputDir: URL, backendIsAPI: Bool) async {
        let outDir = outputDir.resolvingSymlinksInPath()
        do {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            let work = outDir
            let preferredPython = settings.pythonInterpreterPath

            // Stage: extract / OCR
            let isPDF = inputURL.pathExtension.lowercased() == "pdf"
            setProgress(stage: isPDF ? "OCR" : "抽取", percent: 5,
                        message: isPDF ? "正在准备 OCR 运行环境（Python + 依赖）…" : "开始抽取文本：\(inputURL.lastPathComponent)")

            let box = WeakAppStateBox(self)
            let envProgress: @Sendable (String) -> Void = { m in
                Task { @MainActor in box.state?.appendLog("[环境] \(m)") }
            }
            let ocrProgress: @Sendable (String) -> Void = { m in
                Task { @MainActor in box.state?.appendLog("[OCR] \(m)") }
            }
            let jpTxt: URL = try await Task.detached(priority: .userInitiated) {
                let python: String
                if isPDF {
                    python = try await PythonBootstrap.ensureInterpreter(
                        preferred: preferredPython, onProgress: envProgress)
                } else {
                    python = preferredPython.isEmpty ? "python3" : preferredPython
                }
                return try await TextExtractor.extractText(
                    inputURL: inputURL,
                    workDir: work,
                    python: python,
                    abortCheck: { abortLock.withLock { $0 } },
                    onProgress: ocrProgress
                )
            }.value

            let content = (try? String(contentsOf: jpTxt, encoding: .utf8)) ?? ""
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppError.extraction("OCR / 抽取结果为空，未识别到任何文字。\n中间产物目录：\(work.path)")
            }
            setProgress(stage: isPDF ? "OCR" : "抽取", percent: 90, message: "文本就绪：\(jpTxt.lastPathComponent)")

            // Glossary（GlossaryPolicy.resolve 唯一推导入口）
            var glossary = Glossary.empty()
            let hasUser = GlossaryPolicy.hasUserGlossary(settings)
            if hasUser {
                glossary = try Glossary.loadCSV(URL(fileURLWithPath: settings.glossaryPath))
            }
            let policy = GlossaryPolicy.resolve(hasUserGlossary: hasUser,
                                                autoGlossaryEnabled: settings.autoGlossaryEnabled)
            logger.info("术语策略：\(policy.rawValue)（hasUser=\(hasUser), auto=\(settings.autoGlossaryEnabled)）")

            // Resolve skill
            let skillInfo: SkillInfo? = SkillRegistry.resolveSkill(
                skillID: settings.selectedSkill, customPath: settings.customSkillPath)

            // 续跑三选（SW-3）：state 已存在且不可续跑 → 弹窗
            let stateDir = outDir.appendingPathComponent("state")
            try await resolveRunContinuation(stateDir: stateDir, jpTxt: jpTxt, policy: policy)

            // [WB only] 运行前确认（F24 / 新 ConfirmRequest）
            if !backendIsAPI {
                let payload = try buildConfirmPayload(jpTxt: jpTxt, outputDir: outDir,
                                                      skillInfo: skillInfo, policy: policy, resumeHint: resumeHint(for: stateDir))
                let confirmed = await requestConfirm(payload)
                if !confirmed || abortRequested {
                    finishAborted()
                    return
                }
            }

            // Translate
            setProgress(stage: "翻译", percent: 10, message: "使用 \(settings.translationBackend) 后端翻译中…")
            let translator = createTranslator(settings)
            let outcome = try await translator.translate(
                jpTxt: jpTxt,
                outDir: outDir,
                glossary: glossary,
                bilingual: settings.bilingual,
                skillInfo: skillInfo,
                customPrompt: settings.customPrompt,
                abortCheck: { abortLock.withLock { $0 } },
                onProgress: { [weak self] m in
                    Task { @MainActor in self?.appendLog("[翻译] \(m)") }
                }
            )

            // 收尾：合规结论 + 自动术语收编提示 + T10 用量展示
            if let stateDir = outcome.stateDir {
                refreshPipeline(stateDir: stateDir)
                if let compliant = outcome.compliant {
                    complianceWarning = !compliant
                }
                if policy.offersAdoption, let exportPath = outcome.glossaryExportPath,
                   FileManager.default.fileExists(atPath: exportPath.path) {
                    autoExportPath = exportPath.path
                    autoTermsToAdopt = countCSVRows(exportPath)
                }
                // T10：DS 后端读取 usage.json 供界面展示（WB 无 usage → 保持 nil）
                if settings.isAPI {
                    let scriptsDir = Paths.builtinSkillScriptsDir()
                    let client = LLMToolClient(python: Paths.pythonForScripts(settings: settings),
                                               scriptURL: scriptsDir, stateDir: stateDir)
                    if let usage = try? client.usage(), usage.totals.calls > 0 {
                        llmUsage = usage
                    }
                }
            }
            setProgress(stage: "生成PDF", percent: 100, message: "已生成 \(outcome.pdfs.count) 个 PDF")
            finishCompleted(outcome.pdfs)
        } catch let appErr as AppError {
            let msg = appErr.localizedDescription
            setProgress(stage: "ERROR", percent: 0, message: msg)
            appendLog("[错误] \(msg)")
            resetRunFlags()
        } catch {
            let msg = "未预期错误：\(error.localizedDescription)"
            setProgress(stage: "ERROR", percent: 0, message: msg)
            appendLog("[错误] \(msg)")
            resetRunFlags()
        }
    }

    /// SW-3 续跑判定：state 已存在且（enable_resume ∧ 哈希一致）→ 续跑；
    /// 否则弹「继续 / 归档旧状态并重新开始 / 取消」。
    private func resolveRunContinuation(stateDir: URL, jpTxt: URL, policy: GlossaryPolicy) async throws {
        let store = StateStore(root: stateDir)
        guard let config = store.readConfig() else { return }   // 全新任务
        guard !config.params.enableResume else { return }       // 开启续跑 → 交给 translator 的 stateInit 判定

        let inputSHA = sha256Hex(of: jpTxt)
        let params = settings.toRunParams(hasUserGlossary: policy.seedsFromUser,
                                          userGlossarySHA: Settings.userGlossarySHA(path: settings.glossaryPath))
        if config.isResumable(inputSHA256: inputSHA, params: params) {
            return
        }
        let decision = await requestResumeDecision(
            "检测到未完成的旧任务（state/ 存在），且输入或参数已变化（\(config.inputSHA256 == inputSHA ? "参数变化" : "输入变化")）。\n"
            + "· 继续：沿用旧 state（可能用到旧翻译进度）；\n"
            + "· 归档并重新开始：把旧 state 改名为 state_archive_<时间戳> 后全新开始；\n"
            + "· 取消：中止本次操作。")
        switch decision {
        case .resume:
            return
        case .archive:
            _ = try store.archive()
            appendLog("已归档旧状态：state_archive_*")
        case .cancel:
            finishAborted()
        }
    }

    private func resumeHint(for stateDir: URL) -> String {
        let store = StateStore(root: stateDir)
        guard let config = store.readConfig(), !config.params.enableResume else { return "" }
        if let status = store.readStatus(), status.finished { return "上次任务已完成，本次将从新 state 开始。" }
        return "检测到未完成任务：将按断点续跑规则只处理未完成块。"
    }

    private func refreshPipeline(stateDir: URL) {
        let store = StateStore(root: stateDir)
        pipeline = store.readStatus()
    }

    private func sha256Hex(of url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func countCSVRows(_ url: URL) -> Int {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n").dropFirst().filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    // MARK: - Confirm payload（新契约）

    private func buildConfirmPayload(jpTxt: URL, outputDir: URL, skillInfo: SkillInfo?,
                                     policy: GlossaryPolicy, resumeHint: String) throws -> ConfirmRequest {
        let info = skillInfo ?? SkillRegistry.resolveSkill(skillID: settings.selectedSkill, customPath: settings.customSkillPath)
        let (ok, _) = SkillRegistry.checkStatus(info)
        let status = ok ? "已装载 ✓" : "未装载 ✗"
        let promptRaw = settings.customPrompt.trimmingCharacters(in: .whitespaces)
        let promptSummary: String
        if promptRaw.isEmpty {
            promptSummary = "内置默认（使用内置默认提示词）"
        } else {
            let first = promptRaw.split(separator: "\n").prefix(2).joined(separator: "\n").trimmingCharacters(in: .whitespaces)
            promptSummary = "自定义：\(first)"
        }
        let stem = jpTxt.deletingPathExtension().lastPathComponent
        let paths = Paths.pdfPaths(outDir: outputDir, stem: stem, bilingual: settings.bilingual)
        var lines = "  · 译文：\(paths.zh.path)"
        if let bi = paths.bi {
            lines += "\n  · 原文：\(paths.ja.path)\n  · 双语：\(bi.path)"
        } else {
            lines += "\n  · 原文：\(paths.ja.path)"
        }
        let chars = (try? String(contentsOf: jpTxt, encoding: .utf8))?.count ?? 0
        let estimated = max(1, Int(ceil(Double(chars) / Double(settings.maxCharsPerChunk))))
        return ConfirmRequest(
            jpTxtPath: jpTxt.path, outputDir: outputDir.path,
            skillName: info.name, skillStatus: status,
            promptSummary: promptSummary, outPdfLines: lines,
            policyPreview: policy.promptText, policyName: policy.displayName,
            estimatedChunks: estimated, resumeHint: resumeHint
        )
    }

    // MARK: - Completion handlers

    private func finishCompleted(_ pdfs: [URL]) {
        isRunning = false
        canAbort = false
        setProgress(stage: "DONE", percent: 100, message: "完成")
        for p in pdfs { appendLog("已生成：\(p.path)") }
        if complianceWarning {
            appendLog("⚠️ 事后合规核验未通过（F33-02）：请查看报告中的缺失块号。")
        }
        if let first = pdfs.first {
            NSWorkspace.shared.open(first)
        }
    }

    private func finishAborted() {
        isRunning = false
        canAbort = false
        setProgress(stage: "中止", percent: 100, message: "已中止 / 已取消")
        appendLog("任务已中止或取消。")
    }

    private func resetRunFlags() {
        isRunning = false
        canAbort = false
    }

    // MARK: - Log / progress helpers

    func appendLog(_ line: String) {
        logs.append(line)
        if logs.count > 500 { logs.removeFirst(logs.count - 500) }
    }

    private func setProgress(stage: String, percent: Double, message: String) {
        self.stage = stage
        self.percent = percent
        self.message = message
        if !message.isEmpty { appendLog("[\(stage)] \(message)") }
    }
}
