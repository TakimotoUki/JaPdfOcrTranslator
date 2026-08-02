import Foundation

/// 术语类型（DESIGN §3.6 值域，未知一律归 `其他`）。
enum TermType: String, Codable, Sendable, CaseIterable {
    case person  = "人物"
    case place   = "地名"
    case org     = "组织"
    case term    = "术语"
    case skill   = "招式"
    case item    = "物品"
    case address = "称谓"
    case honor   = "敬称"
    case habit   = "口癖"
    case phrase  = "固定表达"
    case other   = "其他"

    /// §3.6：这四类**只按 `source` 匹配，忽略 `aliases`**。
    static let sourceOnlyTypes: Set<TermType> = [.address, .honor, .habit, .phrase]

    /// 未知值一律归 `其他`；空值取默认类型（用户 CSV 侧缺列按 `其他`，与库内 `术语` 不同）。
    static func normalize(_ raw: String?) -> TermType {
        guard let raw else { return .other }
        return TermType(rawValue: raw.trimmingCharacters(in: .whitespaces)) ?? .other
    }

    var isSourceOnly: Bool { Self.sourceOnlyTypes.contains(self) }
}

/// 术语来源（§3.6：`user | auto`）。
enum TermOrigin: String, Codable, Sendable {
    case user = "user"
    case auto = "auto"
}

/// 术语状态（§3.6：`ok | conflict`）。
enum TermStatus: String, Codable, Sendable {
    case ok = "ok"
    case conflict = "conflict"
}

/// 用户术语表（DESIGN §5.1 `Glossary` / §3.6）。
///
/// **红线：本文件不得出现写 `glossary.json` 的代码** —— 术语库唯一写路径是
/// `glossary_tool.py`（Swift 侧经 `GlossaryToolClient` 子进程调用）。
/// 本类型只负责：用户 CSV/JSON 的读取（编辑器视图模型）与导出（CSV2/CSV5）。
struct Glossary: Sendable {
    /// 单条术语。`id` 仅用于 SwiftUI 列表标识，编码时用 `CodingKeys` 排除。
    struct Entry: Codable, Sendable, Identifiable, Equatable {
        var id = UUID()
        var source: String
        var target: String
        var reading: String = ""
        var type: TermType = .other
        var gender: String = ""
        var aliases: [String] = []
        var note: String = ""
        var origin: TermOrigin = .user
        var locked: Bool = true
        var status: TermStatus = .ok
        var firstChunk: Int? = nil
        var hits: Int = 0
        var createdAt: Double = 0
        var updatedAt: Double = 0

        private enum CodingKeys: String, CodingKey {
            case source, target, reading, type, gender, aliases, note
            case origin, locked, status
            case firstChunk = "first_chunk"
            case hits
            case createdAt = "created_at"
            case updatedAt = "updated_at"
            // `id` 故意缺席 → 解码时用默认 UUID()，不参与 JSON 往返
        }

        init(source: String, target: String, reading: String = "", type: TermType = .other,
             gender: String = "", aliases: [String] = [], note: String = "",
             origin: TermOrigin = .user, locked: Bool = true, status: TermStatus = .ok,
             firstChunk: Int? = nil, hits: Int = 0,
             createdAt: Double = 0, updatedAt: Double = 0) {
            self.source = source
            self.target = target
            self.reading = reading
            self.type = type
            self.gender = gender
            self.aliases = aliases
            self.note = note
            self.origin = origin
            self.locked = locked
            self.status = status
            self.firstChunk = firstChunk
            self.hits = hits
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        var isSourceOnlyType: Bool { type.isSourceOnly }
    }

    var entries: [Entry]
    var schemaVersion: Int = 1
    var policy: GlossaryPolicy = .userPlusAuto

    init(entries: [Entry] = []) { self.entries = entries }

    static func empty() -> Glossary { Glossary() }

    var isEmpty: Bool { entries.isEmpty }
    var lockedCount: Int { entries.lazy.filter { $0.locked }.count }
    var autoCount: Int { entries.lazy.filter { $0.origin == .auto }.count }

    // MARK: - CSV 表头识别（与 Python `_HEADER_FIRST/_HEADER_SECOND` 对齐）

