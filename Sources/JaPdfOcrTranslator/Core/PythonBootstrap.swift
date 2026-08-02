import Foundation

/// 跨机器可移植的 Python 运行环境解析与自动供给。
///
/// 设计目标：让本 App 在**任意 Mac**（无论是否装过 WorkBuddy、是否配过 venv）
/// 上首次运行 OCR 时都能「开箱即用」——自动找到一个可用 Python，并在缺失 OCR
/// 依赖时于 `~/Library/Application Support/JaPdfOcrTranslator/venv` 自建 venv 并
/// `pip install` 随包内置的 `requirements.txt`。
///
/// 解析优先级：
/// 1. 用户在「设置 → OCR 引擎」里显式指定的解释器（非空且非裸 `python3`）：先校验依赖，可用即用之；
/// 2. 候选解释器列表：
///    a. WorkBuddy 托管的 venv（若已存在）
///    b. 本 App 自己的 venv（若已存在）
///    c. 系统 / 用户基础 python3（/usr/bin/python3、Homebrew、python.org 等）
///    逐个校验依赖，第一个通过者即用；
/// 3. 若候选都缺依赖，挑一个基础 python3 自动建 venv + 安装内置 requirements.txt；
/// 4. 全失败则抛出清晰错误，提示用户先安装 Python 3.9+。
enum PythonBootstrap {

    /// OCR 所需的全部 Python 模块（与 `requirements.txt` 严格对应）。
    private static let requiredModules = [
        "onnxruntime", "cv2", "pypdfium2", "pypdf",
        "yaml", "numpy", "PIL", "networkx", "lxml"
    ]

    /// 让调用方拿到一个「已装好 OCR 依赖」的 Python 解释器路径。
    ///
    /// - Parameters:
    ///   - preferred: 用户在设置里填的解释器路径（可为空或裸 `python3`，表示自动）。
    ///   - onProgress: 进度回调（如自动安装时的提示）。
    /// - Returns: 可用的 Python 解释器绝对路径。
    /// - Throws: `AppError.ocr` 当完全找不到可用 Python 时。
    static func ensureInterpreter(
        preferred: String,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let pref = preferred.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. 用户显式路径：校验依赖后优先使用，但绝不擅自改写它
        if !pref.isEmpty, pref != "python3", FileManager.default.isExecutableFile(atPath: pref) {
            if await checkDeps(python: pref) {
                return pref
            }
            // 显式路径缺依赖：不强行改造，继续走自动解析
        }

        // 2. 候选解释器（已存在者）逐个校验依赖
        for cand in candidateInterpreters() {
            if await checkDeps(python: cand) {
                return cand
            }
        }

        // 3. 自动建 venv 并安装依赖（首次运行，需联网）
        onProgress?("正在准备 Python 运行环境（首次约需 1–2 分钟，需联网下载 OCR 依赖）…")
        for base in basePythonCandidates() {
            if let venvPython = try? await bootstrapVenv(basePython: base, onProgress: onProgress) {
                return venvPython
            }
        }

        // 4. 彻底失败
        throw AppError.ocr(
            "未找到可用的 Python 3（需 3.9+）来运行 OCR。\n\n" +
            "请先安装 Python：\n" +
            "  · Homebrew：  brew install python3\n" +
            "  · 或前往 https://www.python.org/downloads/ 下载 macOS 安装包\n\n" +
            "安装完成后重新打开本应用，即可自动完成 OCR 依赖的安装。"
        )
    }

    // MARK: - 候选解释器发现

    /// 已存在且可能带依赖的解释器（按优先级）。
    private static func candidateInterpreters() -> [String] {
        var list: [String] = []

        // a. WorkBuddy 托管 venv
        let managed = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".workbuddy/binaries/python/envs/default/bin/python3")
        if FileManager.default.isExecutableFile(atPath: managed) { list.append(managed) }

        // b. 本 App 自建 venv
        if let appVenv = appVenvPython(), FileManager.default.isExecutableFile(atPath: appVenv) {
            list.append(appVenv)
        }

        // c. 系统 / 用户基础 python3
        list.append(contentsOf: basePythonCandidates())

