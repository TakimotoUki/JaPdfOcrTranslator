import AppKit
import CoreGraphics
import CoreText
import Foundation

/// Native PDF builder (port of `pdf/builder.py` + `scripts/build_pdf.py`).
///
/// Produces the three output variants via Core Text pagination:
///  - 译文版 `*_zh.pdf` (Chinese translation)
///  - 原文版 `*_ja.pdf` (Japanese original)
///  - 双语版 `*_bi.pdf` (interleaved original + translation, when enabled)
struct PdfBuilder {
    // A4 in points.
    private let pageWidth: CGFloat = 595.28
    private let pageHeight: CGFloat = 841.89
    private let margin: CGFloat = 56
    private let footerHeight: CGFloat = 28

    private let zhFont: CTFont
    private let jaFont: CTFont
    private let titleFont: CTFont

    init() {
        self.zhFont = CTFontCreateWithName("PingFang SC" as CFString, 11, nil)
        self.jaFont = CTFontCreateWithName("Hiragino Sans" as CFString, 11, nil)
        self.titleFont = CTFontCreateWithName("PingFang SC" as CFString, 18, nil)
    }

    // MARK: - Public API (mirrors build_translation / build_original / build_bilingual)

    func buildTranslation(_ inURL: URL, _ outURL: URL, title: String = "", author: String = "", date: String = "") throws {
        let text = try String(contentsOf: inURL, encoding: .utf8)
        let attr = attributedBody(text, font: zhFont, title: title, author: author, date: date, gray: false)
        try render(attr, to: outURL)
    }

    func buildOriginal(_ inURL: URL, _ outURL: URL, title: String = "", author: String = "", date: String = "") throws {
        let text = try String(contentsOf: inURL, encoding: .utf8)
        let attr = attributedBody(text, font: jaFont, title: title, author: author, date: date, gray: false)
        try render(attr, to: outURL)
    }

    func buildBilingual(_ translationURL: URL, _ originalURL: URL, _ outURL: URL,
                        title: String = "", author: String = "", date: String = "") throws {
        let zh = try String(contentsOf: translationURL, encoding: .utf8)
        let ja = try String(contentsOf: originalURL, encoding: .utf8)
        let attr = attributedBilingual(original: ja, translation: zh, title: title, author: author, date: date)
        try render(attr, to: outURL)
    }

    // MARK: - Attributed string construction

    private func bodyParagraphStyle() -> NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.alignment = .justified
        ps.firstLineHeadIndent = 22
        ps.lineSpacing = 4
        ps.paragraphSpacing = 6
        return ps
    }

    private func attributedBody(_ text: String, font: CTFont, title: String,
                                author: String, date: String, gray: Bool) -> NSAttributedString {
        let paras = text.split(separator: "\n").map { String($0) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let ps = bodyParagraphStyle()
        let color = gray ? NSColor.systemGray : NSColor.textColor
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: font as Any,
            .paragraphStyle: ps,
            .foregroundColor: color
        ]
        var result = NSMutableAttributedString()
        appendTitleBlock(&result, title: title, author: author, date: date)
        for p in paras {
            let s = NSAttributedString(string: p + "\n", attributes: baseAttrs)
            result.append(s)
        }
        return result
    }

    private func attributedBilingual(original: String, translation: String,
                                     title: String, author: String, date: String) -> NSAttributedString {
        let origParas = original.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let transParas = translation.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let ps = bodyParagraphStyle()

        let origAttrs: [NSAttributedString.Key: Any] = [
            .font: jaFont as Any,
            .paragraphStyle: ps,
            .foregroundColor: NSColor.systemGray
        ]
        let transAttrs: [NSAttributedString.Key: Any] = [
            .font: zhFont as Any,
            .paragraphStyle: ps,
            .foregroundColor: NSColor.textColor
        ]
        var result = NSMutableAttributedString()
        appendTitleBlock(&result, title: title, author: author, date: date)

        let n = max(origParas.count, transParas.count)
        for i in 0..<n {
            if i < origParas.count {
                result.append(NSAttributedString(string: origParas[i] + "\n", attributes: origAttrs))
            }
            if i < transParas.count {
                result.append(NSAttributedString(string: transParas[i] + "\n", attributes: transAttrs))
            }
        }
        return result
    }

    private func appendTitleBlock(_ result: inout NSMutableAttributedString, title: String, author: String, date: String) {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let titlePS = NSMutableParagraphStyle()
        titlePS.alignment = .center
        titlePS.paragraphSpacing = 10
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: titleFont as Any,
            .paragraphStyle: titlePS,
            .foregroundColor: NSColor.textColor
        ]
        result.append(NSAttributedString(string: title + "\n", attributes: titleAttrs))
        if !author.isEmpty || !date.isEmpty {
            let subPS = NSMutableParagraphStyle()
            subPS.alignment = .center
            subPS.paragraphSpacing = 16
            let subAttrs: [NSAttributedString.Key: Any] = [
                .font: zhFont as Any,
                .paragraphStyle: subPS,
                .foregroundColor: NSColor.systemGray
            ]
            let sub = [author, date].filter { !$0.isEmpty }.joined(separator: "  ·  ")
            result.append(NSAttributedString(string: sub + "\n", attributes: subAttrs))
        }
    }

    // MARK: - Rendering (Core Text pagination)

    private func render(_ attrString: NSAttributedString, to outURL: URL) throws {
        // SDK replacement for the deprecated `CGPDFContextCreateWithURL`:
        // `CGContext.init(_:mediaBox:_:)` (first & third args unlabeled,
        // second is `mediaBox:`).
        guard let ctx = CGContext(outURL as CFURL, mediaBox: nil, nil) else {
            throw AppError.pipeline("无法创建 PDF 上下文：\n  \(outURL.path)")
        }
        paginate(attrString, into: ctx)
    }

    private func paginate(_ attrString: NSAttributedString, into context: CGContext) {
        let framesetter = CTFramesetterCreateWithAttributedString(attrString)
        let contentRect = CGRect(
            x: margin,
            y: margin + footerHeight,
            width: pageWidth - 2 * margin,
            height: pageHeight - 2 * margin - footerHeight
        )
        let path = CGPath(rect: contentRect, transform: nil)
        let total = attrString.length
        var index = 0
        var page = 1

        while index < total {
            let frameRange = CFRangeMake(index, 0)
            guard let frame = CTFramesetterCreateFrame(framesetter, frameRange, path, nil) as CTFrame? else { break }
            context.beginPDFPage(nil)
            CTFrameDraw(frame, context)
            drawFooter(context, page: page)
            context.endPDFPage()

            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.length == 0 { break }
            index += visible.length
            page += 1
        }
    }

    private func drawFooter(_ context: CGContext, page: Int) {
        let text = "— \(page) —" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: CTFontCreateWithName("PingFang SC" as CFString, 9, nil) as Any,
            .foregroundColor: NSColor.systemGray
        ]
        let size = text.size(withAttributes: attrs)
        let point = CGPoint(x: (pageWidth - size.width) / 2, y: margin / 2)
        let localCtx = context
        let nsctx = NSGraphicsContext(cgContext: localCtx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsctx
        text.draw(at: point, withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }
}
