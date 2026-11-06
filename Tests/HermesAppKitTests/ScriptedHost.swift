#if canImport(Combine)
import Foundation
import HermesAppKit
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
    private(set) var steered: [String] = []
    /// Fail the next steer with this, after recording the text (as the real client does).
    var steerError: Error?
    /// Park `steer` here to inspect the model's in-flight state deterministically.
    var onSteer: (@Sendable () async -> Void)?
    /// Attachment and submit failure injection for composer-retention regressions.
    private(set) var attached: [(name: String, isImage: Bool)] = []
    var attachError: Error?
    var submitError: Error?
    var onAttach: (@Sendable () async -> Void)?
    var onSubmit: (@Sendable () async -> Void)?

    /// Failure injection for canonical conversation lifecycle tests.
    var createError: Error?
    var titleError: Error?
    /// When set, `titleError` applies only to this session (so archiving one row can fail while
    /// publishing the replacement succeeds).
    var titleErrorForID: SessionID?
    var resumeError: Error?
    /// Park a call here to drive concurrency / navigation deterministically.
    var onCreate: (@Sendable () async -> Void)?
    var onTitle: (@Sendable (_ id: SessionID, _ title: String) async -> Void)?

    private let continuation: AsyncStream<ClientEvent>.Continuation
    private let scriptedEvents: AsyncStream<ClientEvent>
    // Lifecycle regressions use the real client's subscription implementation while retaining
    // this host's deterministic session/catalogue responses. Existing fixtures remain unchanged.
    private let eventClient: GatewayClientProtocol?
    var events: AsyncStream<ClientEvent> { eventClient?.events ?? scriptedEvents }

    init(session: SessionID, entries: [TranscriptEntry] = [],
         eventClient: GatewayClientProtocol? = nil) {
        self.session = session
        self.entries = entries
        self.eventClient = eventClient
        var captured: AsyncStream<ClientEvent>.Continuation!
        scriptedEvents = AsyncStream { captured = $0 }
        continuation = captured
    }

    var state: TransportState { get async { .open } }

    /// Push one wire event into the model.
    func emit(_ event: ClientEvent) { continuation.yield(event) }

    // MARK: Handshake

    func connect() async throws { try await eventClient?.connect() }
    func disconnect() async { await eventClient?.disconnect() }

    // MARK: Bots

    var bots: [Bot] = [Bot(id: "cody")]
    /// Every `configureDescription` call, so a test can prove what crossed the client boundary.
    private(set) var descriptions: [(String, String)] = []
    /// The host-side canonical rows a test wants the client to find (`profile → stored id`).
    var canonicalSessions: [String: SessionID] = [:]
    /// What `session.most_recent` answers for a profile.
    var mostRecentSessions: [String: SessionID] = [:]
    /// Titles the client asked the host to write, in order.
    private(set) var titleWrites: [(SessionID, String)] = []
    /// Titles the host actually stores, after a successful write.
    private(set) var storedTitles: [SessionID: String] = [:]
    private var createdOwner: [SessionID: String] = [:]
    /// Creates the client requested, with the bot and title it sent.
    private(set) var createdSessions: [(profile: String?, title: String?)] = []
    /// Sessions the client tried to resume, so tests can prove unrelated rows are never touched.
    private(set) var resumedIDs: [SessionID] = []

    func listBots() async throws -> [Bot] { bots }

    func configureDescription(profile: String, description: String) async throws {
        descriptions.append((profile, description))
    }

    // MARK: Sessions

    func ping() async throws {}
    func listSessions(limit: Int) async throws -> [SessionSummary] { [summary] }
    func listSessions(limit: Int, profile: String?, includeHidden: Bool) async throws -> [SessionSummary] { [summary] }

    private var summary: SessionSummary {
        SessionSummary(id: session, title: "test thread")
    }

    func resumeSession(_ id: SessionID) async throws -> SessionResume {
        try await resumeSession(id, profile: nil)
    }
    func resumeSession(_ id: SessionID, profile: String?) async throws -> SessionResume {
        resumedIDs.append(id)
        if let resumeError { throw resumeError }
        return resume()
    }

    private func resume() -> SessionResume {
        SessionResume(id: session, entries: entries, inflight: nil, openRequests: [])
    }

    func createSession(model: String?, provider: String?) async throws -> SessionID { session }
    func createSession(model: String?, provider: String?, profile: String?) async throws -> SessionID { session }
    func createSession(model: String?, provider: String?,
                       profile: String?, title: String?) async throws -> SessionID {
        createdSessions.append((profile, title))
        if let onCreate { await onCreate() }
        if let createError { throw createError }
        let created = "created-\(profile ?? "default")-\(createdSessions.count)"
        if let profile { createdOwner[created] = profile }
        // A title passed to `session.create` is a *pending* title on the real host; the row
        // becomes discoverable by exact title only after the title write or first prompt.
        _ = title
        return created
    }

    func sessionID(titled title: String, profile: String?) async throws -> SessionID? {
        if let seeded = canonicalSessions[profile ?? ""] { return seeded }
        return storedTitles.first { $0.value == title }?.key
    }

    func mostRecentSession(profile: String?) async throws -> SessionID? {
        mostRecentSessions[profile ?? ""]
    }

    func setSessionTitle(_ id: SessionID, title: String) async throws {
        titleWrites.append((id, title))
        if let onTitle { await onTitle(id, title) }
        if let titleError, titleErrorForID == nil || titleErrorForID == id {
            throw titleError
        }
        storedTitles[id] = title
        let owner = createdOwner[id]
        let seededProfiles = canonicalSessions.compactMap { $0.value == id ? $0.key : nil }
        for profile in Set([owner].compactMap { $0 } + seededProfiles) {
            if title == AppModel.canonicalConversationTitle {
                canonicalSessions[profile] = id
            } else if canonicalSessions[profile] == id {
                canonicalSessions.removeValue(forKey: profile)
            }
        }
    }

    func history(_ id: SessionID, limit: Int) async throws -> [TranscriptEntry] { entries }

    // MARK: Turns

    func attach(session: SessionID, name: String, data: Data, isImage: Bool) async throws -> AttachmentReceipt {
        if let onAttach { await onAttach() }
        if let attachError { throw attachError }
        attached.append((name, isImage))
        return AttachmentReceipt(refText: isImage ? nil : "@file:\(name)")
    }

    func submit(session: SessionID, text: String) async throws {
        if let onSubmit { await onSubmit() }
        if let submitError { throw submitError }
        submitted.append(text)
    }
    func steer(session: SessionID, text: String) async throws {
        steered.append(text)
        if let onSteer { await onSteer() }
        if let steerError { throw steerError }
    }
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
