import Foundation

/// Translation prompt construction（DESIGN §7.2 / F33-05 / T04-i）。
///
/// v3.3 变更：
/// - `systemCore` 删除旧版「默认禁止自动建表」硬编码（F33-05 判据：全仓 grep 旧文案命中 0）；
/// - 删除 `glossaryDirective` / `glossaryAbsentHint`（硬编码术语表指令）；
/// - `buildTranslationSystemPrompt` 改签名：接 `policy: GlossaryPolicy, glossaryBlock: String`，
///   策略段由 `GlossaryPolicy.promptText` 注入（与 Python `render --policy` 逐字一致）；
/// - 新增 DS 后端 S2/S3/S4 用的五段提示词：`digestPrompt` / `synopsisPrompt` / `stylePrompt` /
///   `preExtractPrompt` / `postExtractPrompt`。
enum TranslationPrompts {
    /// The built-in default system prompt（五大铁律）。也用作自定义提示词编辑器的基线。
    static let systemCore = """
    你是一位专业的日文中译翻译。请将用户提供的日语文本完整、忠实地翻译为简体中文。

    【五大铁律】
    1. 忠实准确、尊重原文：不增删、不篡改、不"雅化性"改写；允许直白、粗俗、露骨或冒犯性表述照译，不得回避或淡化。
    2. 通俗易懂：译文用现代普通话，明白晓畅；避免晦涩文言、生僻词、过度复杂的长难句。
    3. 保格式：序号、标记符、占位符、换行符、转义符、代码调用过程等特殊内容原样保留，只替换日语自然语言。
    4. 句子完整：绝不在一个完整句子中间断开翻译。
    5. 整篇交付：逐块翻译后由调用方合并，最终交付完整中文译文。

    【翻译原则】
    - 逐句、逐段翻译，不漏译、不跳段、不概括性省略。
    - 学术 / 技术文本中的术语、定义、数据、公式必须精确对应。
    - 先通读再译，把握语气、大意、氛围。

    【禁止事项】
    - 不要添加"以下是翻译""译者注"之类的开场白或总结。
    - 不要在译文里混入日文原文（双语对照由调用方统一处理）。
    """

    /// 构建系统提示词（F16：custom/skill prompt 覆盖 core）。
    /// - Parameters:
    ///   - policy: 术语表策略（策略段由 `GlossaryPolicy.promptText` 注入）。
    ///   - glossaryBlock: 已渲染好的术语段（`Glossary.toPromptBlock` 或 `glossary_tool hits/render` 输出）；
    ///     空串表示无术语段，不追加。
    ///   - skillPrompt: 自定义/skill 提示词；为空时用内置 `systemCore`。
    static func buildTranslationSystemPrompt(policy: GlossaryPolicy,
                                             glossaryBlock: String,
                                             skillPrompt: String? = nil) -> String {
        let core = (skillPrompt?.isEmpty == false) ? skillPrompt! : systemCore
        var parts = [core]
        parts.append("")
        parts.append(policy.promptText)
        if !glossaryBlock.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("")
            parts.append(glossaryBlock)
        }
        return parts.joined(separator: "\n")
    }

    /// 构建单块用户提示词。
    static func buildTranslationUserPrompt(_ chunk: String) -> String {
        "请将以下日语文本翻译为简体中文（仅返回该段中文译文，不要开场白、" +
        "不要夹带日文、不要自我总结）：\n\n" + chunk
    }

    // MARK: - DS 后端 S2/S3/S4 提示词（T04-i）

    /// S2 单块梗概：≤200 字中文梗概。
    static func digestPrompt(chunk: String) -> String {
        "请用简体中文写出这段日文的中文梗概，不超过 200 字，只输出梗概正文：\n\n" + chunk
    }

    /// S2 全书梗概：依据归并包写 ≤800 字全书梗概。
    static func synopsisPrompt(digestPacks: String) -> String {
        "以下是全书各段的中文梗概归并包。请通读后写出全书的中文梗概，不超过 800 字，" +
        "覆盖主要人物、事件脉络与主题，只输出梗概正文：\n\n" + digestPacks
    }

    /// S3 风格指南：依据抽样包归纳六字段风格指南（见 references/style_guide_template.md）。
    static func stylePrompt(samplePack: String) -> String {
        "以下是原文抽样（前/中/后各段）。请按六个字段归纳翻译风格：体裁 / 语气 / 叙事人称 / " +
        "句式节奏 / 语域 / 对话风格。每个字段给 1–3 句结论并附一个抽样例句。无法判断的字段写" +
        "「未观察到明显特征」。只输出风格指南正文：\n\n" + samplePack
    }

    /// S4 ①译前预抽：从源文抽取候选术语（输出 JSON `{"terms":[…]}`）。
    static func preExtractPrompt(chunk: String, glossarySummary: String) -> String {
        "你是术语抽取器。从下面的日文源文中抽取应当入表的专名与术语，输出 JSON 数组格式：" +
        "{\"terms\":[{\"source\":\"原文\",\"target\":\"中文译名\",\"type\":\"人物|地名|组织|术语|招式|物品|称谓|敬称|口癖|固定表达|其他\"}]}。" +
        "已存在的术语表摘要如下（同 source 请沿用现值，不要提出新译名）：\n\(glossarySummary)\n\n源文：\n" + chunk
    }

    /// S4 ④译后回抽：依据「原文 + 译文」校准实际采用的译名（输出 JSON `{"terms":[…]}`）。
    static func postExtractPrompt(source: String, translation: String, glossarySummary: String) -> String {
        "你是术语回抽器。对照下面的日文原文与中文译文，找出译文中实际采用的专名译法，输出 JSON 数组格式：" +
        "{\"terms\":[{\"source\":\"原文\",\"target\":\"译文实际写法\",\"type\":\"...\"}]}。" +
        "已存在的术语表摘要如下（同 source 且已锁定请跳过）：\n\(glossarySummary)\n\n原文：\n" + source + "\n\n译文：\n" + translation
    }
}
