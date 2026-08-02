import Foundation

let WB_POLL_TIMEOUT: TimeInterval = 21600   // 6 hours
let WB_DEEP_LINK_ACTION = "start"
let WB_STALE_SECONDS: TimeInterval = 300    // status.json 陈旧阈值（F33-09 降级路径）

// MARK: - URL / prompt construction (port of workbuddy/backend.py)

func buildSwitchModelURL(_ modelID: String) -> String {
    "workbuddy://switch-model?modelId=\(modelID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? modelID)"
}

func buildTaskURL(prompt: String, cwd: URL, skills: String, action: String = "start",
                  connectorIDs: String? = nil) -> String {
    // 查询值不能使用 `.urlQueryAllowed` 手工编码：其中仍允许 `&`、`+`、`=`
    // 等分隔符，会把长提示词拆成额外参数，导致 WorkBuddy 收不到完整 prompt。
    var components = URLComponents()
    components.scheme = "workbuddy"
    components.host = "task"
    var items: [(String, String)] = [
        ("action", action),
        ("prompt", prompt),
        ("cwd", cwd.path),
        ("skills", skills),
    ]
    if let c = connectorIDs, !c.isEmpty {
        items.append(("connectorIds", c))
    }
    var unreserved = CharacterSet.alphanumerics
    unreserved.insert(charactersIn: "-._~")
    components.percentEncodedQuery = items.map { name, value in
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        let encodedValue = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        return "\(encodedName)=\(encodedValue)"
    }.joined(separator: "&")
    return components.url?.absoluteString ?? ""
}

/// 构建 WorkBuddy 任务指令（T05-a / SW-1 重写）。
///
/// 注入：①`$STATE` 绝对路径 ②术语表策略段（`policyText`，与 `glossary_tool render` 逐字一致）
/// ③九阶段执行要求（引用 SKILL.md，不复述）④续跑指令（先跑 `state_tool.py pending`）
/// ⑤三份 PDF 绝对路径 ⑥「所有中间产物写 `$STATE`，勿写 skill 目录」。
func buildPrompt(
    txtPath: URL, stateDir: URL, zhPDF: URL, jaPDF: URL, biPDF: URL?,
    policyText: String = "", customPrompt: String = "",
    skill: String = "jp-txt2pdf-translator"
) -> String {
    let txt = txtPath.resolvingSymlinksInPath()
    let state = stateDir.resolvingSymlinksInPath()
    let zh = zhPDF.resolvingSymlinksInPath()
    let ja = jaPDF.resolvingSymlinksInPath()
    let bi = biPDF?.resolvingSymlinksInPath()

    var lines: [String] = []
    if !customPrompt.trimmingCharacters(in: .whitespaces).isEmpty {
        lines.append(customPrompt.trimmingCharacters(in: .whitespaces))
        lines.append("")
    } else {
        lines.append("请使用 \(skill) skill 的九阶段流水线完成「日文 txt -> 中文 PDF」的翻译与排版。")
    }

    lines.append("【状态目录（绝对路径，所有中间产物一律写这里，禁止写 skill 目录）】")
    lines.append("$STATE = \(state.path)")
    lines.append("")

    lines.append("【执行要求】")
    lines.append("1) 待翻译的日文原文（完整）位于以下绝对路径，请直接读取该文件：")
    lines.append("   \(txt.path)")
    lines.append("2) 九阶段流水线的执行细节以 \(skill) skill 的 SKILL.md 为准（S0 初始化 → S1 切分 → "
                 + "S2 预扫 → S3 风格定调 → S4 逐块翻译 → S5 跨块修复 → S6 质检 → S7 QA → S8 合并交付）。"
                 + "其中 S0 初始化 / S1 切分 / S3 抽样、S6 标点 / S7 QA / S8 合并排版已由应用侧脚本完成，"
                 + "你负责：S2 全书梗概、S3 风格指南、S4 逐块翻译（含术语预抽/回抽）、S5 跨块截断句修复。")
    lines.append("3) 【断点续跑】开始前先运行 `state_tool.py pending --state \"$STATE\"`："
                 + "已完成块（pending 之外）不得重译；只处理 pending 列表里的块。")
    lines.append("4) 【术语表】每块翻译前必须先执行 `glossary_tool.py upsert --state \"$STATE\" --chunk N "
                 + "--phase pre --stdin`（即使无新词也以 {\"terms\":[]} 调用一次），"
                 + "然后 `glossary_tool.py hits --chunk N --format md` 取本块命中子集；"
                 + "翻译后回抽 `--phase post`。")
    lines.append("5) 用 skill 的 scripts/build_pdf.py 生成以下 PDF（--input/--output）：")
    lines.append("   译文版（中文）：\(zh.path)")
    lines.append("   原文版（日文）：\(ja.path)")
    if let bi {
        lines.append("   双语对照版：\(bi.path)（生成时需 --bilingual --original <原文全文>）")
    } else {
        lines.append("   无需生成双语版。")
    }
    lines.append("")

    if !policyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        lines.append(policyText)
        lines.append("")
    }

    lines.append("【收尾】全部块完成后运行 `state_tool.py status --state \"$STATE\" --finish --message 完成`；"
                 + "确保所有 PDF 均保存为有效（非空）文件并存在于上述绝对路径。")
    return lines.joined(separator: "\n")
}

