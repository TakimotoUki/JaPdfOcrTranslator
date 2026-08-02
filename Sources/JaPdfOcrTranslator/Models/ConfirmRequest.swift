import Foundation

/// Payload shown in the pre-translation confirmation sheet（T05：策略预览 / 预计块数 / 续跑提示）。
struct ConfirmRequest: Identifiable, Sendable {
    let jpTxtPath: String
    let outputDir: String
    let skillName: String
    let skillStatus: String
    let promptSummary: String      // "内置默认" | "自定义：…"
    let outPdfLines: String        // human-readable list of target PDFs
    let policyPreview: String      // GlossaryPolicy.promptText（运行前核对）
    let policyName: String         // 情形 A/B/C/D 名称
    let estimatedChunks: Int       // 预计块数（0 = 未知）
    let resumeHint: String         // 续跑提示（空 = 全新任务）

    var id: String { jpTxtPath + "|" + outputDir }
}
