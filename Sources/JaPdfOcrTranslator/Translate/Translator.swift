import Foundation

/// Unified translation outcome（DESIGN §5.1 / T04-j / T05）。
struct TranslateOutcome: Sendable {
    let pdfs: [URL]
    let translationFull: URL?
    let originalFull: URL?
    let chunksDir: URL?
    let stateDir: URL?
    let reportPath: URL?
    let glossaryExportPath: URL?
    let compliant: Bool?

    init(pdfs: [URL],
         translationFull: URL? = nil,
         originalFull: URL? = nil,
         chunksDir: URL? = nil,
         stateDir: URL? = nil,
         reportPath: URL? = nil,
         glossaryExportPath: URL? = nil,
         compliant: Bool? = nil) {
        self.pdfs = pdfs
        self.translationFull = translationFull
        self.originalFull = originalFull
        self.chunksDir = chunksDir
        self.stateDir = stateDir
        self.reportPath = reportPath
        self.glossaryExportPath = glossaryExportPath
        self.compliant = compliant
    }
}

/// Translation backend abstraction（DESIGN §5.1 `Translator` 协议）。
protocol Translator {
    func translate(
        jpTxt: URL,
        outDir: URL,
        glossary: Glossary,
        bilingual: Bool,
        skillInfo: SkillInfo?,
        customPrompt: String,
        abortCheck: @Sendable @escaping () -> Bool,
        onProgress: @Sendable @escaping (String) -> Void
    ) async throws -> TranslateOutcome
}

/// Factory selecting the backend by settings.
func createTranslator(_ settings: Settings) -> any Translator {
    if settings.isAPI {
        return DeepSeekTranslator(settings: settings)
    }
    return WorkBuddyTranslator(settings: settings)
}

// ════════════════════════════════════════════════════════════════════════
// PipelineExecutor —— 两个后端共用的「Python 脚本引擎」薄封装（T05）
// ════════════════════════════════════════════════════════════════════════

/// 统一封装 `state_tool.py` / `glossary_tool.py` / `llm_tool.py` / 阶段脚本
/// 的子进程调用。`Sendable struct`：不可变值，跨 actor 安全。
///
/// 退出码语义沿用 §4.0（0 成功 / 4 状态未初始化 / 5 检查未通过 / 6 LLM 重试耗尽）；
/// `runScript` 只负责执行与透传 stdout，具体解释由各调用点负责。
struct PipelineExecutor: Sendable {
    let python: String
    let scriptsDir: URL
    let stateDir: URL
    let outDir: URL

    init(python: String, scriptsDir: URL, stateDir: URL, outDir: URL) {
        self.python = python
        self.scriptsDir = scriptsDir
        self.stateDir = stateDir
        self.outDir = outDir
    }

    // MARK: - 底层

