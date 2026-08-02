import AppKit

/// 关闭当前获得焦点的窗口。
///
/// 用于以 `Window` 场景（而非 `.sheet`）方式弹出的二级窗口：
/// 在 `Window` 场景下 `@Environment(\.dismiss)` 无法关闭窗口，
/// 因此直接用 AppKit 关闭 key window。
@MainActor
func closeCurrentWindow() {
    if let window = NSApp.windows.first(where: { @MainActor in $0.isKeyWindow }) {
        window.close()
    }
}
