import Foundation

/// `status.json`（DESIGN §3.3）—— Swift 侧解码/编码模型。
///
/// 未知字段容错：所有字段 `decodeIfPresent` + 默认值；`schema_version != 1` 抛 `AppError.state`。
/// 与 `state_tool.py` 的 `_blank_status` / `_write_status` 共用同一 schema。
struct TranslationState: Codable, Sendable, Equatable {
    var schemaVersion: Int = 1
    var updatedAt: Double = 0
    var stage: String = "S0"
    var stageIndex: Int = 0
    var stageTotal: Int = 9
    var stageName: String = "初始化"
    var chunksTotal: Int = 0
    var chunksDone: Int = 0
    var chunksFailed: Int = 0
    var chunksSkipped: Int = 0
    var currentChunk: Int?
    var glossaryTerms: Int = 0
    var glossaryLocked: Int = 0
    var glossaryConflictsOpen: Int = 0
    var qaIssues: Int = 0
    var alignmentIssues: Int = 0
    var finished: Bool = false
    var failed: Bool = false
    var compliant: Bool?
    var message: String = ""
    var chunkStatus: [String: String] = [:]
    var artifacts: Artifacts = Artifacts()

    struct Artifacts: Codable, Sendable, Equatable {
        var zhPdf: String = ""
        var jaPdf: String = ""
        var biPdf: String = ""
        var report: String = ""
        var glossaryCsv: String = ""

        private enum CodingKeys: String, CodingKey {
            case zhPdf = "zh_pdf", jaPdf = "ja_pdf", biPdf = "bi_pdf"
            case report, glossaryCsv = "glossary_csv"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case updatedAt = "updated_at"
        case stage
        case stageIndex = "stage_index"
        case stageTotal = "stage_total"
        case stageName = "stage_name"
        case chunksTotal = "chunks_total"
        case chunksDone = "chunks_done"
        case chunksFailed = "chunks_failed"
        case chunksSkipped = "chunks_skipped"
        case currentChunk = "current_chunk"
        case glossaryTerms = "glossary_terms"
        case glossaryLocked = "glossary_locked"
        case glossaryConflictsOpen = "glossary_conflicts_open"
        case qaIssues = "qa_issues"
        case alignmentIssues = "alignment_issues"
        case finished, failed, compliant, message
        case chunkStatus = "chunk_status"
        case artifacts
    }

    init() {}

    /// UI 文案派生（F33-09）：`阶段 {stage_index+1}/9 · {stage_name} ｜ 第 {chunks_done}/{chunks_total} 块 ｜ 术语 …`
    var progressLine: String {
        "阶段 \(stageIndex + 1)/\(stageTotal) · \(stageName) ｜ 第 \(chunksDone)/\(chunksTotal) 块" +
        " ｜ 术语 \(glossaryTerms) 条 · 冲突 \(glossaryConflictsOpen) · QA \(qaIssues)"
    }

    /// `updated_at` 超过 300s 未更新 → 判定 UI 卡死（F33-09 降级路径）。
    func isStale(now: Double = Date().timeIntervalSince1970) -> Bool {
        (now - updatedAt) > 300
    }

    /// schema 校验：`schema_version` 必须为 1。
    static func validated(from data: Data) throws -> TranslationState {
        let state = try JSONDecoder().decode(TranslationState.self, from: data)
        guard state.schemaVersion == 1 else {
            throw AppError.state("status.json schema_version 不兼容：\(state.schemaVersion)（期望 1）")
        }
        return state
    }

    /// 解码时对缺失键宽容：显式实现 `init(from:)` 用 `decodeIfPresent`。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt) ?? 0
        stage = try c.decodeIfPresent(String.self, forKey: .stage) ?? "S0"
        stageIndex = try c.decodeIfPresent(Int.self, forKey: .stageIndex) ?? 0
        stageTotal = try c.decodeIfPresent(Int.self, forKey: .stageTotal) ?? 9
        stageName = try c.decodeIfPresent(String.self, forKey: .stageName) ?? "初始化"
        chunksTotal = try c.decodeIfPresent(Int.self, forKey: .chunksTotal) ?? 0
        chunksDone = try c.decodeIfPresent(Int.self, forKey: .chunksDone) ?? 0
        chunksFailed = try c.decodeIfPresent(Int.self, forKey: .chunksFailed) ?? 0
        chunksSkipped = try c.decodeIfPresent(Int.self, forKey: .chunksSkipped) ?? 0
        currentChunk = try c.decodeIfPresent(Int.self, forKey: .currentChunk)
        glossaryTerms = try c.decodeIfPresent(Int.self, forKey: .glossaryTerms) ?? 0
        glossaryLocked = try c.decodeIfPresent(Int.self, forKey: .glossaryLocked) ?? 0
        glossaryConflictsOpen = try c.decodeIfPresent(Int.self, forKey: .glossaryConflictsOpen) ?? 0
        qaIssues = try c.decodeIfPresent(Int.self, forKey: .qaIssues) ?? 0
        alignmentIssues = try c.decodeIfPresent(Int.self, forKey: .alignmentIssues) ?? 0
        finished = try c.decodeIfPresent(Bool.self, forKey: .finished) ?? false
        failed = try c.decodeIfPresent(Bool.self, forKey: .failed) ?? false
        compliant = try c.decodeIfPresent(Bool.self, forKey: .compliant)
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        chunkStatus = try c.decodeIfPresent([String: String].self, forKey: .chunkStatus) ?? [:]
        artifacts = try c.decodeIfPresent(Artifacts.self, forKey: .artifacts) ?? Artifacts()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(stage, forKey: .stage)
        try c.encode(stageIndex, forKey: .stageIndex)
        try c.encode(stageTotal, forKey: .stageTotal)
        try c.encode(stageName, forKey: .stageName)
        try c.encode(chunksTotal, forKey: .chunksTotal)
        try c.encode(chunksDone, forKey: .chunksDone)
        try c.encode(chunksFailed, forKey: .chunksFailed)
        try c.encode(chunksSkipped, forKey: .chunksSkipped)
        try c.encodeIfPresent(currentChunk, forKey: .currentChunk)
        try c.encode(glossaryTerms, forKey: .glossaryTerms)
        try c.encode(glossaryLocked, forKey: .glossaryLocked)
        try c.encode(glossaryConflictsOpen, forKey: .glossaryConflictsOpen)
        try c.encode(qaIssues, forKey: .qaIssues)
        try c.encode(alignmentIssues, forKey: .alignmentIssues)
        try c.encode(finished, forKey: .finished)
        try c.encode(failed, forKey: .failed)
        try c.encodeIfPresent(compliant, forKey: .compliant)
        try c.encode(message, forKey: .message)
        try c.encode(chunkStatus, forKey: .chunkStatus)
        try c.encode(artifacts, forKey: .artifacts)
    }
}
