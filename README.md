# 日文 PDF 转译

一款面向 macOS 用户的日文文档 OCR、翻译与 PDF 生成工具。

它可以从日文 PDF、TXT、JSON、XML、DOC 或 DOCX 中提取文字，通过 WorkBuddy
或兼容 OpenAI Chat Completions 的模型 API 翻译为中文，并生成便于阅读和保存的 PDF。

[下载最新版本](../../releases/latest)

## 主要功能

- 识别扫描版和图片型日文 PDF。
- 支持 PDF、TXT、JSON、XML、DOC、DOCX。
- 支持竖排、横排及包含复杂版面的日文资料。
- 可选择 WorkBuddy 或大模型 API 翻译。
- API 模式可使用不同服务商和模型，不绑定特定品牌。
- 支持用户术语表和自动术语整理。
- 自动检查漏译、段落对齐、标点和术语一致性。
- 支持长文分块、断点续跑和任务恢复。
- 生成中文版、日文原文版；WorkBuddy 模式还可生成双语对照版。
- 日志与输入、选项和进度位于同一个滚动页面，任务运行时自动显示最新内容。

## 系统要求

| 项目 | 要求 |
|---|---|
| 操作系统 | macOS 14 Sonoma 或更高版本 |
| 处理器 | Apple Silicon 或 Intel |
| 磁盘空间 | 建议至少预留 2GB |
| 内存 | 建议 8GB 以上；大型 PDF 建议 16GB |
| Python | 3.9 或更高版本 |
| 网络 | 首次准备 OCR 环境、使用云端模型时需要 |

发布包是 Universal 2 应用，可在 Apple Silicon 和 Intel Mac 上原生运行。

## 安装

### 1. 下载应用

前往 [Releases](../../releases/latest)，下载：

`JaPdfOcrTranslator-macOS-release.zip`

解压后，将 `JaPdfOcrTranslator.app` 拖入“应用程序”文件夹。

### 2. 首次打开

如果 macOS 阻止打开：

1. 在 Finder 中右键应用。
2. 选择“打开”。
3. 在确认窗口中再次选择“打开”。

如果仍无法启动，请进入“系统设置 → 隐私与安全性”，在页面底部允许打开该应用。

仅在你确认文件来自本仓库 Release 时，也可以在终端执行：

```bash
xattr -dr com.apple.quarantine /Applications/JaPdfOcrTranslator.app
```

### 3. 安装 Python

推荐通过 Homebrew 安装：

```bash
brew install python
```

