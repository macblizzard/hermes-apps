import Foundation
import XCTest
@testable import HermesKit

/// Selection ordering is enforced below the UI: a resume whose bot the user has already left must
/// not re-bind the transport when its reply finally arrives. These tests hold the old reply with a
/// continuation and complete a newer selection first, so the interleaving is deterministic.
final class SessionSelectionOrderingTests: XCTestCase {

    private func makeClient(_ gateway: FakeGateway) -> GatewayClient {
        GatewayClient(makeTransport: { gateway.bridge() },
                      timeouts: .testing,
                      reconnect: .disabled)
    }

    private func alphaBeta(_ gateway: FakeGateway) async {
        await gateway.setResult(FakeGateway.resumeResult(storedID: "alpha", runtimeID: "rt-alpha"),
                                for: "session.resume", whenParam: "session_id", equals: "alpha")
        await gateway.setResult(FakeGateway.resumeResult(storedID: "beta", runtimeID: "rt-beta"),
                                for: "session.resume", whenParam: "session_id", equals: "beta")
    }

    func testAStaleResumeCannotAttachAfterANewerResume() async throws {
        let gateway = FakeGateway()
        await alphaBeta(gateway)
        let client = makeClient(gateway)
        try await client.connect()

        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        await gateway.setOnRequest { method, params in
            guard method == "session.resume",
                  params?["session_id"]?.stringValue == "alpha" else { return }
            enteredContinuation.yield(())
            var iterator = release.makeAsyncIterator()
            _ = await iterator.next()
        }

        let stale = Task { try await client.resumeSession("alpha", profile: "alpha") }
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()

        // The newer bot is selected and attached before the old reply is allowed to land.
        _ = try await client.resumeSession("beta", profile: "beta")
        releaseContinuation.yield(())

        // The stale call may still return its own data; what matters is that it did not attach.
        _ = try await stale.value

        // The transport still translates beta's stored id to beta's runtime id. If the stale
        // alpha reply had attached, beta would no longer be addressable by its runtime id.
        try await client.submit(session: "beta", text: "still beta")
        let betaSubmit = await gateway.params(method: "prompt.submit")
        XCTAssertEqual(betaSubmit?["session_id"]?.stringValue, "rt-beta")

        // And alpha was never attached: its stored id is passed through untouched.
        try await client.submit(session: "alpha", text: "not attached")
        let alphaSubmit = await gateway.params(method: "prompt.submit")
        XCTAssertEqual(alphaSubmit?["session_id"]?.stringValue, "alpha")
    }

    func testAnExplicitSelectionInvalidatesAResumeEvenBeforeTheNewResumeStarts() async throws {
        let gateway = FakeGateway()
        await alphaBeta(gateway)
        let client = makeClient(gateway)
        try await client.connect()

        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        await gateway.setOnRequest { method, params in
            guard method == "session.resume",
                  params?["session_id"]?.stringValue == "alpha" else { return }
            enteredContinuation.yield(())
            var iterator = release.makeAsyncIterator()
            _ = await iterator.next()
        }

        let stale = Task { try await client.resumeSession("alpha", profile: "alpha") }
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()

        // The UI has selected another bot, but its own resume has not left yet.
        await client.beginSessionSelection()
        releaseContinuation.yield(())

        _ = try await stale.value

        try await client.submit(session: "alpha", text: "not attached")
        let submit = await gateway.params(method: "prompt.submit")
        XCTAssertEqual(submit?["session_id"]?.stringValue, "alpha",
                       "no runtime translation means the stale alpha resume never attached")
    }

    func testAReconnectCannotReattachTheOldBotOverANewerResume() async throws {
        let first = FakeGateway()
        let second = FakeGateway()
        let feeder = TransportFeeder([first.bridge(), second.bridge()])
        let client = GatewayClient(makeTransport: { try feeder.next() },
                                   timeouts: .testing,
                                   reconnect: .init(enabled: true, maxAttempts: 2,
                                                    initialDelay: 0.01, multiplier: 1, maxDelay: 0.01))
        await alphaBeta(second)
        await second.setResult(FakeGateway.resumeResult(storedID: "alpha", runtimeID: "rt-alpha"),
                               for: "session.resume", whenParam: "session_id", equals: "alpha")
        try await client.connect()
        _ = try await client.resumeSession("alpha", profile: "alpha")

        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        await second.setOnRequest { method, params in
            guard method == "session.resume",
                  params?["session_id"]?.stringValue == "alpha" else { return }
            enteredContinuation.yield(())
            var iterator = release.makeAsyncIterator()
            _ = await iterator.next()
        }

        await first.drop("socket died")
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()

        // While the reconnect's old alpha resume is parked, the user selects beta.
        _ = try await client.resumeSession("beta", profile: "beta")
        releaseContinuation.yield(())
        try? await Task.sleep(nanoseconds: 50_000_000)

        try await client.submit(session: "beta", text: "still beta")
        let submit = await second.params(method: "prompt.submit")
        XCTAssertEqual(submit?["session_id"]?.stringValue, "rt-beta",
                       "the stale reconnect must not put the old bot back on the transport")
    }
}
