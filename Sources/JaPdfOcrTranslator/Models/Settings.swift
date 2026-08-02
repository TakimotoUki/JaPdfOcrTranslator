import CryptoKit
import Foundation

/// 全局应用设置（DESIGN §3.2 参数映射 / PRD §7.2）。
///
/// v3.3 新增 10 个字段（PRD §7.2 八项 + `preExtractMode` + `preExtractFirstN`）。
/// **旧存档反序列化必须容错**：所有字段显式 `decodeIfPresent` + 默认值，
/// 老用户的 settings.json 缺新字段时用默认值补齐，绝不整份丢弃。
struct Settings: Codable, Equatable, Sendable {
    // MARK: - WorkBuddy driver
    var workbuddyAppPath: String = "/Applications/WorkBuddy.app"
    var workbuddyModel: String = "Hy3"
    var outputPdfTemplate: String = "<stem>_zh.pdf"   // display only
    var workDir: String = ""

    // MARK: - OCR (ndlocr-lite)
    var pythonInterpreterPath: String = Self.defaultPythonInterpreter()

    // MARK: - Translation backend & DeepSeek
    var translationBackend: String = "workbuddy"       // "workbuddy" | "api"
    var deepseekApiKey: String = ""
    var deepseekModel: String = "deepseek-v4-flash"
    var deepseekBaseURL: String = "https://api.deepseek.com"
    var deepseekTemperature: Double = 0.3
    var deepseekTimeout: Int = 120
    var deepseekMaxRetries: Int = 2

    // MARK: - Bilingual / glossary
    var bilingual: Bool = true
    var glossaryPath: String = ""

    // MARK: - Translation skill & prompt (3.2 / F13-F16)
    var selectedSkill: String = "jp-txt2pdf-translator"
    var customSkillPath: String = ""
    var customPrompt: String = ""
    var skillInstalled: Bool = false

    // MARK: - v3.3 术语表与流水线（PRD §7.2 / F33-18）
    /// 是否允许自动生成/补充术语表（决策矩阵开关，默认 true）。
    var autoGlossaryEnabled: Bool = true
    /// 术语注入范围：`chunk`=只注入本块命中词条；`full`=注入全表。
    var glossaryScope: String = "chunk"
    /// 译前预抽模式：`always` / `firstNChunks` / `off`（off 时仍以空数组调用留证据）。
    var preExtractMode: String = "always"
    /// `firstNChunks` 模式下的前 N 块。
    var preExtractFirstN: Int = 10
    /// S2 全书预扫。
    var enablePrescan: Bool = true
    /// S3 样本分析与风格指南。
    var enableStyleAnalysis: Bool = true
    /// S6 标点规范化。
    var enablePunctNormalize: Bool = true
    /// S7 一致性 QA。
    var enableQA: Bool = true
    /// P2 润色（默认关，成本高）。
    var enablePolish: Bool = false
    /// 断点续跑。
    var enableResume: Bool = true
    /// 每块目标字符数（对应 `split_text.py --target`）。
    var maxCharsPerChunk: Int = 4000

    // MARK: - v3.3-llm 多 Provider 设置（DESIGN-v3.3-llm §3.5 / U-LLM）
    /// LLM provider：deepseek | openai | openrouter | openai-compatible | ollama | vllm | gemini | fake。
    var llmProvider: String = "deepseek"
    /// 空 = 用 provider 默认 base_url。
    var llmBaseURL: String = "https://api.deepseek.com"
    /// 本轮仍存 Settings.json（与 v3.2 一致）；写 llm_config.json 时权限 0600、日志一律 redacted（U-LLM2 建议 v3.4 迁 Keychain）。
    var llmApiKey: String = ""
    /// 可选的 API Key 环境变量名；显式 Key 为空时由 llm_tool.py 从环境读取。
    var llmApiKeyEnv: String = ""
    var llmTimeout: Int = 120
    var llmMaxRetries: Int = 4
    var llmReasoningStyle: String = "none"
    var llmModelStrong: String = "deepseek-v4-flash"
    var llmModelCheap: String = ""
    var llmModelFast: String = ""
    var llmTierStrongThinking: Bool = true
    var llmTierCheapThinking: Bool = true
    var llmTierFastThinking: Bool = false

