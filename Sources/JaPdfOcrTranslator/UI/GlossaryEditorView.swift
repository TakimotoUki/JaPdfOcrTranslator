import SwiftUI

/// Glossary editor — v3.3 重写（T05-j / F33-08）。
///
/// - **五列**：日语 / 中文 / 类型 / 备注 / 锁定；
/// - **修复 v3.2 bug**：「删除选中行」此前实为删空行；现用 `Table($entries, selection:)`
///   真实选中（`Set<UUID>`），删除即删**选中的行**；
/// - 搜索 / 类型筛选 / 仅看冲突；
/// - 导入 CSV… / 导出 CSV… / 导入本次自动术语（N 条）；
/// - 底部策略说明条（`GlossaryPolicy.uiFooterText`）。
struct GlossaryEditorView: View {
    @EnvironmentObject var state: AppState

    @State private var entries: [Glossary.Entry] = []
    @State private var selection: Set<Glossary.Entry.ID> = []
    @State private var searchText: String = ""
    @State private var typeFilter: String = "全部"
    @State private var conflictOnly: Bool = false
    @State private var loadError: String?
    @State private var upgradeNoticeShown = false

    private let typeOptions = ["全部", "人物", "地名", "组织", "术语", "招式", "物品",
                               "称谓", "敬称", "口癖", "固定表达", "其他"]

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                toolbarRow
                Table($entries, selection: $selection) {
                    TableColumn("日语（原文）") { $e in
                        TextField("", text: $e.source)
                    }
                    TableColumn("中文（译名）") { $e in
                        TextField("", text: $e.target)
                    }
                    TableColumn("类型") { $e in
                        Picker("", selection: $e.type) {
                            ForEach(TermType.allCases, id: \.self) { t in
                                Text(t.rawValue).tag(t)
                            }
                        }
                        .labelsHidden()
                    }
                    TableColumn("备注") { $e in
                        TextField("", text: $e.note)
                    }
                    TableColumn("锁定") { e in
                        // e 是 Binding<Glossary.Entry>（Table 的行绑定），取值须用 wrappedValue（P0-1）
                        Image(systemName: e.wrappedValue.locked ? "lock.fill" : "lock.open")
                            .foregroundStyle(e.wrappedValue.locked ? Color.secondary : Color.clear)
                    }
                    .width(44)
                }
                .frame(minHeight: 320)
                .adaptiveGlass(cornerRadius: 12)

                HStack {
                    Button("添加行") { addRow() }
                    Button("删除选中行（\(selection.count)）") { deleteSelected() }
                        .disabled(selection.isEmpty)
                    Button("清空") { entries.removeAll() }
                    Spacer()
                    Button("导入 CSV…") { importCSV() }
                    Button("导出 CSV…") { exportCSV() }
                    if state.autoTermsToAdopt > 0 {
                        Button("导入本次自动术语（\(state.autoTermsToAdopt) 条）") { adoptAutoTerms() }
                    }
                }

                // 策略说明条
                let hasUser = GlossaryPolicy.hasUserGlossary(state.settings)
                let policy = GlossaryPolicy.resolve(hasUserGlossary: hasUser,
                                                    autoGlossaryEnabled: state.settings.autoGlossaryEnabled)
                Text(policy.uiFooterText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let loadError {
                    Text(loadError).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    Button("取消") { closeCurrentWindow() }
                    Button("保存") { save() }
                }
            }
            .padding(20)
            .navigationTitle("编辑术语表")
            .onAppear(perform: load)
            .alert("术语表已升级格式", isPresented: $upgradeNoticeShown) {
                Button("知道了") {}
            } message: {
                Text("旧两栏 CSV 已按 v3.3 五栏格式加载：缺省列已填默认值（类型=其他 / 来源=用户 / 锁定）。\n保存后将写为五栏格式。")
            }
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    // MARK: - 过滤

