import XCTest
@testable import HermesKit

final class BotActivityOrderTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    func testMostRecentMessageFirstRegardlessOfHostOrder() {
        let bots = [Bot(id: "a"), Bot(id: "b"), Bot(id: "c")]
        let order = BotActivityOrder.order(bots, activity: [
            "a": base, "b": base.addingTimeInterval(60), "c": base.addingTimeInterval(120),
        ])
        XCTAssertEqual(order.map(\.id), ["c", "b", "a"])
    }

    func testUnusedBotsKeepHostOrderAtTheBottom() {
        let bots = [Bot(id: "a"), Bot(id: "b"), Bot(id: "c"), Bot(id: "d")]
        let order = BotActivityOrder.order(bots, activity: ["c": base])
        XCTAssertEqual(order.map(\.id), ["c", "a", "b", "d"])
    }

    /// Two bots written in the same second must not swap places on every refresh.
    func testEqualActivityFallsBackToHostOrder() {
        let bots = [Bot(id: "a"), Bot(id: "b"), Bot(id: "c")]
        let order = BotActivityOrder.order(bots, activity: ["a": base, "b": base, "c": base])
        XCTAssertEqual(order.map(\.id), ["a", "b", "c"])
    }

    func testActivityForABotNoLongerServedIsIgnored() {
        let bots = [Bot(id: "a")]
        let order = BotActivityOrder.order(bots, activity: ["gone": base, "a": base.addingTimeInterval(-5)])
        XCTAssertEqual(order.map(\.id), ["a"])
    }
}
