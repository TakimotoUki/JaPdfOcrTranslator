import CryptoKit
import Foundation

// ════════════════════════════════════════════════════════════════════════
// 支持模型（§3.3 / §3.4 / §3.5 / §3.8 / §3.9）
// ════════════════════════════════════════════════════════════════════════

/// `events.jsonl` 的一行（DESIGN §3.4）。
struct StateEvent: Codable, Sendable, Equatable {
    var seq: Int
    var ts: Double
    var type: String
    var stage: String?
    var chunk: Int?
    var actor: String
    var data: [String: JSONValue] = [:]

    /// 宽容解码用的值类型（事件 `data` 载荷类型不定）。
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
    }

    private enum CodingKeys: String, CodingKey {
        case seq, ts, type, stage, chunk, actor, data
    }
}

/// `structure.json`（DESIGN §3.5）。
struct Structure: Codable, Sendable, Equatable {
    var schemaVersion: Int = 1
    var generatedAt: Double = 0
    var sourcePath: String = ""
    var totalChars: Int = 0
    var chunkCount: Int = 0
    var target: Int = 4000
    var maxp: Int = 8000
    var chapters: [Chapter] = []
    var chunks: [Chunk] = []

    struct Chapter: Codable, Sendable, Equatable {
        var index: Int
        var title: String
        var startChunk: Int
        var startParagraph: Int

        private enum CodingKeys: String, CodingKey {
            case index, title
            case startChunk = "start_chunk"
            case startParagraph = "start_paragraph"
        }
    }

    struct Chunk: Codable, Sendable, Equatable {
        var index: Int
        var file: String
        var chars: Int
        var paragraphs: Int
        var chapterIndex: Int?
        var startsMidSentence: Bool = false
        var endsMidSentence: Bool = false
        var sha256: String = ""

        private enum CodingKeys: String, CodingKey {
            case index, file, chars, paragraphs
            case chapterIndex = "chapter_index"
            case startsMidSentence = "starts_mid_sentence"
            case endsMidSentence = "ends_mid_sentence"
            case sha256
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case sourcePath = "source_path"
        case totalChars = "total_chars"
        case chunkCount = "chunk_count"
        case target, maxp, chapters, chunks
    }
}

/// `qa_issues.json`（DESIGN §3.9）。
struct QAReport: Codable, Sendable, Equatable {
    var schemaVersion: Int = 1
    var generatedAt: Double = 0
    var chunksScanned: Int = 0
    var terminologyRate: Double = 1.0
    var summary: Summary = Summary()
    var issues: [Issue] = []

    struct Summary: Codable, Sendable, Equatable {
        var total: Int = 0
        var byKind: [String: Int] = [:]
        var bySeverity: [String: Int] = [:]
        var terminologyExpected: Int = 0
        var terminologyViolations: Int = 0
        var terminologyRate: Double = 1.0

        private enum CodingKeys: String, CodingKey {
            case total
            case byKind = "by_kind"
            case bySeverity = "by_severity"
            case terminologyExpected = "terminology_expected"
            case terminologyViolations = "terminology_violations"
            case terminologyRate = "terminology_rate"
        }
    }

    struct Issue: Codable, Sendable, Equatable {
        var chunk: Int
        var kind: String          // japanese_residue | terminology | placeholder | number | punctuation | paragraph
        var severity: String      // error | warning | suggestion
        var message: String = ""
        var source: String? = nil
        var suggestion: String? = nil
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case chunksScanned = "chunks_scanned"
        case terminologyRate = "terminology_rate"
        case summary, issues
    }
}

/// `alignment_report.json`（DESIGN §3.8）。
struct AlignmentReport: Codable, Sendable, Equatable {
    var schemaVersion: Int = 1
    var generatedAt: Double = 0
    var chunksChecked: Int = 0
    var errorChunks: [Int] = []
    var issues: [Issue] = []

    struct Issue: Codable, Sendable, Equatable {
        var chunk: Int
        var kind: String          // missing_file | empty_translation | paragraph_count_mismatch | ratio_out_of_range
        var severity: String      // error | warning
        var srcParagraphs: Int = 0
        var zhParagraphs: Int = 0
        var delta: Int = 0
        var ratio: Double = 1.0
        var message: String = ""

