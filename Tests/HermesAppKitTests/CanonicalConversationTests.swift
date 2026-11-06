#if canImport(Combine)
import Foundation
import XCTest
@testable import HermesAppKit
import HermesKit

/// The bot conversation is resolved by an exact host title, but that title is a discovery hint,
/// not a distributed lock. These tests pin the safe behaviour around that limitation: recover a
/// device-local thread instead of replacing it, never claim a title write that failed, and make a
/// reset all-or-nothing so history is not renamed or stranded by a failure or a navigation.
@MainActor
final class CanonicalConversationTests: XCTestCase {

    private func makeModel(bot: String) -> (AppModel, ScriptedHost) {
        let host = ScriptedHost(session: "s1")
        let model = AppModel(client: host, hostName: "test-\(bot)")
        return (model, host)
    }

    private func key(_ bot: String) -> String { "hermes.endlessSession.\(bot)" }

    /// Each test owns a fresh bot id so UserDefaults cannot leak a seed between cases.
    private func freshBot(_ label: String) -> String { "\(label)-\(UUID().uuidString)" }

    func testTheHostCanonicalTitleWinsOverEveryLocalSeed() async {
        let bot = freshBot("canonical")
        defer { UserDefaults.standard.removeObject(forKey: key(bot)) }
        let (model, host) = makeModel(bot: bot)
        UserDefaults.standard.set("stale-local-id", forKey: key(bot))
        host.canonicalSessions[bot] = "server-canonical-id"
        host.mostRecentSessions[bot] = "some-other-recent-id"

        let opened = await model.endlessSession(for: bot)

        XCTAssertEqual(opened, "server-canonical-id")
        XCTAssertEqual(model.selectedSessionID, "server-canonical-id")
        XCTAssertEqual(host.resumedIDs, ["server-canonical-id"],
                       "only the host's exact-title row is opened")
        XCTAssertTrue(host.createdSessions.isEmpty,
                      "an existing canonical conversation must never be replaced")
        XCTAssertTrue(host.titleWrites.isEmpty,
                      "the host already owns the canonical title; do not churn it")
        await model.stop()
    }

    /// The old client ignored the local id entirely and created a fresh empty `Bot Chat`, which
    /// made a pre-canonical conversation unreachable. Recovering it is not an identity claim:
    /// the host must still be able to resume it.
    func testADeviceLocalConversationIsRecoveredInsteadOfReplaced() async {
        let bot = freshBot("recover-local")
        defer { UserDefaults.standard.removeObject(forKey: key(bot)) }
        let (model, host) = makeModel(bot: bot)
        UserDefaults.standard.set("legacy-local-id", forKey: key(bot))
        host.mostRecentSessions[bot] = "unrelated-recent-id"

        let opened = await model.endlessSession(for: bot)

        XCTAssertEqual(opened, "legacy-local-id")
        XCTAssertEqual(model.selectedSessionID, "legacy-local-id")
        XCTAssertEqual(host.resumedIDs, ["legacy-local-id"])
        XCTAssertTrue(host.createdSessions.isEmpty,
                      "existing device-local history must not be replaced by a fresh Bot Chat")
        XCTAssertTrue(host.titleWrites.isEmpty,
                      "recovered history keeps its own title; it is never silently migrated")
        XCTAssertEqual(UserDefaults.standard.string(forKey: key(bot)), "legacy-local-id")
        await model.stop()
    }

    /// A failed resume is not proof the row is gone. Keep the pointer and report, rather than
    /// silently replacing it with a new empty thread.
    func testATransientResumeFailureKeepsTheDeviceLocalConversationAndCreatesNothing() async {
        let bot = freshBot("transient-local")
        defer { UserDefaults.standard.removeObject(forKey: key(bot)) }
        let (model, host) = makeModel(bot: bot)
        UserDefaults.standard.set("legacy-local-id", forKey: key(bot))
        host.resumeError = GatewayError.timeout(method: "session.resume", seconds: 120)

        let opened = await model.endlessSession(for: bot)

        XCTAssertNil(opened)
        XCTAssertTrue(host.createdSessions.isEmpty,
                      "a timeout must not be turned into a fresh conversation")
        XCTAssertEqual(UserDefaults.standard.string(forKey: key(bot)), "legacy-local-id")
        XCTAssertTrue(model.lastSendError?.contains("left in place") == true)
        await model.stop()
    }

