// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "JaPdfOcrTranslator",
    platforms: [
        .macOS("14.0")
    ],
    products: [
        .executable(name: "JaPdfOcrTranslator", targets: ["JaPdfOcrTranslator"])
    ],
    targets: [
        .executableTarget(
            name: "JaPdfOcrTranslator",
            path: "Sources/JaPdfOcrTranslator",
            exclude: [
                // Python 运行缓存与机器相关，不应进入可分发应用。
                "Resources/skills/jp-txt2pdf-translator/scripts/__pycache__"
            ],
            resources: [
                // 内置 skill：复制整个目录（与 ndlocr_lite 一致），
                // 落地为 Contents/Resources/jp-txt2pdf-translator/，
                // 才能被 Paths.builtinSkillDir() 以目录名直接解析。
                // 注意：复制单个文件会被 SPM 拍扁到 bundle 根目录，
                // 导致 skills/jp-txt2pdf-translator/ 子目录不存在。
                .copy("Resources/skills/jp-txt2pdf-translator"),
                // ndlocr-lite OCR 引擎：原始 vendored 源码 + 4 个 ONNX 权重 + 配置
                .copy("Resources/ndlocr_lite"),
                // 子进程驱动脚本：调用 ndlocr-lite 并合并 ja_combined.txt
                .copy("Resources/ocr_driver.py"),
                // OCR 依赖清单：首次运行若本机缺依赖，自动建 venv 用此文件 pip install
                .copy("Resources/requirements.txt")
            ]
        )
    ]
)
