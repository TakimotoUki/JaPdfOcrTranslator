import Foundation

/// 冲突裁决结果（§3.7 `resolution` 值域）。
enum ConflictResolution: String, Codable, Sendable {
    case pending           = ""               // 未裁决
    case rejectedByLock    = "rejected_by_lock"
    case resolvedByUser    = "resolved_by_user"
    case resolvedByAgent   = "resolved_by_agent"
    case superseded        = "superseded"
}

/// `glossary_conflicts.json.conflicts[]` 的一条（DESIGN §3.7）。
struct GlossaryConflict: Codable, Sendable, Identifiable, Equatable {
    var id: Int
    var source: String
    var existingTarget: String
    var proposedTarget: String
    var chunk: Int?
    var phase: String = "manual"          // pre | post | import | manual
    var resolved: Bool = false
    var resolution: ConflictResolution = .pending
    var resolvedBy: String = ""           // system | user | agent
    var createdAt: Double = 0
    var resolvedAt: Double = 0

    /// `resolution == "" && resolved == false` → 待裁决，计入 `glossary_conflicts_open`。
    var isOpen: Bool { !resolved && resolution == .pending }

    private enum CodingKeys: String, CodingKey {
        case id, source
        case existingTarget = "existing_target"
        case proposedTarget = "proposed_target"
        case chunk, phase, resolved, resolution
        case resolvedBy = "resolved_by"
        case createdAt = "created_at"
        case resolvedAt = "resolved_at"
    }

    init(id: Int, source: String, existingTarget: String, proposedTarget: String,
         chunk: Int? = nil, phase: String = "manual", resolved: Bool = false,
         resolution: ConflictResolution = .pending, resolvedBy: String = "",
         createdAt: Double = 0, resolvedAt: Double = 0) {
        self.id = id
        self.source = source
        self.existingTarget = existingTarget
        self.proposedTarget = proposedTarget
        self.chunk = chunk
        self.phase = phase
        self.resolved = resolved
        self.resolution = resolution
        self.resolvedBy = resolvedBy
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
    }
}

/// `glossary_conflicts.json` 整文件容器（§3.7）。
struct GlossaryConflictFile: Codable, Sendable {
    var schemaVersion: Int = 1
    var nextId: Int = 1
    var conflicts: [GlossaryConflict] = []

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case nextId = "next_id"
        case conflicts
    }

    var openCount: Int { conflicts.lazy.filter { $0.isOpen }.count }
}