        return list
    }

    /// 可能用于「新建 venv」的基础 Python（不要求已装 OCR 依赖）。
    private static func basePythonCandidates() -> [String] {
        var seen = Set<String>()
        var list: [String] = []

        func add(_ p: String) {
            let expanded = (p as NSString).expandingTildeInPath
            guard !expanded.isEmpty,
                  FileManager.default.isExecutableFile(atPath: expanded),
                  !seen.contains(expanded) else { return }
            seen.insert(expanded)
            list.append(expanded)
        }

        // PATH 上的 python3 / python3.x
        for cmd in ["python3", "python3.13", "python3.12", "python3.11", "python3.10", "python3.9"] {
            if let which = runWhich(cmd) { add(which) }
        }
        // 常见固定位置
        add("/usr/bin/python3")
        add("/opt/homebrew/bin/python3")        // Apple Silicon Homebrew
        add("/usr/local/bin/python3")           // Intel Homebrew
        add("/opt/local/bin/python3")           // MacPorts
        // python.org 框架安装
        if let framework = pythonFrameworkPython() { add(framework) }

        return list
    }

    private static func pythonFrameworkPython() -> String? {
        let base = "/Library/Frameworks/Python.framework/Versions"
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: base) else { return nil }
        // 取版本号最大的一个
        let sorted = versions.filter { $0.first?.isNumber == true }.sorted { $0 < $1 }
        guard let latest = sorted.last else { return nil }
        return base + "/\(latest)/bin/python3"
    }

    private static func runWhich(_ cmd: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = [cmd]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let out = String(data: data, encoding: .utf8) else { return nil }
        let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    // MARK: - 依赖校验

    /// 校验给定 Python 是否已安装全部 OCR 依赖。
    private static func checkDeps(python: String) async -> Bool {
        let imports = requiredModules.map { "import \($0)" }.joined(separator: "; ")
        let script = "\(imports); print('DEPS_OK')"
        let (status, stdout, _) = runProcess(executable: python, arguments: ["-c", script])
        return status == 0 && stdout.contains("DEPS_OK")
    }

    // MARK: - 自动建 venv

    /// 用基础 python 在本 App 支持目录自建 venv 并安装内置依赖；成功返回 venv 的 python3 路径。
    private static func bootstrapVenv(basePython: String, onProgress: (@Sendable (String) -> Void)?) async throws -> String? {
        guard let venvPython = appVenvPython() else { return nil }
        let venvDir = (venvPython as NSString).deletingLastPathComponent  // .../venv/bin

        let fm = FileManager.default
        // 若已存在 venv，直接复用（可能已经装好）
        if fm.isExecutableFile(atPath: venvPython), await checkDeps(python: venvPython) {
            return venvPython
        }
        // 否则清掉残桩重建
        let venvRoot = (venvDir as NSString).deletingLastPathComponent  // .../venv
        try? fm.removeItem(atPath: venvRoot)
        try fm.createDirectory(at: URL(fileURLWithPath: venvRoot), withIntermediateDirectories: true)

        onProgress?("正在创建 Python 虚拟环境…")
        var (status, _, _) = runProcess(executable: basePython, arguments: ["-m", "venv", venvRoot])
        if status != 0 {
            // 某些基础 python 缺 ensurepip；尝试补救
            onProgress?("正在为虚拟环境引导 pip…")
            _ = runProcess(executable: basePython, arguments: ["-m", "ensurepip", "--upgrade"])
            (status, _, _) = runProcess(executable: basePython, arguments: ["-m", "venv", venvRoot])
        }
        guard status == 0, fm.isExecutableFile(atPath: venvPython) else {
            return nil
        }

        // 安装依赖
        guard let reqs = requirementsFileURL() else { return nil }
        onProgress?("正在安装 OCR 依赖（onnxruntime / opencv / pypdfium2 …，请稍候）…")
        let (pipStatus, _, pipErr) = runProcess(
            executable: venvPython,
            arguments: ["-m", "pip", "install", "--upgrade", "pip", "-r", reqs.path]
        )
        guard pipStatus == 0 else {
            onProgress?("依赖安装失败：\(pipErr.prefix(300))")
            return nil
        }

        // 再次校验
        guard await checkDeps(python: venvPython) else { return nil }
        return venvPython
    }

    // MARK: - 路径辅助

    /// 本 App 自建 venv 的 python3 路径（目录可能尚未创建）。
    private static func appVenvPython() -> String? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let venvRoot = support.appendingPathComponent("JaPdfOcrTranslator/venv")
        return venvRoot.appendingPathComponent("bin/python3").path
    }

    /// 随包内置的 requirements.txt 路径（优先 Bundle.module；兼容 swift run / 独立 .app 场景）。
    private static func requirementsFileURL() -> URL? {
        if let url = Paths.bundledResource(name: "requirements", ext: "txt") { return url }
        // 兜底：与可执行文件同目录，或 .app/Contents/Resources
        let exeDir = (Bundle.main.executableURL?.deletingLastPathComponent()) ??
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            exeDir.appendingPathComponent("requirements.txt"),
            exeDir.appendingPathComponent("../Resources/requirements.txt"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Sources/JaPdfOcrTranslator/Resources/requirements.txt")
        ]
        for c in candidates where FileManager.default.fileExists(atPath: c.path) { return c }
        return nil
    }

    // MARK: - 通用进程工具

    /// 同步运行进程并返回 (退出码, 标准输出, 标准错误)。
    private static func runProcess(executable: String, arguments: [String])
        -> (Int32, String, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
        } catch {
            return (-1, "", error.localizedDescription)
        }
        proc.waitUntilExit()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""
        return (proc.terminationStatus, out, err)
    }
}