        private enum CodingKeys: String, CodingKey {
            case chunk, kind, severity
            case srcParagraphs = "src_paragraphs"
            case zhParagraphs = "zh_paragraphs"
            case delta, ratio, message
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case chunksChecked = "chunks_checked"
        case errorChunks = "error_chunks"
        case issues
    }
}

/// F33-02 / 阶段产物合规校验结果。
struct ComplianceResult: Codable, Sendable, Equatable {
    var compliant: Bool
    var missingPreExtract: [Int] = []
    var outOfOrder: [Int] = []
    var checks: [String: Bool] = [:]

    private enum CodingKeys: String, CodingKey {
        case compliant
        case missingPreExtract = "missing_pre_extract"
        case outOfOrder = "out_of_order"
        case checks
    }
}

// ════════════════════════════════════════════════════════════════════════
// StateStore（DESIGN §5.1）
// ════════════════════════════════════════════════════════════════════════

/// `state/` 目录的统一读写入口（Swift 侧）。
///
/// 写操作一律 `FileLock` + 原子写；`appendEvent` 在 `state.lock` 内
/// `nextSeqLocked`（读 `.locks/seq` → +1 → 写回 → 追加一行），与 Python 侧
/// `_common.next_seq` / `append_event` 语义完全一致（DESIGN §10.4）。
struct StateStore: Sendable {
    let root: URL

    init(root: URL) { self.root = root }

    // MARK: - 布局

    /// 确保 `state/`、`state/chunks/`、`state/.locks/` 存在。
    func ensureLayout() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("chunks"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".locks"), withIntermediateDirectories: true)
    }

    private var locksDir: URL { root.appendingPathComponent(".locks") }

    // MARK: - config.json

    func readConfig() -> RunConfig? {
        let url = root.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? RunConfig.validated(from: data)
    }

    func writeConfig(_ config: RunConfig) throws {
        let url = root.appendingPathComponent("config.json")
        try ensureLayout()
        let data = try JSONEncoder().encode(config)
        try FileLock.withExclusiveLock(at: locksDir.appendingPathComponent("state.lock")) {
            try Self.atomicWrite(data, to: url)
        }
    }

    // MARK: - status.json

