import Foundation
import CoreFoundation

/// Multi-format Japanese text extraction (port of ``core/extract.py``).
///
/// Every non-PDF path converges on a UTF-8 Japanese plain-text file so the
/// downstream translation stage is format-agnostic.
enum TextExtractor {
    static let supportedExtensions: Set<String> = [
        ".pdf", ".txt", ".json", ".xml", ".doc", ".docx"
    ]

    /// Extract text from `inputURL` into `workDir`, returning the jp_txt URL.
    static func extractText(inputURL: URL, workDir: URL,
                            python: String = "python3",
                            abortCheck: @Sendable @escaping () -> Bool = { false },
                            onProgress: @Sendable @escaping (String) -> Void = { _ in }) async throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: inputURL.path) else {
            throw AppError.extraction("输入文件不存在：\n  \(inputURL.path)")
        }
        let ext = inputURL.pathExtension.lowercased()
        guard supportedExtensions.contains(".\(ext)") else {
            let list = supportedExtensions.sorted().joined(separator: ", ")
            throw AppError.extraction("不支持的输入类型：.\(ext)\n仅支持：\(list)")
        }

        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        let stem = inputURL.deletingPathExtension().lastPathComponent

        switch ext {
        case "pdf":
            return try await OcrEngine.recognize(pdfURL: inputURL, outDir: workDir,
                                                 python: python, abortCheck: abortCheck, onProgress: onProgress)
        case "txt":
            return try copyTxt(inputURL, workDir: workDir, stem: stem)
        case "json":
            return try extractJSON(inputURL, workDir: workDir, stem: stem)
        case "xml":
            return try extractXML(inputURL, workDir: workDir, stem: stem)
        case "doc", "docx":
            return try extractDoc(inputURL, workDir: workDir, stem: stem)
        default:
            throw AppError.extraction("未处理的输入类型：.\(ext)")
        }
    }

    // MARK: - txt (encoding-tolerant copy, never overwrites the original)

    private static func copyTxt(_ url: URL, workDir: URL, stem: String) throws -> URL {
        let text = try readTextAny(url)
        var dest = workDir.appendingPathComponent("\(stem).txt")
        // F27 guard: if dest would clobber the original, relocate to _work/.
        if dest.standardizedFileURL == url.standardizedFileURL {
            let safe = workDir.appendingPathComponent("_work", isDirectory: true)
            try FileManager.default.createDirectory(at: safe, withIntermediateDirectories: true)
            dest = safe.appendingPathComponent("\(stem).txt")
        }
        try text.write(to: dest, atomically: true, encoding: .utf8)
        return dest
    }

    private static func readTextAny(_ url: URL) throws -> String {
        // `String.Encoding` exposes no `gb18030` static member, and the
        // `kCFStringEncodingGB_18030_2000` constant is not in scope on some SDKs,
        // so we use its raw CoreFoundation value (0x082E = GB18030-2000) directly.
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(0x082E))
        let encodings: [String.Encoding] = [
            .utf8, .utf32, .shiftJIS, .japaneseEUC, .iso2022JP, gb18030
        ]
        for enc in encodings {
            if let s = try? String(contentsOf: url, encoding: enc) { return s }
        }
        throw AppError.extraction("无法解码文件（请确认其文本编码，支持 UTF-8 / Shift-JIS / EUC-JP / GB18030 等）：\n  \(url.path)")
    }

    // MARK: - json (recursive string extraction)

    private static func extractJSON(_ url: URL, workDir: URL, stem: String) throws -> URL {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) else {
            throw AppError.extraction("JSON 解析失败：\n  \(url.path)")
        }
        var parts: [String] = []
        func walk(_ node: Any) {
            switch node {
            case let s as String:
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { parts.append(t) }
            case let dict as [String: Any]:
                dict.values.forEach(walk)
            case let arr as [Any]:
                arr.forEach(walk)
            default: break
            }
        }
        walk(obj)
        guard !parts.isEmpty else {
            throw AppError.extraction("JSON 中未找到任何字符串文本：\n  \(url.path)")
        }
        let dest = workDir.appendingPathComponent("\(stem).txt")
        try parts.joined(separator: "\n\n").write(to: dest, atomically: true, encoding: .utf8)
        return dest
    }

    // MARK: - xml (element text, structure newlines preserved)

    private static func extractXML(_ url: URL, workDir: URL, stem: String) throws -> URL {
        guard let data = try? Data(contentsOf: url) else {
            throw AppError.extraction("XML 读取失败：\n  \(url.path)")
        }
        let parser = SimpleXMLTextExtractor(data: data)
        let lines = parser.extract()
        guard !lines.isEmpty else {
            throw AppError.extraction("XML 中未找到任何文本内容：\n  \(url.path)")
        }
        let dest = workDir.appendingPathComponent("\(stem).txt")
        try lines.joined(separator: "\n").write(to: dest, atomically: true, encoding: .utf8)
        return dest
    }

    // MARK: - doc / docx (macOS textutil)

    private static func extractDoc(_ url: URL, workDir: URL, stem: String) throws -> URL {
        let text = try ProcessRunner.extractTextFromDoc(url)
        let dest = workDir.appendingPathComponent("\(stem).txt")
        try text.write(to: dest, atomically: true, encoding: .utf8)
        return dest
    }
}

/// Minimal XML text extractor (element text + inter-element text preserved).
private final class SimpleXMLTextExtractor: NSObject, XMLParserDelegate {
    private let data: Data
    private var lines: [String] = []
    private var current: String?

    init(data: Data) { self.data = data }

    func extract() -> [String] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return lines.compactMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                     .filter { !$0.isEmpty }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let t = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { current = (current ?? "") + t }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if let c = current, !c.isEmpty { lines.append(c) }
        current = nil
    }
}
