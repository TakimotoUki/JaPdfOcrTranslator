import SwiftUI

/// Settings window（T05-i）：新增「术语表策略」「翻译流水线」两组 + 快速/标准/精译预设。
struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var selectedSkillID: String = "jp-txt2pdf-translator"
    @State private var customSkillPath: String = ""
    @State private var promptText: String = ""
    @State private var skillStatusText: String = ""
    @State private var verifyHighlight = false
    @State private var showAPIAdvanced = false

    var body: some View {
        NavigationStack {
            ScrollView {
                AdaptiveGlassContainer(spacing: 18) {
                    VStack(spacing: 18) {
                        backendCard
                        if state.settings.isAPI {
                            llmCard
                        } else {
                            workbuddyCard
                        }
                        ocrCard
                        glossaryPolicyCard
                        pipelineCard
                        skillCard
                        promptCard
                    }
                }
                .padding(20)
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { closeCurrentWindow() }
                        .adaptiveGlassButton(prominent: true)
                }
            }
            .onAppear(perform: loadFromSettings)
            .onChange(of: state.settings.translationBackend) { _, _ in syncBilingualControl() }
            .onChange(of: state.settings.autoGlossaryEnabled) { _, _ in state.settings.save() }
        }
        .frame(minWidth: 760, minHeight: 720)
    }

    // MARK: - Cards

    private var workbuddyCard: some View {
        SectionCard(title: "WorkBuddy（翻译驱动，deep link）") {
            PathField(title: "WorkBuddy 路径", path: $state.settings.workbuddyAppPath,
                      forFiles: true, allowedExtensions: ["app"])
            HStack {
                Text("默认模型").frame(width: 150, alignment: .leading).foregroundStyle(.secondary)
                TextField("", text: $state.settings.workbuddyModel).textFieldStyle(.roundedBorder)
            }
            PathField(title: "工作目录", path: $state.settings.workDir, forFiles: false)
        }
    }

    private var ocrCard: some View {
        SectionCard(title: "OCR 引擎（ndlocr-lite）") {
            HStack {
                Text("Python 解释器").frame(width: 150, alignment: .leading).foregroundStyle(.secondary)
                TextField("python3", text: $state.settings.pythonInterpreterPath)
                    .textFieldStyle(.roundedBorder)
            }
            Text("PDF 日文 OCR 由内嵌的 ndlocr-lite 模型（DEIM 检测 + PARSeq 级联识别）完成，"
                 + "通过本机 Python 运行。请确保其已安装依赖：\n"
                 + "onnxruntime · opencv-python · pypdfium2 · pypdf · pyyaml · numpy · Pillow · networkx · lxml")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(state.ocrEnvChecking ? "正在检测…" : "检查 / 修复 Python 环境") { state.checkOcrEnv() }
                    .disabled(state.ocrEnvChecking)
                if !state.ocrEnvStatus.isEmpty {
                    Text(state.ocrEnvStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
        }
    }

    private var backendCard: some View {
        SectionCard(title: "翻译方式") {
            Picker("选择翻译方式", selection: $state.settings.translationBackend) {
                Text("WorkBuddy").tag("workbuddy")
                Text("调用大模型 API").tag("api")
            }
            .pickerStyle(.segmented)
            .onChange(of: state.settings.translationBackend) { _, _ in syncBilingualControl() }

            Toggle("默认开启双语对照输出", isOn: $state.settings.bilingual)
                .disabled(state.settings.isAPI)
            if state.settings.isAPI {
                Text("模型 API 模式当前输出译文版和原文版，不生成双语对照 PDF。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            PathField(title: "术语表路径（CSV）", path: $state.settings.glossaryPath,
                      forFiles: true, allowedExtensions: ["csv"])
        }
    }

    /// 用户提供兼容 OpenAI Chat Completions 的地址、凭据和模型 ID。
    private var llmCard: some View {
        SectionCard(title: "大模型 API") {
            HStack {
                Text("API 地址").frame(width: 150, alignment: .leading).foregroundStyle(.secondary)
                TextField("例如 https://api.example.com/v1", text: $state.settings.llmBaseURL)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("API Key").frame(width: 150, alignment: .leading).foregroundStyle(.secondary)
                SecureField("本地免密接口可留空", text: $state.settings.llmApiKey)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("模型名称").frame(width: 150, alignment: .leading).foregroundStyle(.secondary)
                TextField("接口支持的模型 ID", text: $state.settings.llmModelStrong)
                    .textFieldStyle(.roundedBorder)
            }

            DisclosureGroup("高级设置", isExpanded: $showAPIAdvanced) {
                VStack(spacing: 10) {
                    HStack {
                        Text("Key 环境变量").frame(width: 150, alignment: .leading).foregroundStyle(.secondary)
                        TextField("可选，如 OPENAI_API_KEY", text: $state.settings.llmApiKeyEnv)
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Text("推理参数格式").frame(width: 150, alignment: .leading).foregroundStyle(.secondary)
                        Picker("", selection: $state.settings.llmReasoningStyle) {
                            Text("不附加（兼容性最佳）").tag("none")
                            Text("DeepSeek").tag("deepseek")
                            Text("OpenAI").tag("openai")
                            Text("OpenRouter").tag("openrouter")
                        }
                        .labelsHidden()
                        Spacer()
                    }
                    HStack {
                        Text("低成本模型").frame(width: 150, alignment: .leading).foregroundStyle(.secondary)
                        TextField("留空则回退到主模型", text: $state.settings.llmModelCheap)
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Text("快速模型").frame(width: 150, alignment: .leading).foregroundStyle(.secondary)
                        TextField("留空则回退到主模型", text: $state.settings.llmModelFast)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(.top, 8)
            }
            HStack {
                Button(state.llmPingChecking ? "测试中…" : "测试连接") { testLLMConnection() }
                    .disabled(state.llmPingChecking)
                if !state.llmPingStatus.isEmpty {
                    Text(state.llmPingStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            Text("接口需兼容 OpenAI Chat Completions；程序会在该地址后调用 /chat/completions。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// 「测试连接」：LLMToolClient.ping（Ollama 有服务 → pong；无服务 → 可读错误，不崩溃）。
    private func testLLMConnection() {
        state.llmPingChecking = true
        state.llmPingStatus = "正在连接…"
        let config = state.settings.toLLMConfig()
        let scriptsDir = Paths.builtinSkillScriptsDir()
        let stateDir = FileManager.default.temporaryDirectory.appendingPathComponent("llm-ping-\(UUID().uuidString)")
        let client = LLMToolClient(python: Paths.pythonForScripts(settings: state.settings),
                                   scriptURL: scriptsDir, stateDir: stateDir)
        let box = WeakAppStateBox(state)
        Task.detached(priority: .userInitiated) {
            defer { try? FileManager.default.removeItem(at: stateDir) }
            let result: String
            do {
                let text = try client.ping(config: config)
                result = "✅ 连接成功：\(text.prefix(40))"
            } catch {
                result = "❌ \(error.localizedDescription)"
            }
            await MainActor.run {
                box.state?.llmPingChecking = false
                box.state?.llmPingStatus = result
            }
        }
    }

    /// PRD §8.3：「术语表策略」分组 —— 自动补充 Toggle + 注入范围 Segmented + 实时 A/B/C/D 后果。
    private var glossaryPolicyCard: some View {
        let hasUser = GlossaryPolicy.hasUserGlossary(state.settings)
        let policy = GlossaryPolicy.resolve(hasUserGlossary: hasUser,
                                            autoGlossaryEnabled: state.settings.autoGlossaryEnabled)
        return SectionCard(title: "术语表策略") {
            Toggle("自动生成/补充术语表", isOn: $state.settings.autoGlossaryEnabled)
                .onChange(of: state.settings.autoGlossaryEnabled) { _, _ in state.settings.save() }
            Picker("术语注入范围", selection: $state.settings.glossaryScope) {
                Text("本块命中（推荐）").tag("chunk")
                Text("全表").tag("full")
            }
            .pickerStyle(.segmented)
            .onChange(of: state.settings.glossaryScope) { _, _ in state.settings.save() }
            Text(policy.displayName)
                .font(.caption.bold())
            Text(policy.uiFooterText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if policy.showsRiskBanner {
                Text("⚠️ 未启用术语一致性保障：本次不建表、不做术语校验，长文可能出现同名异译。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// PRD §8.3：「翻译流水线」分组 —— 6 Toggle + 步进器 + 快速/标准/精译预设。
    private var pipelineCard: some View {
        SectionCard(title: "翻译流水线") {
            HStack(spacing: 8) {
                Text("预设：").foregroundStyle(.secondary)
                ForEach(Settings.Preset.allCases, id: \.rawValue) { preset in
                    Button(preset.displayName) {
                        state.settings.applyPreset(preset)
                        state.settings.save()
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
            }
            Toggle("全书预扫（S2）", isOn: $state.settings.enablePrescan)
                .onChange(of: state.settings.enablePrescan) { _, _ in state.settings.save() }
            Toggle("样本风格分析（S3）", isOn: $state.settings.enableStyleAnalysis)
                .onChange(of: state.settings.enableStyleAnalysis) { _, _ in state.settings.save() }
            Toggle("标点规范化（S6）", isOn: $state.settings.enablePunctNormalize)
                .onChange(of: state.settings.enablePunctNormalize) { _, _ in state.settings.save() }
            Toggle("一致性 QA（S7）", isOn: $state.settings.enableQA)
                .onChange(of: state.settings.enableQA) { _, _ in state.settings.save() }
            Toggle("润色（P2，耗时翻倍）", isOn: $state.settings.enablePolish)
                .onChange(of: state.settings.enablePolish) { _, _ in state.settings.save() }
            Toggle("断点续跑", isOn: $state.settings.enableResume)
                .onChange(of: state.settings.enableResume) { _, _ in state.settings.save() }
            HStack {
                Text("每块字符上限").frame(width: 150, alignment: .leading).foregroundStyle(.secondary)
                Stepper("\(state.settings.maxCharsPerChunk) 字", value: $state.settings.maxCharsPerChunk,
                        in: 1000...12000, step: 500)
                    .onChange(of: state.settings.maxCharsPerChunk) { _, _ in state.settings.save() }
            }
        }
    }

    private var skillCard: some View {
        SectionCard(title: "翻译 skill") {
            HStack {
                Picker("skill", selection: $selectedSkillID) {
                    Text("jp-txt2pdf-translator（内置）").tag("jp-txt2pdf-translator")
                    if !customSkillPath.isEmpty {
                        Text(URL(fileURLWithPath: customSkillPath).lastPathComponent + "（自选）")
                            .tag(URL(fileURLWithPath: customSkillPath).lastPathComponent)
                    }
                }
                .onChange(of: selectedSkillID) { _, _ in autoVerify() }
                Button("导入 skill…") { importSkill() }
            }
            HStack {
                Button(verifyHighlight ? "校验 / 重新装载" : "校验 / 重新装载") {
                    verifySkill()
                }
                Text(skillStatusText).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                Spacer()
            }
        }
    }

    private var promptCard: some View {
        SectionCard(title: "提示词") {
            TextEditor(text: $promptText)
                .frame(minHeight: 160)
                .adaptiveGlass(cornerRadius: 10)
                .onChange(of: promptText) { _, _ in updatePromptUsage() }
            HStack {
                Button("恢复默认") { restoreDefault() }
                Button("保存提示词") { savePrompt() }
                Text(promptUsage).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            Text("提示：WB 默认模板略有不同，但自定义提示词对 WorkBuddy / DeepSeek 双后端统一生效；留空即使用内置默认。")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @State private var promptUsage: String = "当前使用：内置默认"

    // MARK: - Logic

    private func loadFromSettings() {
        selectedSkillID = state.settings.selectedSkill.isEmpty ? "jp-txt2pdf-translator" : state.settings.selectedSkill
        customSkillPath = state.settings.customSkillPath
        promptText = state.settings.customPrompt.isEmpty ? TranslationPrompts.systemCore : state.settings.customPrompt
        autoVerify()
        updatePromptUsage()
    }

    private func syncBilingualControl() {
        if state.settings.isAPI {
            state.settings.bilingual = false
            state.settings.save()
        }
    }

    private func importSkill() {
        if let url = presentOpenPanel(forFiles: false) {
            customSkillPath = url.path
            state.settings.customSkillPath = url.path
            selectedSkillID = url.lastPathComponent
            autoVerify()
        }
    }

    private func autoVerify() {
        let info = SkillRegistry.resolveSkill(skillID: selectedSkillID, customPath: customSkillPath)
        let (ok, detail) = SkillRegistry.checkStatus(info)
        skillStatusText = detail
        verifyHighlight = !ok
    }

    private func verifySkill() {
        let info = SkillRegistry.resolveSkill(skillID: selectedSkillID, customPath: customSkillPath)
        do {
            try SkillRegistry.ensureLoaded(info)
            let (_, detail) = SkillRegistry.checkStatus(info)
            skillStatusText = detail
            verifyHighlight = false
        } catch {
            skillStatusText = "未装载 ✗：\(error.localizedDescription)"
            verifyHighlight = true
        }
        state.settings.selectedSkill = selectedSkillID
        state.settings.customSkillPath = customSkillPath
        state.settings.save()
        state.refreshSkillStatus()
    }

    private func updatePromptUsage() {
        let def = TranslationPrompts.systemCore.trimmingCharacters(in: .whitespacesAndNewlines)
        let cur = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !state.settings.customPrompt.isEmpty {
            promptUsage = "当前使用：自定义（已保存）"
        } else if cur == def {
            promptUsage = "当前使用：内置默认"
        } else {
            promptUsage = "当前使用：内置默认（已编辑未保存）"
        }
    }

    private func savePrompt() {
        let def = TranslationPrompts.systemCore.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        state.settings.customPrompt = (raw == def) ? "" : raw
        state.settings.save()
        updatePromptUsage()
    }

    private func restoreDefault() {
        state.settings.customPrompt = ""
        state.settings.save()
        promptText = TranslationPrompts.systemCore
        updatePromptUsage()
    }
}
