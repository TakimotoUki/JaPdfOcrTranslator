import SwiftUI

/// About and open-source acknowledgements.
struct AboutView: View {
    var body: some View {
        AdaptiveGlassContainer(spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                SectionCard(title: "") {
                    Label("日文 PDF 转译", systemImage: "doc.text.magnifyingglass")
                        .font(.title2.bold())
                    Text("日文 OCR · 大模型翻译 · PDF 生成")
                        .foregroundStyle(.secondary)
                }

                SectionCard(title: "致谢与开源许可") {
                    ScrollView {
                        Text(acknowledgement)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 200, maxHeight: .infinity)
                }

                HStack {
                    Spacer()
                    Button("关闭") { closeCurrentWindow() }
                        .adaptiveGlassButton()
                }
            }
        }
        .padding(24)
        .frame(minWidth: 420, idealWidth: 520, maxWidth: .infinity,
               minHeight: 320, idealHeight: 440, maxHeight: .infinity)
    }

    private let acknowledgement = """
    版本 3.3.1
    支持 macOS 14 或更高版本
    支持 Apple Silicon 与 Intel Mac

    感谢

    • 国立国会图书馆 NDL Lab
      本应用使用 NDLOCR-Lite 完成日文版面检测、文字识别与阅读顺序恢复。
      NDLOCR-Lite 以 CC BY 4.0 许可证发布。

    • PARSeq 与 DEIM 项目贡献者
      PARSeq 用于文字序列识别，DEIM 系列方法用于版面目标检测。

    • 开源运行时与工具
      ONNX Runtime、OpenCV、NumPy、Pillow、PyYAML、NetworkX、lxml、
      pypdfium2、pypdf 与 ReportLab 为 OCR 和文档处理提供了基础能力。

    • Apple 开发平台
      Swift、SwiftUI、AppKit、PDFKit、Core Text 与 CryptoKit 构成应用的
      原生界面、文件处理、安全存储和 PDF 排版能力。

    • WorkBuddy 与模型服务生态
      应用可通过 WorkBuddy 或用户配置的兼容 API 完成长篇翻译。

    开源组件及模型的著作权与许可证归各自作者所有。

    隐私说明

    OCR 与 PDF 排版在本机完成。使用 WorkBuddy 或模型 API 翻译时，
    待译文本会按用户选择发送到相应服务，请在使用前了解服务方的隐私政策。
    """
}
