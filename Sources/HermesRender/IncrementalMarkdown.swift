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

    /// Blocks that can never change again while streaming.
    private var stableBlocks: [Block] = []
    /// UTF-8 offset where the last block (the only re-parsable one) starts.
    private var tailOffset: Int?

    /// How many characters have been re-parsed so far. Diagnostics for the
    /// performance rule: appending one token should add the length of the last
    /// block, not the length of the transcript.
    public private(set) var reparsedCharacterCount: Int = 0

    public init() {}

    /// Append a streamed delta and return only the blocks that changed.
    /// Block identity is by index, so the UI can diff cheaply.
    ///
    /// Only the final block is re-parsed: a delta can extend the block it lands
    /// in, or start new ones after it, but it can never rewrite an earlier block.
    @discardableResult
    public mutating func append(_ delta: String) -> [Int] {
        guard !delta.isEmpty else { return [] }
        source += delta

        let start = stringIndex(atUTF8: tailOffset ?? 0)
        let tail = source[start...]
        let parsed = IncrementalMarkdown.parseDetail(String(tail))
        reparsedCharacterCount += tail.count

        let newBlocks = stableBlocks + parsed.blocks
        var changed: [Int] = []
        changed.reserveCapacity(1)
        for index in newBlocks.indices where index >= blocks.count || blocks[index] != newBlocks[index] {
            changed.append(index)
        }
        blocks = newBlocks

        if parsed.blocks.isEmpty {
            stableBlocks = newBlocks
            tailOffset = nil
        } else {
            stableBlocks = Array(newBlocks.dropLast())
            tailOffset = (tailOffset ?? 0) + parsed.lastBlockStart
        }
        return changed
    }

    public static func parse(_ text: String) -> [Block] {
        parseDetail(text).blocks
    }

    /// Parse a whole text and report where its last block starts (UTF-8 offset),
    /// which is the only region `append` has to look at again.
    static func parseDetail(_ text: String) -> (blocks: [Block], lastBlockStart: Int) {
        var blocks: [Block] = []
        var lastBlockStart = 0
        var paragraph: [String] = []
        var paragraphStart = 0
        var offset = 0
        var i = text.startIndex

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            lastBlockStart = paragraphStart
            paragraph.removeAll()
        }

        func beginParagraph(at lineOffset: Int) {
            if paragraph.isEmpty { paragraphStart = lineOffset }
        }

        while i < text.endIndex {
            let lineEnd = text[i...].firstIndex(of: "\n") ?? text.endIndex
            var line = String(text[i..<lineEnd])
            let lineOffset = offset
            offset += line.utf8.count + (lineEnd == text.endIndex ? 0 : 1)
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
                    offset += inner.utf8.count + (end == text.endIndex ? 0 : 1)
                    if inner.hasPrefix("```") { closed = true; i = after; break }
                    body += (body.isEmpty ? "" : "\n") + inner
                    i = after
                }
                blocks.append(.code(language: language.isEmpty ? nil : language, body: body, closed: closed))
                lastBlockStart = lineOffset
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
                lastBlockStart = lineOffset
                i = next
                continue
            }

            if line.hasPrefix("> ") {
                flushParagraph()
                blocks.append(.quote(String(line.dropFirst(2))))
                lastBlockStart = lineOffset
                i = next
                continue
            }

            if line == "---" || line == "***" {
                flushParagraph()
                blocks.append(.rule)
                lastBlockStart = lineOffset
                i = next
                continue
            }

            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                blocks.append(.bullet(String(line.dropFirst(2))))
                lastBlockStart = lineOffset
                i = next
                continue
            }

            if let numbered = IncrementalMarkdown.numberedLine(line) {
                flushParagraph()
                blocks.append(.numbered(index: numbered.0, text: numbered.1))
                lastBlockStart = lineOffset
                i = next
                continue
            }

            line = line.trimmingCharacters(in: .whitespaces)
            beginParagraph(at: lineOffset)
            paragraph.append(line)
            i = next
        }
        flushParagraph()
        return (blocks, lastBlockStart)
    }

    static func numberedLine(_ line: String) -> (Int, String)? {
        let digits = line.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") else { return nil }
        return (number, String(rest.dropFirst(2)))
    }

    private func stringIndex(atUTF8 offset: Int) -> String.Index {
        let clamped = min(max(offset, 0), source.utf8.count)
        let utf8Index = source.utf8.index(source.utf8.startIndex, offsetBy: clamped)
        return String.Index(utf8Index, within: source) ?? source.endIndex
    }
}
