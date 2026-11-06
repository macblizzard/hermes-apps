#if canImport(Combine)
import Foundation
import XCTest
@testable import HermesAppKit
import HermesKit

/// Steering the turn that is already running.
///
/// The point of these tests is the difference between the two verbs: a live turn takes
/// `session.steer`, a completed one takes `prompt.submit`, and a failure must never quietly
/// turn the first into the second. They also pin the state the user can see while the call is
/// on the wire (draft retained, one press only) and that the streamed reply, reasoning and
/// tool cards survive a steer untouched.
@MainActor
final class AppModelSteerTests: XCTestCase {

    private func openModel(entries: [TranscriptEntry] = [
        TranscriptEntry(id: "u1", role: .user, text: "start the turn"),
    ]) async -> (AppModel, ScriptedHost) {
        let host = ScriptedHost(session: "s1", entries: entries)
        let model = AppModel(client: host, hostName: "test-steer-\(UUID().uuidString)")
        await model.start()
        await model.select("s1")
        return (model, host)
    }

    private func waitUntil(_ condition: @escaping () -> Bool,
                           timeout: TimeInterval = 3,
                           file: StaticString = #filePath,
                           line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition not met within \(timeout)s", file: file, line: line)
    }

    /// Put the model into a live turn with a partial reply, reasoning, and one tool still running.
    private func startLiveTurn(model: AppModel, host: ScriptedHost) async {
        host.emit(.thinkingDelta(session: "s1", text: "The failing test narrows the scope."))
        host.emit(.toolStart(session: "s1", name: "terminal", callID: "t1", input: "swift test\n"))
        host.emit(.messageDelta(session: "s1", text: "Running the suite"))
        await waitUntil {
            model.isStreaming && !model.streamingText.isEmpty && !model.reasoningText.isEmpty
                && !model.liveTools.isEmpty
        }
    }

    func testSteerUsesSessionSteerAndPreservesTheLiveTurn() async {
        let (model, host) = await openModel()
        await startLiveTurn(model: model, host: host)
        let before = model.transcript

        model.draft = "  Focus on the failing test.  "
        await model.steer()

        XCTAssertEqual(host.steered, ["Focus on the failing test."])
        XCTAssertTrue(host.submitted.isEmpty, "steering must never cross the wire as prompt.submit")
        XCTAssertEqual(model.draft, "", "the draft clears only after the host accepts it")
        XCTAssertNil(model.lastSendError)
        XCTAssertTrue(model.isStreaming, "the running turn is still running")
        XCTAssertEqual(model.streamingText, "Running the suite", "the partial reply is preserved")
        XCTAssertEqual(model.reasoningText, "The failing test narrows the scope.",
                       "reasoning for the live turn is preserved")
        XCTAssertEqual(model.liveTools.map(\.name), ["terminal"], "the live tool card is preserved")
        XCTAssertEqual(Array(model.transcript.prefix(before.count)), before,
                       "the existing transcript is not rewritten")
        XCTAssertEqual(model.transcript.last?.role, .user)
        XCTAssertEqual(model.transcript.last?.text, "Focus on the failing test.",
                       "the steering message appears exactly once")
        XCTAssertFalse(model.isSteering)
    }

    func testSteerFailureKeepsTheDraftAndTheLiveTurn() async {
        let (model, host) = await openModel()
        await startLiveTurn(model: model, host: host)
        let before = model.transcript
        host.steerError = GatewayError.rpc(RPCError(code: 4009, message: "session busy"))

        model.draft = "Try the narrower test first"
        await model.steer()

        XCTAssertEqual(host.steered, ["Try the narrower test first"])
        XCTAssertTrue(host.submitted.isEmpty, "a failed steer is reported, never retried as a prompt")
        XCTAssertEqual(model.draft, "Try the narrower test first", "the words stay in the composer")
        XCTAssertEqual(model.lastSendError,
                       "Could not steer the running turn: session busy. Your text is still in the composer.")
        XCTAssertTrue(model.isStreaming)
        XCTAssertEqual(model.streamingText, "Running the suite")
        XCTAssertEqual(model.liveTools.map(\.name), ["terminal"])
        XCTAssertEqual(model.transcript, before, "a failed steer adds no phantom message")
        XCTAssertFalse(model.isSteering)
    }

