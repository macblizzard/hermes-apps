#if canImport(Combine)
import Foundation
import HermesKit

/// A gateway that answers from a script instead of a socket, so `AppModel`'s state machine can be
/// driven event by event.
///
/// Only the calls the tests use return anything meaningful; the rest throw `GatewayError.notConnected`
/// on purpose — an unexpected call is a bug in the test, not something to paper over with `nil`.
final class ScriptedHost: GatewayClientProtocol, @unchecked Sendable {

    let session: SessionID
    /// The transcript a resume answers with. Tests rewrite it to model what the host persisted.
    var entries: [TranscriptEntry]
    private(set) var submitted: [String] = []

    private let continuation: AsyncStream<ClientEvent>.Continuation
    let events: AsyncStream<ClientEvent>

    init(session: SessionID, entries: [TranscriptEntry] = []) {
        self.session = session
        self.entries = entries
        var captured: AsyncStream<ClientEvent>.Continuation!
        events = AsyncStream { captured = $0 }
        continuation = captured
    }

    var state: TransportState { get async { .open } }

    /// Push one wire event into the model.
    func emit(_ event: ClientEvent) { continuation.yield(event) }

    // MARK: Handshake

    func connect() async throws {}
    func disconnect() async {}

    // MARK: Bots

    func listBots() async throws -> [Bot] { [Bot(id: "cody")] }

    // MARK: Sessions

    func ping() async throws {}
    func listSessions(limit: Int) async throws -> [SessionSummary] { [summary] }
    func listSessions(limit: Int, profile: String?, includeHidden: Bool) async throws -> [SessionSummary] { [summary] }

    private var summary: SessionSummary {
        SessionSummary(id: session, title: "test thread")
    }

    func resumeSession(_ id: SessionID) async throws -> SessionResume { resume() }
    func resumeSession(_ id: SessionID, profile: String?) async throws -> SessionResume { resume() }

    private func resume() -> SessionResume {
        SessionResume(id: session, entries: entries, inflight: nil, openRequests: [])
    }

    func createSession(model: String?, provider: String?) async throws -> SessionID { session }
    func createSession(model: String?, provider: String?, profile: String?) async throws -> SessionID { session }
    func history(_ id: SessionID, limit: Int) async throws -> [TranscriptEntry] { entries }

    // MARK: Turns

    func submit(session: SessionID, text: String) async throws { submitted.append(text) }
    func steer(session: SessionID, text: String) async throws {}
    func interrupt(session: SessionID) async throws {}
    func rewind(session: SessionID, toRowID: Int64, then text: String) async throws {}

    // MARK: Discovery

    func modelOptions() async throws -> [ModelOption] { [] }
    func modelCatalog() async throws -> ModelCatalog { ModelCatalog(current: nil, options: []) }

    // MARK: Compaction and requests

    func compress(session: SessionID) async throws {}
    func answer(_ request: ServerRequestID, with result: JSONValue) async throws {}
    func decline(_ request: ServerRequestID, with error: RPCError) async throws {}
}
#endif
