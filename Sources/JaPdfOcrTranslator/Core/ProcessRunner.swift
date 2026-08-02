import Foundation

/// Thin wrappers around `Process` for `textutil` (doc/docx extraction) and
/// `open` (WorkBuddy deep links) — both macOS-only, matching the original.
enum ProcessRunner {
    /// Run `textutil -convert txt -stdout <path>` and return the extracted text.
    static func extractTextFromDoc(_ url: URL) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        proc.arguments = ["-convert", "txt", "-stdout", url.path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.extraction("textutil 未抽取到任何文本（文件可能损坏）：\n  \(url.path)")
        }
        return text
    }

    /// Open a `workbuddy://` deep link, retrying a few times (the app may not
    /// be ready yet). Mirrors `workbuddy/backend._open_deep_link`.
    @discardableResult
    static func openDeepLink(_ url: String, retries: Int = 3, delay: TimeInterval = 0.6) throws -> Bool {
        for attempt in 1...max(1, retries) {
            // `Process` 实例只能启动一次；每次重试必须重新创建。
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = [url]
            do {
                try proc.run()
                proc.waitUntilExit()
                if proc.terminationStatus == 0 { return true }
            } catch {
                if attempt == retries {
                    throw AppError.workbuddy("无法打开 WorkBuddy deep link（已重试 \(retries) 次）：\n  \(url)")
                }
            }
            if attempt < retries { Thread.sleep(forTimeInterval: delay) }
        }
        return false
    }

    /// `open -a <app>` to launch WorkBuddy.
    static func launchApp(_ appPath: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-a", appPath]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw AppError.workbuddy("启动 WorkBuddy 失败（exit=\(proc.terminationStatus)）：\n  \(appPath)")
        }
    }

    // MARK: - v3.3 · 通用子进程捕获

    /// 线程安全的字节累加器。`DispatchQueue.async` 的闭包在 Swift 6 下是 `@Sendable`，
    /// 无法直接捕获可变局部变量，故用一个带锁的引用类型承载读取结果。
    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            storage.append(chunk)
        }

        var value: Data {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
    }

    /// 把子进程输出解码为文本，**永不返回 nil**。
    ///
    /// 不能用 `String(data:encoding:.utf8) ?? ""`：只要输出被截断在多字节字符
    /// 中间（`head -c`、被 SIGKILL 打断、脚本崩溃写了半个字符），严格解码就会
    /// 返回 nil，于是错误信息被静默替换成空串——这会让排障线索彻底丢失。
    /// `String(decoding:as:)` 用 U+FFFD 替换非法字节序列，保证内容尽量可见。
    private static func decodeOutput(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    /// 运行一个子进程并完整捕获 stdout / stderr，可选写入 stdin。
    ///
    /// 这是 v3.3 中 `GlossaryToolClient` / `StateToolClient` 调用 python 脚本的唯一底座。
    ///
    /// - Important: stdout / stderr / stdin **必须并发处理**（DESIGN §11.1 R10）。
    ///   如果在 `waitUntilExit()` 之后才读管道，子进程一旦输出超过内核管道缓冲区
    ///   （Darwin 上通常 64KB）就会阻塞在 `write()` 上永不退出，而父进程阻塞在
    ///   `waitUntilExit()` 上 —— 双向死锁。`glossary_tool.py hits --scope full`
    ///   在大术语库下会真实触发这个场景，因此此处用后台队列并发读，主线程只等信号量。
    ///
    /// - Parameters:
    ///   - exec: 可执行文件绝对路径。
    ///   - args: 参数数组。
    ///   - stdin: 需要写入子进程标准输入的文本；`nil` 表示不写（直接关闭）。
    ///   - timeout: 最长等待时间，超时先 `SIGTERM`、宽限 3s 后 `SIGKILL`，并抛错。
    ///   - environment: 额外环境变量；`nil` 表示继承当前进程环境。
    ///   - currentDirectory: 子进程工作目录；`nil` 表示继承。
    /// - Returns: `(code, out, err)` —— 退出码与两个流的 UTF-8 文本。
    ///   **非零退出码不抛错**，由调用方按 DESIGN §4.0 的退出码语义解释
    ///   （例如退 5 是「检查未通过」这一业务结果，而非故障）。
    /// - Throws: `AppError.pipeline`（无法启动 / 超时）。
    static func runCapturing(
        exec: String,
        args: [String],
        stdin: String? = nil,
        timeout: TimeInterval = 60,
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil
    ) throws -> (code: Int32, out: String, err: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exec)
        proc.arguments = args
        if let environment { proc.environment = environment }
        if let currentDirectory { proc.currentDirectoryURL = currentDirectory }

        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = inPipe

        let outBox = DataBox()
        let errBox = DataBox()
        let readers = DispatchGroup()
        let exited = DispatchSemaphore(value: 0)

        // terminationHandler 必须在 run() 之前挂上，否则极短命的进程可能漏掉信号。
        proc.terminationHandler = { _ in exited.signal() }

        do {
            try proc.run()
        } catch {
            throw AppError.pipeline(
                "无法启动子进程：\n  \(exec)\n  \(error.localizedDescription)\n  请检查该可执行文件是否存在且有执行权限。"
            )
        }

        // ── 并发读 stdout / stderr（防 64KB 管道死锁）──
        let ioQueue = DispatchQueue(label: "process.runner.io", attributes: .concurrent)
        for (pipe, box) in [(outPipe, outBox), (errPipe, errBox)] {
            ioQueue.async(group: readers) {
                let handle = pipe.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    box.append(chunk)
                }
                try? handle.close()
            }
        }

        // ── 并发写 stdin（大输入同样会撑爆管道缓冲区）──
        let stdinPayload = stdin
        ioQueue.async(group: readers) {
            let handle = inPipe.fileHandleForWriting
            if let text = stdinPayload, let data = text.data(using: .utf8), !data.isEmpty {
                // 分片写入，避免单次 write 过大；忽略 EPIPE（子进程可能提前退出）。
                try? handle.write(contentsOf: data)
            }
            try? handle.close()
        }

        // ── 等待退出（带超时）──
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            if exited.wait(timeout: .now() + 3) == .timedOut, proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
            _ = readers.wait(timeout: .now() + 2)
            let partialErr = decodeOutput(errBox.value)
            throw AppError.pipeline(
                "子进程执行超时（\(Int(timeout))s）已被终止：\n  \(exec) \(args.joined(separator: " "))"
                + (partialErr.isEmpty ? "" : "\n  stderr: \(partialErr.prefix(500))")
            )
        }

        // 进程已退出，等读端把残留数据抽干。
        _ = readers.wait(timeout: .now() + 10)

        let out = decodeOutput(outBox.value)
        let err = decodeOutput(errBox.value)
        return (proc.terminationStatus, out, err)
    }
}