    private var filteredEntries: [Glossary.Entry] {
        var list = entries
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
            list = list.filter {
                $0.source.lowercased().contains(q) || $0.target.lowercased().contains(q)
                    || $0.note.lowercased().contains(q)
            }
        }
        if typeFilter != "全部" {
            list = list.filter { $0.type.rawValue == typeFilter }
        }
        if conflictOnly {
            list = list.filter { $0.status == .conflict }
        }
        return list
    }

    private var toolbarRow: some View {
        HStack(spacing: 10) {
            SearchField(text: $searchText)
                .frame(maxWidth: 240)
            Picker("类型", selection: $typeFilter) {
                ForEach(typeOptions, id: \.self) { Text($0).tag($0) }
            }
            .frame(maxWidth: 160)
            Toggle("仅看冲突", isOn: $conflictOnly)
            Spacer()
            Text("共 \(entries.count) 条 · 已选 \(selection.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 编辑

    private func addRow() {
        entries.append(Glossary.Entry(source: "", target: ""))
    }

    /// 修复 v3.2「删除选中行实为删空行」：删除 `selection` 中真实选中的行（T05 判据 3）。
    private func deleteSelected() {
        entries.removeAll { selection.contains($0.id) }
        selection.removeAll()
    }

    private func load() {
        let path = state.settings.glossaryPath.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }
        do {
            let g = try Glossary.loadCSV(URL(fileURLWithPath: path))
            // 旧两栏 CSV 升级提示：任何条目类型都是默认「其他」且来源为 user
            let isLegacy = !g.entries.isEmpty && g.entries.allSatisfy {
                $0.type == .other && $0.note.isEmpty && $0.aliases.isEmpty
            }
            entries = g.entries
            if isLegacy { upgradeNoticeShown = true }
        } catch {
            loadError = "术语表加载失败：\(error.localizedDescription)"
        }
    }

    private func save() {
        let g = Glossary(entries: entries.filter { !$0.source.trimmingCharacters(in: .whitespaces).isEmpty })
        if g.entries.isEmpty {
            state.settings.glossaryPath = ""
            state.settings.save()
            state.glossaryDisplayPath = ""
            closeCurrentWindow()
            return
        }
        let path = state.settings.glossaryPath.trimmingCharacters(in: .whitespaces).isEmpty
            ? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("JaPdfOcrTranslator/glossary.csv").path)
            : state.settings.glossaryPath
        do {
            try g.saveCSV5(URL(fileURLWithPath: path))
            state.settings.glossaryPath = path
            state.settings.save()
            state.glossaryDisplayPath = path
        } catch {
            loadError = "保存失败：\(error.localizedDescription)"
            return
        }
        closeCurrentWindow()
    }

    // MARK: - 导入 / 导出 / 收编

    private func importCSV() {
        guard let url = presentOpenPanel(forFiles: true, allowedExtensions: ["csv", "json"]) else { return }
        do {
            if url.pathExtension.lowercased() == "json" {
                let g = try Glossary.loadJSON(url)
                entries = g.entries
            } else {
                let g = try Glossary.loadCSV(url)
                entries = g.entries
            }
            loadError = nil
        } catch {
            loadError = "导入失败：\(error.localizedDescription)"
        }
    }

    private func exportCSV() {
        guard let url = presentSavePanel(defaultName: "glossary.csv") else { return }
        let g = Glossary(entries: entries.filter { !$0.source.isEmpty })
        do {
            try g.saveCSV5(url)
            loadError = nil
        } catch {
            loadError = "导出失败：\(error.localizedDescription)"
        }
    }

    /// F33-15：把本次自动术语（export --origin auto 的 csv5）追加进用户表并转 origin=user。
    private func adoptAutoTerms() {
        guard state.autoTermsToAdopt > 0 else { return }
        let exportPath = (state.autoExportPath ?? "").trimmingCharacters(in: .whitespaces)
        guard !exportPath.isEmpty, FileManager.default.fileExists(atPath: exportPath) else {
            loadError = "未找到自动术语导出文件（glossary_export.csv）。"
            return
        }
        do {
            let auto = try Glossary.loadCSV(URL(fileURLWithPath: exportPath))
            var merged = entries
            for a in auto.entries {
                var adopted = a
                adopted.origin = .user
                adopted.locked = true
                adopted.status = .ok
                if let idx = merged.firstIndex(where: { $0.source == adopted.source }) {
                    if merged[idx].target == adopted.target || !merged[idx].locked {
                        merged[idx] = adopted
                    }
                } else {
                    merged.append(adopted)
                }
            }
            entries = merged
            state.autoTermsToAdopt = 0
            loadError = nil
            // 直接落盘，避免用户忘记保存
            save()
        } catch {
            loadError = "收编自动术语失败：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func presentSavePanel(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
