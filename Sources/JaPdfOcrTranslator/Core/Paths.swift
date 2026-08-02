import Foundation

/// Cross-module path conventions (port of ``core/paths.py``).
enum Paths {
    static let skillName = "jp-txt2pdf-translator"

    /// Built-in skill bundled inside the app resources.
    ///
    /// The skill is copied as a **whole directory** via
    /// `.copy("Resources/skills/jp-txt2pdf-translator")` in Package.swift.
    /// SPM strips the `Resources/skills/` prefix (exactly the way
    /// `ndlocr_lite` ends up at `Contents/Resources/ndlocr_lite`), so the
    /// directory is reachable by name directly at the bundle root as
    /// `jp-txt2pdf-translator`. This matches the proven lookup in
    /// `OcrEngine` (`Bundle.module.url(forResource: "ndlocr_lite", ...)`).
    /// 跨打包方式健壮地解析内嵌资源（目录或文件）。
    ///
    /// 兼容以下场景，确保 `swift run` / Xcode Run 与 `make-app.sh` 打出的独立
    /// `.app` 都能正确找到资源（skill / ndlocr_lite / ocr_driver.py / requirements.txt）：
    /// 1. `Bundle.module` 可用（SPM 生成的权威路径，优先使用）；
    /// 2. 独立 `.app`：`Contents/Resources/<任意>.resources/` 或 `<任意>.bundle/...`；
    /// 3. 扁平 / 绝对路径布局兜底。
    ///
    /// 不假设具体命名（如 `JaPdfOcrTranslator.resources` 或
    /// `JaPdfOcrTranslator_JaPdfOcrTranslator.bundle`），而是**扫描**已知根目录下
    /// 所有 `.resources` / `.bundle` 容器，因此对任意 SwiftPM 版本都兼容。
    static func bundledResource(name: String, ext: String? = nil) -> URL? {
        let fm = FileManager.default
        let nameWithExt = ext.map { "\(name).\($0)" } ?? name

        // 1) 首选：SPM 生成的 Bundle.module（权威，覆盖绝大多数布局）
        #if SWIFT_PACKAGE
        if let u = Bundle.module.url(forResource: name, withExtension: ext) { return u }
        #endif

        // 2) 兜底：扫描已知根目录下的任意 *.resources / *.bundle 容器。
        let appBundle = Bundle.main.bundleURL
        let exeDir = (Bundle.main.executableURL?.deletingLastPathComponent()) ?? appBundle
        let roots: [URL] = [
            appBundle.appendingPathComponent("Contents/Resources"),
            appBundle.appendingPathComponent("Contents/MacOS"),
            exeDir,
            Bundle.main.resourceURL,
        ].compactMap { $0 }

        var containers: [URL] = []
        for root in roots {
            guard let subs = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for sub in subs where sub.pathExtension == "resources" || sub.pathExtension == "bundle" {
                containers.append(sub)
            }
        }

        for container in containers {
            let candidates = [
                container.appendingPathComponent(nameWithExt),
                container.appendingPathComponent(name),
                container.appendingPathComponent("Contents/Resources/\(nameWithExt)"),
                container.appendingPathComponent("Contents/Resources/\(name)"),
            ]
            for c in candidates where fm.fileExists(atPath: c.path) { return c }
        }
        return nil
    }

    static func builtinSkillDir() -> URL {
        if let dir = bundledResource(name: skillName),
           FileManager.default.fileExists(atPath: dir.appendingPathComponent("SKILL.md").path) {
            return dir
        }
        // Fallback for `swift run` invoked from the package root.
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/JaPdfOcrTranslator/Resources/skills/\(skillName)")
    }

    static func builtinSkillScriptsDir() -> URL {
        builtinSkillDir().appendingPathComponent("scripts")
    }