// MARK: - Backend

/// Drives the local WorkBuddy app via the `workbuddy://` URL scheme
/// (port of ``workbuddy/backend.WorkBuddyBackend``).
final class WorkBuddyBackend {
    let appPath: String
    let model: String

    init(settings: Settings) {
        self.appPath = settings.workbuddyAppPath.trimmingCharacters(in: .whitespaces).isEmpty
            ? "/Applications/WorkBuddy.app" : settings.workbuddyAppPath
        self.model = settings.workbuddyModel.trimmingCharacters(in: .whitespaces).isEmpty
            ? "Hy3" : settings.workbuddyModel
    }

    func isAvailable() -> Bool {
        let url = URL(fileURLWithPath: appPath)
        return FileManager.default.fileExists(atPath: appPath) && url.pathExtension == "app"
    }

    func ensureLaunched() throws {
        guard isAvailable() else {
            throw AppError.workbuddy("未检测到 WorkBuddy 应用：\n  \(appPath)\n请先安装 WorkBuddy（需支持 workbuddy:// URL Scheme）。")
        }
        let wasRunning = appIsRunning()
        try ProcessRunner.launchApp(appPath)
        if !wasRunning {
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                if appIsRunning() { break }
                Thread.sleep(forTimeInterval: 0.5)
            }
            Thread.sleep(forTimeInterval: 2.5)
        }
    }

    func selectModel(_ modelID: String) throws {
        try ProcessRunner.openDeepLink(buildSwitchModelURL(modelID))
    }

    /// 发送 v3.3 深链任务（注入 `$STATE`、策略段、九阶段要求、PDF 路径）。
    func startTranslationTask(
        txtPath: URL, stateDir: URL, zhPDF: URL, jaPDF: URL, biPDF: URL?,
        cwd: URL, policyText: String = "", customPrompt: String = "",
        skill: String = "jp-txt2pdf-translator",
        action: String = WB_DEEP_LINK_ACTION, connectorIDs: String? = nil
    ) throws {
        let prompt = buildPrompt(
            txtPath: txtPath, stateDir: stateDir, zhPDF: zhPDF, jaPDF: jaPDF, biPDF: biPDF,
            policyText: policyText, customPrompt: customPrompt, skill: skill
        )
        guard !prompt.isEmpty else {
            throw AppError.workbuddy("WorkBuddy 任务提示词为空，无法创建任务。")
        }
        let taskURL = buildTaskURL(
            prompt: prompt, cwd: cwd, skills: skill, action: action, connectorIDs: connectorIDs)
        guard !taskURL.isEmpty else {
            throw AppError.workbuddy("无法编码 WorkBuddy 任务链接。")
        }
        Thread.sleep(forTimeInterval: 0.4)
        try ProcessRunner.openDeepLink(taskURL)
    }

    /// T05-b：轮询 `state/status.json`（阶段/块/术语数/冲突数），PDF 存在性作为最终判据。
    ///
    /// - 优先读 `status.json`；`finished==true` 且 PDF 齐全 → 成功。
    /// - `status.json` 缺失或 `updatedAt` 陈旧 >300s → 降级 v3.2 行为（只等 PDF）。
    /// - 首次读到 `config.json` 即校验 `skill_version == 3.3.0`，不符立即抛 `AppError.skillVersion`（B2）。
    func waitForCompletion(
        stateDir: URL, pdfs: [URL], timeout: TimeInterval = WB_POLL_TIMEOUT,
        pollInterval: TimeInterval = 3,
        onProgress: (@Sendable (String) -> Void)? = nil,
        abortCheck: @Sendable @escaping () -> Bool
    ) async throws {
        let start = Date()
        let logger = getLogger("workbuddy.backend")
        let store = StateStore(root: stateDir)
        var checkedVersion = false
        logger.info("开始轮询 state/status.json + 输出 PDF（\(pdfs.count) 个，超时 \(Int(timeout))s）")

        while true {
            if abortCheck() { throw AppError.abort }
            let waited = Int(Date().timeIntervalSince(start))

            // B2：首次读到 config.json 即校验 skill_version
            if !checkedVersion {
                if let config = store.readConfig() {
                    guard config.skillVersion == "3.3.0" else {
                        throw AppError.skillVersion(
                            "state 的 skill_version 为 \(config.skillVersion)，应用要求 3.3.0。\n"
                            + "请勿用 v3.2 的 WorkBuddy 旧 skill 驱动 v3.3 任务。")
                    }
                    checkedVersion = true
                }
            }

            // 优先轮询 status.json
            if let status = store.readStatus() {
                onProgress?(status.progressLine)
                if status.failed {
                    throw AppError.workbuddy("WorkBuddy 任务失败：\(status.message)")
                }
                let pdfsReady = pdfs.allSatisfy { $0.existsAndNonEmpty }
                if status.finished && pdfsReady {
                    logger.info("status.finished=true 且全部 PDF 就绪（\(pdfs.count) 个）")
                    return
                }
                if !pdfsReady && status.isStale() {
                    // 降级 v3.2 文案：只看 PDF
                    onProgress?("已等待 \(waited)s，仍在处理…")
                }
            } else {
                // status.json 缺失 → 降级 v3.2 行为（只等 PDF）
                onProgress?("已等待 \(waited)s，仍在处理…")
            }

            // 最终判据：PDF 存在性（v3.2 语义兜底）
            let missing = pdfs.filter { !$0.existsAndNonEmpty }
            if missing.isEmpty {
                logger.info("检测到全部输出 PDF（\(pdfs.count) 个）")
                return
            }
            if Date().timeIntervalSince(start) >= timeout {
                let names = missing.map { $0.path }.joined(separator: "\n  ")
                throw AppError.workbuddy(
                    "等待 WorkBuddy 输出超时（\(Int(timeout))s），以下 PDF 未生成：\n  \(names)\n"
                    + "请检查 WorkBuddy 是否已正确执行 jp-txt2pdf-translator skill 并生成 PDF。")
            }
            if abortCheck() { throw AppError.abort }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }

    /// T05-c：事后合规核验（F33-02）。调 `StateToolClient.verify()`，失败降级为
    /// Swift 侧 `StateStore.verifyPreExtractOrder()`。
    func verifyCompliance(stateDir: URL, python: String, scriptsDir: URL) -> ComplianceResult {
        let stateClient = StateToolClient(python: python, scriptsDir: scriptsDir, stateDir: stateDir)
        do {
            let result = try stateClient.verify(check: "all")
            if result.compliant { return result }
            // 降级：Swift 侧 F33-02 复算
            let store = StateStore(root: stateDir)
            if let config = store.readConfig() {
                return store.verifyPreExtractOrder(config)
            }
            return result
        } catch {
            let store = StateStore(root: stateDir)
            if let config = store.readConfig() {
                return store.verifyPreExtractOrder(config)
            }
            return ComplianceResult(compliant: false, checks: ["verify_failed": false])
        }
    }

    private func appIsRunning() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-f", "WorkBuddy"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try? proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let out = String(data: data, encoding: .utf8) else { return false }
        return !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension URL {
    var existsAndNonEmpty: Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64 else { return false }
        return size > 0
    }
}
