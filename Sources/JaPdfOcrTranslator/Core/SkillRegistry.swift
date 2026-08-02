import CryptoKit
import Foundation

/// Unified skill resolve / verify / load (port of ``core/skill_registry``).
///
/// The built-in skill is bundled with the app; on first launch (gated by
/// `skillInstalled`) it is synced into the user registry
/// `~/.workbuddy/skills/jp-txt2pdf-translator` so WorkBuddy can find it by name.
/// A SHA-256 tree signature guarantees the copy stays in sync (self-heals).
enum SkillRegistry {
    static let builtinID = "jp-txt2pdf-translator"

    // MARK: - Resolve

    static func resolveSkill(skillID: String, customPath: String) -> SkillInfo {
        let isBuiltin = (skillID == builtinID) || customPath.isEmpty
        let sourceDir = isBuiltin ? Paths.builtinSkillDir() : URL(fileURLWithPath: customPath)

        var name = skillID
        var body = ""
        let skillMd = sourceDir.appendingPathComponent("SKILL.md")
        if let text = try? String(contentsOf: skillMd, encoding: .utf8) {
            let (fm, b) = splitFrontmatter(text)
            if let n = extractName(fm) { name = n }
            body = b
        }

        let prompt: String
        if isBuiltin {
            prompt = TranslationPrompts.systemCore
        } else {
            prompt = body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? TranslationPrompts.systemCore
                : body
        }

        let scriptsDir = sourceDir.appendingPathComponent("scripts")
        var info = SkillInfo(
            id: skillID, name: name, prompt: prompt,
            scriptsDir: scriptsDir, isLoaded: false
        )
        info.isLoaded = isSynced(info)
        return info
    }

    /// Names of the pipeline scripts the built-in skill must ship. If any of
    /// these is missing, WorkBuddy fails the translation (it only sees the
    /// `SKILL.md`). This list is the single source of truth for "is the skill
    /// complete?" so the app's status never lies about a broken skill.
    ///
    /// v3.3：13 项主流水线脚本 + T06 新增 2 个 LLM 脚本，共 15 项。
    /// 与 DESIGN §2.6 `SkillRegistry.requiredScripts` + DESIGN-v3.3-llm §2.2 一致；
    /// 与 smoke_test.sh 的「≥13 + _llm_common.py/llm_tool.py 齐备」断言保持同步。
    static let requiredScripts = [
        "_common.py", "state_tool.py", "glossary_tool.py",
        "split_text.py", "sample_text.py", "reduce_digests.py",
        "check_boundaries.py", "check_alignment.py", "normalize_punct.py",
        "qa_consistency.py", "merge.py", "make_report.py", "build_pdf.py",
        "_llm_common.py", "llm_tool.py"
    ]

    // MARK: - Verify

    /// Single source of truth for `check_status` (F29).
    static func verify(_ info: SkillInfo) -> Bool {
        let registry = registryDir(of: info)
        let registryMd = registry.appendingPathComponent("SKILL.md")
        guard FileManager.default.fileExists(atPath: registry.path),
              FileManager.default.fileExists(atPath: registryMd.path) else {
            return false
        }
        // Built-in skill must also ship its 13 pipeline scripts; otherwise
        // WorkBuddy will report "skill 原始只含 SKILL.md（脚本缺失）".
        if info.id == builtinID {
            let scriptsDir = registry.appendingPathComponent("scripts")
            for s in Self.requiredScripts {
                guard FileManager.default.fileExists(
                    atPath: scriptsDir.appendingPathComponent(s).path
                ) else { return false }
            }
        }
        return (try? String(contentsOf: registryMd, encoding: .utf8)) != nil
    }