    /// User-side skill directory where WorkBuddy looks it up by name.
    static func userSkillDir() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".workbuddy")
            .appendingPathComponent("skills")
            .appendingPathComponent(skillName)
    }

    static func registryRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".workbuddy")
            .appendingPathComponent("skills")
    }

    /// Compute the three PDF output paths for a run.
    struct PdfPaths: Sendable {
        let zh: URL
        let ja: URL
        let bi: URL?
    }

    static func pdfPaths(outDir: URL, stem: String, bilingual: Bool) -> PdfPaths {
        PdfPaths(
            zh: outDir.appendingPathComponent("\(stem)_zh.pdf"),
            ja: outDir.appendingPathComponent("\(stem)_ja.pdf"),
            bi: bilingual ? outDir.appendingPathComponent("\(stem)_bi.pdf") : nil
        )
    }

    // MARK: - v3.3 · state 契约目录

    /// v3.3 契约目录：`<outDir>/state/`（DESIGN §3.1，决策 D4 —— 不做 slug 子目录）。
    ///
    /// 该目录是 Swift 侧与 python skill 脚本共享的唯一契约面，两端都只能通过
    /// 这个入口拼路径，禁止在别处硬编码 `"state"` 字面量。
    static func stateDir(outDir: URL) -> URL {
        outDir.appendingPathComponent("state")
    }

    /// 块文件路径：`<state>/chunks/chunk_NNN.txt` 或 `chunk_NNN_zh.txt`。
    ///
    /// 编号规则（DESIGN §10.1）：**1-based、三位补零**。JSON 里的 `chunk` 字段
    /// 仍是 int（`13`），只有文件名补零。
    ///
    /// - Parameters:
    ///   - state: `stateDir(outDir:)` 的返回值。
    ///   - index: 1-based 块号。
    ///   - zh: `true` 取译文块，`false` 取日文源块。
    static func chunkFile(state: URL, index: Int, zh: Bool) -> URL {
        let name = String(format: "chunk_%03d%@.txt", index, zh ? "_zh" : "")
        return state.appendingPathComponent("chunks").appendingPathComponent(name)
    }

    /// 块梗概路径：`<state>/digests/chunk_NNN.md`。
    static func digestFile(state: URL, index: Int) -> URL {
        let name = String(format: "chunk_%03d.md", index)
        return state.appendingPathComponent("digests").appendingPathComponent(name)
    }

    /// skill 脚本目录：**优先 registry**（`~/.workbuddy/skills/<skill>/scripts`），
    /// 回退到应用内置 bundle（`builtinSkillScriptsDir()`）。
    ///
    /// 优先 registry 的原因：Agent 实际执行的是 registry 里那一份，Swift 侧调用
    /// 同一份脚本才能保证两个后端的行为完全一致。只有 registry 尚未同步（首次启动、
    /// 写入失败）时才回退内置副本。
    static func skillScriptsDir() -> URL {
        let registry = userSkillDir().appendingPathComponent("scripts")
        if FileManager.default.fileExists(atPath: registry.appendingPathComponent("_common.py").path) {
            return registry
        }
        return builtinSkillScriptsDir()
    }

    /// 指定 skill 的脚本目录（已知 `SkillInfo` 时使用，语义同上）。
    static func skillScriptsDir(for info: SkillInfo) -> URL {
        let registry = SkillRegistry.registryDir(of: info).appendingPathComponent("scripts")
        if FileManager.default.fileExists(atPath: registry.appendingPathComponent("_common.py").path) {
            return registry
        }
        return builtinSkillScriptsDir()
    }

    /// 运行 skill 脚本用的 python 解释器。
    ///
    /// 优先 `settings.pythonInterpreterPath`（用户配置 / WorkBuddy 托管 venv），
    /// 回退系统 `/usr/bin/python3`。脚本本身零第三方依赖，任何 3.9+ 解释器都能跑。
    static func pythonForScripts(settings: Settings) -> String {
        let configured = settings.pythonInterpreterPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty, configured != "python3",
           FileManager.default.isExecutableFile(atPath: configured) {
            return configured
        }
        return "/usr/bin/python3"
    }

    // MARK: - v3.3-llm 路径（DESIGN-v3.3-llm §3.1）

    /// `<state>/llm_config.json` —— 单次运行的 LLM 配置快照（含 api_key，权限 0600）。
    static func llmConfigURL(stateDir: URL) -> URL {
        stateDir.appendingPathComponent("llm_config.json")
    }

    /// `<state>/usage.json` —— LLM 用量累计（totals + by_tier + by_stage）。
    static func usageURL(stateDir: URL) -> URL {
        stateDir.appendingPathComponent("usage.json")
    }
}