    func testSteerIsSingleFlightAndKeepsTheDraftUntilAccepted() async {
        let (model, host) = await openModel()
        await startLiveTurn(model: model, host: host)

        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        host.onSteer = {
            enteredContinuation.yield(())
            var iterator = release.makeAsyncIterator()
            _ = await iterator.next()
        }

        model.draft = "also check the retry path"
        let first = Task { await model.steer() }
        var enteredIterator = entered.makeAsyncIterator()
        _ = await enteredIterator.next()

        XCTAssertTrue(model.isSteering, "the control can show an in-flight steer")
        XCTAssertEqual(model.draft, "also check the retry path",
                       "the draft is not cleared before acceptance")
        // A second press while the first is on the wire is a no-op, not a duplicate.
        await model.steer()
        XCTAssertEqual(host.steered.count, 1)

        releaseContinuation.yield(())
        await first.value

        XCTAssertFalse(model.isSteering)
        XCTAssertEqual(host.steered, ["also check the retry path"])
        XCTAssertEqual(model.draft, "")
        XCTAssertEqual(model.transcript.filter { $0.role == .user && $0.text == "also check the retry path" }.count,
                       1, "the steering message is appended once")
    }

    /// The turn can end between the UI seeing "working" and the RPC leaving. That race is
    /// explained with the draft intact; it is not permission to submit.
    func testSteerAfterTheTurnEndedKeepsTheDraftAndDoesNotSubmit() async {
        let (model, host) = await openModel()
        model.draft = "Too late to steer"

        await model.steer()

        XCTAssertTrue(host.steered.isEmpty)
        XCTAssertTrue(host.submitted.isEmpty)
        XCTAssertEqual(model.draft, "Too late to steer")
        XCTAssertEqual(model.lastSendError,
                       "The turn finished before your message could be steered. Your text is still in the composer — press Send to start a new turn.")
        XCTAssertFalse(model.isSteering)
    }

    /// If the turn ends while the RPC is on the wire and the steer fails, the race is named
    /// explicitly instead of being reported as a generic busy turn.
    func testSteerFailureAfterTheTurnEndsExplainsTheRace() async {
        let (model, host) = await openModel()
        await startLiveTurn(model: model, host: host)
        host.steerError = GatewayError.rpc(RPCError(code: 4009, message: "no active turn"))

        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        host.onSteer = {
            enteredContinuation.yield(())
            var iterator = release.makeAsyncIterator()
            _ = await iterator.next()
        }

        model.draft = "Too late after all"
        let first = Task { await model.steer() }
        var enteredIterator = entered.makeAsyncIterator()
        _ = await enteredIterator.next()

        host.emit(.messageComplete(session: "s1", text: "The turn finished first."))
        await waitUntil { !model.isStreaming }
        releaseContinuation.yield(())
        await first.value

        XCTAssertTrue(host.submitted.isEmpty)
        XCTAssertEqual(model.draft, "Too late after all")
        XCTAssertEqual(model.lastSendError,
                       "The turn ended before the steer reached it (no active turn). Your text is still in the composer — press Send to start a new turn.")
        XCTAssertFalse(model.isSteering)
    }