    /// 返回缺失文件名的完整列表（SKILL.md + 13 个脚本），供 `checkStatus` 文案与 UI 提示。
    static func missingFiles(of info: SkillInfo) -> [String] {
        let registry = registryDir(of: info)
        let fm = FileManager.default
        var missing: [String] = []
        if !fm.fileExists(atPath: registry.path) {
            return ["（registry 目录缺失）"]
        }
        if !fm.fileExists(atPath: registry.appendingPathComponent("SKILL.md").path) {
            missing.append("SKILL.md")
        }
        if info.id == builtinID {
            let scriptsDir = registry.appendingPathComponent("scripts")
            for s in Self.requiredScripts {
                if !fm.fileExists(atPath: scriptsDir.appendingPathComponent(s).path) {
                    missing.append("scripts/\(s)")
                }
            }
        }
        return missing
    }

    /// Unified status口径 (F29): `(ok, detail)`. 缺失文件名会出现在 detail 里（T04 判据 6）。
    static func checkStatus(_ info: SkillInfo) -> (Bool, String) {
        let ok = verify(info)
        guard ok else {
            let missing = missingFiles(of: info)
            let joined = missing.isEmpty ? "未知原因" : missing.joined(separator: "、")
            return (false, "未装载 ✗（校验未通过，缺失：\(joined)）")
        }
        return (true, "已装载 ✓（\(info.name)）")
    }

    // MARK: - Load

    /// Syncs the bundled skill into the user registry **without ever deleting**
    /// files that are already there. A previous implementation did
    /// `removeItem(target)` + `copyItem(bundle → target)`, which replaced the
    /// complete skill (incl. its 4 scripts) with an incomplete bundle that only
    /// shipped `SKILL.md` — so on every launch the scripts vanished and
    /// WorkBuddy reported "skill 原始只含 SKILL.md（4 个脚本缺失）".
    ///
    /// Merging overlays the authoritative bundle contents (SKILL.md + scripts +
    /// references) on top of whatever the user already has, so the scripts
    /// survive and the skill stays complete. A purely destructive copy can no
    /// longer recur.
    @discardableResult
    static func ensureLoaded(_ info: SkillInfo) throws -> URL {
        let target = registryDir(of: info)
        try mergeSkillDirectory(from: sourceDir(of: info), into: target)
        guard verify(info) else {
            throw AppError.skill("skill 装载后校验失败：\(info.id)（\(target.path)）")
        }
        return target
    }