    /// Only an explicit "session not found" makes the cached id stale enough to replace.
    func testAMissingDeviceLocalConversationIsReplacedSafely() async {
        let bot = freshBot("missing-local")
        defer { UserDefaults.standard.removeObject(forKey: key(bot)) }
        let (model, host) = makeModel(bot: bot)
        UserDefaults.standard.set("legacy-local-id", forKey: key(bot))
        host.resumeError = GatewayError.rpc(RPCError(code: 4007, message: "session not found"))
        host.mostRecentSessions[bot] = "unrelated-recent-id"

        let opened = await model.endlessSession(for: bot)

        XCTAssertEqual(opened, "created-\(bot)-1")
        XCTAssertEqual(host.resumedIDs, ["legacy-local-id"],
                       "the local id is verified before being abandoned")
        XCTAssertEqual(host.createdSessions.map { $0.profile }, [Optional(bot)])
        XCTAssertEqual(host.createdSessions.map { $0.title }, [Optional(AppModel.canonicalConversationTitle)])
        XCTAssertEqual(UserDefaults.standard.string(forKey: key(bot)), "created-\(bot)-1")
        await model.stop()
    }

    func testNoCanonicalOrLocalRowCreatesAFreshThreadWithoutAdoptingRecent() async {
        let bot = freshBot("no-adopt")
        defer { UserDefaults.standard.removeObject(forKey: key(bot)) }
        let (model, host) = makeModel(bot: bot)
        host.mostRecentSessions[bot] = "unrelated-recent-id"

        let opened = await model.endlessSession(for: bot)

        XCTAssertEqual(opened, "created-\(bot)-1")
        XCTAssertEqual(host.resumedIDs, [])
        XCTAssertEqual(host.createdSessions.map { $0.profile }, [Optional(bot)])
        XCTAssertEqual(host.createdSessions.map { $0.title }, [Optional(AppModel.canonicalConversationTitle)])
        XCTAssertEqual(model.selectedSessionID, "created-\(bot)-1")
        await model.stop()
    }

    /// If the title cannot be written, the row must not be cached or returned as the shared
    /// conversation. The failure is a blocker, not a silent local substitute.
    func testTitlePublicationFailureCreatesNothingUsableAndReportsTheBlocker() async {
        let bot = freshBot("title-fail")
        defer { UserDefaults.standard.removeObject(forKey: key(bot)) }
        let (model, host) = makeModel(bot: bot)
        host.titleError = GatewayError.rpc(RPCError(code: 5001, message: "title store unavailable"))

        let opened = await model.endlessSession(for: bot)

        XCTAssertNil(opened)
        XCTAssertNil(model.selectedSessionID)
        XCTAssertNil(UserDefaults.standard.string(forKey: key(bot)),
                     "an unconfirmed title must not be cached as the shared identity")
        XCTAssertTrue(model.lastSendError?.contains("not claimed") == true)
        XCTAssertEqual(host.createdSessions.count, 1)
        await model.stop()
    }

    /// Recovering an existing thread does not depend on a title write at all. Even when the host's
    /// title store is broken, the local history opens and remains accessible, unmodified.
    func testRecoveredLocalHistoryOpensWithoutAnyTitleWrite() async {
        let bot = freshBot("recover-no-title-write")
        defer { UserDefaults.standard.removeObject(forKey: key(bot)) }
        let (model, host) = makeModel(bot: bot)
        UserDefaults.standard.set("legacy-local-id", forKey: key(bot))
        host.titleError = GatewayError.rpc(RPCError(code: 5001, message: "title store unavailable"))

        let opened = await model.endlessSession(for: bot)

        XCTAssertEqual(opened, "legacy-local-id")
        XCTAssertEqual(model.selectedSessionID, "legacy-local-id")
        XCTAssertEqual(UserDefaults.standard.string(forKey: key(bot)), "legacy-local-id")
        XCTAssertTrue(host.titleWrites.isEmpty,
                      "opening history must not attempt a canonical migration")
        XCTAssertNil(model.lastSendError)
        await model.stop()
    }