    // 三档 model 默认空串：空 = 回退 v3.2 `deepseekModel`（§3.5 兼容映射）；都空时用 §4.5 内置名。

    /// 组装 `LLMConfig`（DESIGN §3.5 兼容回退：apiKey ← deepseekApiKey、strong.model ← deepseekModel、
    /// baseURL ← deepseekBaseURL）。档位 model 解析链：显式值 → deepseekModel → §4.5 内置名。
    func toLLMConfig() -> LLMConfig {
        var config = LLMConfig()
        // UI 统一为用户自填的 OpenAI-compatible API，不再要求理解 provider 品牌。
        // 旧设置仍可迁移：没有新地址/Key/模型时才读取旧 DeepSeek 字段。
        config.provider = "openai-compatible"
        config.baseURL = llmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if config.baseURL.isEmpty {
            config.baseURL = deepseekBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        config.apiKey = llmApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if config.apiKey.isEmpty {
            config.apiKey = deepseekApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        config.apiKeyEnv = llmApiKeyEnv.trimmingCharacters(in: .whitespacesAndNewlines)
        config.timeout = llmTimeout
        config.maxRetries = llmMaxRetries
        config.reasoningStyle = llmReasoningStyle.isEmpty ? "none" : llmReasoningStyle
        let strongModel = {
            let explicit = llmModelStrong.trimmingCharacters(in: .whitespacesAndNewlines)
            if !explicit.isEmpty { return explicit }
            return deepseekModel.trimmingCharacters(in: .whitespacesAndNewlines)
        }()
        let cheapModel = llmModelCheap.trimmingCharacters(in: .whitespacesAndNewlines)
        let fastModel = llmModelFast.trimmingCharacters(in: .whitespacesAndNewlines)
        if !strongModel.isEmpty {
            config.tiers["strong"] = LLMTierConfig(
                model: strongModel, thinking: llmTierStrongThinking, reasoningEffort: "high")
        }
        if !cheapModel.isEmpty {
            config.tiers["cheap"] = LLMTierConfig(
                model: cheapModel, thinking: llmTierCheapThinking, reasoningEffort: "high")
        }
        if !fastModel.isEmpty {
            config.tiers["fast"] = LLMTierConfig(
                model: fastModel, thinking: llmTierFastThinking, reasoningEffort: "none")
        }
        return config
    }

    /// 翻译预设（PRD §8.3 顶部三按钮）。
    enum Preset: String, CaseIterable, Sendable {
        case fast, standard, fine
        var displayName: String {
            switch self {
            case .fast:     return "快速"
            case .standard: return "标准"
            case .fine:     return "精译"
            }
        }
    }

    /// 一键套用预设。
    ///
    /// - Note: 设计文档只规定了三个预设的存在（T04-d / PRD §8.3），未给具体取值；
    ///   这里按「快速=省 API 调用、标准=默认、精译=更细块+全预抽」的合理解释实现，
    ///   后续若 Bob 给出精确取值再收敛。
    mutating func applyPreset(_ preset: Preset) {
        switch preset {
        case .fast:
            enablePrescan = false
            enableStyleAnalysis = false
            enablePunctNormalize = true
            enableQA = true
            enablePolish = false
            enableResume = true
            preExtractMode = "off"          // 省一次独立 API 调用（仍留空数组证据）
            preExtractFirstN = 10
            maxCharsPerChunk = 6000
        case .standard:
            enablePrescan = true
            enableStyleAnalysis = true
            enablePunctNormalize = true
            enableQA = true
            enablePolish = false
            enableResume = true
            preExtractMode = "always"
            preExtractFirstN = 10
            maxCharsPerChunk = 4000
        case .fine:
            enablePrescan = true
            enableStyleAnalysis = true
            enablePunctNormalize = true
            enableQA = true
            enablePolish = false
            enableResume = true
            preExtractMode = "always"
            preExtractFirstN = 20
            maxCharsPerChunk = 3000
        }
    }

    /// 生成 `config.json.params`（§3.2）。`glossary_policy` 由决策矩阵推导，不在此拼接。
    func toRunParams(hasUserGlossary: Bool, userGlossarySHA: String) -> RunParams {
        var p = RunParams()
        p.glossaryPolicy = GlossaryPolicy.resolve(hasUserGlossary: hasUserGlossary,
                                                  autoGlossaryEnabled: autoGlossaryEnabled).rawValue
        p.autoGlossaryEnabled = autoGlossaryEnabled
        p.glossaryScope = glossaryScope
        p.preExtractMode = preExtractMode
        p.preExtractFirstN = preExtractFirstN
        p.enablePrescan = enablePrescan
        p.enableStyleAnalysis = enableStyleAnalysis
        p.enablePunctNormalize = enablePunctNormalize
        p.enableQA = enableQA
        p.enablePolish = enablePolish
        p.enableResume = enableResume
        p.maxCharsPerChunk = maxCharsPerChunk
        p.maxCharsPerParagraph = 8000                 // 固定
        p.bilingual = bilingual
        if isAPI {
            p.bilingual = false                       // DS 后端强制 false（PRD §7.3）
        }
        p.userGlossarySHA256 = userGlossarySHA
        return p
    }

    /// 用户术语表内容哈希（空路径 → ""）。用户改表则参数哈希变化 → 不可续跑（§3.2）。
    static func userGlossarySHA(path: String) -> String {
        let p = path.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, FileManager.default.fileExists(atPath: p),
              let data = try? Data(contentsOf: URL(fileURLWithPath: p)) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Persistence

    static var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("JaPdfOcrTranslator")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }

    static func load() -> Settings {
        let url = storeURL
        guard let data = try? Data(contentsOf: url) else { return Settings() }
        guard let decoded = try? JSONDecoder().decode(Settings.self, from: data) else {
            return Settings()
        }
        // 自愈：旧存档里是裸 `python3`，而本机存在 WorkBuddy 托管 venv 时自动切换。
        var result = decoded
        var healed = false
        if result.llmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.llmBaseURL = result.deepseekBaseURL
            healed = true
        }
        if result.llmModelStrong.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.llmModelStrong = result.deepseekModel
            healed = true
        }
        if result.pythonInterpreterPath == "python3" {
            let managed = (NSHomeDirectory() as NSString)
                .appendingPathComponent(".workbuddy/binaries/python/envs/default/bin/python3")
            if FileManager.default.isExecutableFile(atPath: managed) {
                result.pythonInterpreterPath = managed
                healed = true
            }
        }
        if healed { result.save() }
        return result
    }

