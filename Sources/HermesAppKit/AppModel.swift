#if canImport(Combine)
import Foundation
import Combine
import HermesKit

/// Shared application state for both apps.
///
/// One `AppModel` per window (macOS) or per app (iOS). It owns *what the user sees*:
/// the connection chip, the session list, the open transcript, the live approval.
/// It owns no sockets and no JSON — all of that is `GatewayClientProtocol`.
///
/// Ownership note: this file is the contract between the macOS and iOS screens. Add
/// to it freely; do not rename or remove members without updating both apps.
@MainActor
public final class AppModel: ObservableObject {

    // MARK: Connection

    public enum Connection: Equatable {
        case idle, connecting, connected, reconnecting(attempt: Int), failed(String), offline

        public var label: String {
            switch self {
            case .idle: return "not connected"
            case .connecting: return "connecting"
            case .connected: return "direct"
            case .reconnecting(let n): return "reconnecting (\(n))"
            case .failed(let why): return why
            case .offline: return "offline"
            }
        }

        public var isLive: Bool { self == .connected }
    }

    @Published public private(set) var connection: Connection = .idle
    @Published public private(set) var hostName: String = "hermes"
    /// Round-trip time of the last `ping`, for the connection chip.
    @Published public private(set) var latencyMS: Int?

    // MARK: Sessions

    @Published public private(set) var sessions: [SessionSummary] = []
    @Published public private(set) var sessionsLoading = false
    @Published public var selectedSessionID: SessionID?
    @Published public private(set) var transcript: [TranscriptEntry] = []
    @Published public private(set) var runningSessions: Set<SessionID> = []

    // MARK: Live turn

    /// Text still streaming into the last assistant bubble.
    @Published public private(set) var streamingText: String = ""
    @Published public private(set) var isStreaming = false

    // MARK: Questions the agent is blocked on

    @Published public private(set) var pendingRequests: [ServerRequest] = []

    // MARK: Composer

    @Published public var draft: String = ""
    @Published public private(set) var sending = false

    /// Set when a send failed, so the UI can offer "retry" instead of losing the draft.
    @Published public private(set) var lastSendError: String?

    private let client: GatewayClientProtocol
    private var eventTask: Task<Void, Never>?

    public init(client: GatewayClientProtocol, hostName: String = "hermes") {
        self.client = client
        self.hostName = hostName
    }

    // MARK: Lifecycle

    public func start() async {
        connection = .connecting
        do {
            try await client.connect()
            connection = .connected
            await observeEvents()
            await loadSessions()
        } catch {
            connection = .failed(error.localizedDescription)
        }
    }

    public func stop() async {
        eventTask?.cancel()
        eventTask = nil
        await client.disconnect()
        connection = .offline
    }

    // MARK: Sessions

    public func loadSessions() async {
        sessionsLoading = true
        defer { sessionsLoading = false }
        do {
            sessions = try await client.listSessions(limit: 50)
        } catch {
            // A silent gateway must not look like "no sessions" — surface it.
            connection = .failed("could not load sessions: \(error.localizedDescription)")
        }
    }

    public func select(_ id: SessionID) async {
        selectedSessionID = id
        transcript = []
        streamingText = ""
        pendingRequests = []
        do {
            let resumed = try await client.resumeSession(id)
            transcript = resumed.entries
            pendingRequests = resumed.openRequests
            if let inflight = resumed.inflight {
                streamingText = inflight.assistantText
                isStreaming = inflight.streaming
                if inflight.streaming { runningSessions.insert(id) }
            }
        } catch {
            connection = .failed("could not resume session: \(error.localizedDescription)")
        }
    }

    // MARK: Turn

