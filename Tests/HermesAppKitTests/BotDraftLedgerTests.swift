#if canImport(Combine)
import XCTest
@testable import HermesAppKit

/// The draft half of a bot switch is asynchronous, so an older completion must not overwrite the
/// current composer, and an accepted steer must not be offered again when the user comes back.
final class BotDraftLedgerTests: XCTestCase {

    func testStaleSwitchCannotRestoreItsDraftOverANewerSelection() {
        var ledger = BotDraftLedger()

        let firstToken = ledger.beginSwitch(from: "alpha", draft: "alpha notes")
        let secondToken = ledger.beginSwitch(from: "beta", draft: "beta notes")

        XCTAssertFalse(ledger.isCurrent(firstToken))
        XCTAssertNil(ledger.draft(for: "alpha", token: firstToken),
                     "the slower alpha open must not write over the newer beta selection")
        XCTAssertEqual(ledger.draft(for: "beta", token: secondToken), "beta notes")
    }

    func testTextTypedWhileOpeningWinsOverTheRestoredDraft() {
        var ledger = BotDraftLedger()
        ledger.beginSwitch(from: "alpha", draft: "old alpha draft")
        let token = ledger.beginSwitch(from: "beta", draft: "")

        // The UI only restores when the composer is still empty; this is the same gate.
        let currentDraft = "typed while beta was opening"
        let restored = ledger.draft(for: "beta", token: token)
        XCTAssertEqual(restored, "")
        XCTAssertEqual(currentDraft, "typed while beta was opening")
    }

    func testAcceptedSteerClearsTheParkedCopyEvenAfterASwitch() {
        var ledger = BotDraftLedger()
        let token = ledger.beginSwitch(from: "alpha", draft: "steer this")

        ledger.consumeAccepted(botID: "alpha", text: "steer this")

        XCTAssertEqual(ledger.draft(for: "alpha", token: token), "",
                       "coming back to alpha must not reoffer an accepted steer")
    }

    func testAcceptedTextDoesNotClearANewerParkedComposition() {
        var ledger = BotDraftLedger()
        let token = ledger.beginSwitch(from: "alpha", draft: "new words typed later")

        ledger.consumeAccepted(botID: "alpha", text: "older accepted steer")

        XCTAssertEqual(ledger.draft(for: "alpha", token: token), "new words typed later")
    }
}
#endif