    func save() {
        let url = Settings.storeURL
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
        // 设置中可能含 API Key，禁止同机其它用户读取。
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Validate that the current settings are sufficient to launch the selected backend.
    var isValid: Bool {
        if isAPI {
            let config = toLLMConfig()
            guard config.tiers["strong"]?.model.isEmpty == false else { return false }
            if config.resolvedBaseURL.isEmpty {
                return false
            }
            return !config.requiresAPIKey || config.hasConfiguredAPIKey
        }
        return !workbuddyAppPath.trimmingCharacters(in: .whitespaces).isEmpty
            && !workbuddyModel.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var isAPI: Bool { translationBackend == "api" || translationBackend == "deepseek" }

    /// 解析默认 Python 解释器：优先托管 venv，回退 `python3`。
    private static func defaultPythonInterpreter() -> String {
        let managed = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".workbuddy/binaries/python/envs/default/bin/python3")
        if FileManager.default.isExecutableFile(atPath: managed) {
            return managed
        }
        return "python3"
    }

    // MARK: - Codable（显式 decodeIfPresent，保证旧存档容错）

    private enum CodingKeys: String, CodingKey {
        case workbuddyAppPath, workbuddyModel, outputPdfTemplate, workDir, pythonInterpreterPath
        case translationBackend, deepseekApiKey, deepseekModel, deepseekBaseURL
        case deepseekTemperature, deepseekTimeout, deepseekMaxRetries
        case bilingual, glossaryPath
        case selectedSkill, customSkillPath, customPrompt, skillInstalled
        case autoGlossaryEnabled, glossaryScope, preExtractMode, preExtractFirstN
        case enablePrescan, enableStyleAnalysis, enablePunctNormalize, enableQA
        case enablePolish, enableResume, maxCharsPerChunk
        case llmProvider, llmBaseURL, llmApiKey, llmApiKeyEnv, llmTimeout, llmMaxRetries, llmReasoningStyle
        case llmModelStrong, llmModelCheap, llmModelFast
        case llmTierStrongThinking, llmTierCheapThinking, llmTierFastThinking
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workbuddyAppPath = try c.decodeIfPresent(String.self, forKey: .workbuddyAppPath) ?? "/Applications/WorkBuddy.app"
        workbuddyModel = try c.decodeIfPresent(String.self, forKey: .workbuddyModel) ?? "Hy3"
        outputPdfTemplate = try c.decodeIfPresent(String.self, forKey: .outputPdfTemplate) ?? "<stem>_zh.pdf"
        workDir = try c.decodeIfPresent(String.self, forKey: .workDir) ?? ""
        pythonInterpreterPath = try c.decodeIfPresent(String.self, forKey: .pythonInterpreterPath) ?? Self.defaultPythonInterpreter()
        translationBackend = try c.decodeIfPresent(String.self, forKey: .translationBackend) ?? "workbuddy"
        if translationBackend == "deepseek" { translationBackend = "api" }
        deepseekApiKey = try c.decodeIfPresent(String.self, forKey: .deepseekApiKey) ?? ""
        deepseekModel = try c.decodeIfPresent(String.self, forKey: .deepseekModel) ?? "deepseek-v4-flash"
        deepseekBaseURL = try c.decodeIfPresent(String.self, forKey: .deepseekBaseURL) ?? "https://api.deepseek.com"
        deepseekTemperature = try c.decodeIfPresent(Double.self, forKey: .deepseekTemperature) ?? 0.3
        deepseekTimeout = try c.decodeIfPresent(Int.self, forKey: .deepseekTimeout) ?? 120
        deepseekMaxRetries = try c.decodeIfPresent(Int.self, forKey: .deepseekMaxRetries) ?? 2
        bilingual = try c.decodeIfPresent(Bool.self, forKey: .bilingual) ?? true
        glossaryPath = try c.decodeIfPresent(String.self, forKey: .glossaryPath) ?? ""
        selectedSkill = try c.decodeIfPresent(String.self, forKey: .selectedSkill) ?? "jp-txt2pdf-translator"
        customSkillPath = try c.decodeIfPresent(String.self, forKey: .customSkillPath) ?? ""
        customPrompt = try c.decodeIfPresent(String.self, forKey: .customPrompt) ?? ""
        skillInstalled = try c.decodeIfPresent(Bool.self, forKey: .skillInstalled) ?? false
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
        // v3.3-llm（旧存档缺失 → 默认值，绝不让老用户设置丢失）
        llmProvider = try c.decodeIfPresent(String.self, forKey: .llmProvider) ?? "deepseek"
        llmBaseURL = try c.decodeIfPresent(String.self, forKey: .llmBaseURL) ?? "https://api.deepseek.com"
        llmApiKey = try c.decodeIfPresent(String.self, forKey: .llmApiKey) ?? ""
        llmApiKeyEnv = try c.decodeIfPresent(String.self, forKey: .llmApiKeyEnv) ?? ""
        llmTimeout = try c.decodeIfPresent(Int.self, forKey: .llmTimeout) ?? 120
        llmMaxRetries = try c.decodeIfPresent(Int.self, forKey: .llmMaxRetries) ?? 4
        llmReasoningStyle = try c.decodeIfPresent(String.self, forKey: .llmReasoningStyle) ?? "none"
        llmModelStrong = try c.decodeIfPresent(String.self, forKey: .llmModelStrong) ?? "deepseek-v4-flash"
        llmModelCheap = try c.decodeIfPresent(String.self, forKey: .llmModelCheap) ?? ""
        llmModelFast = try c.decodeIfPresent(String.self, forKey: .llmModelFast) ?? ""
        llmTierStrongThinking = try c.decodeIfPresent(Bool.self, forKey: .llmTierStrongThinking) ?? true
        llmTierCheapThinking = try c.decodeIfPresent(Bool.self, forKey: .llmTierCheapThinking) ?? true
        llmTierFastThinking = try c.decodeIfPresent(Bool.self, forKey: .llmTierFastThinking) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(workbuddyAppPath, forKey: .workbuddyAppPath)
        try c.encode(workbuddyModel, forKey: .workbuddyModel)
        try c.encode(outputPdfTemplate, forKey: .outputPdfTemplate)
        try c.encode(workDir, forKey: .workDir)
        try c.encode(pythonInterpreterPath, forKey: .pythonInterpreterPath)
        try c.encode(translationBackend, forKey: .translationBackend)
        try c.encode(deepseekApiKey, forKey: .deepseekApiKey)
        try c.encode(deepseekModel, forKey: .deepseekModel)
        try c.encode(deepseekBaseURL, forKey: .deepseekBaseURL)
        try c.encode(deepseekTemperature, forKey: .deepseekTemperature)
        try c.encode(deepseekTimeout, forKey: .deepseekTimeout)
        try c.encode(deepseekMaxRetries, forKey: .deepseekMaxRetries)
        try c.encode(bilingual, forKey: .bilingual)
        try c.encode(glossaryPath, forKey: .glossaryPath)
        try c.encode(selectedSkill, forKey: .selectedSkill)
        try c.encode(customSkillPath, forKey: .customSkillPath)
        try c.encode(customPrompt, forKey: .customPrompt)
        try c.encode(skillInstalled, forKey: .skillInstalled)
        try c.encode(autoGlossaryEnabled, forKey: .autoGlossaryEnabled)
        try c.encode(glossaryScope, forKey: .glossaryScope)
        try c.encode(preExtractMode, forKey: .preExtractMode)
        try c.encode(preExtractFirstN, forKey: .preExtractFirstN)
        try c.encode(enablePrescan, forKey: .enablePrescan)
        try c.encode(enableStyleAnalysis, forKey: .enableStyleAnalysis)
        try c.encode(enablePunctNormalize, forKey: .enablePunctNormalize)
        try c.encode(enableQA, forKey: .enableQA)
        try c.encode(enablePolish, forKey: .enablePolish)
        try c.encode(enableResume, forKey: .enableResume)
        try c.encode(maxCharsPerChunk, forKey: .maxCharsPerChunk)
        try c.encode(llmProvider, forKey: .llmProvider)
        try c.encode(llmBaseURL, forKey: .llmBaseURL)
        try c.encode(llmApiKey, forKey: .llmApiKey)
        try c.encode(llmApiKeyEnv, forKey: .llmApiKeyEnv)
        try c.encode(llmTimeout, forKey: .llmTimeout)
        try c.encode(llmMaxRetries, forKey: .llmMaxRetries)
        try c.encode(llmReasoningStyle, forKey: .llmReasoningStyle)
        try c.encode(llmModelStrong, forKey: .llmModelStrong)
        try c.encode(llmModelCheap, forKey: .llmModelCheap)
        try c.encode(llmModelFast, forKey: .llmModelFast)
        try c.encode(llmTierStrongThinking, forKey: .llmTierStrongThinking)
        try c.encode(llmTierCheapThinking, forKey: .llmTierCheapThinking)
        try c.encode(llmTierFastThinking, forKey: .llmTierFastThinking)
    }
}
