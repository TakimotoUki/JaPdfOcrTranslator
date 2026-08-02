#!/usr/bin/env bash
# ============================================================
#  把 SPM 可执行包打包成可双击的 独立 .app（含资源与 Info.plist）
#  用法：
#    ./make-app.sh                         # release 通用包（arm64 + x86_64，默认）
#    ./make-app.sh debug --native          # 当前架构调试包
#    ./make-app.sh release --no-sandbox    # 受管环境
#  产物：build/JaPdfOcrTranslator.app
#
#  说明：
#  - 仅依赖 Xcode 命令行工具 / swift 工具链，无需在 Xcode GUI 里 Run。
#  - SwiftPM 把可执行 target 的资源（skills / ndlocr_lite / ocr_driver.py / requirements.txt）
#    打包后放在 .build/<config>/ 下，目录名随 SwiftPM 版本不同可能是
#    <TargetName>.resources（资源在目录根）或 <TargetName>.bundle（资源在
#    <bundle>/Contents/Resources/ 下，Xcode 27 / Swift 6.4 实测为此种）。
#    打包时保留这层目录名、整体复制进 .app/Contents/Resources/，SPM 生成的
#    Bundle.module / 扫描式兜底才能正确解析内嵌资源（拍平复制会导致资源全部找不到）。
# ============================================================
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="JaPdfOcrTranslator"
PRODUCT="$APP_NAME"
APP_VERSION="3.3.1"
# 用法：./make-app.sh [debug|release] [--universal|--native] [--no-sandbox]
#   --no-sandbox：把 --disable-sandbox 传给 SwiftPM。默认不开（保持 SwiftPM 沙箱）。
#   仅用于受管/沙箱化 CI 环境（本机工具沙箱会拒绝 SwiftPM 的 sandbox-exec）。
CONFIG="release"
UNIVERSAL=1
BUILD_ARGS=()
for arg in "$@"; do
    case "$arg" in
        debug|release) CONFIG="$arg" ;;
        --no-sandbox) BUILD_ARGS+=("--disable-sandbox") ;;
        --universal) UNIVERSAL=1 ;;
        --native) UNIVERSAL=0 ;;
        *)
            echo "❌ 未知参数：$arg"
            echo "用法：$0 [debug|release] [--universal|--native] [--no-sandbox]"
            exit 2
            ;;
    esac
done
ARCH_ARGS=()
if [ "$UNIVERSAL" -eq 1 ]; then
    ARCH_ARGS=("--arch" "arm64" "--arch" "x86_64")
else
    ARCH_ARGS=("--arch" "$(uname -m)")
fi

# macOS 自带 Bash 3.2 在 `set -u` 下展开空数组会报 unbound variable。
# 把必选参数与可选参数合并为始终非空的数组，保证本机和 GitHub Actions
# 使用相同命令路径。
SWIFT_BUILD_ARGS=("-c" "$CONFIG" "${ARCH_ARGS[@]}")
if [ "${#BUILD_ARGS[@]}" -gt 0 ]; then
    SWIFT_BUILD_ARGS+=("${BUILD_ARGS[@]}")
fi

# ─────────────────────────────────────────────────────────────
# 关键：必须使用「完整 Xcode」的工具链构建，不能用 Command Line Tools。
# SwiftUI 的 @State/@Observable 等宏的实现（SwiftUIMacros 插件）
# 只随 Xcode 的 SDK 提供；用 CLT 的 `swift build` 会报
# "plugin for module 'SwiftUIMacros' not found"，导致 @State 无法展开、
# 进而连锁出一堆 cannot assign to 'self' 错误。
# 因此这里用多种策略定位完整 Xcode，并把 DEVELOPER_DIR 指向它；
# 若实在找不到，则直接报错退出，避免用 CLT 做注定失败的构建。
# ─────────────────────────────────────────────────────────────

detect_xcode_developer_dir() {
    # 1) 当前 xcode-select 指向的若是 Xcode，直接用
    local sel
    sel=$(xcode-select -p 2>/dev/null || true)
    if [ -n "$sel" ] && [[ "$sel" == *"Xcode.app"* ]]; then
        echo "$sel"
        return 0
    fi
    # 2) 常见安装位置
    local candidates=(
        "/Applications/Xcode.app/Contents/Developer"
        "/Applications/Xcode-beta.app/Contents/Developer"
    )
    local c
    for c in "${candidates[@]}"; do
        if [ -d "$c" ]; then echo "$c"; return 0; fi
    done
    # 3) Spotlight 兜底（适合装在非标准路径的情况）
    local found
    found=$(mdfind "kMDItemFSName == 'Xcode.app'" 2>/dev/null | head -1 || true)
    if [ -n "$found" ] && [ -d "$found/Contents/Developer" ]; then
        echo "$found/Contents/Developer"
        return 0
    fi
    return 1
}

