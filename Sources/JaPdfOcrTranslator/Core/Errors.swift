import Foundation

/// Unified error model (port of ``utils/errors.py``). Each case carries a
/// user-facing Chinese message so the UI can surface it directly.
enum AppError: Error, Sendable {
    case extraction(String)
    case workbuddy(String)
    case translator(String)
    case deepseek(String)
    case pipeline(String)
    case ocr(String)
    case glossary(String)
    case skill(String)
    /// v3.3: `state/` 目录读写、schema 校验、锁获取失败等状态层错误。
    case state(String)
    /// v3.3: `glossary_tool.py` 子进程调用失败（参数错误 / 输入畸形 / 解析失败）。
    case glossaryTool(String)
    /// v3.3: registry 中的 skill 版本与应用要求不符（B2 版本印记校验）。
    case skillVersion(String)
    /// v3.3-llm: `llm_tool.py` 调用失败（参数/输入/stdout 解析失败等）。
    case llmTool(String)
    /// v3.3-llm: LLM 调用重试耗尽（exit 6）。
    case llmRetryExhausted(String)
    /// v3.3-llm: 凭据/配置校验未通过（exit 5，validate 子命令）。
    case llmCredential(String)
    /// v3.3-llm: LLM 配置 JSON 畸形 / 无法构造（exit 3）。
    case llmConfig(String)
    case abort   // sentinel for graceful abort
}

extension AppError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .extraction(let m): return m
        case .workbuddy(let m): return m
        case .translator(let m): return m
        case .deepseek(let m): return m
        case .pipeline(let m): return m
        case .ocr(let m): return m
        case .glossary(let m): return m
        case .skill(let m): return m
        case .state(let m): return m
        case .glossaryTool(let m): return m
        case .skillVersion(let m): return m
        case .llmTool(let m): return m
        case .llmRetryExhausted(let m): return m
        case .llmCredential(let m): return m
        case .llmConfig(let m): return m
        case .abort: return "用户中止了任务。"
        }
    }
}
