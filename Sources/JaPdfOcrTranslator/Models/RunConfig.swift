import CryptoKit
import Foundation

/// `config.json.params` 子对象（DESIGN §3.2）—— `params_sha256` 的计算范围。
struct RunParams: Codable, Sendable, Equatable {
    var glossaryPolicy: String = "B"
    var autoGlossaryEnabled: Bool = true
    var glossaryScope: String = "chunk"           // chunk | full
    var preExtractMode: String = "always"         // always | firstNChunks | off
    var preExtractFirstN: Int = 10
    var enablePrescan: Bool = true
    var enableStyleAnalysis: Bool = true
    var enablePunctNormalize: Bool = true
    var enableQA: Bool = true
    var enablePolish: Bool = false                // P2，恒为 false
    var enableResume: Bool = true
    var maxCharsPerChunk: Int = 4000
    var maxCharsPerParagraph: Int = 8000          // 固定
    var bilingual: Bool = false                   // DS 后端强制 false
    var userGlossarySHA256: String = ""
    /// v3.3-llm（U-LLM3）：纳入 `params_sha256` 计算；切换 provider → 参数哈希变化 → 旧 run 不可续跑（期望行为）。
    var llmProvider: String = "deepseek"

    private enum CodingKeys: String, CodingKey {
        case glossaryPolicy = "glossary_policy"
        case autoGlossaryEnabled = "auto_glossary_enabled"
        case glossaryScope = "glossary_scope"
        case preExtractMode = "pre_extract_mode"
        case preExtractFirstN = "pre_extract_first_n"
        case enablePrescan = "enable_prescan"
        case enableStyleAnalysis = "enable_style_analysis"
        case enablePunctNormalize = "enable_punct_normalize"
        case enableQA = "enable_qa"
        case enablePolish = "enable_polish"
        case enableResume = "enable_resume"
        case maxCharsPerChunk = "max_chars_per_chunk"
        case maxCharsPerParagraph = "max_chars_per_paragraph"
        case bilingual
        case userGlossarySHA256 = "user_glossary_sha256"
        case llmProvider = "llm_provider"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        glossaryPolicy = try c.decodeIfPresent(String.self, forKey: .glossaryPolicy) ?? "B"
        autoGlossaryEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoGlossaryEnabled) ?? true
        glossaryScope = try c.decodeIfPresent(String.self, forKey: .glossaryScope) ?? "chunk"
        preExtractMode = try c.decodeIfPresent(String.self, forKey: .preExtractMode) ?? "always"
        preExtractFirstN = try c.decodeIfPresent(Int.self, forKey: .preExtractFirstN) ?? 10
        enablePrescan = try c.decodeIfPresent(Bool.self, forKey: .enablePrescan) ?? true
        enableStyleAnalysis = try c.decodeIfPresent(Bool.self, forKey: .enableStyleAnalysis) ?? true
        enablePunctNormalize = try c.decodeIfPresent(Bool.self, forKey: .enablePunctNormalize) ?? true
        enableQA = try c.decodeIfPresent(Bool.self, forKey: .enableQA) ?? true
        enablePolish = try c.decodeIfPresent(Bool.self, forKey: .enablePolish) ?? false
        enableResume = try c.decodeIfPresent(Bool.self, forKey: .enableResume) ?? true
        maxCharsPerChunk = try c.decodeIfPresent(Int.self, forKey: .maxCharsPerChunk) ?? 4000
        maxCharsPerParagraph = try c.decodeIfPresent(Int.self, forKey: .maxCharsPerParagraph) ?? 8000
        bilingual = try c.decodeIfPresent(Bool.self, forKey: .bilingual) ?? false
        userGlossarySHA256 = try c.decodeIfPresent(String.self, forKey: .userGlossarySHA256) ?? ""
        llmProvider = try c.decodeIfPresent(String.self, forKey: .llmProvider) ?? "deepseek"
    }

    /// 规范化 JSON（键按声明顺序），供 `params_sha256` 计算。
    var canonicalJSON: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(self) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    var sha256: String {
        SHA256.hash(data: Data(canonicalJSON.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

/// `config.json`（DESIGN §3.2）—— Swift 侧解码/编码模型。
///
/// `schema_version != 1` 抛 `AppError.state`。`params_sha256` 由 `params` 规范化 JSON 计算；
/// 续跑判定用 `isResumable(input:params:)`。
struct RunConfig: Codable, Sendable, Equatable {
    var schemaVersion: Int = 1
    var createdAt: Double = 0
    var updatedAt: Double = 0
    var appVersion: String = "3.3.0"
    var skillVersion: String = "3.3.0"
    var backend: String = "workbuddy"             // workbuddy | deepseek
    var inputPath: String = ""
    var inputSHA256: String = ""
    var paramsSHA256: String = ""
    var params: RunParams = RunParams()
    var totalChunks: Int = 0
    var pathMode: String = "full"                 // full | simple（≤2 块）
    var prescanMode: String = "off"               // full | sampled | off
    var prescanSampleIndices: [Int] = []
    var stages: [String] = []
    /// v3.3-llm：`config.json.llm` 块（§3.2 增量）。**不含 api_key**（api_key 只写 llm_config.json）。
    /// WB 后端（不走 LLM 管线）为 nil。
    var llm: LLMBlock?

    /// `config.json.llm`（DESIGN-v3.3-llm §3.2）。api_key 故意缺席——config.json 公开可 diff，不存密。
    struct LLMBlock: Codable, Sendable, Equatable {
        var provider: String = "deepseek"
        var baseURL: String = ""
        var apiKeyEnv: String = ""
        var timeout: Int = 120
        var maxRetries: Int = 4
        var reasoningStyle: String = "deepseek"
        var tiers: [String: LLMTierConfig] = [:]

        private enum CodingKeys: String, CodingKey {
            case provider
            case baseURL = "base_url"
            case apiKeyEnv = "api_key_env"
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
            timeout = try c.decodeIfPresent(Int.self, forKey: .timeout) ?? 120
            maxRetries = try c.decodeIfPresent(Int.self, forKey: .maxRetries) ?? 4
            reasoningStyle = try c.decodeIfPresent(String.self, forKey: .reasoningStyle) ?? "deepseek"
            tiers = try c.decodeIfPresent([String: LLMTierConfig].self, forKey: .tiers) ?? [:]
        }

        /// 从 `LLMConfig` 派生（丢弃 api_key 后写入 config.json 快照）。
        static func fromConfig(_ config: LLMConfig) -> LLMBlock {
            var block = LLMBlock()
            block.provider = config.provider
            block.baseURL = config.baseURL
            block.apiKeyEnv = config.apiKeyEnv
            block.timeout = config.timeout
            block.maxRetries = config.maxRetries
            block.reasoningStyle = config.reasoningStyle
            block.tiers = config.tiers
            return block
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case appVersion = "app_version"
        case skillVersion = "skill_version"
        case backend
        case inputPath = "input_path"
        case inputSHA256 = "input_sha256"
        case paramsSHA256 = "params_sha256"
        case params
        case totalChunks = "total_chunks"
        case pathMode = "path_mode"
        case prescanMode = "prescan_mode"
        case prescanSampleIndices = "prescan_sample_indices"
        case stages
        case llm
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        createdAt = try c.decodeIfPresent(Double.self, forKey: .createdAt) ?? 0
        updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt) ?? 0
        appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion) ?? "3.3.0"
        skillVersion = try c.decodeIfPresent(String.self, forKey: .skillVersion) ?? "3.3.0"
        backend = try c.decodeIfPresent(String.self, forKey: .backend) ?? "workbuddy"
        inputPath = try c.decodeIfPresent(String.self, forKey: .inputPath) ?? ""
        inputSHA256 = try c.decodeIfPresent(String.self, forKey: .inputSHA256) ?? ""
        paramsSHA256 = try c.decodeIfPresent(String.self, forKey: .paramsSHA256) ?? ""
        params = try c.decodeIfPresent(RunParams.self, forKey: .params) ?? RunParams()
        totalChunks = try c.decodeIfPresent(Int.self, forKey: .totalChunks) ?? 0
        pathMode = try c.decodeIfPresent(String.self, forKey: .pathMode) ?? "full"
        prescanMode = try c.decodeIfPresent(String.self, forKey: .prescanMode) ?? "off"
        prescanSampleIndices = try c.decodeIfPresent([Int].self, forKey: .prescanSampleIndices) ?? []
        stages = try c.decodeIfPresent([String].self, forKey: .stages) ?? []
        llm = try c.decodeIfPresent(LLMBlock.self, forKey: .llm)
    }

    /// 续跑判定（§3.2 / Q5）：输入与参数双哈希一致且未 finished。
    func isResumable(inputSHA256 currentInput: String, params currentParams: RunParams) -> Bool {
        params.enableResume
            && schemaVersion == 1
            && inputSHA256 == currentInput
            && paramsSHA256 == currentParams.sha256
    }

    /// schema 校验：`schema_version` 必须为 1。
    static func validated(from data: Data) throws -> RunConfig {
        let config = try JSONDecoder().decode(RunConfig.self, from: data)
        guard config.schemaVersion == 1 else {
            throw AppError.state("config.json schema_version 不兼容：\(config.schemaVersion)（期望 1）")
        }
        return config
    }
}