    /// Reset is deliberately removed: making a new row canonical would require retitling or
    /// archiving the existing chat. The old thread, its title and the local pointer stay untouched.
    func testResetDoesNotCreateRetitleOrArchiveExistingHistory() async {
        let bot = freshBot("reset-noop")
        defer { UserDefaults.standard.removeObject(forKey: key(bot)) }
        let (model, host) = makeModel(bot: bot)
        host.canonicalSessions[bot] = "old-id"

        let opened = await model.endlessSession(for: bot)
        XCTAssertEqual(opened, "old-id")
        let beforeTranscript = model.transcript

        await model.resetEndlessSession(for: bot)

        XCTAssertEqual(model.selectedSessionID, "old-id")
        XCTAssertEqual(model.transcript, beforeTranscript)
        XCTAssertEqual(UserDefaults.standard.string(forKey: key(bot)), "old-id")
        XCTAssertTrue(host.createdSessions.isEmpty,
                      "no replacement is created behind the user's back")
        XCTAssertTrue(host.titleWrites.isEmpty,
                      "the existing chat is never silently retitled or archived")
        XCTAssertEqual(host.canonicalSessions[bot], "old-id")
        XCTAssertTrue(model.lastSendError?.contains("nothing was changed") == true)
        await model.stop()
    }

    func testResetForAnotherBotTouchesNothing() async {
        let bot = freshBot("reset-other")
        defer { UserDefaults.standard.removeObject(forKey: key(bot)) }
        let (model, host) = makeModel(bot: bot)
        host.canonicalSessions[bot] = "old-id"
        _ = await model.endlessSession(for: bot)

        await model.selectBot("another-bot")
        await model.resetEndlessSession(for: bot)

        XCTAssertEqual(model.selectedBotID, "another-bot")
        XCTAssertEqual(host.canonicalSessions[bot], "old-id")
        XCTAssertTrue(host.createdSessions.isEmpty)
        XCTAssertTrue(host.titleWrites.isEmpty)
        XCTAssertTrue(model.lastSendError?.contains("not the open bot") == true)
        await model.stop()
    }

    /// A slow open for the bot selected first must not attach itself after a newer bot has taken
    /// over the screen. The stale task returns without resetting the current selection.
    func testASlowerOpenForAnOlderBotCannotTakeTheSelectionBack() async {
        let alpha = freshBot("stale-alpha")
        let beta = freshBot("stale-beta")
        defer {
            UserDefaults.standard.removeObject(forKey: key(alpha))
            UserDefaults.standard.removeObject(forKey: key(beta))
        }
        let (model, host) = makeModel(bot: alpha)
        host.bots = [Bot(id: alpha), Bot(id: beta)]

        let gate = FirstCallGate()
        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        host.onCreate = {
            guard gate.shouldBlock() else { return }
            enteredContinuation.yield(())
            var iterator = release.makeAsyncIterator()
            _ = await iterator.next()
        }

        let older = Task { await model.endlessSession(for: alpha) }
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()

        let newer = await model.endlessSession(for: beta)
        XCTAssertEqual(newer, "created-\(beta)-2")
        XCTAssertEqual(model.selectedBotID, beta)

        releaseContinuation.yield(())
        let stale = await older.value

        XCTAssertNil(stale)
        XCTAssertEqual(model.selectedBotID, beta,
                       "the older open must not switch the screen back")
        XCTAssertEqual(model.selectedSessionID, newer)
        await model.stop()
    }

    /// Concurrent opens for one bot must resolve to one conversation. This is the local
    /// coalescing guarantee; it does not turn the host's title lookup into a distributed lock.
    func testConcurrentOpensForOneBotCreateAtMostOneConversation() async {
        let bot = freshBot("concurrent")
        defer { UserDefaults.standard.removeObject(forKey: key(bot)) }
        let (model, host) = makeModel(bot: bot)

        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        host.onCreate = {
            enteredContinuation.yield(())
            var iterator = release.makeAsyncIterator()
            _ = await iterator.next()
        }

        let first = Task { await model.endlessSession(for: bot) }
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()
        let second = Task { await model.endlessSession(for: bot) }
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(host.createdSessions.count, 1,
                       "the second open waits for the first instead of creating a duplicate")
        releaseContinuation.yield(())
        let a = await first.value
        let b = await second.value

        XCTAssertEqual(a, "created-\(bot)-1")
        XCTAssertEqual(b, a)
        XCTAssertEqual(host.createdSessions.count, 1)
        XCTAssertEqual(model.selectedSessionID, a)
        await model.stop()
    }
}

/// Lets exactly the first caller park, so a concurrency test can hold one open while another
/// completes. The lock is only for the test's synchronous predicate; the suspension uses the
/// stream continuations.
private final class FirstCallGate: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func shouldBlock() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}

#endif