    public func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let sid = selectedSessionID, !sending else { return }
        sending = true
        lastSendError = nil
        draft = ""
        transcript.append(TranscriptEntry(id: UUID().uuidString, role: .user, text: text))
        streamingText = ""
        isStreaming = true
        runningSessions.insert(sid)
        do {
            try await client.submit(session: sid, text: text)
        } catch {
            isStreaming = false
            lastSendError = error.localizedDescription
            draft = text // never lose what the user typed
            transcript.removeLast()
        }
        sending = false
    }

    public func interrupt() async {
        guard let sid = selectedSessionID else { return }
        try? await client.interrupt(session: sid)
    }

    // MARK: Approvals

    public func answer(_ request: ServerRequest, choice: String) async {
        try? await client.answer(request.id, with: .object(["choice": .string(choice)]))
        pendingRequests.removeAll { $0.id == request.id }
    }

    public func answers(_ request: ServerRequest, _ answers: [String: String]) async {
        let value = JSONValue.object(answers.mapValues { JSONValue.string($0) })
        try? await client.answer(request.id, with: .object(["answers": value]))
        pendingRequests.removeAll { $0.id == request.id }
    }

    public func decline(_ request: ServerRequest) async {
        try? await client.decline(request.id, with: .methodNotFound)
        pendingRequests.removeAll { $0.id == request.id }
    }

    // MARK: Events

    private func observeEvents() async {
        eventTask?.cancel()
        let events = client.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.apply(event)
            }
        }
    }

    private func apply(_ event: ClientEvent) async {
        switch event {
        case .ready:
            connection = .connected
        case .state(let state):
            switch state {
            case .open: connection = .connected
            case .connecting: connection = .connecting
            case .reconnecting(let n): connection = .reconnecting(attempt: n)
            case .closed, .idle: break
            case .failed(let why): connection = .failed(why)
            }
        case .messageDelta(let session, let text):
            guard session == selectedSessionID else { return }
            isStreaming = true
            runningSessions.insert(session)
            streamingText += text
        case .messageComplete(let session, let text):
            guard session == selectedSessionID else { return }
            transcript.append(TranscriptEntry(id: UUID().uuidString, role: .assistant, text: text))
            streamingText = ""
            isStreaming = false
            runningSessions.remove(session)
        case .request(let request):
            pendingRequests.append(request)
        case .requestCancelled(let id, _):
            pendingRequests.removeAll { $0.id == id }
        case .sessionUpdated(let session):
            if session == selectedSessionID { /* keep transcript; a refresh comes from resume */ }
            await loadSessions()
        case .error(_, let message):
            lastSendError = message
        case .toolStart, .toolProgress, .toolComplete, .unknown:
            break // tool cards are rendered from the transcript projection (M1)
        }
    }
}

// MARK: - Previews

/// A client that answers nothing, so SwiftUI previews and CI snapshots never touch a network.
public final class PreviewGatewayClient: GatewayClientProtocol, @unchecked Sendable {
    public var state: TransportState { get async { .open } }

    public let events: AsyncStream<ClientEvent>

    public init() {
        var continuation: AsyncStream<ClientEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        continuation.yield(.ready(replayEpoch: nil))
    }

    public func connect() async throws {}
    public func disconnect() async {}
    public func listSessions(limit: Int) async throws -> [SessionSummary] {
        [SessionSummary(id: "preview-1", title: "Vault backup + docs sync", preview: "Streaming · 42s", running: true),
         SessionSummary(id: "preview-2", title: "Tailscale ACL audit", preview: "Reviewed 3 tags · no drift")]
    }
    public func resumeSession(_ id: SessionID) async throws -> SessionResume {
        SessionResume(id: id,
                      entries: [TranscriptEntry(id: "1", role: .user, text: "Back up the vault and re-sync docs."),
                                TranscriptEntry(id: "2", role: .assistant, text: "Snapshotting the vault first, then I'll diff the docs tree.")],
                      inflight: nil,
                      openRequests: [])
    }
    public func createSession(model: String?, provider: String?) async throws -> SessionID { "preview-new" }
    public func history(_ id: SessionID, limit: Int) async throws -> [TranscriptEntry] { [] }
    public func submit(session: SessionID, text: String) async throws {}
    public func steer(session: SessionID, text: String) async throws {}
    public func interrupt(session: SessionID) async throws {}
    public func rewind(session: SessionID, toRowID: Int64, then text: String) async throws {}
    public func modelOptions() async throws -> [ModelOption] {
        [ModelOption(id: "deepseek-v4.1-flash", provider: "opencode-go", label: "DeepSeek V4.1 Flash")]
    }
    public func answer(_ request: ServerRequestID, with result: JSONValue) async throws {}
    public func decline(_ request: ServerRequestID, with error: RPCError) async throws {}
}
#endif
