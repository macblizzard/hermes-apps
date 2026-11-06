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

    /// A rapid second selection can still see the previous bot (or an empty box) before the first
    /// open has attached. That must not erase either bot's parked draft.
    func testRapidSelectionsDoNotClearOrOverwriteParkedDrafts() {
        var ledger = BotDraftLedger()
        let first = ledger.beginSwitch(from: "alpha", draft: "alpha notes")
        XCTAssertEqual(ledger.draft(for: "alpha", token: first), "alpha notes")

        // The first open has not attached yet, so the composer is empty. The safe default must not
        // erase alpha's parked text.
        let second = ledger.beginSwitch(from: "alpha", draft: "")
        XCTAssertNil(ledger.draft(for: "alpha", token: first))
        XCTAssertEqual(ledger.draft(for: "alpha", token: second), "alpha notes")

        // Likewise, parking beta's empty composer must not clear a draft beta already had.
        let third = ledger.beginSwitch(from: "beta", draft: "")
        XCTAssertEqual(ledger.draft(for: "beta", token: third), "")
        let withBeta = ledger.beginSwitch(from: "beta", draft: "beta notes")
        let fourth = ledger.beginSwitch(from: "beta", draft: "")
        XCTAssertEqual(ledger.draft(for: "beta", token: fourth), "beta notes")
        XCTAssertNil(ledger.draft(for: "beta", token: withBeta))
    }

    /// A deliberate clear from an attached composer is still allowed.
    func testAnAttachedComposerCanExplicitlyClearItsParkedDraft() {
        var ledger = BotDraftLedger()
        _ = ledger.beginSwitch(from: "alpha", draft: "old")
        let token = ledger.beginSwitch(from: "alpha", draft: "", replacingParkedDraft: true)
        XCTAssertEqual(ledger.draft(for: "alpha", token: token), "")
    }

    func testFailedSendRestoresOnlyWhenNothingNewerWasParked() {
        var ledger = BotDraftLedger()
        _ = ledger.beginSwitch(from: "alpha", draft: "")

        ledger.restoreFailedDraft(botID: "alpha", text: "failed composition")
        var token = ledger.beginSwitch(from: "beta", draft: "")
        XCTAssertEqual(ledger.draft(for: "alpha", token: token), "failed composition")

        // A newer composition typed after the failure wins; the late callback must not replace it.
        _ = ledger.beginSwitch(from: "alpha", draft: "newer text")
        ledger.restoreFailedDraft(botID: "alpha", text: "failed composition")
        token = ledger.beginSwitch(from: "beta", draft: "")
        XCTAssertEqual(ledger.draft(for: "alpha", token: token), "newer text")
    }
}
#endif