    func readStatus() -> TranslationState? {
        let url = root.appendingPathComponent("status.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? TranslationState.validated(from: data)
    }

    func writeStatus(_ state: TranslationState) throws {
        let url = root.appendingPathComponent("status.json")
        try ensureLayout()
        let data = try JSONEncoder().encode(state)
        try FileLock.withExclusiveLock(at: locksDir.appendingPathComponent("state.lock")) {
            try Self.atomicWrite(data, to: url)
        }
    }

    // MARK: - events.jsonl

    /// 在 `state.lock` 内自增 seq 并追加一行（§3.4 / §10.4 R1-R4）。
    @discardableResult
    func appendEvent(type: String, stage: String?, chunk: Int?, actor: String,
                     data: [String: StateEvent.JSONValue] = [:]) throws -> Int {
        try ensureLayout()
        return try FileLock.withExclusiveLock(at: locksDir.appendingPathComponent("state.lock")) {
            let seq = FileLock.nextSeqLocked(stateDir: root)
            let event = StateEvent(seq: seq,
                                   ts: Date().timeIntervalSince1970,
                                   type: type,
                                   stage: stage,
                                   chunk: chunk,
                                   actor: actor,
                                   data: data)
            var line = try JSONEncoder().encode(event)
            line.append(0x0A)   // 追加换行（与 Python json.dumps + "\n" 对齐）
            let url = root.appendingPathComponent("events.jsonl")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            return seq
        }
    }

    func readEvents() -> [StateEvent] {
        let url = root.appendingPathComponent("events.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [StateEvent] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let event = try? JSONDecoder().decode(StateEvent.self, from: data) else { continue }
            out.append(event)
        }
        return out
    }

    // MARK: - 只读报告

    func readStructure() -> Structure? {
        let url = root.appendingPathComponent("structure.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Structure.self, from: data)
    }

    func readQAIssues() -> QAReport? {
        let url = root.appendingPathComponent("qa_issues.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(QAReport.self, from: data)
    }

    func readAlignment() -> AlignmentReport? {
        let url = root.appendingPathComponent("alignment_report.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AlignmentReport.self, from: data)
    }

    /// 只读 `glossary.json`（唯一写路径是 glossary_tool.py，见 T04-b 红线）。
    func readGlossary() -> Glossary {
        let url = root.appendingPathComponent("glossary.json")
        return (try? Glossary.loadJSON(url)) ?? Glossary()
    }

    func readConflicts() -> [GlossaryConflict] {
        let url = root.appendingPathComponent("glossary_conflicts.json")
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(GlossaryConflictFile.self, from: data) else { return [] }
        return file.conflicts
    }

    // MARK: - F33-02 合规校验（§3.4 验收算法）

    /// 逐块校验 `glossary_pre_extract{chunk:N}` 是否早于 `chunk_translated{chunk:N}`。
    ///
    /// 与 Python 侧 `state_tool.py verify --check pre-extract-order` 同一算法：
    /// ```
    /// required = { N : 1 ≤ N ≤ total_chunks
    ///                  ∧ chunk_status[N] == "done"
    ///                  ∧ (pre_extract_mode == "always"
    ///                     ∨ (pre_extract_mode == "firstNChunks" ∧ N ≤ pre_extract_first_n)) }
    /// for N in required:
    ///     pre = min{ e.seq | e.type == "glossary_pre_extract" ∧ e.chunk == N }
    ///     tr  = min{ e.seq | e.type == "chunk_translated"     ∧ e.chunk == N }
    ///     fail if pre 不存在 or tr 不存在 or pre >= tr
    /// ```
    /// `pre_extract_mode == "off"` → 恒 compliant（报告另标注降级）。
    func verifyPreExtractOrder(_ config: RunConfig) -> ComplianceResult {
        let events = readEvents()
        let status = readStatus()

        func minSeq(type: String, chunk: Int) -> Int? {
            events.lazy
                .filter { $0.type == type && $0.chunk == chunk }
                .map { $0.seq }
                .min()
        }

        var required: [Int] = []
        let total = max(config.totalChunks, status?.chunksTotal ?? 0)
        let chunkStatus = status?.chunkStatus ?? [:]
        let mode = config.params.preExtractMode
        let firstN = config.params.preExtractFirstN

        for n in 1...max(total, 0) {
            let key = "\(n)"
            guard chunkStatus[key] == "done" else { continue }
            switch mode {
            case "firstNChunks":
                guard n <= firstN else { continue }
            case "off":
                continue                    // off → 不纳入 required
            default:                        // always
                break
            }
            required.append(n)
        }

        var missing: [Int] = []
        var outOfOrder: [Int] = []
        for n in required {
            guard let pre = minSeq(type: "glossary_pre_extract", chunk: n),
                  let tr = minSeq(type: "chunk_translated", chunk: n),
                  pre < tr else {
                if minSeq(type: "glossary_pre_extract", chunk: n) == nil {
                    missing.append(n)
                } else {
                    outOfOrder.append(n)
                }
                continue
            }
        }

        let compliant = (mode == "off") || (missing.isEmpty && outOfOrder.isEmpty)
        return ComplianceResult(compliant: compliant,
                                missingPreExtract: missing,
                                outOfOrder: outOfOrder,
                                checks: ["pre_extract_order": compliant,
                                         "chunk_complete": status?.finished ?? false])
    }

    // MARK: - 归档

    /// 把 `state/` 整体改名为 `state_archive_<ts>/` 后返回新路径（§4.10 reset --archive）。
    @discardableResult
    func archive() throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else {
            throw AppError.state("state 目录不存在，无法归档：\(root.path)")
        }
        let ts = Int(Date().timeIntervalSince1970)
        let parent = root.deletingLastPathComponent()
        let target = parent.appendingPathComponent("state_archive_\(ts)")
        guard !fm.fileExists(atPath: target.path) else {
            throw AppError.state("归档目标已存在：\(target.path)")
        }
        try fm.moveItem(at: root, to: target)
        return target
    }

    // MARK: - 原子写

    /// `tmp + fsync + os.replace` 语义（与 Python `_common.write_json_atomic` 对齐）。
    private static func atomicWrite(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try? FileHandle(forWritingTo: tmp).synchronizeFile()
            if fm.fileExists(atPath: url.path) {
                _ = try? fm.removeItem(at: url)
            }
            try fm.moveItem(at: tmp, to: url)
        } catch {
            try? fm.removeItem(at: tmp)
            throw AppError.state("原子写入失败：\(url.path)（\(error.localizedDescription)）")
        }
    }
}
