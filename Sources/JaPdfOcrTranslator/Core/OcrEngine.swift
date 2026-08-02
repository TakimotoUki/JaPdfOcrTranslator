import Foundation

/// ndlocr OCR 引擎。
///
/// 复用原始项目 vendored 的 **ndlocr-lite** 模型（DEIM 文本检测 + PARSeq 级联识别），
/// 通过子进程调用内嵌的 `ocr_driver.py` 执行推理，再读回合并后的 `ja_combined.txt`。
///
/// 这正是原始 Python 版 `NdlOcrEngine` 在进程内所做的事——只是改由 Swift 以子进程
/// 方式驱动，从而无需在 App 中重新实现 DEIM/PARSeq 的预处理、解码与阅读顺序重组。
///
/// 为避免在 `@Sendable` 异步闭包中捕获非 `Sendable` 的 `Pipe`，子进程的标准输出 / 错误
/// 统一重定向到临时日志文件，轮询期间尾随该文件以流式上报进度，结束后整体读回用于错误诊断。
enum OcrEngine {
    /// 4 个 ONNX 权重（与原始 `_REQUIRED_WEIGHTS` 一致：det + rec 100/50/30）。
    private static let requiredWeights = [
        "deim-s-1024x1024.onnx",
        "parseq-ndl-24x256-30-tiny-189epoch-tegaki3-r8data-202604.onnx",
        "parseq-ndl-24x384-50-tiny-300epoch-tegaki3-r8data-202604.onnx",
        "parseq-ndl-24x768-100-tiny-153epoch-tegaki3-r8data-202604.onnx"
    ]

    /// 内嵌的 ndlocr-lite 目录是否就位（模型权重齐全）。
    static func isAvailable(python: String = "python3") -> Bool {
        guard let ndlDir = Paths.bundledResource(name: "ndlocr_lite") else { return false }
        let modelDir = ndlDir.appendingPathComponent("model")
        for w in requiredWeights {
            if !FileManager.default.fileExists(atPath: modelDir.appendingPathComponent(w).path) { return false }
        }
        return true
    }