    /// 运行任意 skill 脚本并返回 stdout；非零退出码抛 `AppError.pipeline`（带 stderr）。
    @discardableResult
    func runScript(_ name: String, args: [String],
                   stdin: String? = nil,
                   allowExitCodes: Set<Int32> = [0]) throws -> String {
        let script = scriptsDir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw AppError.pipeline("skill 脚本缺失：\(script.path)\n  请先校验 / 重新装载 skill。")
        }
        let result = try ProcessRunner.runCapturing(exec: python, args: [script.path] + args,
                                                    stdin: stdin, timeout: 600)
        if !allowExitCodes.contains(result.code) {
            let err = result.err.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppError.pipeline("\(name) 退出码 \(result.code)：\n  \(err.isEmpty ? String(result.out.prefix(300)) : err)")
        }
        return result.out
    }

    /// 运行脚本并把 stdout 解析为 JSON 对象。
    func runScriptJSON(_ name: String, args: [String],
                       stdin: String? = nil,
                       allowExitCodes: Set<Int32> = [0]) throws -> [String: Any] {
        let out = try runScript(name, args: args, stdin: stdin, allowExitCodes: allowExitCodes)
        guard let data = out.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.pipeline("\(name) stdout 不是合法 JSON：\n  \(out.prefix(300))")
        }
        return json
    }

    // MARK: - state_tool 快捷

    func stateInit(input: URL, backend: String, params: RunParams) throws -> (resumable: Bool, reason: String?) {
        let json = try runScriptJSON("state_tool.py",
                                     args: ["init", "--state", stateDir.path,
                                            "--input", input.path,
                                            "--backend", backend,
                                            "--params-json", params.canonicalJSON],
                                     allowExitCodes: [0, 4])
        return (json["resumable"] as? Bool ?? false, json["reason"] as? String)
    }

    func setStage(_ stage: String, name: String? = nil, finish: Bool = false,
                  skip: Bool = false, reason: String? = nil) throws {
        var args = ["set-stage", "--state", stateDir.path, "--stage", stage]
        if let name { args += ["--name", name] }
        if finish { args += ["--finish"] }
        if skip {
            args += ["--skip"]
            if let reason { args += ["--reason", reason] }
        }
        _ = try runScriptJSON("state_tool.py", args: args)
    }

    func markChunk(_ n: Int, value: String, zhChars: Int? = nil, reason: String? = nil) throws {
        var args = ["mark-chunk", "--state", stateDir.path, "--chunk", "\(n)", "--value", value]
        if let zhChars { args += ["--zh-chars", "\(zhChars)"] }
        if let reason { args += ["--reason", reason] }
        _ = try runScriptJSON("state_tool.py", args: args)
    }

    func pendingChunks() throws -> [Int] {
        let json = try runScriptJSON("state_tool.py", args: ["pending", "--state", stateDir.path])
        return json["pending"] as? [Int] ?? []
    }

    func readStatus() throws -> TranslationState {
        let json = try runScriptJSON("state_tool.py",
                                     args: ["status", "--state", stateDir.path, "--refresh", "--format", "json"])
        let data = try JSONSerialization.data(withJSONObject: json)
        return try TranslationState.validated(from: data)
    }

    func verify(check: String = "all") throws -> (result: ComplianceResult, exitCode: Int32) {
        let script = scriptsDir.appendingPathComponent("state_tool.py")
        let result = try ProcessRunner.runCapturing(
            exec: python,
            args: [script.path, "verify", "--state", stateDir.path, "--check", check],
            timeout: 120)
        guard let data = result.out.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.pipeline("state_tool.py verify 输出解析失败：\n  \(result.out.prefix(300))")
        }
        let compliance = ComplianceResult(compliant: json["compliant"] as? Bool ?? false,
                                          missingPreExtract: json["missing_pre_extract"] as? [Int] ?? [],
                                          outOfOrder: json["out_of_order"] as? [Int] ?? [],
                                          checks: json["checks"] as? [String: Bool] ?? [:])
        return (compliance, result.code)
    }

    // MARK: - glossary_tool 快捷

    func glossaryInit(policy: String, userCSV: URL?) throws {
        var args = ["init", "--state", stateDir.path, "--policy", policy]
        if let userCSV { args += ["--user-csv", userCSV.path] }
        _ = try runScriptJSON("glossary_tool.py", args: args)
    }

    func glossaryUpsert(termsJSON: String, chunk: Int, phase: String) throws {
        _ = try runScriptJSON("glossary_tool.py",
                              args: ["upsert", "--state", stateDir.path,
                                     "--chunk", "\(chunk)", "--phase", phase, "--stdin"],
                              stdin: termsJSON)
    }

    func glossaryHitsMarkdown(chunk: Int) throws -> String {
        try runScript("glossary_tool.py",
                      args: ["hits", "--state", stateDir.path, "--chunk", "\(chunk)",
                             "--scope", "chunk", "--format", "md"])
    }

    func glossaryRender(chunk: Int?, policy: String) throws -> String {
        var args = ["render", "--state", stateDir.path, "--scope", "chunk"]
        if let chunk { args += ["--chunk", "\(chunk)"] }
        args += ["--policy", policy]
        return try runScript("glossary_tool.py", args: args)
    }

    func glossaryExport(out: URL, format: String = "csv5", origin: String? = nil) throws {
        var args = ["export", "--state", stateDir.path, "--out", out.path, "--format", format]
        if let origin { args += ["--origin", origin] }
        _ = try runScriptJSON("glossary_tool.py", args: args)
    }

    func glossaryStats() throws -> (terms: Int, locked: Int, openConflicts: Int) {
        let json = try runScriptJSON("glossary_tool.py", args: ["stats", "--state", stateDir.path])
        return (json["terms"] as? Int ?? 0,
                json["locked"] as? Int ?? 0,
                json["open_conflicts"] as? Int ?? 0)
    }

    // MARK: - 阶段脚本

    func splitText(input: URL, target: Int, maxp: Int) throws -> Int {
        let json = try runScriptJSON("split_text.py",
                                     args: ["--input", input.path, "--out", stateDir.path,
                                            "--target", "\(target)", "--maxp", "\(maxp)",
                                            "--format", "json"])
        return json["chunks"] as? Int ?? 0
    }

    func sampleText(n: Int = 3, chars: Int = 3000) throws {
        _ = try runScriptJSON("sample_text.py",
                              args: ["--state", stateDir.path, "--n", "\(n)", "--chars", "\(chars)"])
    }

    func reduceDigests(group: Int = 20) throws {
        _ = try runScriptJSON("reduce_digests.py",
                              args: ["--state", stateDir.path, "--group", "\(group)"])
    }

    func checkBoundaries() throws {
        _ = try runScriptJSON("check_boundaries.py", args: ["--state", stateDir.path])
    }

    func checkAlignment() throws {
        _ = try runScriptJSON("check_alignment.py", args: ["--state", stateDir.path], allowExitCodes: [0, 5])
    }

    func normalizePunct() throws {
        _ = try runScriptJSON("normalize_punct.py", args: ["--state", stateDir.path])
    }

    func runQA(failOn: String = "error", minTermRate: Double = 0.98) throws -> Double {
        let json = try runScriptJSON("qa_consistency.py",
                                     args: ["--state", stateDir.path,
                                            "--fail-on", failOn,
                                            "--min-term-rate", String(format: "%g", minTermRate)],
                                     allowExitCodes: [0, 5])
        return json["terminology_rate"] as? Double ?? 1.0
    }

    func resolveConflicts() throws {
        // 自动词条冲突：逐个 take proposed（用户裁决语义由 UI 层决定；此处仅收尾）
        let json = try runScriptJSON("glossary_tool.py",
                                     args: ["conflicts", "--state", stateDir.path],
                                     allowExitCodes: [0, 5])
        for item in (json["items"] as? [[String: Any]] ?? []) {
            guard let source = item["source"] as? String else { continue }
            _ = try? runScriptJSON("glossary_tool.py",
                                   args: ["resolve", "--state", stateDir.path,
                                          "--source", source, "--take", "proposed", "--by", "agent"])
        }
    }

    func mergeChunks(out: URL, pattern: String, exclude: String?) throws {
        var args = ["merge.py", "--indir", stateDir.appendingPathComponent("chunks").path,
                    "--out", out.path, "--pattern", pattern, "--state", stateDir.path]
        if let exclude { args += ["--exclude", exclude] }
        _ = try runScript("merge.py", args: Array(args.dropFirst()))
    }

    func makeReport() throws {
        _ = try runScriptJSON("make_report.py", args: ["--state", stateDir.path])
    }

    func buildPDF(input: URL, output: URL, title: String = "", author: String = "", date: String = "") throws {
        var args = ["build_pdf.py", "--input", input.path, "--output", output.path]
        if !title.isEmpty { args += ["--title", title] }
        if !author.isEmpty { args += ["--author", author] }
        if !date.isEmpty { args += ["--date", date] }
        _ = try runScript("build_pdf.py", args: args)
    }

    func finishRun(message: String) throws {
        _ = try runScriptJSON("state_tool.py",
                              args: ["status", "--state", stateDir.path, "--finish", "--message", message])
    }

    func failRun(error: String) throws {
        _ = try runScriptJSON("state_tool.py",
                              args: ["status", "--state", stateDir.path, "--fail", "--error", error])
    }

    // MARK: - 文件助手

    func chunkURL(_ n: Int, zh: Bool) -> URL {
        let name = String(format: "chunk_%03d%@.txt", n, zh ? "_zh" : "")
        return stateDir.appendingPathComponent("chunks").appendingPathComponent(name)
    }

    func readChunk(_ n: Int, zh: Bool) -> String {
        (try? String(contentsOf: chunkURL(n, zh: zh), encoding: .utf8)) ?? ""
    }

    func writeChunk(_ n: Int, zh: Bool, text: String) throws {
        try text.write(to: chunkURL(n, zh: zh), atomically: true, encoding: .utf8)
    }

    func writeStateFile(_ name: String, text: String) throws {
        try text.write(to: stateDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func appendStateEvent(type: String, stage: String?, chunk: Int?, json: String) throws {
        var args = ["event", "--state", stateDir.path, "--type", type]
        if let stage { args += ["--stage", stage] }
        if let chunk { args += ["--chunk", "\(chunk)"] }
        args += ["--json", json]
        _ = try runScriptJSON("state_tool.py", args: args)
    }

    /// 把 `config.json.llm` 快照写回（T08；**不含 api_key**——config.json 公开可 diff 不存密）。
    ///
    /// state_tool init 已写 config.json；此处读-改-原子写回，追加 `llm` 块供事后取证。
    func writeConfigLLMBlock(_ block: RunConfig.LLMBlock) throws {
        let store = StateStore(root: stateDir)
        guard var config = store.readConfig() else {
            // init 尚未完成（理论上不会发生）；静默跳过，不阻断流程。
            return
        }
        config.llm = block
        try store.writeConfig(config)
    }
}
