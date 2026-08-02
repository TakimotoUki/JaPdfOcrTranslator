import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// 跨进程排他文件锁（`flock(2)`）。
///
/// 与 Python 侧 `_common.file_lock()` 使用**同一个锁文件路径**和**同一个系统调用**
/// （`fcntl.flock` 在 Darwin 上就是 `flock(2)`），因此 Swift 进程与 python 子进程
/// 之间的互斥是真实有效的（DESIGN §10.5 L4）。
///
/// 注意（DESIGN §10.5 L1）：锁文件**永不删除**。删除锁文件会让后续持锁者拿到
/// 不同 inode，从而破坏互斥语义。
enum FileLock {
    /// 默认锁等待超时，与 Python 侧 `_common.file_lock(timeout=30.0)` 对齐。
    static let defaultTimeout: TimeInterval = 30.0

    /// 轮询间隔，与 Python 侧 `time.sleep(0.05)` 对齐。
    private static let pollInterval: TimeInterval = 0.05

    /// 在指定锁文件上持有排他锁执行 `body`，退出作用域时保证解锁并关闭 fd。
    ///
    /// - Parameters:
    ///   - url: 锁文件路径（如 `<state>/.locks/glossary.lock`）。父目录会被自动创建。
    ///   - timeout: 获取锁的最长等待时间，超时抛 `AppError.state`。
    ///   - body: 持锁期间执行的闭包。
    /// - Returns: `body` 的返回值。
    /// - Throws: `AppError.state`（无法打开锁文件 / 获取锁超时）或 `body` 抛出的错误。
    @discardableResult
    static func withExclusiveLock<T>(
        at url: URL,
        timeout: TimeInterval = defaultTimeout,
        _ body: () throws -> T
    ) throws -> T {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // O_CREAT|O_RDWR + 0o644：与 Python 侧 open(path, "a+b") 等价的持有方式。
        let fd = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            let reason = String(cString: strerror(errno))
            throw AppError.state("无法打开锁文件（\(reason)）：\n  \(url.path)\n  请检查该目录是否可写。")
        }
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }

        try acquire(fd: fd, url: url, timeout: timeout)
        return try body()
    }

    /// 非阻塞轮询获取锁，直到成功或超时。
    ///
    /// 用 `LOCK_EX|LOCK_NB` 轮询而不是阻塞式 `LOCK_EX`，是为了能真正实现超时语义
    /// （阻塞式 `flock` 无法中断）。
    private static func acquire(fd: Int32, url: URL, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return }
            let err = errno
            // EWOULDBLOCK / EAGAIN：锁被他人持有，继续轮询。其余为真错误。
            guard err == EWOULDBLOCK || err == EAGAIN || err == EINTR else {
                let reason = String(cString: strerror(err))
                throw AppError.state("获取文件锁失败（\(reason)）：\n  \(url.path)")
            }
            if Date() >= deadline {
                let shown = String(format: "%g", timeout)
                throw AppError.state(
                    "获取文件锁超时（\(shown)s）：\n  \(url.path)\n  疑似有另一个任务正在写术语库，请稍后重试。"
                )
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
    }

    /// 读取并自增 `<state>/.locks/seq` 计数器，返回**新值**（1-based）。
    ///
    /// 语义与 Python 侧 `_common.next_seq()` 完全一致（DESIGN §10.4 R2/R3）：
    /// 锁内 `read → +1 → write`。`seq` 文件丢失或损坏时从 `events.jsonl` 行数自愈。
    ///
    /// - Important: 调用方必须**已经持有** `state.lock`，本函数不自行加锁。
    static func nextSeqLocked(stateDir: URL) -> Int {
        let seqFile = stateDir.appendingPathComponent(".locks/seq")
        var current = 0
        if let raw = try? String(contentsOf: seqFile, encoding: .utf8),
           let parsed = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            current = parsed
        } else {
            // 自愈：用 events.jsonl 的非空行数重建计数器。
            let events = stateDir.appendingPathComponent("events.jsonl")
            if let text = try? String(contentsOf: events, encoding: .utf8) {
                current = text.split(separator: "\n").filter {
                    !$0.trimmingCharacters(in: .whitespaces).isEmpty
                }.count
            }
        }
        let next = current + 1
        try? "\(next)\n".write(to: seqFile, atomically: true, encoding: .utf8)
        return next
    }
}