    /// Recursive, non-destructive directory overlay. Copies every regular file
    /// from `source` into `target`, creating intermediate directories as needed
    /// and overwriting files that already exist, but never removing files that
    /// exist only in `target`. Hidden files are skipped.
    private static func mergeSkillDirectory(from source: URL, into target: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        // macOS 上 /tmp 是 /private/tmp 的符号链接，枚举器返回解析后的路径；
        // 必须把 base 也解析到同一形式，否则相对路径计算会错位（拷进 private/…）。
        var base = source.resolvingSymlinksInPath().path
        if base.hasSuffix("/") { base.removeLast() }
        guard let enumerator = fm.enumerator(
            at: source,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for case let fileURL as URL in enumerator {
            guard let res = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  res.isRegularFile == true else { continue }
            let full = fileURL.resolvingSymlinksInPath().path
            var rel = full
            if full.hasPrefix(base) {
                let idx = full.index(full.startIndex, offsetBy: base.count)
                rel = String(full[idx...])
            }
            if rel.hasPrefix("/") { rel.removeFirst() }
            let dest = target.appendingPathComponent(rel)
            try fm.createDirectory(at: dest.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try? fm.removeItem(at: dest)   // overwrite if present
            try fm.copyItem(at: fileURL, to: dest)
        }
    }

    // MARK: - Sync state

    /// 单向包含校验（T04 判据 7）：source 里每个文件在 registry 存在且 SHA-256 相同。
    /// **不再要求两边完全相等** —— registry 里多出 `scripts/tmp.py` 之类的额外文件
    /// 不再导致 isSynced=false（也就不会每次都触发重 merge）。额外文件由
    /// `orphanFiles` 只读诊断暴露。
    static func isSynced(_ info: SkillInfo) -> Bool {
        let registry = registryDir(of: info)
        let source = sourceDir(of: info)
        let fm = FileManager.default
        guard fm.fileExists(atPath: registry.path),
              fm.fileExists(atPath: source.path) else { return false }
        guard let enumerator = fm.enumerator(at: source,
                                             includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsHiddenFiles]) else { return false }
        for case let fileURL as URL in enumerator {
            guard let res = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  res.isRegularFile == true else { continue }
            let rel = relativePath(fileURL.path, from: source.path)
            guard let sourceData = try? Data(contentsOf: fileURL) else { continue }
            let target = registry.appendingPathComponent(rel)
            guard let targetData = try? Data(contentsOf: target),
                  sha256Hex(sourceData) == sha256Hex(targetData) else { return false }
        }
        return true
    }

    /// 只读诊断：列出 registry 中存在但 source 中不存在的文件（T04 判据 7）。
    /// 只写 warning 日志，不触发删除。
    static func orphanFiles(_ info: SkillInfo) -> [String] {
        let registry = registryDir(of: info)
        let source = sourceDir(of: info)
        let fm = FileManager.default
        guard fm.fileExists(atPath: registry.path),
              fm.fileExists(atPath: source.path) else { return [] }
        let sourceFiles = collectRelativeFiles(source)
        let registryFiles = collectRelativeFiles(registry)
        return registryFiles.sorted().filter { !sourceFiles.contains($0) }
    }

    // MARK: - Internal helpers

    private static func collectRelativeFiles(_ dir: URL) -> Set<String> {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: dir,
                                             includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsHiddenFiles]) else { return [] }
        var out = Set<String>()
        for case let fileURL as URL in enumerator {
            guard let res = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  res.isRegularFile == true else { continue }
            out.insert(relativePath(fileURL.path, from: dir.path))
        }
        return out
    }

    private static func relativePath(_ path: String, from base: String) -> String {
        // macOS /tmp → /private/tmp 符号链接：统一解析后再比较前缀。
        var base = URL(fileURLWithPath: base).resolvingSymlinksInPath().path
        let full = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        if base.hasSuffix("/") { base.removeLast() }
        var rel = full
        if rel.hasPrefix(base) {
            let idx = rel.index(rel.startIndex, offsetBy: base.count)
            rel = String(rel[idx...])
        }
        if rel.hasPrefix("/") { rel.removeFirst() }
        return rel
    }

    private static func sha256Hex(_ data: Data) -> String {
        CryptoKit.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Internal dirs

    static func sourceDir(of info: SkillInfo) -> URL {
        if info.scriptsDir == Paths.builtinSkillScriptsDir() {
            return Paths.builtinSkillDir()
        }
        return info.scriptsDir.deletingLastPathComponent()
    }

    static func registryDir(of info: SkillInfo) -> URL {
        if info.scriptsDir == Paths.builtinSkillScriptsDir() {
            return Paths.userSkillDir()
        }
        return Paths.registryRoot().appendingPathComponent(info.id)
    }

    // MARK: - Frontmatter helpers

    private static func splitFrontmatter(_ text: String) -> (String, String) {
        guard text.hasPrefix("---") else { return ("", text) }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return ("", text) }
        var end: Int?
        for i in 1..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" { end = i; break }
        }
        guard let end else { return ("", text) }
        let fm = lines[1..<end].joined(separator: "\n")
        let body = lines[(end + 1)...].joined(separator: "\n")
        return (fm, body)
    }

    private static func extractName(_ fm: String) -> String? {
        for line in fm.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.hasPrefix("name:") else { continue }
            var v = String(s.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if let first = v.first, first == "\"" || first == "'" {
                if v.count >= 2 && v.last == first {
                    v = String(v.dropFirst().dropLast())
                }
            }
            return v
        }
        return nil
    }
}
