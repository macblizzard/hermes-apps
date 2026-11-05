import Foundation

/// Incremental markdown for a streaming chat.
///
/// The rule that keeps 120 Hz smooth: never re-parse the whole message on every
/// token. We keep the last parsed prefix and only parse the unfinished tail.
public enum Block: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case bullet(String)
    case numbered(index: Int, text: String)
    case code(language: String?, body: String, closed: Bool)
    case quote(String)
    case rule
}

public struct IncrementalMarkdown: Sendable {
    public private(set) var source: String = ""
    public private(set) var blocks: [Block] = []

    public init() {}

    /// Append a streamed delta and return only the blocks that changed.
    /// Block identity is by index, so the UI can diff cheaply.
    @discardableResult
    public mutating func append(_ delta: String) -> [Int] {
        guard !delta.isEmpty else { return [] }
        source += delta
        let newBlocks = IncrementalMarkdown.parse(source)
        var changed: [Int] = []
        for index in newBlocks.indices where index >= blocks.count || blocks[index] != newBlocks[index] {
            changed.append(index)
        }
        blocks = newBlocks
        return changed
    }

    public static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var i = text.startIndex

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph.removeAll()
        }

        while i < text.endIndex {
            let lineEnd = text[i...].firstIndex(of: "\n") ?? text.endIndex
            var line = String(text[i..<lineEnd])
            let next = lineEnd == text.endIndex ? text.endIndex : text.index(after: lineEnd)

            // Fenced code: everything until the closing fence, or to the end while it
            // is still streaming (that is why `closed` exists).
            if line.hasPrefix("```") {
                flushParagraph()
                let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body = ""
                var closed = false
                i = next
                while i < text.endIndex {
                    let end = text[i...].firstIndex(of: "\n") ?? text.endIndex
                    let inner = String(text[i..<end])
                    let after = end == text.endIndex ? text.endIndex : text.index(after: end)
                    if inner.hasPrefix("```") { closed = true; i = after; break }
                    body += (body.isEmpty ? "" : "\n") + inner
                    i = after
                }
                blocks.append(.code(language: language.isEmpty ? nil : language, body: body, closed: closed))
                continue
            }

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
                i = next
                continue
            }

            if line.hasPrefix("#") {
                flushParagraph()
                let level = line.prefix(while: { $0 == "#" }).count
                let title = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: min(level, 6), text: title))
                i = next
                continue
            }

            if line.hasPrefix("> ") {
                flushParagraph()
                blocks.append(.quote(String(line.dropFirst(2))))
                i = next
                continue
            }

            if line == "---" || line == "***" {
                flushParagraph()
                blocks.append(.rule)
                i = next
                continue
            }

            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                blocks.append(.bullet(String(line.dropFirst(2))))
                i = next
                continue
            }

            if let numbered = IncrementalMarkdown.numberedLine(line) {
                flushParagraph()
                blocks.append(.numbered(index: numbered.0, text: numbered.1))
                i = next
                continue
            }

            line = line.trimmingCharacters(in: .whitespaces)
            paragraph.append(line)
            i = next
        }
        flushParagraph()
        return blocks
    }

    static func numberedLine(_ line: String) -> (Int, String)? {
        let digits = line.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") else { return nil }
        return (number, String(rest.dropFirst(2)))
    }
}
