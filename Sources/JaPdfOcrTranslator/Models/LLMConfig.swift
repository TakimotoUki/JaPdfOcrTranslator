import Foundation

/// 单档位配置（DESIGN-v3.3-llm §3.2 / §5.2 `LLMTierConfig`）。
struct LLMTierConfig: Codable, Sendable, Equatable {
    var model: String
    var thinking: Bool = true
    var reasoningEffort: String = "high"
    var requestOverrides: [String: JSONValue] = [:]

    /// 宽容解码用的任意值（request_overrides 载荷类型不定）。
    enum JSONValue: Codable, Sendable, Equatable {
        case string(String), int(Int), double(Double), bool(Bool)
        case array([JSONValue]), object([String: JSONValue]), null

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .string(s); return }
            if let i = try? c.decode(Int.self) { self = .int(i); return }
            if let b = try? c.decode(Bool.self) { self = .bool(b); return }
            if let d = try? c.decode(Double.self) { self = .double(d); return }
            if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
            if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
            self = .null
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let s): try c.encode(s)
            case .int(let i): try c.encode(i)
            case .double(let d): try c.encode(d)
            case .bool(let b): try c.encode(b)
            case .array(let a): try c.encode(a)
            case .object(let o): try c.encode(o)
            case .null: try c.encodeNil()
            }
        }

        var rawValue: Any {
            switch self {
            case .string(let s): return s
            case .int(let i): return i
            case .double(let d): return d
            case .bool(let b): return b
            case .array(let a): return a.map { $0.rawValue }
            case .object(let o): return o.mapValues { $0.rawValue }
            case .null: return NSNull()
            }
        }
    }

    /// 序列化为 `llm_config.json` 的 `tiers.<name>` 结构：`{model, options{thinking, reasoning_effort, request_overrides}}`。
    func toConfigDict() -> [String: Any] {
        var options: [String: Any] = ["thinking": thinking]
        if reasoningEffort != "none" {
            options["reasoning_effort"] = reasoningEffort
        }
        if !requestOverrides.isEmpty {
            options["request_overrides"] = requestOverrides.mapValues { $0.rawValue }
        }
        return ["model": model, "options": options]
    }

    // ⚠️ T04 教训：CodingKeys 必须 snake_case，否则 llm_tool.py 读不到（T07 判据 2 前提）。
    private enum CodingKeys: String, CodingKey {
        case model, thinking
        case reasoningEffort = "reasoning_effort"
        case requestOverrides = "request_overrides"
    }

    init(model: String, thinking: Bool = true, reasoningEffort: String = "high",
         requestOverrides: [String: JSONValue] = [:]) {
        self.model = model
        self.thinking = thinking
        self.reasoningEffort = reasoningEffort
        self.requestOverrides = requestOverrides
    }
}

/// LLM 配置（DESIGN-v3.3-llm §3.2 / §5.2 `LLMConfig`）。
///
/// 对应 `llm_config.json` 的字段（**snake_case CodingKeys**，与 llm_tool.py 逐字对应）。
/// `apiKey` 只在 `llm_config.json`（0600）中出现，绝不进 `config.json` / argv / 日志 / events。
struct LLMConfig: Codable, Sendable, Equatable {
    var provider: String = "deepseek"
    var baseURL: String = ""
    var apiKeyEnv: String = ""
    var apiKey: String = ""
    var timeout: Int = 120
    var maxRetries: Int = 4
    var reasoningStyle: String = "deepseek"
    var tiers: [String: LLMTierConfig] = [:]

    private enum CodingKeys: String, CodingKey {
        case provider
        case baseURL = "base_url"
        case apiKeyEnv = "api_key_env"
        case apiKey = "api_key"
        case timeout
        case maxRetries = "max_retries"
        case reasoningStyle = "reasoning_style"
        case tiers
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "deepseek"
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        apiKeyEnv = try c.decodeIfPresent(String.self, forKey: .apiKeyEnv) ?? ""
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        timeout = try c.decodeIfPresent(Int.self, forKey: .timeout) ?? 120
        maxRetries = try c.decodeIfPresent(Int.self, forKey: .maxRetries) ?? 4
        reasoningStyle = try c.decodeIfPresent(String.self, forKey: .reasoningStyle) ?? "deepseek"
        tiers = try c.decodeIfPresent([String: LLMTierConfig].self, forKey: .tiers) ?? [:]
    }

    /// 序列化为 llm_tool.py 期望的 `llm` 配置 JSON（不含 `api_key` 之外的敏感项；api_key 本就在内）。
    func toConfigJSON() -> String {
        var dict: [String: Any] = [
            "provider": provider,
            "timeout": timeout,
            "max_retries": maxRetries,
            "reasoning_style": reasoningStyle,
        ]
        if !baseURL.isEmpty { dict["base_url"] = baseURL }
        if !apiKeyEnv.isEmpty { dict["api_key_env"] = apiKeyEnv }
        if !apiKey.isEmpty { dict["api_key"] = apiKey }
        dict["tiers"] = tiers.mapValues { $0.toConfigDict() }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    /// 日志安全描述：**绝不包含 api_key**（U-LLM2 / §3.5 建议项）。
    var redactedDescription: String {
        "provider=\(provider), base_url=\(baseURL.isEmpty ? "(默认)" : baseURL), "
            + "reasoning_style=\(reasoningStyle), max_retries=\(maxRetries), "
            + "tiers=\(tiers.map { "\($0.key):\($0.value.model)" }.sorted().joined(separator: ","))"
    }

    var resolvedBaseURL: String {
        if !baseURL.isEmpty { return baseURL }
        switch provider.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "deepseek": return "https://api.deepseek.com"
        case "openai": return "https://api.openai.com/v1"
        case "openrouter": return "https://openrouter.ai/api/v1"
        case "ollama": return "http://localhost:11434/v1"
        case "vllm": return "http://localhost:8000/v1"
        case "gemini": return "https://generativelanguage.googleapis.com/v1beta/openai"
        default: return ""
        }
    }

    /// 该 provider 是否需要 API key（D10 判定用；ollama/fake 免密）。
    var requiresAPIKey: Bool {
        switch provider.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "ollama", "fake": return false
        case "openai-compatible", "vllm": return !apiKey.isEmpty || !apiKeyEnv.isEmpty
        default: return true
        }
    }

    var resolvedAPIKeyEnv: String {
        if !apiKeyEnv.isEmpty { return apiKeyEnv }
        switch provider.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "deepseek": return "DEEPSEEK_API_KEY"
        case "openai": return "OPENAI_API_KEY"
        case "openrouter": return "OPENROUTER_API_KEY"
        case "gemini": return "GEMINI_API_KEY"
        default: return ""
        }
    }

    /// 是否能从设置文件或进程环境中取得凭据。
    var hasConfiguredAPIKey: Bool {
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        let envName = resolvedAPIKeyEnv
        guard !envName.isEmpty else { return false }
        return !(ProcessInfo.processInfo.environment[envName] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
