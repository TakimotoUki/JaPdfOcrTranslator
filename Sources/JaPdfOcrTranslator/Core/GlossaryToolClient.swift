import Foundation

/// `glossary_tool.py` 的 Swift 封装（DESIGN §4，9 个子命令）。
///
/// `Sendable struct`：不可变值 + 纯函数式调用，跨 actor 安全。
/// 错误映射（§4.0 退出码语义）：
/// - 退 1 / 3 → `AppError.glossaryTool("参数或输入错误: …")`
/// - 退 2       → `AppError.state`
/// - 退 4       → `AppError.state("术语库未初始化")`
/// - 退 5       → 业务结果（仅 `conflicts --fail-if-open` 用），由调用方按需处理
/// - stdout JSON 解析失败时把 stderr 一并塞进错误信息
struct GlossaryToolClient: Sendable {
    let python: String
    let scriptsDir: URL
    let stateDir: URL

    private var tool: String { scriptsDir.appendingPathComponent("glossary_tool.py").path }

    // MARK: - 底层执行

    /// 运行并解析 stdout JSON；`allowExitCodes` 之外的退出码按 §4.0 映射抛错。
    private func runJSON(_ args: [String],
                         stdin: String? = nil,
                         allowExitCodes: Set<Int32> = [0]) throws -> [String: Any] {
        let result = try ProcessRunner.runCapturing(exec: python, args: [tool] + args,
                                                    stdin: stdin, timeout: 120)
        if !allowExitCodes.contains(result.code) {
            throw Self.mapExit(code: result.code, err: result.err)
        }
        guard let data = result.out.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.glossaryTool(
                "glossary_tool.py stdout 不是合法 JSON（exit=\(result.code)）。\n"
                + "stdout: \(result.out.prefix(300))\n"
                + "stderr: \(result.err.prefix(500))"
            )
        }
        return json
    }

    /// 运行并返回原始 stdout 文本（`render` / `hits --format md` 用）。
    private func runText(_ args: [String]) throws -> String {
        let result = try ProcessRunner.runCapturing(exec: python, args: [tool] + args,
                                                    timeout: 120)
        if result.code != 0 {
            throw Self.mapExit(code: result.code, err: result.err)
        }
        return result.out
    }

    private static func mapExit(code: Int32, err: String) -> AppError {
        let detail = err.trimmingCharacters(in: .whitespacesAndNewlines)
        switch code {
        case 1, 3:
            return .glossaryTool("参数或输入错误（exit=\(code)）：\n  \(detail)")
        case 2:
            return .state("IO / 锁错误（exit=2）：\n  \(detail)")
        case 4:
            return .state("术语库未初始化或目标不存在（exit=4）：\n  \(detail)")
        case 5:
            return .glossaryTool("检查未通过（exit=5）：\n  \(detail)")
        default:
            return .glossaryTool("未知退出码 \(code)：\n  \(detail)")
        }
    }

    // MARK: - 子命令（§4.1–§4.9）

    /// §4.1 `init`：初始化术语库。
    struct InitResult {
        var ok: Bool
        var created: Bool
        var policy: String
        var terms: Int
        var locked: Int
        var auto: Int
    }

    func initGlossary(policy: String, userCSV: URL? = nil) throws -> InitResult {
        var args = ["init", "--state", stateDir.path, "--policy", policy]
        if let userCSV { args += ["--user-csv", userCSV.path] }
        let json = try runJSON(args)
        return InitResult(ok: json["ok"] as? Bool ?? false,
                          created: json["created"] as? Bool ?? false,
                          policy: json["policy"] as? String ?? policy,
                          terms: json["terms"] as? Int ?? 0,
                          locked: json["locked"] as? Int ?? 0,
                          auto: json["auto"] as? Int ?? 0)
    }

    /// §4.2 `upsert`：写入术语（唯一写路径）。
    struct UpsertSummary {
        var inserted: Int
        var unchanged: Int
        var conflict: Int
        var rejectedByLock: Int
        var rejectedByPolicy: Int
        var invalid: Int
    }

    struct UpsertResult {
        var ok: Bool
        var chunk: Int?
        var phase: String?
        var summary: UpsertSummary
        var terms: Int
        var locked: Int
        var openConflicts: Int
    }

    func upsert(termsJSON: String, chunk: Int?, phase: String?) throws -> UpsertResult {
        var args = ["upsert", "--state", stateDir.path, "--stdin"]
        if let chunk { args += ["--chunk", "\(chunk)"] }
        if let phase { args += ["--phase", phase] }
        let json = try runJSON(args, stdin: termsJSON)
        let s = json["summary"] as? [String: Any] ?? [:]
        let totals = json["totals"] as? [String: Any] ?? [:]
        return UpsertResult(
            ok: json["ok"] as? Bool ?? false,
            chunk: json["chunk"] as? Int,
            phase: json["phase"] as? String,
            summary: UpsertSummary(inserted: s["inserted"] as? Int ?? 0,
                                   unchanged: s["unchanged"] as? Int ?? 0,
                                   conflict: s["conflict"] as? Int ?? 0,
                                   rejectedByLock: s["rejected_by_lock"] as? Int ?? 0,
                                   rejectedByPolicy: s["rejected_by_policy"] as? Int ?? 0,
                                   invalid: s["invalid"] as? Int ?? 0),
            terms: totals["terms"] as? Int ?? 0,
            locked: totals["locked"] as? Int ?? 0,
            openConflicts: totals["open_conflicts"] as? Int ?? 0
        )
    }

    /// §4.3 `hits`：命中裁剪。
    struct HitTerm {
        var source: String
        var target: String
        var type: String
        var locked: Bool
        var aliases: [String]
        var note: String
        var status: String
    }

    struct HitsResult {
        var ok: Bool
        var chunk: Int?
        var scope: String
        var count: Int
        var truncated: Bool
        var terms: [HitTerm]
        /// `format == "md"` 时的纯文本命中段（P0-2：此前 runText 结果被丢弃）
        var text: String = ""
    }

    func hits(chunk: Int?, scope: String = "chunk", format: String = "json") throws -> HitsResult {
        var args = ["hits", "--state", stateDir.path, "--scope", scope, "--format", format]
        if let chunk { args += ["--chunk", "\(chunk)"] }
        if format == "md" {
            // hits --format md 输出纯文本（§4.3），按文本返回
            let text = try runText(args)
            return HitsResult(ok: true, chunk: chunk, scope: scope,
                              count: 0, truncated: false, terms: [], text: text)
        }
        let json = try runJSON(args)
        let terms = (json["terms"] as? [[String: Any]] ?? []).map { t in
            HitTerm(source: t["source"] as? String ?? "",
                    target: t["target"] as? String ?? "",
                    type: t["type"] as? String ?? "",
                    locked: t["locked"] as? Bool ?? false,
                    aliases: t["aliases"] as? [String] ?? [],
                    note: t["note"] as? String ?? "",
                    status: t["status"] as? String ?? "ok")
        }
        return HitsResult(ok: json["ok"] as? Bool ?? false,
                          chunk: json["chunk"] as? Int,
                          scope: json["scope"] as? String ?? scope,
                          count: json["count"] as? Int ?? terms.count,
                          truncated: json["truncated"] as? Bool ?? false,
                          terms: terms)
    }

    /// hits --format md 的纯文本版本（注入提示词用）。
    func hitsMarkdown(chunk: Int, scope: String = "chunk") throws -> String {
        try runText(["hits", "--state", stateDir.path, "--chunk", "\(chunk)",
                     "--scope", scope, "--format", "md"])
    }

    /// §4.4 `render`：渲染完整提示词块（策略段 + 命中术语段，纯文本）。
    func render(chunk: Int?, scope: String = "chunk", policy: String? = nil) throws -> String {
        var args = ["render", "--state", stateDir.path, "--scope", scope]
        if let chunk { args += ["--chunk", "\(chunk)"] }
        if let policy { args += ["--policy", policy] }
        return try runText(args)
    }

    /// §4.5 `conflicts`：冲突查询。
    struct ConflictsResult {
        var open: Int
        var total: Int
        var items: [GlossaryConflict]
    }

    func conflicts(openOnly: Bool = true, failIfOpen: Bool = false) throws -> ConflictsResult {
        var args = ["conflicts", "--state", stateDir.path]
        if !openOnly { args += ["--all"] }
        if failIfOpen { args += ["--fail-if-open"] }
        // 退 5 = 存在未决冲突（业务结果，不是故障）
        let json = try runJSON(args, allowExitCodes: [0, 5])
        let items = (json["items"] as? [[String: Any]] ?? []).map { d in
            GlossaryConflict(id: d["id"] as? Int ?? 0,
                             source: d["source"] as? String ?? "",
                             existingTarget: d["existing_target"] as? String ?? "",
                             proposedTarget: d["proposed_target"] as? String ?? "",
                             chunk: d["chunk"] as? Int,
                             phase: d["phase"] as? String ?? "manual",
                             resolved: d["resolved"] as? Bool ?? false,
                             resolution: ConflictResolution(rawValue: d["resolution"] as? String ?? "") ?? .pending,
                             createdAt: d["created_at"] as? Double ?? 0)
        }
        return ConflictsResult(open: json["open"] as? Int ?? 0,
                               total: json["total"] as? Int ?? 0,
                               items: items)
    }

    /// §4.6 `resolve`：冲突裁决（F33-16）。
    struct ResolveResult {
        var ok: Bool
        var source: String
        var target: String
        var lock: Bool
        var by: String
    }

    func resolve(source: String, target: String? = nil, take: String? = nil,
                 lock: Bool = false, by: String = "user") throws -> ResolveResult {
        var args = ["resolve", "--state", stateDir.path, "--source", source]
        if let target { args += ["--target", target] }
        if let take { args += ["--take", take] }
        if lock { args += ["--lock"] }
        args += ["--by", by]
        let json = try runJSON(args)
        return ResolveResult(ok: json["ok"] as? Bool ?? false,
                             source: json["source"] as? String ?? source,
                             target: json["target"] as? String ?? target ?? "",
                             lock: json["lock"] as? Bool ?? lock,
                             by: json["by"] as? String ?? by)
    }

    /// §4.7 `export`：导出术语表。
    struct ExportResult {
        var ok: Bool
        var out: String
        var rows: Int
    }

    func export(out: URL, format: String = "csv5", origin: String? = nil) throws -> ExportResult {
        var args = ["export", "--state", stateDir.path, "--out", out.path, "--format", format]
        if let origin { args += ["--origin", origin] }
        let json = try runJSON(args)
        return ExportResult(ok: json["ok"] as? Bool ?? false,
                            out: json["out"] as? String ?? out.path,
                            rows: json["rows"] as? Int ?? 0)
    }

    /// §4.8 `import`：导入外部术语。
    struct ImportResult {
        var ok: Bool
        var imported: Int
        var origin: String
    }

    func importGlossary(file: URL, origin: String = "user", lock: Bool = false) throws -> ImportResult {
        var args = ["import", "--state", stateDir.path, "--file", file.path, "--origin", origin]
        if lock { args += ["--lock"] }
        let json = try runJSON(args)
        return ImportResult(ok: json["ok"] as? Bool ?? false,
                            imported: json["added"] as? Int ?? 0,
                            origin: json["origin"] as? String ?? origin)
    }

    /// §4.9 `stats`：统计。
    struct GlossaryStats {
        var terms: Int
        var locked: Int
        var auto: Int
        var openConflicts: Int
        var policy: String
    }

    func stats() throws -> GlossaryStats {
        let json = try runJSON(["stats", "--state", stateDir.path])
        return GlossaryStats(terms: json["terms"] as? Int ?? 0,
                             locked: json["locked"] as? Int ?? 0,
                             auto: json["auto"] as? Int ?? 0,
                             openConflicts: json["open_conflicts"] as? Int ?? 0,
                             policy: json["policy"] as? String ?? "")
    }
}
