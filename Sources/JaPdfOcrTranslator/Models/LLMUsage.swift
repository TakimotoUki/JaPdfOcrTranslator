import Foundation

/// 单次调用用量（DESIGN-v3.3-llm §3.3 / §5.2 `LLMUsageSample`）。
struct LLMUsageSample: Codable, Sendable, Equatable {
    var promptTokens: Int = 0
    var completionTokens: Int = 0
    var totalTokens: Int = 0
    var cacheHitTokens: Int = 0
    var cacheMissTokens: Int = 0

    private enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case cacheHitTokens = "cache_hit_tokens"
        case cacheMissTokens = "cache_miss_tokens"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        promptTokens = try c.decodeIfPresent(Int.self, forKey: .promptTokens) ?? 0
        completionTokens = try c.decodeIfPresent(Int.self, forKey: .completionTokens) ?? 0
        totalTokens = try c.decodeIfPresent(Int.self, forKey: .totalTokens) ?? 0
        cacheHitTokens = try c.decodeIfPresent(Int.self, forKey: .cacheHitTokens) ?? 0
        cacheMissTokens = try c.decodeIfPresent(Int.self, forKey: .cacheMissTokens) ?? 0
    }
}

/// 用量槽位（totals / by_tier / by_stage 的每一项，§3.3 / §5.2 `LLMUsageSlot`）。
struct LLMUsageSlot: Codable, Sendable, Equatable {
    var calls: Int = 0
    var promptTokens: Int = 0
    var completionTokens: Int = 0
    var totalTokens: Int = 0
    var cacheHitTokens: Int = 0
    var cacheMissTokens: Int = 0
    var cacheHitRate: Double = 0

    private enum CodingKeys: String, CodingKey {
        case calls
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case cacheHitTokens = "cache_hit_tokens"
        case cacheMissTokens = "cache_miss_tokens"
        case cacheHitRate = "cache_hit_rate"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        calls = try c.decodeIfPresent(Int.self, forKey: .calls) ?? 0
        promptTokens = try c.decodeIfPresent(Int.self, forKey: .promptTokens) ?? 0
        completionTokens = try c.decodeIfPresent(Int.self, forKey: .completionTokens) ?? 0
        totalTokens = try c.decodeIfPresent(Int.self, forKey: .totalTokens) ?? 0
        cacheHitTokens = try c.decodeIfPresent(Int.self, forKey: .cacheHitTokens) ?? 0
        cacheMissTokens = try c.decodeIfPresent(Int.self, forKey: .cacheMissTokens) ?? 0
        cacheHitRate = try c.decodeIfPresent(Double.self, forKey: .cacheHitRate) ?? 0
    }
}

/// `usage.json` 读模型（DESIGN-v3.3-llm §3.3 / §5.2 `LLMUsage`）。
struct LLMUsage: Codable, Sendable, Equatable {
    var schemaVersion: Int = 1
    var updatedAt: Double = 0
    var totals: LLMUsageSlot = LLMUsageSlot()
    var byTier: [String: LLMUsageSlot] = [:]
    var byStage: [String: LLMUsageSlot] = [:]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case updatedAt = "updated_at"
        case totals
        case byTier = "by_tier"
        case byStage = "by_stage"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt) ?? 0
        totals = try c.decodeIfPresent(LLMUsageSlot.self, forKey: .totals) ?? LLMUsageSlot()
        byTier = try c.decodeIfPresent([String: LLMUsageSlot].self, forKey: .byTier) ?? [:]
        byStage = try c.decodeIfPresent([String: LLMUsageSlot].self, forKey: .byStage) ?? [:]
    }

    /// 进度归因（T10）：某阶段累计调用次数（by_stage 取不到时回退 totals）。
    func calls(forStage stage: String?) -> Int {
        guard let stage, let slot = byStage[stage] else { return totals.calls }
        return slot.calls
    }

    // MARK: - 成本估算（T10-b）

    /// 官方计价（每百万 token 美元；照搬 DESIGN-v3.3-llm §4.5 / wenyi，可配置扩展）。
    /// deepseek：输入 $0.27 / 输出 $1.10（deepseek-chat 官方价）；缓存命中输入 $0.07。
    /// openai：gpt-4o-mini 输入 $0.15 / 输出 $0.60（官方价）。
    static let pricingPerMTok: [String: (input: Double, output: Double, cacheInput: Double?)] = [
        "deepseek": (0.27, 1.10, 0.07),
        "openai": (0.15, 0.60, nil),
    ]

    /// 按 provider 官方价估算本次运行成本（美元）。
    ///
    /// - Returns: `Double?` —— 未知 provider（未在计价表内）返回 `nil`，UI 显示「无法估算」。
    func totalCostEstimate(provider: String) -> Double? {
        let key = provider.lowercased().replacingOccurrences(of: "_", with: "-")
        guard let price = Self.pricingPerMTok[key] else { return nil }
        let prompt = Double(totals.promptTokens) / 1_000_000.0
        let completion = Double(totals.completionTokens) / 1_000_000.0
        var cost = prompt * price.input + completion * price.output
        if let cacheInput = price.cacheInput {
            let cacheHit = Double(totals.cacheHitTokens) / 1_000_000.0
            let cacheMiss = Double(totals.cacheMissTokens) / 1_000_000.0
            // 输入成本 = 命中部分按缓存价 + 未命中部分按原价
            cost = cacheHit * cacheInput + cacheMiss * price.input + completion * price.output
        }
        return cost
    }
}
