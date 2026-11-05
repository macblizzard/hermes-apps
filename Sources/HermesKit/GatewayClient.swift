import Foundation

/// The one API the two apps are allowed to call.
///
/// Frozen contract for the app agents: everything below is implemented in
/// `Sources/HermesKit/` by the protocol-core work. Apps talk to `GatewayClient`
/// and observe `ClientEvent` — they never touch sockets, tickets or JSON.
public protocol GatewayClientProtocol: AnyObject, Sendable {
    /// Current transport state, for the connection chip.
    var state: TransportState { get async }

    /// Events from the gateway: streamed text, tool lifecycle, approvals, lifecycle.
    var events: AsyncStream<ClientEvent> { get }

    /// Attach to a host and perform the mandatory handshake
    /// (`gateway.ready` → `client.capabilities {server_requests:true}`).
    func connect() async throws

    func disconnect() async

    // Sessions
    /// Cheapest possible round trip: the gateway answers `{"pong": true}` without touching
    /// the session database. Used for the connection chip's latency figure — `session.list`
    /// would make the number depend on how warm the profile is (see `fixtures/NOTES.md` §4).
    func ping() async throws
    func listSessions(limit: Int) async throws -> [SessionSummary]
    func resumeSession(_ id: SessionID) async throws -> SessionResume
    func createSession(model: String?, provider: String?) async throws -> SessionID
    func history(_ id: SessionID, limit: Int) async throws -> [TranscriptEntry]

    // Turns
    func submit(session: SessionID, text: String) async throws
    func steer(session: SessionID, text: String) async throws
    func interrupt(session: SessionID) async throws
    /// Rewind + resend. Must send `confirm_truncate` and prefer `truncate_before_row_id`.
    func rewind(session: SessionID, toRowID: Int64, then text: String) async throws

    // Discovery
    func modelOptions() async throws -> [ModelOption]

    /// Answer a request the gateway sent us (approval, clarify, sudo, secret…).
    func answer(_ request: ServerRequestID, with result: JSONValue) async throws
    func decline(_ request: ServerRequestID, with error: RPCError) async throws
}

public typealias SessionID = String
public typealias ServerRequestID = RPCID

public struct SessionSummary: Identifiable, Hashable, Sendable {
    public let id: SessionID
    public let title: String
    public let updatedAt: Date?
    public let preview: String?
    public let running: Bool

    public init(id: SessionID, title: String, updatedAt: Date? = nil, preview: String? = nil, running: Bool = false) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.preview = preview
        self.running = running
    }
}

public struct SessionResume: Sendable {
    public let id: SessionID
    public let entries: [TranscriptEntry]
    /// The turn still running that history does not hold yet.
    public let inflight: InflightTurn?
    /// Approvals/clarify questions still waiting for an answer.
    public let openRequests: [ServerRequest]

    public init(id: SessionID, entries: [TranscriptEntry], inflight: InflightTurn?, openRequests: [ServerRequest]) {
        self.id = id
        self.entries = entries
        self.inflight = inflight
        self.openRequests = openRequests
    }
}

public struct InflightTurn: Sendable {
    public let userText: String
    public let assistantText: String
    public let streaming: Bool

    public init(userText: String, assistantText: String, streaming: Bool) {
        self.userText = userText
        self.assistantText = assistantText
        self.streaming = streaming
    }
}

public struct TranscriptEntry: Identifiable, Hashable, Sendable {
    public enum Role: String, Sendable { case user, assistant, tool, system }
    public let id: String
    public let rowID: Int64?
    public let role: Role
    public let text: String
    public let at: Date?

    public init(id: String, rowID: Int64? = nil, role: Role, text: String, at: Date? = nil) {
        self.id = id
        self.rowID = rowID
        self.role = role
        self.text = text
        self.at = at
    }
}

public struct ModelOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let provider: String
    public let label: String

    public init(id: String, provider: String, label: String) {
        self.id = id
        self.provider = provider
        self.label = label
    }
}

/// A request the *gateway* sends the client and blocks on.
public struct ServerRequest: Identifiable, Sendable {
    public let id: ServerRequestID
    public let method: String
    public let params: JSONValue

    public init(id: ServerRequestID, method: String, params: JSONValue) {
        self.id = id
        self.method = method
        self.params = params
    }
}

/// Everything the UI reacts to. Note the wrapped `event` envelope: on the wire these
/// arrive as `method:"event"` with `params.type` + `params.payload` (see
/// `fixtures/NOTES.md`), never as `method:"message.delta"`.
public enum ClientEvent: Sendable {
    case ready(replayEpoch: String?)
    case state(TransportState)
    case messageDelta(session: SessionID, text: String)
    case messageComplete(session: SessionID, text: String)
    case toolStart(session: SessionID, name: String, callID: String, input: JSONValue?)
    case toolProgress(session: SessionID, callID: String, text: String)
    case toolComplete(session: SessionID, callID: String, output: String?, ok: Bool, durationMS: Int?)
    case request(ServerRequest)
    case requestCancelled(id: ServerRequestID, reason: String?)
    case sessionUpdated(SessionID)
    case error(code: Int?, message: String)
    /// Any event we do not model yet. Kept so a Hermes upgrade never breaks the client.
    case unknown(type: String, payload: JSONValue)
}
