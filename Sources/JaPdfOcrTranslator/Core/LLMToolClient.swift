import Foundation

/// `llm_tool.py` 的 Swift 封装（DESIGN-v3.3-llm §4，T07）。
///
/// `Sendable struct`：不可变值 + 每次调用独立 `ProcessRunner`，跨 actor 安全。
///
/// **红线（D2 延续）**：本文件只调 `llm_tool.py`，**永不读写术语库主存文件**（术语唯一写路径是
/// `glossary_tool.py`。`api_key` 只经 `llm_config.json`（0600）传给子进程，不进 argv / 日志 / events（T06 判据 7）。
///
/// 退出码映射（§4.0 + 新增 6）：
/// - 0 成功；1 用法 → `.llmTool`；2 IO/锁 → `.state`；3 配置畸形 → `.llmConfig`；
/// - 4 状态未初始化 → `.state`；5 凭据/配置校验未通过 → `.llmCredential`；6 重试耗尽 → `.llmRetryExhausted`。
struct LLMToolClient: Sendable {
    let python: String
    let scriptURL: URL
    let stateDir: URL

    private var tool: String { scriptURL.appendingPathComponent("llm_tool.py").path }

    init(python: String, scriptURL: URL, stateDir: URL) {
        self.python = python
        self.scriptURL = scriptURL
        self.stateDir = stateDir
    }

    // MARK: - llm_config.json 写入（0600）

    /// 把 `LLMConfig` 写为 `<state>/llm_config.json`（权限 0600），返回文件 URL。
    @discardableResult
    func writeConfigFile(_ config: LLMConfig) throws -> URL {
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let url = Paths.llmConfigURL(stateDir: stateDir)
        let text = config.toConfigJSON()
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    // MARK: - 底层执行

    /// 运行 llm_tool 并解析 stdout JSON；退出码按 §4.0 映射。
    ///
    /// `allowExitCodes` 里的**非 0 失败码**（5 凭据失败 / 6 重试耗尽）在解析 stdout 之前
    /// 先映射成对应错误——这些路径 llm_tool 只写 stderr、stdout 为空，直接解析会误报
    /// 「stdout 不是合法 JSON」。
    private func runJSON(_ args: [String], allowExitCodes: Set<Int32> = [0]) throws -> [String: Any] {
        let result = try ProcessRunner.runCapturing(exec: python, args: [tool] + args, timeout: 180)
        if !allowExitCodes.contains(result.code) {
            throw Self.mapExit(code: result.code, err: result.err)
        }
        if result.code != 0 {
            // 业务失败码（5/6）：stdout 无 JSON，直接映射错误。
            throw Self.mapExit(code: result.code, err: result.err)
        }
        guard let data = result.out.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.llmTool(
                "llm_tool.py stdout 不是合法 JSON（exit=\(result.code)）。\n"
                + "stdout: \(result.out.prefix(300))\n"
                + "stderr: \(result.err.prefix(500))"
            )
        }
        return json
    }

    private static func mapExit(code: Int32, err: String) -> AppError {
        let detail = err.trimmingCharacters(in: .whitespacesAndNewlines)
        switch code {
        case 1:
            return .llmTool("用法/参数错误（exit=1）：\n  \(detail)")
        case 2:
            return .state("IO / 锁错误（exit=2）：\n  \(detail)")
        case 3:
            return .llmConfig("LLM 配置 JSON 畸形（exit=3）：\n  \(detail)")
        case 4:
            return .state("状态未初始化 / 目标不存在（exit=4）：\n  \(detail)")
        case 5:
            return .llmCredential("凭据/配置校验未通过（exit=5）：\n  \(detail)")
        case 6:
            return .llmRetryExhausted("LLM 调用重试耗尽（exit=6）：\n  \(detail)")
        default:
            return .llmTool("未知退出码 \(code)：\n  \(detail)")
        }
    }

    // MARK: - 子命令（§4.1–§4.4）

    /// §4.1 `complete`：纯文本补全。
    struct CompleteResult {
        var text: String
        var provider: String
        var model: String
        var tier: String
        var stage: String?
        var usage: LLMUsageSample
        var totals: LLMUsageSlot
    }

