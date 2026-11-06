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

    // MARK: Pins

    func testPinnedBotsComeBeforeEveryUnpinnedOneEvenWithoutActivity() {
        let bots = [Bot(id: "a"), Bot(id: "b"), Bot(id: "c"), Bot(id: "d")]
        let order = BotActivityOrder.order(bots,
                                           activity: ["d": base, "c": base.addingTimeInterval(60)],
                                           pinned: ["a"])
        XCTAssertEqual(order.map(\.id), ["a", "c", "d", "b"],
                       "a pin outranks recency; the rest keep their activity order")
    }

    func testSeveralPinsKeepHostOrderAmongThemselves() {
        let bots = [Bot(id: "a"), Bot(id: "b"), Bot(id: "c"), Bot(id: "d")]
        // Activity would rank d, then b; the pins must ignore it and stay b, d.
        let order = BotActivityOrder.order(bots,
                                           activity: ["d": base.addingTimeInterval(120),
                                                      "b": base.addingTimeInterval(60),
                                                      "a": base.addingTimeInterval(30)],
                                           pinned: ["d", "b"])
        XCTAssertEqual(order.map(\.id), ["b", "d", "a", "c"],
                       "pins are not re-sorted by activity — host order wins among them")
    }

    func testPinnedBotThatWasJustUsedIsStillFirst() {
        let bots = [Bot(id: "a"), Bot(id: "b"), Bot(id: "c")]
        let order = BotActivityOrder.order(bots,
                                           activity: ["a": base.addingTimeInterval(30),
                                                      "b": base.addingTimeInterval(600)],
                                           pinned: ["a"])
        XCTAssertEqual(order.map(\.id), ["a", "b", "c"],
                       "a pin is first whether or not it also has the newest message")
    }

    func testUnpinningReturnsTheBotToItsActivitySlot() {
        let bots = [Bot(id: "a"), Bot(id: "b"), Bot(id: "c")]
        let activity = ["a": base.addingTimeInterval(30),
                        "b": base.addingTimeInterval(600),
                        "c": base.addingTimeInterval(300)]

        let pinnedOrder = BotActivityOrder.order(bots, activity: activity, pinned: ["a"])
        XCTAssertEqual(pinnedOrder.map(\.id), ["a", "b", "c"])

        let unpinnedOrder = BotActivityOrder.order(bots, activity: activity, pinned: [])
        XCTAssertEqual(unpinnedOrder.map(\.id), ["b", "c", "a"],
                       "after unpinning, activity alone decides the position")
    }

    func testPinnedIDsThatAreNotServedAreIgnored() {
        let bots = [Bot(id: "a"), Bot(id: "b")]
        let order = BotActivityOrder.order(bots, activity: ["a": base], pinned: ["gone"])
        XCTAssertEqual(order.map(\.id), ["a", "b"])
    }
}