    private static let headerFirst: Set<String> = ["日语", "日文", "原文", "source", "japanese", "ja"]
    private static let headerSecond: Set<String> = ["中文", "译名", "译文", "target", "chinese", "zh"]
    private static let originCN: [String: TermOrigin] = ["用户": .user, "自动": .auto]

    private static func looksLikeHeader(_ cells: [String]) -> Bool {
        guard cells.count >= 2 else { return false }
        let first = cells[0].trimmingCharacters(in: .whitespaces).lowercased()
        let second = cells[1].trimmingCharacters(in: .whitespaces).lowercased()
        return headerFirst.contains(first) || headerSecond.contains(second)
    }

    // MARK: - 读取（两栏 / 五栏自动识别，缺列填默认）

    /// 从 UTF-8 CSV 加载用户术语表（T04 判据 4：v3.2 两栏 CSV → `type=其他, origin=user, locked=true`）。
    static func loadCSV(_ url: URL) throws -> Glossary {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AppError.glossary("术语表文件不存在：\n  \(url.path)")
        }
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            throw AppError.glossary("术语表读取失败：\n  \(url.path)")
        }
        var rows: [[String]] = []
        raw.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            rows.append(splitCSVLine(line))
        }
        guard !rows.isEmpty else { return Glossary() }

        var working = rows
        if looksLikeHeader(rows[0]) {
            working = Array(rows.dropFirst())
        }

        var entries: [Entry] = []
        for row in working {
            // 与 Python parse_user_csv 一致：去掉尾部空 cell 后判定列数
            var cells = row.map { $0.trimmingCharacters(in: .whitespaces) }
            while let last = cells.last, last.isEmpty { cells.removeLast() }
            guard cells.count >= 2, !cells[0].isEmpty, !cells[1].isEmpty else { continue }

            var entry = Entry(source: cells[0], target: cells[1])
            if cells.count >= 3, !cells[2].isEmpty {
                entry.type = TermType.normalize(cells[2])
            }
            if cells.count >= 4, !cells[3].isEmpty {
                let originRaw = cells[3].trimmingCharacters(in: .whitespaces)
                if let mapped = originCN[originRaw] {
                    entry.origin = mapped
                } else if originRaw == "user" {
                    entry.origin = .user
                } else if originRaw == "auto" {
                    entry.origin = .auto
                } else {
                    entry.origin = .user     // 未知来源列一律按用户词条处理
                }
                entry.locked = (entry.origin == .user)
            }
            if cells.count >= 5, !cells[4].isEmpty {
                entry.note = cells[4]
            }
            entries.append(entry)
        }
        return Glossary(entries: entries)
    }

    /// 从 `glossary.json`（§3.6 契约）加载 —— 仅供读取展示，不写回。
    static func loadJSON(_ url: URL) throws -> Glossary {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AppError.glossary("术语库文件不存在：\n  \(url.path)")
        }
        guard let data = try? Data(contentsOf: url) else {
            throw AppError.glossary("术语库读取失败：\n  \(url.path)")
        }
        struct Disk: Decodable {
            let schemaVersion: Int?
            let policy: String?
            let terms: [DiskTerm]?
        }
        struct DiskTerm: Decodable {
            let source: String?
            let target: String?
            let reading: String?
            let type: String?
            let gender: String?
            let aliases: [String]?
            let note: String?
            let origin: String?
            let locked: Bool?
            let status: String?
            let firstChunk: Int?
            let hits: Int?
            let createdAt: Double?
            let updatedAt: Double?

            private enum CodingKeys: String, CodingKey {
                case source, target, reading, type, gender, aliases, note
                case origin, locked, status
                case firstChunk = "first_chunk"
                case hits
                case createdAt = "created_at"
                case updatedAt = "updated_at"
            }
        }
        guard let disk = try? JSONDecoder().decode(Disk.self, from: data) else {
            throw AppError.glossary("术语库 JSON 解析失败：\n  \(url.path)")
        }
        var glossary = Glossary()
        glossary.schemaVersion = disk.schemaVersion ?? 1
        glossary.policy = GlossaryPolicy(rawValue: disk.policy ?? "B") ?? .userPlusAuto
        for t in disk.terms ?? [] {
            let origin = (t.origin == "auto") ? TermOrigin.auto : TermOrigin.user
            let locked = t.locked ?? (origin == .user)
            glossary.entries.append(Entry(
                source: t.source ?? "",
                target: t.target ?? "",
                reading: t.reading ?? "",
                type: TermType.normalize(t.type),
                gender: t.gender ?? "",
                aliases: t.aliases ?? [],
                note: t.note ?? "",
                origin: origin,
                locked: locked,
                status: (t.status == "conflict") ? .conflict : .ok,
                firstChunk: t.firstChunk,
                hits: t.hits ?? 0,
                createdAt: t.createdAt ?? 0,
                updatedAt: t.updatedAt ?? 0
            ))
        }
        return glossary
    }

    // MARK: - 写回（仅编辑器导出用；绝不写 `glossary.json`）

    /// v3.2 兼容别名：`load` 即两栏/五栏自动识别的 `loadCSV`。T05 重写后应迁移到 `loadCSV`。
    @available(*, deprecated, message: "用 loadCSV 取代（语义相同）")
    static func load(_ url: URL) throws -> Glossary {
        try loadCSV(url)
    }

    /// v3.2 兼容别名：`save` 即两栏导出 `saveCSV2`。T05 重写后应迁移到 `saveCSV2`。
    @available(*, deprecated, message: "用 saveCSV2 取代（语义相同）")
    func save(_ url: URL) throws {
        try saveCSV2(url)
    }

    /// 两栏 CSV（v3.2 兼容格式）：`日语,中文`。
    func saveCSV2(_ url: URL) throws {
        var lines = ["日语,中文"]
        for e in entries {
            lines.append("\(e.source),\(csvQuote(e.target))")
        }
        try writeLines(lines, to: url)
    }

    /// 五栏 CSV（v3.3 编辑器格式）：`日语,中文,类型,来源,备注`。
    func saveCSV5(_ url: URL) throws {
        var lines = ["日语,中文,类型,来源,备注"]
        for e in entries {
            let originCN = (e.origin == .auto) ? "自动" : "用户"
            lines.append("\(e.source),\(csvQuote(e.target)),\(e.type.rawValue),\(originCN),\(csvQuote(e.note))")
        }
        try writeLines(lines, to: url)
    }

    /// 按策略 + 作用域渲染提示词块（分组：锁定组在前、自动组在后；`scope=chunk` 只放命中子集）。
    ///
    /// - Note: `policy` / `scope` / `matchedSources` 带默认值仅为兼容 v3.2 调用点
    ///   （T05 重写后应显式传参）；默认渲染全表、按情形 B 策略语义分组。
    func toPromptBlock(policy: GlossaryPolicy = .userPlusAuto,
                       scope: String = "full",
                       matchedSources: Set<String>? = nil) -> String {
        var pool = entries
        if scope == "chunk", let matched = matchedSources {
            pool = pool.filter { matched.contains($0.source) }
        }
        guard !pool.isEmpty else { return "" }

        var lines: [String] = []
        let locked = pool.filter { $0.locked }
        let auto = pool.filter { !$0.locked }

        if !locked.isEmpty {
            lines.append("【锁定词条】（locked —— 用户提供，优先级最高，必须逐字执行）")
            lines.append("日语,中文,类型,备注")
            for e in locked { lines.append(termLine(e)) }
        }
        if !auto.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append("【自动词条】（auto —— 软件维护，遇到新专名请补入；已有条目优先沿用现值）")
            lines.append("日语,中文,类型,备注")
            for e in auto { lines.append(termLine(e)) }
        }
        return lines.joined(separator: "\n")
    }

    private func termLine(_ e: Entry) -> String {
        "\(e.source),\(csvQuote(e.target)),\(e.type.rawValue),\(csvQuote(e.note))"
    }

    private func writeLines(_ lines: [String], to url: URL) throws {
        let text = lines.joined(separator: "\n") + "\n"
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw AppError.glossary("术语表保存失败：\n  \(url.path)")
        }
    }

    private func csvQuote(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    /// CSV 行切分（容忍双引号包裹字段）。与 v3.2 行为一致。
    static func splitCSVLine(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        for ch in line {
            if ch == "\"" {
                inQuotes.toggle()
            } else if ch == ",", !inQuotes {
                result.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        result.append(current)
        return result.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
