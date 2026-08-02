import SwiftUI

/// Pre-translation confirmation sheet — v3.3（T05：策略预览 + 预计块数 + 续跑提示）。
struct ConfirmRunView: View {
    let request: ConfirmRequest
    let onRespond: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("请核对翻译任务")
                .font(.title2.bold())
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    row("翻译 skill", "\(request.skillName)（\(request.skillStatus)）")
                    row("提示词", request.promptSummary)
                    if request.estimatedChunks > 0 {
                        row("预计块数", "约 \(request.estimatedChunks) 块（按每块上限 4000 字估算）")
                    }
                    if !request.resumeHint.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .foregroundStyle(.blue)
                            Text(request.resumeHint)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    row("已就绪 OCR 产物（绝对路径，兜底核对用）", request.jpTxtPath)
                    Text("输出 PDF：").font(.subheadline.bold())
                    Text(request.outPdfLines)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)

                    // 策略预览（与注入提示词逐字一致）
                    Text("术语表策略（\(request.policyName)）").font(.subheadline.bold())
                    Text(request.policyPreview)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 10))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 220, maxHeight: .infinity)
            Text("即将自动在 WorkBuddy 新建任务并预填：skill / 提示词 / 日文 txt 路径（已填好），请在 WorkBuddy 中点击「发送」开始翻译。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("取消") { onRespond(false) }
                Button("我已核对，去 WorkBuddy 发送") { onRespond(true) }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(minWidth: 520, idealWidth: 640, maxWidth: .infinity,
               minHeight: 420, idealHeight: 560, maxHeight: .infinity)
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.subheadline.bold())
            Text(value).textSelection(.enabled)
        }
    }
}
