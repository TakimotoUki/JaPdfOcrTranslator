import Foundation

/// v3.3 九阶段流水线（DESIGN §3.1 / §5.1 / T01-g）。
///
/// **WorkBuddy 后端与 DeepSeek 后端共用同一份枚举**：WB 后端把它渲染进 deep link
/// 提示词、并用 `requiredArtifacts` 做事后产物存在性取证；DS 后端用它驱动应用内
/// 编排并写 `status.stage` / `stage_index`。
///
/// 编号约定（DESIGN §10.1）：`rawValue` 为 `"S0"`…`"S8"`，`index` 为 0–8，
/// UI 显示 `阶段 {index+1}/9`。
enum PipelineStage: String, CaseIterable, Codable, Sendable {
    case s0Init            = "S0"
    case s1Split           = "S1"
    case s2Prescan         = "S2"
    case s3Sample          = "S3"
    case s4Translate       = "S4"
    case s5Boundary        = "S5"
    case s6DeterministicQC = "S6"
    case s7QA              = "S7"
    case s8Deliver         = "S8"

    /// 阶段总数，恒为 9。`status.json.stage_total` 的唯一来源。
    static let total: Int = PipelineStage.allCases.count

    /// 0-based 阶段序号，写入 `status.json.stage_index`。
    var index: Int {
        switch self {
        case .s0Init:            return 0
        case .s1Split:           return 1
        case .s2Prescan:         return 2
        case .s3Sample:          return 3
        case .s4Translate:       return 4
        case .s5Boundary:        return 5
        case .s6DeterministicQC: return 6
        case .s7QA:              return 7
        case .s8Deliver:         return 8
        }
    }

    /// 中文阶段名，写入 `status.json.stage_name`，UI 与 `report.md` 直接展示。
    var displayName: String {
        switch self {
        case .s0Init:            return "初始化"
        case .s1Split:           return "切分与结构分析"
        case .s2Prescan:         return "全书预扫"
        case .s3Sample:          return "样本分析与风格定调"
        case .s4Translate:       return "逐块翻译"
        case .s5Boundary:        return "跨块边界修复"
        case .s6DeterministicQC: return "确定性质检"
        case .s7QA:              return "一致性 QA"
        case .s8Deliver:         return "合并与交付"
        }
    }

    /// 该阶段完成后**必须存在**的产物，路径**相对 `<outDir>/state/`**。
    ///
    /// 两个后端都用它做产物存在性自检：WB 后端在轮询结束后逐个 `fileExists`，
    /// DS 后端在切换阶段前自检。目录型产物（`chunks/`）以 `/` 结尾表示只校验目录非空。
    ///
    /// - Note: S4 的译文块数量随总块数变化，无法静态枚举，故只校验 `chunks/` 目录本身；
    ///   逐块完成情况由 `status.json.chunk_status` 承载。
    var requiredArtifacts: [String] {
        switch self {
        case .s0Init:
            return ["config.json", "status.json"]
        case .s1Split:
            return ["structure.json", "manifest.json", "chunks/"]
        case .s2Prescan:
            return ["book_synopsis.md"]
        case .s3Sample:
            return ["samples/sample_pack.md", "style_guide.md"]
        case .s4Translate:
            return ["chunks/", "glossary.json"]
        case .s5Boundary:
            return ["boundary_report.json"]
        case .s6DeterministicQC:
            return ["alignment_report.json"]
        case .s7QA:
            return ["qa_issues.json"]
        case .s8Deliver:
            return ["translation_full.txt", "original_full.txt", "report.md"]
        }
    }

    /// 该阶段是否可被跳过。
    ///
    /// 可跳过的阶段由 `config.json.stages` 决定（受 `path_mode` 与流水线开关影响，
    /// 见 DESIGN §3.2）：`S2` 受 `enable_prescan` / `path_mode=simple` 控制，
    /// `S3` 受 `enable_style_analysis` 控制，`S6` 受 `enable_punct_normalize` 控制，
    /// `S7` 受 `enable_qa` 控制，`S5` 在单块输入下无意义。
    ///
    /// `S0`/`S1`/`S4`/`S8` 是骨架阶段，**任何配置下都不得跳过**。
    var isSkippable: Bool {
        switch self {
        case .s0Init, .s1Split, .s4Translate, .s8Deliver:
            return false
        case .s2Prescan, .s3Sample, .s5Boundary, .s6DeterministicQC, .s7QA:
            return true
        }
    }

    /// 由 `status.json.stage` 字符串还原阶段；无法识别时返回 `nil`。
    static func from(rawStage: String?) -> PipelineStage? {
        guard let rawStage else { return nil }
        return PipelineStage(rawValue: rawStage.trimmingCharacters(in: .whitespaces).uppercased())
    }

    /// UI 进度文案的阶段片段：`阶段 5/9 · 逐块翻译`。
    var progressLabel: String {
        "阶段 \(index + 1)/\(Self.total) · \(displayName)"
    }
}