    func complete(config: LLMConfig, system: String, user: String,
                  tier: String = "strong", stage: String? = nil,
                  jsonMode: Bool = false, maxTokens: Int? = nil) throws -> CompleteResult {
        let configFile = try writeConfigFile(config)
        var args = ["complete", "--state", stateDir.path, "--config-file", configFile.path,
                    "--tier", tier]
        if let stage { args += ["--stage", stage] }
        if let maxTokens { args += ["--max-tokens", "\(maxTokens)"] }
        if jsonMode { args += ["--json-mode"] }
        if !system.isEmpty { args += ["--system", system] }
        args += ["--user", user]
        let json = try runJSON(args, allowExitCodes: [0, 6])
        return CompleteResult(
            text: json["text"] as? String ?? "",
            provider: json["provider"] as? String ?? config.provider,
            model: json["model"] as? String ?? "",
            tier: json["tier"] as? String ?? tier,
            stage: json["stage"] as? String ?? stage,
            usage: decodeSample(json["usage"]),
            totals: decodeSlot(json["totals"])
        )
    }

    /// §4.2 `complete-json`：JSON 模式补全 + 宽松解析。
    struct JSONResult {
        var value: Any?
        var repaired: Bool
        var text: String
        var provider: String
        var model: String
        var usage: LLMUsageSample
    }

    func completeJSON(config: LLMConfig, system: String, user: String,
                      tier: String = "strong", stage: String? = nil,
                      maxTokens: Int? = nil) throws -> JSONResult {
        let configFile = try writeConfigFile(config)
        var args = ["complete-json", "--state", stateDir.path, "--config-file", configFile.path,
                    "--tier", tier]
        if let stage { args += ["--stage", stage] }
        if let maxTokens { args += ["--max-tokens", "\(maxTokens)"] }
        if !system.isEmpty { args += ["--system", system] }
        args += ["--user", user]
        let json = try runJSON(args, allowExitCodes: [0, 6])
        return JSONResult(
            value: json["value"],
            repaired: json["repaired"] as? Bool ?? false,
            text: json["text"] as? String ?? "",
            provider: json["provider"] as? String ?? config.provider,
            model: json["model"] as? String ?? "",
            usage: decodeSample(json["usage"])
        )
    }

    /// §4.3 `validate`：凭据/配置校验（不发网络请求）。
    struct ValidateResult {
        var ok: Bool
        var provider: String
        var requiresAPIKey: Bool
        var hasAPIKey: Bool
        var tiers: [String]
    }

    func validate(config: LLMConfig) throws -> ValidateResult {
        let configFile = try writeConfigFile(config)
        let json = try runJSON(["validate", "--state", stateDir.path, "--config-file", configFile.path],
                               allowExitCodes: [0, 5])
        return ValidateResult(ok: json["ok"] as? Bool ?? false,
                              provider: json["provider"] as? String ?? config.provider,
                              requiresAPIKey: json["requires_api_key"] as? Bool ?? false,
                              hasAPIKey: json["has_api_key"] as? Bool ?? false,
                              tiers: json["tiers"] as? [String] ?? [])
    }

    /// §4.4 `ping`：最小连通性测试。
    func ping(config: LLMConfig) throws -> String {
        let configFile = try writeConfigFile(config)
        let json = try runJSON(["ping", "--state", stateDir.path, "--config-file", configFile.path],
                               allowExitCodes: [0, 6])
        return json["text"] as? String ?? ""
    }

    /// §4.4 `usage`：只读 usage.json（缺文件退 4 → 返回全零）。
    func usage() throws -> LLMUsage {
        let url = Paths.usageURL(stateDir: stateDir)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let usage = try? JSONDecoder().decode(LLMUsage.self, from: data) else {
            return LLMUsage()
        }
        return usage
    }

    // MARK: - 解码助手

    private func decodeSample(_ value: Any?) -> LLMUsageSample {
        guard let value else { return LLMUsageSample() }
        let data = (try? JSONSerialization.data(withJSONObject: value)) ?? Data()
        return (try? JSONDecoder().decode(LLMUsageSample.self, from: data)) ?? LLMUsageSample()
    }

    private func decodeSlot(_ value: Any?) -> LLMUsageSlot {
        guard let value else { return LLMUsageSlot() }
        let data = (try? JSONSerialization.data(withJSONObject: value)) ?? Data()
        return (try? JSONDecoder().decode(LLMUsageSlot.self, from: data)) ?? LLMUsageSlot()
    }
}
