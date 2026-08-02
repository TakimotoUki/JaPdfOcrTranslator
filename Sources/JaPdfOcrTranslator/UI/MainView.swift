import SwiftUI
import AppKit

/// Main window（T05-h）：进度卡片三行改造 + 术语状态徽标 + 合规横幅。
struct MainView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    private let inputExtensions = ["pdf", "txt", "json", "xml", "doc", "docx"]
    private let logBottomID = "main-log-bottom"

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    // 所有主界面卡片共用这一条内容流；日志不是固定底栏，
                    // 也不再创建会截获滚轮事件的第二个 ScrollView。
                    VStack(spacing: 18) {
                        inputOutputCard
                        optionsCard
                        runCard
                        progressCard
                        usageCard
                        logCard
                    }
                    .padding(20)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: state.logs.count) { _, _ in
                    guard !state.logs.isEmpty else { return }
                    withAnimation {
                        proxy.scrollTo(logBottomID, anchor: .bottom)
                    }
                }
            }
            .navigationTitle("日文 PDF 转译")
            .toolbarBackground(.visible, for: .windowToolbar)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { openWindow(id: "settings") }) {
                        Label("设置", systemImage: "gearshape")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { openWindow(id: "about") }) {
                        Label("致谢 / 开源许可", systemImage: "info.circle")
                    }
                }
            }
            .sheet(item: $state.confirmRequest) { req in
                ConfirmRunView(request: req) { confirmed in
                    state.respondToConfirm(confirmed: confirmed)
                }
            }
            .alert("需要决定如何处理上次任务", isPresented: $state.showResumePrompt) {
                Button("继续上次任务") { state.resumeDecision = .resume }
                Button("归档旧状态并重新开始") { state.resumeDecision = .archive }
                Button("取消", role: .cancel) { state.resumeDecision = .cancel }
            } message: {
                Text(state.resumePromptMessage)
            }
        }
        .frame(minWidth: 820, minHeight: 680)
        // 主窗口红色关闭按钮代表退出工具；即使设置等辅助窗口仍开着也不留后台进程。
        .onDisappear {
            NSApp.terminate(nil)
        }
    }

    // MARK: - Cards

    private var inputOutputCard: some View {
        SectionCard(title: "输入输出") {
            PathField(title: "输入文件", path: $state.inputPath, forFiles: true,
                      allowedExtensions: inputExtensions)
            PathField(title: "输出目录", path: $state.outputDir, forFiles: false)
        }
    }

    private var optionsCard: some View {
        SectionCard(title: "翻译选项") {
            Toggle("双语对照输出（同时生成 中日对照 / 原文 / 译文 三版）", isOn: $state.settings.bilingual)
                .disabled(state.settings.isAPI)
                .help(state.settings.isAPI
                      ? "模型 API 模式不支持双语对照，已自动禁用。"
                      : "勾选后产出 3 个 PDF；不勾选仅产出 原文 + 译文 2 个 PDF。")
            HStack(spacing: 8) {
                PathField(title: "术语表（CSV，两栏 日语,中文）", path: $state.glossaryDisplayPath,
                          forFiles: true, allowedExtensions: ["csv"])
                Button("编辑术语表…") { openWindow(id: "glossary") }
                Button("清除") {
                    state.glossaryDisplayPath = ""
                    state.settings.glossaryPath = ""
                    state.settings.save()
                }
            }
            glossaryPolicyBadge
        }
    }

    /// 术语策略徽标（F33-01）：`用户表 12 条 · 自动补充开` / `未设置 · 将自动生成` / `未启用术语保障 ⚠️`。
    private var glossaryPolicyBadge: some View {
        let hasUser = GlossaryPolicy.hasUserGlossary(state.settings)
        let policy = GlossaryPolicy.resolve(hasUserGlossary: hasUser,
                                            autoGlossaryEnabled: state.settings.autoGlossaryEnabled)
        return HStack(spacing: 8) {
            Image(systemName: policy.showsRiskBanner ? "exclamationmark.triangle.fill" : "book.closed.fill")
                .foregroundStyle(policy.showsRiskBanner ? Color.orange : Color.secondary)
            Text(glossaryBadgeText(hasUser: hasUser, policy: policy))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func glossaryBadgeText(hasUser: Bool, policy: GlossaryPolicy) -> String {
        if hasUser {
            return "用户表已载入 · 自动补充\(policy.allowsAutoInsert ? "开" : "关")（\(policy.displayName)）"
        }
        if policy.allowsAutoInsert {
            return "未设置术语表 · 将自动生成（\(policy.displayName)）"
        }
        return "未启用术语保障 ⚠️（\(policy.displayName)）"
    }

    private var runCard: some View {
        HStack(spacing: 12) {
            PrimaryButton(
                title: "开始翻译",
                systemImage: "play.fill",
                action: { state.startTranslation() },
                disabled: state.isRunning
            )
            Button(action: { state.abort() }) {
                Label("中止", systemImage: "stop.fill")
                    .font(.headline)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
            }
            .disabled(!state.canAbort)
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private var progressCard: some View {
        SectionCard(title: "进度") {
            if let pipeline = state.pipeline {
                StageBar(stages: PipelineStage.allCases,
                         currentIndex: min(pipeline.stageIndex, PipelineStage.total - 1))
                HStack {
                    Text(pipeline.progressLine)
                        .font(.system(.body, design: .rounded).bold())
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                    Spacer()
                }
                HStack(spacing: 8) {
                    MetricChip(label: "术语", value: "\(pipeline.glossaryTerms) 条")
                    MetricChip(label: "冲突", value: "\(pipeline.glossaryConflictsOpen)",
                               tint: pipeline.glossaryConflictsOpen > 0 ? .orange : .secondary)
                    MetricChip(label: "QA", value: "\(pipeline.qaIssues)",
                               tint: pipeline.qaIssues > 0 ? .orange : .secondary)
                    Spacer()
                }
                ComplianceBanner(compliant: pipeline.compliant)
            } else {
                HStack {
                    Text(state.stage)
                        .font(.system(.body, design: .rounded).bold())
                        .foregroundStyle(.tint)
                    Spacer()
                    Text(state.message)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                ProgressView(value: state.percent, total: 100)
                    .progressViewStyle(.linear)
            }
        }
    }

    /// T10-c：用量摘要卡片（DS 后端完成时显示；WB 无 usage → 隐藏）。
    @ViewBuilder
    private var usageCard: some View {
        if let usage = state.llmUsage {
            SectionCard(title: "API 用量（LLM）") {
                HStack(spacing: 8) {
                    MetricChip(label: "调用", value: "\(usage.totals.calls) 次")
                    MetricChip(label: "Prompt", value: "\(usage.totals.promptTokens)")
                    MetricChip(label: "Completion", value: "\(usage.totals.completionTokens)")
                    MetricChip(label: "Total", value: "\(usage.totals.totalTokens)")
                    MetricChip(label: "缓存命中", value: String(format: "%.1f%%", usage.totals.cacheHitRate * 100))
                    Spacer()
                }
                HStack {
                    Text("成本估算：")
                        .foregroundStyle(.secondary)
                    if let cost = usage.totalCostEstimate(provider: state.llmProviderForCost) {
                        Text(String(format: "约 $%.2f（%@ 官方价）", cost, state.llmProviderForCost))
                            .fontWeight(.medium)
                    } else {
                        Text("无法估算（\(state.llmProviderForCost) 暂无计价表）")
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                }
                .font(.caption)
            }
        }
    }

    private var logCard: some View {
        SectionCard(title: "日志") {
            Text(state.logs.isEmpty ? "暂无日志" : state.logs.joined(separator: "\n"))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            HStack {
                Spacer()
                Text("skill 状态：\(state.skillStatus)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Color.clear
                .frame(height: 1)
                .id(logBottomID)
        }
        .frame(maxWidth: .infinity)
    }
}
