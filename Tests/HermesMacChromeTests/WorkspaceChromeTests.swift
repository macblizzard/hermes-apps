import XCTest
@testable import HermesMacChrome

final class WorkspaceChromeTests: XCTestCase {
    func testNoSystemInsetStillReservesTheTrafficLightStrip() {
        XCTAssertEqual(WorkspaceChrome.topPadding(safeAreaTop: 0), 28)
        XCTAssertEqual(WorkspaceChrome.topOffset(safeAreaTop: 0), 28)
    }

    func testHiddenTitleBarInsetIsNotAddedTwice() {
        XCTAssertEqual(WorkspaceChrome.topPadding(safeAreaTop: 28), 0)
        XCTAssertEqual(WorkspaceChrome.topOffset(safeAreaTop: 28), 28)
    }

    func testPartialInsetOnlyTopsUpToTheStrip() {
        XCTAssertEqual(WorkspaceChrome.topPadding(safeAreaTop: 12), 16)
        XCTAssertEqual(WorkspaceChrome.topOffset(safeAreaTop: 12), 28)
    }

    func testLargerSystemInsetStaysUnobstructed() {
        XCTAssertEqual(WorkspaceChrome.topPadding(safeAreaTop: 40), 0)
        XCTAssertEqual(WorkspaceChrome.topOffset(safeAreaTop: 40), 40)
    }

    func testNegativeInsetIsTreatedAsZero() {
        XCTAssertEqual(WorkspaceChrome.topPadding(safeAreaTop: -8), 28)
        XCTAssertEqual(WorkspaceChrome.topOffset(safeAreaTop: -8), 28)
    }

    func testWorkspaceNeverStartsInsideTheTrafficLightStrip() {
        for inset in stride(from: CGFloat(-10), through: 80, by: 1) {
            XCTAssertGreaterThanOrEqual(
                WorkspaceChrome.topOffset(safeAreaTop: inset), WorkspaceChrome.titleBarHeight,
                "safe-area inset \(inset) would put content under the traffic lights"
            )
        }
    }

    func testSurroundMatchesTheWindowDesign() {
        XCTAssertEqual(WorkspaceChrome.sideInset, 8)
        XCTAssertEqual(WorkspaceChrome.bottomInset, 8)
        XCTAssertEqual(WorkspaceChrome.titleBarHeight, 28)
    }
}
