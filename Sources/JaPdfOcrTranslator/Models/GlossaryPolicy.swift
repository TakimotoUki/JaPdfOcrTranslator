import Foundation

/// 术语表策略 A/B/C/D（DESIGN §7.1 / PRD §5）。
///
/// Sendable + Codable，跨 actor 安全。`promptText` 与 `glossary_tool.py`
/// 的 `POLICY_PROMPTS` **逐字一致**（DESIGN §7.2 / T04 判据 2 会做 diff 交叉验收），
/// 因此**禁止**在此处擅自改文案 —— 改文案必须同步改 Python 侧。
enum GlossaryPolicy: String, Codable, Sendable, CaseIterable {
    case userOnly     = "A"   // 有用户表 + 关自动
    case userPlusAuto = "B"   // 有用户表 + 开自动（默认路径之一）
    case autoOnly     = "C"   // 无用户表 + 开自动（默认路径之一）
    case none         = "D"   // 无用户表 + 关自动（降级逃生口）

    /// 唯一推导入口。全工程禁止在别处用 if/else 拼这四种情形。
    static func resolve(hasUserGlossary: Bool, autoGlossaryEnabled: Bool) -> GlossaryPolicy {
        switch (hasUserGlossary, autoGlossaryEnabled) {
        case (true, false):  return .userOnly
        case (true, true):   return .userPlusAuto
        case (false, true):  return .autoOnly
        case (false, false): return .none
        }
    }

    /// `hasUserGlossary` 的判定：settings.glossaryPath 指向的文件存在
    /// 且解析后条目数 ≥ 1（空文件 / 只有表头 / 全空行 均视为无表）。
    static func hasUserGlossary(_ settings: Settings) -> Bool {
        let p = settings.glossaryPath.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, FileManager.default.fileExists(atPath: p) else { return false }
        return ((try? Glossary.loadCSV(URL(fileURLWithPath: p)))?.entries.count ?? 0) >= 1
    }

    // ── 行为断言（与 Python 侧 §4.2 upsert 判定表共用同一套语义）──
    var allowsAutoInsert:  Bool { self == .userPlusAuto || self == .autoOnly }
    var seedsFromUser:     Bool { self == .userOnly || self == .userPlusAuto }
    var maintainsGlossary: Bool { self != .none }
    var runsTerminologyQA: Bool { self != .none }
    var emitsSuggestions:  Bool { self == .userOnly }        // Q2：只读建议
    var offersAdoption:    Bool { allowsAutoInsert }         // F33-15
    var showsRiskBanner:   Bool { self == .none }            // UI 黄色提示

    var displayName: String {
        switch self {
        case .userOnly:     return "情形 A · 纯用户表（锁定，禁新增）"
        case .userPlusAuto: return "情形 B · 用户表锁定 + 自动补充新词"
        case .autoOnly:     return "情形 C · 全自动术语表"
        case .none:         return "情形 D · 不维护术语表"
        }
    }

    /// 编辑器底部与设置页灰字文案。
    var uiFooterText: String {
        switch self {
        case .userOnly:
            return "当前策略：**用户表逐字锁定**，翻译过程不新增术语；未入表的专名只给只读建议。"
        case .userPlusAuto:
            return "当前策略：**用户表锁定 + 自动补充新词**（默认）。你填的每一条都不会被改写。"
        case .autoOnly:
            return "当前策略：**全自动术语表**（默认）。软件会边翻边建表，结束后可一键收编。"
        case .none:
            return "⚠️ 未启用术语一致性保障：本次不建表、不做术语校验，长文可能出现同名异译。"
        }
    }

    /// 每种情形注入的策略段（DESIGN §7.2 实际文案）。
    ///
    /// - Warning: 必须与 `glossary_tool.py POLICY_PROMPTS` **逐字一致**。
    ///   T04 判据 2 用 `diff <(swift 输出) <(python 输出)` 验收，改这里不改 Python 会挂。
    var promptText: String {
        switch self {
        case .userOnly:
            return """
            【术语表策略｜情形 A：用户表锁定 · 禁止新增】
            1. 下方术语表由用户提供，是本次翻译的最高权威。表中每一条的中文译名必须逐字执行，
               任何情况下不得改写、简化、意译、加注或调整用字。
            2. 表中未列出的专名（人名、地名、组织名、作品内术语等），沿用其在前文译文中首次出现的
               译法，保持全书一致；不得另起新译名。
            3. 本次不建立、不扩充自动术语表。禁止调用 glossary_tool.py upsert 新增词条。
            4. 若你认为某个未入表的专名应当入表，不要改表 —— 通过
               `state_tool.py event --type glossary_suggestion --chunk N --json '{"source":"…","target":"…"}'`
               留下只读建议，由用户事后裁决。
            """
        case .userPlusAuto:
            return """
            【术语表策略｜情形 B：用户表锁定 + 自动补充（默认）】
            1. 术语表分两组，优先级严格有别：
               · 【锁定词条】(locked) —— 用户提供，优先级最高，必须逐字执行，任何情况下不得改写。
               · 【自动词条】(auto)   —— 软件维护，遇到新专名请补入；已有条目优先沿用现值。
            2. 两组冲突时**无条件服从锁定词条**。你给出的任何与锁定词条不同的译名都会被系统丢弃
               并记为违例（rejected_by_lock），出现在最终质量报告里。
            3. 【硬性时序】翻译第 N 块**之前**，必须先对该块源文做术语预抽取并写库：
               `glossary_tool.py upsert --state <state> --chunk N --phase pre --stdin`
               即使一条新词都没有，也必须以 {"terms":[]} 调用一次 —— 这是流程合规的唯一证据。
            4. 翻译时只使用系统给出的【本块命中术语】子集；未命中的词条与本块无关，不要硬塞进译文。
            5. 翻译完成后，用「原文 + 译文」回抽校准实际采用的译名：`--phase post --chunk N`。
            6. 不得对已存在的 source 提出新译名。若确有充分理由，也只记冲突、不改表。
            """
        case .autoOnly:
            return """
            【术语表策略｜情形 C：全自动术语表（默认）】
            1. 用户未提供术语表。你必须**自行建立并持续维护**一份术语表，作为全书译名一致性的唯一口径。
            2. 同一专名全书必须使用同一译名。首次确定的译法即为基准，后文不得改译。
            3. 【硬性时序】翻译第 N 块**之前**，必须先对该块源文做术语预抽取并写库：
               `glossary_tool.py upsert --state <state> --chunk N --phase pre --stdin`
               即使一条新词都没有，也必须以 {"terms":[]} 调用一次。
            4. 翻译完成后回抽校准：`--phase post --chunk N`，依据译文中**实际采用**的写法填 target，
               不要凭空创造译名。
            5. 应当入表：人名、地名、组织名、作品内专有术语、招式名、物品名、设定名；
               同一实体的称呼变体（昵称／敬称／职称／亲属称呼／外号，应作为独立条目而非仅放 aliases）；
               需全书统一的口癖、咒语、标语、固定台词。
               不应入表：普通寒暄、通用词汇、一次性修辞、普通语气词。
            6. 同一 source 出现不同译名时，系统**保留现值并记冲突**，绝不静默覆盖；请优先沿用现值。
            """
        case .none:
            return """
            【术语表策略｜情形 D：不维护术语表】
            本次运行不建立术语表，也不做术语一致性校验。请仅凭上下文保持译名前后一致。
            （用户已在设置中关闭「自动生成/补充术语表」且未提供自定义术语表。）
            """
        }
    }
}