if [ -z "${DEVELOPER_DIR:-}" ]; then
    if XC=$(detect_xcode_developer_dir); then
        export DEVELOPER_DIR="$XC"
    else
        echo "❌ 未找到完整 Xcode（SwiftUI 宏插件 SwiftUIMacros 仅随 Xcode 提供，Command Line Tools 不含）。"
        echo "   请先安装 Xcode，或执行以下任一操作后再运行本脚本："
        echo "     • sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
        echo "     • export DEVELOPER_DIR=/你的/Xcode.app/Contents/Developer"
        exit 1
    fi
fi
echo "▶ 使用 Xcode toolchain: $DEVELOPER_DIR"

ARCH_LABEL="当前架构"
if [ "$UNIVERSAL" -eq 1 ]; then ARCH_LABEL="arm64 + x86_64"; fi
echo "▶ 构建 $PRODUCT ($CONFIG, $ARCH_LABEL) [toolchain: $(xcrun xcodebuild -version 2>/dev/null | head -1 || echo '?')]…"
xcrun swift build "${SWIFT_BUILD_ARGS[@]}"
BUILD_DIR=$(xcrun swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▶ 拷贝可执行文件…"
cp "$BUILD_DIR/$PRODUCT" "$APP/Contents/MacOS/$PRODUCT"

echo "▶ 拷贝 SwiftPM 打包资源（skills / ndlocr_lite / ocr_driver.py / requirements.txt）…"
# 资源容器名可能是 <TargetName>.resources 或 <TargetName>.bundle（见顶部说明）。
# 关键：以「目录」为单位整体复制进 Contents/Resources/，保留这层目录名——SPM 生成的
# Bundle.module / 扫描式兜底才能正确解析内嵌资源；拍平复制（cp -R "$RESDIR/."）会丢失
# 目录名，导致独立 .app 内所有内嵌资源全部找不到。
# 注意：shell 开启 nullglob，使未匹配的 glob 直接展开为空（而非字面量），保证两种扩展名都能安全遍历。
copied=0
shopt -s nullglob
for RESDIR in "$BUILD_DIR"/*.resources "$BUILD_DIR"/*.bundle; do
    [ -d "$RESDIR" ] || continue
    cp -R "$RESDIR" "$APP/Contents/Resources/"
    echo "    来自 $RESDIR"
    copied=$((copied+1))
done
shopt -u nullglob
if [ "$copied" -eq 0 ]; then
    echo "    ⚠️ 在 $BUILD_DIR 下既未找到 .resources 也未找到 .bundle，请确认 Package.swift 已声明 .copy(...) 资源"
fi
# `.copy` 会保留目录内生成的缓存；分发前移除机器相关字节码。
find "$APP/Contents/Resources" -type d -name __pycache__ -prune -exec rm -rf {} +
find "$APP/Contents/Resources" -type f -name '*.pyc' -delete

echo "▶ 生成 Info.plist…"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>         <string>日文 PDF 转译</string>
    <key>CFBundleIdentifier</key>          <string>com.workbuddy.JaPdfOcrTranslator</string>
    <key>CFBundleVersion</key>             <string>$APP_VERSION</string>
    <key>CFBundleShortVersionString</key>  <string>$APP_VERSION</string>
    <key>CFBundleExecutable</key>          <string>$PRODUCT</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>LSMinimumSystemVersion</key>      <string>14.0</string>
    <key>NSHighResolutionCapable</key>     <true/>
    <key>NSPrincipalClass</key>            <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "▶ 签名应用…"
SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
/usr/bin/codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"

if [ "$UNIVERSAL" -eq 1 ]; then
    echo "▶ 校验通用架构…"
    ARCHS=$(lipo -archs "$APP/Contents/MacOS/$PRODUCT")
    if [[ " $ARCHS " != *" arm64 "* ]] || [[ " $ARCHS " != *" x86_64 "* ]]; then
        echo "❌ 通用包架构不完整：$ARCHS"
        exit 1
    fi
fi

ZIP="build/${APP_NAME}-macOS-${CONFIG}.zip"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "✅ 已生成 $APP"
echo "✅ 分发压缩包：$ZIP"
echo "   架构：$(lipo -archs "$APP/Contents/MacOS/$PRODUCT")"
echo "   运行：open \"$APP\"   或拖入 /Applications 后从启动台打开"
