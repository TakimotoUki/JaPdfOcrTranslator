import SwiftUI
import UniformTypeIdentifiers

/// Present a macOS open panel and return the chosen URL (file or directory).
@MainActor
func presentOpenPanel(forFiles: Bool, allowedExtensions: [String] = []) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = forFiles
    panel.canChooseDirectories = !forFiles
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    if !allowedExtensions.isEmpty {
        panel.allowedContentTypes = allowedExtensions.compactMap { UTType(filenameExtension: $0) }
    }
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    return url
}

/// A glass-morphism card wrapping a labeled group of controls.
struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !title.isEmpty {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .adaptiveGlass(cornerRadius: 16)
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }
}

/// Tahoe 使用 Liquid Glass；较早的受支持系统自动降级为原生材质卡片。
extension View {
    @ViewBuilder
    func adaptiveGlass(cornerRadius: CGFloat) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            self.materialCard(cornerRadius: cornerRadius)
        }
        #else
        self.materialCard(cornerRadius: cornerRadius)
        #endif
    }

    private func materialCard(cornerRadius: CGFloat) -> some View {
        self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}

/// A labeled path field with a browse button.
struct PathField: View {
    let title: String
    @Binding var path: String
    let forFiles: Bool
    var allowedExtensions: [String] = []

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .frame(width: 150, alignment: .leading)
                .foregroundStyle(.secondary)
            TextField("", text: $path)
                .textFieldStyle(.roundedBorder)
            Button(action: browse) {
                Image(systemName: "folder")
            }
            .help("浏览…")
        }
    }

    private func browse() {
        if let url = presentOpenPanel(forFiles: forFiles, allowedExtensions: allowedExtensions) {
            path = url.path
        }
    }
}

/// A primary glass button used for the main run action.
struct PrimaryButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    var disabled: Bool = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
        }
        .disabled(disabled)
    }
}

// MARK: - v3.3 共用组件（T05-g / §8.1）

/// 九段式阶段进度条（S0–S8）。`currentIndex` 0–8；已完成段绿色、当前段高亮、未到段灰。
struct StageBar: View {
    let stages: [PipelineStage]
    let currentIndex: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                VStack(spacing: 4) {
                    Circle()
                        .fill(fillColor(for: index))
                        .frame(width: 12, height: 12)
                        .overlay(
                            Circle().strokeBorder(index == currentIndex ? Color.accentColor : .clear, lineWidth: 2)
                        )
                    Text("S\(index)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(index <= currentIndex ? .primary : .secondary)
                }
                if index < stages.count - 1 {
                    Rectangle()
                        .fill(index < currentIndex ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(height: 2)
                }
            }
        }
        .help("阶段 \(min(currentIndex + 1, 9))/9")
    }

    private func fillColor(for index: Int) -> Color {
        if index < currentIndex { return .accentColor }
        if index == currentIndex { return Color.accentColor.opacity(0.55) }
        return Color.secondary.opacity(0.25)
    }
}

/// 指标小徽章：`术语 12 条` / `冲突 3` / `QA 5`。
struct MetricChip: View {
    let label: String
    let value: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(value).bold().foregroundStyle(tint)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

/// 状态徽章：`阶段 5/9 · 逐块翻译`。
struct StatusBadge: View {
    let text: String
    var ok: Bool = true

    var body: some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.caption.weight(.medium))
            .foregroundStyle(ok ? Color.green : Color.orange)
    }
}

/// 搜索框（术语表编辑器用）。
struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索…", text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// 顶部合规横幅（F33-02 事后取证结果）。
struct ComplianceBanner: View {
    let compliant: Bool?

    var body: some View {
        if let compliant {
            HStack(spacing: 8) {
                Image(systemName: compliant ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                Text(compliant
                     ? "术语预抽时序合规（F33-02 已通过）"
                     : "术语预抽时序不合规：存在块未在翻译前做预抽，报告已列出缺失块号")
                Spacer()
            }
            .font(.caption.weight(.medium))
            .padding(10)
            .background((compliant ? Color.green : Color.orange).opacity(0.15),
                        in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