    /// `session.steer` has no attachment payload. The files and the text both survive, and the
    /// reason is shown rather than a dead button or a silent drop.
    func testSteerWithAttachmentsPreservesBothAndExplains() async {
        let (model, host) = await openModel()
        await startLiveTurn(model: model, host: host)
        model.addPendingAttachment(name: "spec.pdf", data: Data("pdf".utf8), isImage: false)

        model.draft = "Use the attached spec"
        await model.steer()

        XCTAssertTrue(host.steered.isEmpty)
        XCTAssertTrue(host.submitted.isEmpty)
        XCTAssertEqual(model.draft, "Use the attached spec")
        XCTAssertEqual(model.pendingAttachments.map(\.name), ["spec.pdf"])
        XCTAssertEqual(model.lastSendError,
                       "Attachments can't be added to a running turn. Your message and 1 attachment(s) are still here — remove them to steer, or wait for the turn to finish.")
        XCTAssertFalse(model.isSteering)
    }

    /// The old bug this closes: pressing send while the bot was working called the normal
    /// submit path and started a second turn. A live turn has no ordinary-send path.
    func testSendDoesNotSubmitWhileATurnIsRunning() async {
        let (model, host) = await openModel()
        await startLiveTurn(model: model, host: host)

        model.draft = "This belongs to the running turn"
        await model.send()

        XCTAssertTrue(host.submitted.isEmpty)
        XCTAssertEqual(model.draft, "This belongs to the running turn")
    }

    /// A successful steer clears the composition that was sent, not whatever the user has typed
    /// since. The newer words belong to the next turn.
    func testSteerSuccessDoesNotClearTextTypedAfterTheRequest() async {
        let (model, host) = await openModel()
        await startLiveTurn(model: model, host: host)

        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        host.onSteer = {
            enteredContinuation.yield(())
            var iterator = release.makeAsyncIterator()
            _ = await iterator.next()
        }

        model.draft = "steer the running turn"
        let steer = Task { await model.steer() }
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()

        model.draft = "this was typed while the RPC was in flight"
        releaseContinuation.yield(())
        await steer.value

        XCTAssertEqual(model.draft, "this was typed while the RPC was in flight")
        XCTAssertEqual(host.steered, ["steer the running turn"])
        XCTAssertEqual(model.transcript.last?.role, .user)
        XCTAssertEqual(model.transcript.last?.text, "steer the running turn",
                       "the accepted steer is still shown exactly once")
    }

    /// `message.complete` can beat the steer RPC's reply. The answer must not be inserted ahead
    /// of the user instruction that was accepted before it.
    func testCompletionBeforeSteerReplyKeepsTheSteerAboveTheAnswer() async {
        let (model, host) = await openModel()
        await startLiveTurn(model: model, host: host)

        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        host.onSteer = {
            enteredContinuation.yield(())
            var iterator = release.makeAsyncIterator()
            _ = await iterator.next()
        }

        model.draft = "steer first, then answer"
        let steer = Task { await model.steer() }
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()

        host.emit(.messageComplete(session: "s1", text: "The answer arrived first."))
        await waitUntil { model.deferredCompletionCount == 1 }
        XCTAssertFalse(model.transcript.contains { $0.text == "The answer arrived first." },
                       "the completion is held until the steer has an order")

        releaseContinuation.yield(())
        await steer.value

        let texts = model.transcript.map(\.text)
        guard let steerIndex = texts.firstIndex(of: "steer first, then answer"),
              let answerIndex = texts.firstIndex(of: "The answer arrived first.") else {
            return XCTFail("both the steer and the answer must be in the transcript")
        }
        XCTAssertLessThan(steerIndex, answerIndex)
        XCTAssertFalse(model.isStreaming)
        XCTAssertFalse(model.isSteering)
    }

    /// The shell's per-bot draft must learn that the host consumed this text even when the
    /// selection has already changed by the time the RPC is acknowledged.
    func testAcceptedSteerNotifiesTheDraftOwner() async {
        let (model, host) = await openModel()
        await startLiveTurn(model: model, host: host)

        var consumed: [(String, String)] = []
        model.onDraftConsumed = { bot, text in consumed.append((bot, text)) }

        model.draft = "consume me"
        await model.steer()

        XCTAssertEqual(host.steered, ["consume me"])
        XCTAssertEqual(consumed.count, 1)
        XCTAssertEqual(consumed.first?.1, "consume me")
    }
}
#endif
