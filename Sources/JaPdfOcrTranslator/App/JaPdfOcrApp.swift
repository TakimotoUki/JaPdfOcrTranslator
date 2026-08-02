import SwiftUI
import AppKit

/// `NSApplicationDelegate` 仅用于在应用真正完成启动后再声明前台 GUI 身份。
///
/// 关键点：激活策略**绝不能**放在 `App.init()` 里。那时 SwiftUI 的窗口尚未建立，
/// `setActivationPolicy` 会触发 AppKit 内部对 `NSApp.mainWindow!`（隐式解包可选）
/// 的访问——而此时它为 nil，导致
/// `Fatal error: Unexpectedly found nil while implicitly unwrapping an Optional value`。
/// 放到 `applicationDidFinishLaunching` 才是文档规定的安全时机。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// macOS 默认在关闭窗口后保留进程；本工具按用户预期在关闭最后一个窗口时退出。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct JaPdfOcrApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(state)
                .onAppear { state.onLaunch() }
                .frame(minWidth: 820, minHeight: 680)
        }
        .defaultSize(width: 980, height: 820)

        Window("设置", id: "settings") {
            SettingsView().environmentObject(state)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 720, height: 640)

        Window("致谢 / 开源许可", id: "about") {
            AboutView().environmentObject(state)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 560, height: 560)

        Window("编辑术语表", id: "glossary") {
            GlossaryEditorView().environmentObject(state)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 640, height: 560)
    }
}
