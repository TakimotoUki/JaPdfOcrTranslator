import Foundation

/// Resolved skill info — unified contract consumed by both backends
/// (port of ``core/skill_registry.SkillInfo``).
struct SkillInfo: Sendable {
    let id: String
    let name: String
    let prompt: String
    let scriptsDir: URL
    var isLoaded: Bool
}
