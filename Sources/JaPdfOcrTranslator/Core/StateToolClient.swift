import Foundation

/// `state_tool.py` 的 Swift 封装（DESIGN §4.10，8 个子命令）。
///
/// `Sendable struct`：不可变值 + 纯函数式调用，跨 actor 安全。
/// 错误映射与 `GlossaryToolClient` 相同（§4.0 退出码语义）；
/// `init` 退 4（输入/参数已变）时**不抛错**，而是返回 `InitRunResult.resumable=false + reason`，
/// 由调用方走「归档旧状态 / 取消」三选弹窗。
struct StateToolClient: Sendable {
    let python: String
    let scriptsDir: URL
    let stateDir: URL

    private var tool: String { scriptsDir.appendingPathComponent("state_tool.py").path }

    // MARK: - 底层执行

    private func runJSON(_ args: [String], allowExitCodes: Set<Int32> = [0]) throws -> [String: Any] {
        let result = try ProcessRunner.runCapturing(exec: python, args: [tool] + args, timeout: 120)
        if !allowExitCodes.contains(result.code) {
            throw Self.mapExit(code: result.code, err: result.err)
        }
        guard let data = result.out.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.state(
                "state_tool.py stdout 不是合法 JSON（exit=\(result.code)）。\n"
                + "stdout: \(result.out.prefix(300))\n"
                + "stderr: \(result.err.prefix(500))"
            )
        }
        return json
    }

    private static func mapExit(code: Int32, err: String) -> AppError {
        let detail = err.trimmingCharacters(in: .whitespacesAndNewlines)
        switch code {
        case 1, 3:
            return .state("参数或输入错误（exit=\(code)）：\n  \(detail)")
        case 2:
            return .state("IO / 锁错误（exit=2）：\n  \(detail)")
        case 4:
            return .state("状态未初始化或目标不存在（exit=4）：\n  \(detail)")
        case 5:
            return .state("合规校验未通过（exit=5）：\n  \(detail)")
        default:
            return .state("未知退出码 \(code)：\n  \(detail)")
        }
    }

    // MARK: - 子命令（§4.10）

    /// §4.10 `init`：初始化 run。
    struct InitRunResult {
        var resumable: Bool
        var reason: String?        // 非空 = 不可续跑的原因（input_changed / params_changed / …）
        var done: Int
        var pending: Int
        var pathMode: String
        var prescanMode: String
    }

    func initRun(input: URL, backend: String, params: RunParams) throws -> InitRunResult {
        let paramsJSON = params.canonicalJSON
        let args = ["init", "--state", stateDir.path,
                    "--input", input.path,
                    "--backend", backend,
                    "--params-json", paramsJSON]
        // 退 4 = 输入/参数与 config 不一致 → 业务结果（续跑被拒），不抛错
        let json = try runJSON(args, allowExitCodes: [0, 4])
        return InitRunResult(resumable: json["resumable"] as? Bool ?? false,
                             reason: json["reason"] as? String,
                             done: json["done"] as? Int ?? 0,
                             pending: json["pending"] as? Int ?? 0,
                             pathMode: json["path_mode"] as? String ?? "full",
                             prescanMode: json["prescan_mode"] as? String ?? "off")
    }

    /// §4.10 `set-stage`：切换阶段。
    func setStage(_ stage: PipelineStage, finish: Bool = false, skip: Bool = false,
                  reason: String? = nil) throws {
        var args = ["set-stage", "--state", stateDir.path, "--stage", stage.rawValue]
        if finish { args += ["--finish"] }
        if skip {
            args += ["--skip"]
            if let reason { args += ["--reason", reason] }
        } else if let name = Optional(stage.displayName) {
            args += ["--name", name]
        }
        _ = try runJSON(args)
    }

    /// §4.10 `mark-chunk`：更新块状态。
    func markChunk(n: Int, value: String, zhChars: Int? = nil, error: String? = nil,
                   reason: String? = nil) throws {
        var args = ["mark-chunk", "--state", stateDir.path, "--chunk", "\(n)", "--value", value]
        if let zhChars { args += ["--zh-chars", "\(zhChars)"] }
        if let error { args += ["--error", error] }
        if let reason { args += ["--reason", reason] }
        _ = try runJSON(args)
    }

    /// §4.10 `pending`：未完成块列表。
    struct PendingResult {
        var pending: [Int]
        var done: Int
        var total: Int
    }

    func pending() throws -> PendingResult {
        let json = try runJSON(["pending", "--state", stateDir.path])
        return PendingResult(pending: json["pending"] as? [Int] ?? [],
                             done: json["done"] as? Int ?? 0,
                             total: json["total"] as? Int ?? 0)
    }

    /// §4.10 `status`：读取 / 刷新状态。
    func refreshStatus(message: String? = nil) throws -> TranslationState {
        var args = ["status", "--state", stateDir.path, "--refresh", "--format", "json"]
        if let message { args += ["--message", message] }
        let json = try runJSON(args)
        // status --format json 输出即 status.json 内容（含回填后的指标）
        let data = try JSONSerialization.data(withJSONObject: json)
        return try TranslationState.validated(from: data)
    }

    /// §4.10 `verify`：合规校验（不通过退 5 → 返回 compliant=false，不抛错）。
    func verify(check: String = "all") throws -> ComplianceResult {
        let json = try runJSON(["verify", "--state", stateDir.path, "--check", check],
                               allowExitCodes: [0, 5])
        return ComplianceResult(compliant: json["compliant"] as? Bool ?? false,
                                missingPreExtract: json["missing_pre_extract"] as? [Int] ?? [],
                                outOfOrder: json["out_of_order"] as? [Int] ?? [],
                                checks: json["checks"] as? [String: Bool] ?? [:])
    }

    /// §4.10 `event`：追加一条事件（Agent 手工补事件用）。
    @discardableResult
    func appendEvent(type: String, chunk: Int? = nil, stage: String? = nil,
                     kv: [String: String] = [:]) throws -> Int {
        var args = ["event", "--state", stateDir.path, "--type", type]
        if let chunk { args += ["--chunk", "\(chunk)"] }
        if let stage { args += ["--stage", stage] }
        for (k, v) in kv.sorted(by: { $0.key < $1.key }) {
            args += ["--kv", "\(k)=\(v)"]
        }
        let json = try runJSON(args)
        return json["seq"] as? Int ?? 0
    }

    /// §4.10 `reset`：重置状态目录。
    func reset(archive: Bool = false, keepGlossary: Bool = false) throws -> String {
        var args = ["reset", "--state", stateDir.path]
        if archive { args += ["--archive"] }
        if keepGlossary { args += ["--keep-glossary"] }
        let json = try runJSON(args)
        return json["archive"] as? String ?? ""
    }
}
