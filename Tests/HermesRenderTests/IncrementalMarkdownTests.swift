import XCTest
@testable import HermesRender

final class IncrementalMarkdownTests: XCTestCase {

    func testParagraphAndBullets() {
        let blocks = IncrementalMarkdown.parse("Backup is good.\n\n- a.md\n- b.md")
        XCTAssertEqual(blocks, [
            .paragraph("Backup is good."),
            .bullet("a.md"),
            .bullet("b.md"),
        ])
    }

    func testHeadingAndRule() {
        let blocks = IncrementalMarkdown.parse("## Files\n---\ntext")
        XCTAssertEqual(blocks.first, .heading(level: 2, text: "Files"))
        XCTAssertTrue(blocks.contains(.rule))
    }

    func testStreamingCodeFenceStaysOpen() {
        var md = IncrementalMarkdown()
        md.append("```swift\nlet x = 1\n")
        XCTAssertEqual(md.blocks.count, 1)
        guard case .code(let lang, let body, let closed) = md.blocks[0] else { return XCTFail() }
        XCTAssertEqual(lang, "swift")
        XCTAssertEqual(body, "let x = 1")
        XCTAssertFalse(closed, "an unclosed fence while streaming must be marked unclosed")

        md.append("```\n")
        guard case .code(_, _, let nowClosed) = md.blocks[0] else { return XCTFail() }
        XCTAssertTrue(nowClosed)
    }

    func testAppendReportsOnlyChangedBlocks() {
        var md = IncrementalMarkdown()
        md.append("Hello")
        XCTAssertEqual(md.blocks, [.paragraph("Hello")])
        let changed = md.append(" world")
        XCTAssertEqual(changed, [0], "only the live paragraph is re-emitted, not the whole transcript")
        XCTAssertEqual(md.blocks, [.paragraph("Hello world")])
    }

    func testNumberedList() {
        XCTAssertEqual(IncrementalMarkdown.parse("1. one\n2. two"),
                       [.numbered(index: 1, text: "one"), .numbered(index: 2, text: "two")])
    }

    func testQuote() {
        XCTAssertEqual(IncrementalMarkdown.parse("> because it deletes"), [.quote("because it deletes")])
    }
}
