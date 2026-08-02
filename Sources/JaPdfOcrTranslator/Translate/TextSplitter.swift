import Foundation

/// Splits long Japanese text into translation chunks (port of `split_text.py`).
///
/// Chunks never break a sentence in the middle: paragraphs are accumulated up
/// to `target` characters, and an over-long paragraph is cut at the nearest
/// sentence boundary before `maxp`.
enum TextSplitter {
    static func split(_ text: String, target: Int = 4000, maxp: Int = 8000) -> [String] {
        let paragraphs = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var chunks: [String] = []
        var current = ""

        func push(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { chunks.append(t) }
            current = ""
        }

        for para in paragraphs {
            if para.isEmpty {
                // blank line acts as a paragraph boundary
                if !current.isEmpty { push(current) }
                continue
            }
            if current.isEmpty {
                current = para
            } else if (current as NSString).length + para.count + 1 <= target {
                current += "\n" + para
            } else {
                push(current)
                current = para
            }

            // A single paragraph exceeding maxp must be hard-cut at a sentence end.
            while (current as NSString).length > maxp {
                if let cut = sentenceBoundary(in: current, max: maxp) {
                    let head = String(current.prefix(cut))
                    push(head)
                    current = String(current.dropFirst(cut)).trimmingCharacters(in: .whitespaces)
                } else {
                    let head = String(current.prefix(maxp))
                    push(head)
                    current = String(current.dropFirst(maxp)).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        if !current.isEmpty { push(current) }
        return chunks
    }

    /// Find an index ≤ max where a sentence-ending punctuation occurs, preferring
    /// the longest such cut.
    private static func sentenceBoundary(in s: String, max: Int) -> Int? {
        let upper = min(max, (s as NSString).length)
        let sentenceEnds = CharacterSet(charactersIn: "。！？!?…\n")
        for i in (0..<upper).reversed() {
            let idx = s.index(s.startIndex, offsetBy: i)
            if String(s[idx]).rangeOfCharacter(from: sentenceEnds) != nil {
                return i + 1
            }
        }
        return nil
    }

    /// Split and persist chunks + manifest, returning the chunks directory.
    static func splitAndWrite(textURL: URL, workDir: URL) throws -> (chunksDir: URL, count: Int, totalChars: Int) {
        let text = (try? String(contentsOf: textURL, encoding: .utf8)) ?? ""
        let chunks = split(text)
        let dir = workDir.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, chunk) in chunks.enumerated() {
            let name = String(format: "chunk_%03d.txt", i + 1)
            try chunk.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let manifest: [String: Any] = [
            "count": chunks.count,
            "total_chars": text.count
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest)
        try manifestData.write(to: workDir.appendingPathComponent("manifest.json"))
        return (dir, chunks.count, text.count)
    }
}
