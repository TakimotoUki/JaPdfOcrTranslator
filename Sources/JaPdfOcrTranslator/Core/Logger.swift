import Foundation
import os.log

/// Lightweight logger that also forwards lines to the in-app log panel.
///
/// Mirrors the original `utils.logging.get_logger` contract: every log line
/// is emitted to `os.log` and, when a sink is registered, delivered to the UI.
final class AppLogger: @unchecked Sendable {
    private let osLog: OSLog
    private let label: String

    /// Optional sink (set by the pipeline / UI) for streaming lines into the log view.
    var sink: ((String) -> Void)?

    init(_ label: String) {
        self.label = label
        self.osLog = OSLog(subsystem: "com.japdfocr.translator", category: label)
    }

    private func emit(_ level: String, _ message: String) {
        let line = "[\(level)] \(message)"
        os_log("%{public}@", log: osLog, type: .default, line)
        sink?(line)
    }

    func info(_ message: String) { emit("INFO", message) }
    func warning(_ message: String) { emit("WARN", message) }
    func error(_ message: String) { emit("ERROR", message) }
    func log(_ message: String) { emit("LOG", message) }
}

func getLogger(_ label: String) -> AppLogger {
    AppLogger(label)
}