    /// 识别 PDF 中的日文，返回合并后的 `ja_combined.txt` 的 URL。
    ///
    /// - Parameters:
    ///   - pdfURL: 输入 PDF。
    ///   - outDir: 输出目录（ndlocr 在此写出中间文件，最终我们读回 `ja_combined.txt`）。
    ///   - python: 用于运行 `ocr_driver.py` 的 Python 解释器路径（默认 `python3`）。
    ///   - abortCheck: 中止信号轮询（@Sendable）。
    ///   - onProgress: 进度回调（@Sendable），接收 `[INFO] OCR PDF page …` 等行。
    @discardableResult
    static func recognize(pdfURL: URL, outDir: URL,
                          python: String = "python3",
                          abortCheck: @Sendable @escaping () -> Bool = { false },
                          onProgress: @Sendable @escaping (String) -> Void = { _ in }) async throws -> URL {
        guard let ndlDir = Paths.bundledResource(name: "ndlocr_lite") else {
            throw AppError.ocr("未找到内嵌的 ndlocr-lite 资源（ndlocr_lite 目录未随应用打包）。\n请确认构建时 Resources/ndlocr_lite 已被复制进 App。")
        }
        guard let driver = Paths.bundledResource(name: "ocr_driver", ext: "py") else {
            throw AppError.ocr("未找到内嵌的 OCR 驱动脚本 ocr_driver.py。")
        }
        guard isAvailable(python: python) else {
            throw AppError.ocr("ndlocr-lite 模型权重缺失，无法执行 OCR。\n期望 4 个 ONNX 权重位于：\n  \(ndlDir.path)/model/")
        }

        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let stem = pdfURL.deletingPathExtension().lastPathComponent

        // 运行前按 stem 清理旧产物（幂等，避免重跑残留干扰合并）
        cleanupIntermediate(outDir: outDir, stem: stem)

        // 子进程输出重定向到日志文件（避免异步 Pipe 的 Sendable 捕获问题）
        let logURL = outDir.appendingPathComponent("ocr_\(stem).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let logHandle = try? FileHandle(forWritingTo: logURL) else {
            throw AppError.ocr("无法创建 OCR 日志文件：\n  \(logURL.path)")
        }
        defer { logHandle.closeFile() }

        let process = Process()
        if python.contains("/") {
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = [driver.path, ndlDir.path, pdfURL.path, outDir.path, stem]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [python, driver.path, ndlDir.path, pdfURL.path, outDir.path, stem]
        }
        process.currentDirectoryURL = outDir
        // 强制 Python 不缓冲 stdout/stderr，使进度行能即时刷新到日志文件（否则按块缓冲，流式进度会滞后）
        process.environment = ProcessInfo.processInfo.environment
            .merging(["PYTHONUNBUFFERED": "1"]) { $1 }
        process.standardOutput = logHandle
        process.standardError = logHandle

        do {
            try process.run()
        } catch {
            throw AppError.ocr("无法启动 OCR 子进程（Python：'\(python)'）：\n  \(error.localizedDescription)")
        }

        // 轮询中止 + 尾随日志以流式上报进度
        var lastOffset: UInt64 = 0
        var fullLog = ""
        func drainLog() {
            guard let fh = try? FileHandle(forReadingFrom: logURL) else { return }
            defer { fh.closeFile() }
            let end = (try? fh.seekToEnd()) ?? 0
            let from = min(lastOffset, end)
            try? fh.seek(toOffset: from)
            guard let chunk = try? fh.readToEnd(), !chunk.isEmpty else { return }
            lastOffset = from + UInt64(chunk.count)
            guard let s = String(data: chunk, encoding: .utf8) else { return }
            fullLog += s
            for line in s.split(whereSeparator: \.isNewline) {
                let l = line.trimmingCharacters(in: .whitespaces)
                if l.hasPrefix("[INFO] OCR PDF page") || l.hasPrefix("[WARN]") || l.hasPrefix("[ERROR]") {
                    onProgress(l)
                }
            }
        }

        while process.isRunning {
            if abortCheck() {
                process.terminate()
                throw AppError.abort
            }
            drainLog()
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        drainLog() // 收尾，确保末段日志被读回
        process.waitUntilExit()
        let status = process.terminationStatus

        guard status == 0 else {
            throw AppError.ocr("ndlocr 识别失败（退出码 \(status)）。\n请确认 Python 依赖已安装：\n  onnxruntime, opencv-python, pypdfium2, pypdf, pyyaml, numpy, Pillow, networkx, lxml\n\n\(String(fullLog.prefix(3000)))")
        }

        let combined = outDir.appendingPathComponent("ja_combined.txt")
        guard FileManager.default.fileExists(atPath: combined.path) else {
            throw AppError.ocr("ndlocr 未产出 ja_combined.txt。\n\(String(fullLog.prefix(3000)))")
        }
        return combined
    }

    /// 按 stem 精确清理 ndlocr 的中间产物（仅保留 `ja_combined.txt`）。
    private static func cleanupIntermediate(outDir: URL, stem: String) {
        let candidates = [
            outDir.appendingPathComponent("\(stem).txt"),
            outDir.appendingPathComponent("\(stem).xml"),
            outDir.appendingPathComponent("\(stem).json"),
            outDir.appendingPathComponent("\(stem)_text.pdf"),
            outDir.appendingPathComponent("ocr_\(stem).log")
        ]
        for p in candidates where FileManager.default.fileExists(atPath: p.path) {
            try? FileManager.default.removeItem(at: p)
        }
        // ndlocr 的可视化产物 viz_{stem}_*.png
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil) {
            for item in items where item.lastPathComponent.hasPrefix("viz_\(stem)") {
                try? fm.removeItem(at: item)
            }
        }
    }
}