也可以使用 [Python 官方 macOS 安装包](https://www.python.org/downloads/macos/)。

安装完成后打开应用，进入：

“设置 → OCR 引擎 → 检查 / 修复 Python 环境”

应用会创建自己的虚拟环境，不会修改其他 Python 项目。首次准备需要下载 OCR 运行依赖，
通常需要数分钟。

## 快速开始

1. 打开“日文 PDF 转译”。
2. 选择输入文件。
3. 选择输出目录。
4. 点击右上角“设置”，选择翻译方式。
5. 根据所选方式完成配置。
6. 返回主窗口，点击“开始翻译”。
7. 等待 OCR、翻译和 PDF 生成完成。

任务完成后，应用会自动打开中文 PDF。

## 选择翻译方式

### WorkBuddy

适合已经安装 WorkBuddy 的用户。

需要设置：

- WorkBuddy 应用路径。
- WorkBuddy 中使用的模型。
- 是否生成双语对照 PDF。

OCR 完成后，应用会显示任务核对窗口。确认后会打开 WorkBuddy，并预填：

- 翻译 skill；
- 完整任务提示词；
- OCR 文本文件路径；
- 输出目录和目标文件。

请在 WorkBuddy 中检查内容，然后手动点击“发送”。

### 大模型 API

适合希望直接调用模型服务的用户。接口需要兼容 OpenAI Chat Completions 格式。

需要设置：

- API 地址，例如 `https://api.example.com/v1`；
- API Key，本地免密服务可以留空；
- 模型名称，即服务商提供的模型 ID。

API 地址也可以直接填写完整的 `/chat/completions` 地址，应用不会重复拼接路径。

高级设置中可以分别填写低成本模型和快速模型。留空时会自动使用主模型。
如果服务不接受额外的思考参数，请将“推理参数格式”设置为“不附加”。

## 术语表

术语表使用 CSV 文件，最简单的格式为两列：

```csv
日语,中文
御堂 静,御堂静
桜坂,樱坂
```

可在主窗口选择术语表，也可以点击“编辑术语表”直接维护内容。

如果没有术语表，可以启用“自动生成/补充术语表”。程序会在翻译过程中收集人名、地名、
组织名、物品名和作品内专有名词，并尽量保持全书一致。

## 翻译质量选项

设置页提供三种预设：

- 快速：减少分析步骤，适合短文或快速预览。
- 标准：平衡速度、费用和质量。
- 精译：使用更细的分块和更多上下文，适合小说及长篇资料。

还可以单独控制：

- 全书预扫；
- 样本风格分析；
- 标点规范化；
- 一致性检查；
- 润色；
- 断点续跑；
- 每个翻译分块的字符数。

## 输出文件

假设输入文件名为 `book.pdf`，程序通常会生成：

| 文件 | 内容 |
|---|---|
| `book_zh.pdf` | 中文译文 |
| `book_ja.pdf` | 日文原文 |
| `book_bi.pdf` | 中日双语对照，仅 WorkBuddy 双语模式 |
| `state/` | 任务进度、分块、术语、报告和断点数据 |

请不要在任务运行期间移动或删除输出目录中的 `state` 文件夹。

## 中止与继续

- 点击“中止”可以停止当前任务。
- 再次使用相同输入、输出目录和主要参数开始任务时，程序会尝试从未完成部分继续。
- 如果输入文件或关键参数发生变化，程序会提示继续、归档旧状态或取消。
- 关闭主窗口会直接退出应用。

## OCR 说明

应用内置 NDLOCR-Lite 模型，用于检测版面、识别日文并恢复阅读顺序。
OCR 在本机完成，原始 PDF 不会因为 OCR 被上传。

首次使用时，应用会在以下位置创建 Python 虚拟环境：

`~/Library/Application Support/JaPdfOcrTranslator/venv`

如果环境损坏，可以退出应用，删除该 `venv` 文件夹，再通过“检查 / 修复 Python 环境”重新创建。

## 数据与隐私

- OCR 和 PDF 排版在本机完成。
- WorkBuddy 模式的数据去向由 WorkBuddy 及其中选择的模型决定。
- API 模式会把待译文本发送到用户填写的 API 服务。
- API Key 不写入运行日志。
- 输出目录中的 `state` 包含原文和译文分块，分享目录前请检查其中是否有敏感内容。

## 常见问题

### 应用提示“无法验证开发者”

使用 Finder 右键“打开”，或到“系统设置 → 隐私与安全性”允许打开。公开下载时务必确认文件来自本仓库。

### 找不到 Python

确认已经安装 Python 3.9+：

```bash
python3 --version
```

然后在设置中选择正确的 Python 解释器，运行“检查 / 修复 Python 环境”。

### OCR 依赖安装失败

- 检查网络连接。
- 建议使用 Python 3.11 或 3.12。
- 确认磁盘空间充足。
- 删除应用虚拟环境后重新修复。

### OCR 很慢或占用较多内存

高分辨率页面和大型 PDF 会增加时间和内存消耗。可以先拆分 PDF，或关闭其他大型应用后重试。

### WorkBuddy 打开了，但没有预填内容

- 更新到支持 `workbuddy://` 任务链接的 WorkBuddy 版本。
- 确认设置中的 WorkBuddy 路径正确。
- 在 macOS 中确认 `workbuddy://` 链接由 WorkBuddy 打开。

### API 返回 401 或 403

API Key 无效、账户无权限或模型未开通。请在服务商后台确认 Key 和模型权限。

### API 返回 404

优先填写服务根地址，例如 `https://api.example.com/v1`。如果服务商要求特殊路径，也可以填写完整
`/chat/completions` 地址。

### API 拒绝 thinking 或 reasoning 参数

在“高级设置”中将“推理参数格式”改为“不附加”。

### 翻译过程中网络中断

保留原输出目录，恢复网络后重新开始同一任务。启用断点续跑时会尽量跳过已经完成的分块。

### 日志越来越多

日志与主界面的其他内容共用同一个滚动页面。新增日志时页面会自动滚动到最新内容；
向上滚动即可同时浏览任务设置、进度和较早的日志，不存在独立的日志窗口或分隔区域。

## 致谢

本应用使用或参考了以下开源项目与系统能力：

- [NDLOCR-Lite](https://github.com/ndl-lab/ndlocr-lite)，由国立国会图书馆 NDL Lab 发布；
- [PARSeq](https://github.com/baudm/parseq) 文字识别模型；
- DEIM 系列目标检测方法；
- ONNX Runtime、OpenCV、NumPy、Pillow、PyYAML、NetworkX、lxml、pypdfium2、pypdf；
- Apple Swift、SwiftUI、AppKit、PDFKit 与 Core Text。

相关组件及模型遵循各自的许可证。NDLOCR-Lite 由国立国会图书馆以
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) 发布。

## 已知限制

- 需要 macOS 14 或更高版本。
- 首次 OCR 环境准备需要安装 Python 并联网下载依赖。
- 模型 API 必须兼容 OpenAI Chat Completions 请求和响应结构。
- 双语 PDF 当前仅在 WorkBuddy 模式提供。
- 未完成 Apple 公证的构建在其他 Mac 上首次打开时可能出现安全提示。
