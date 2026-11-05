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

    // Bots
    /// The bots (Hermes **profiles**) this one gateway serves.
    ///
    /// `gateway.multiplex_profiles` is true by default, so a host is not one assistant: it is an
    /// address book of them, and every session belongs to exactly one. There is no second
    /// connection and no second ticket — just a `profile` argument on the calls below.
    func listBots() async throws -> [Bot]

    // Sessions
    /// Cheapest possible round trip: the gateway answers `{"pong": true}` without touching
    /// the session database. Used for the connection chip's latency figure — `session.list`
    /// would make the number depend on how warm the profile is (see `fixtures/NOTES.md` §4).
    func ping() async throws
    func listSessions(limit: Int) async throws -> [SessionSummary]
    /// `listSessions`, scoped to one bot.
    ///
    /// - Parameters:
    ///   - profile: the bot's `id`. `nil` means "whatever profile this gateway defaults to",
    ///     which is what an unpaired/older host can answer.
    ///   - includeHidden: **must stay `true`** on any surface with a bots pane. A normal profile
    ///     reports 0 rows under the gateway's default filter (measured: `cody` 0 → 1,
    ///     `jason` 5, `anika` 2, `atlas` 1 with `include_hidden`), so `false` here reads as
    ///     "this bot has no sessions" instead of "this bot exists".
    func listSessions(limit: Int, profile: String?, includeHidden: Bool) async throws -> [SessionSummary]
    func resumeSession(_ id: SessionID) async throws -> SessionResume
    func createSession(model: String?, provider: String?) async throws -> SessionID
    /// Create a session **inside one bot**.
    ///
    /// The gateway's `session.create` accepts `profile` and stores the resulting `profile_home`,
    /// so every later turn of that session re-binds to it (`tui_gateway/methods_session.py::
    /// _create_session`). Without the argument a new session always lands in whichever profile the
    /// gateway defaults to, which is how a user ends up typing into the wrong bot.
    func createSession(model: String?, provider: String?, profile: String?) async throws -> SessionID
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

/// One bot: a Hermes **profile**.
///
/// Measured against the deployed gateway: `profiles.list` answers
/// `{"profiles":[…], "bot_mode_protocol":…, "install_id":…}` with 15 entries for this host, and
/// `session.list {profile:"<name>", include_hidden:true}` returns that bot's own rows. So the bot
/// switcher is one call plus one argument — never a second connection.
///
/// `id` is the wire value (what `profile` accepts), never a prettified label, so selecting a bot
/// is a lookup rather than a string transform.
public struct Bot: Identifiable, Hashable, Sendable {
    /// The profile name exactly as the host reported it; the value `session.list` takes as `profile`.
    public let id: String
    /// The same name, spelled out for callers that think in profiles rather than bots.
    public let name: String
    /// What the switcher renders. Falls back to `name` when the host sends no label of its own.
    public let displayName: String
    /// A one-token label for compact chrome (menu bar item, navigation title).
    public let label: String
    /// One or two characters for the avatar circle ("cody" → "C", "corvus-ops" → "CO").
    public let avatarInitials: String

    public init(id: String,
                name: String? = nil,
                displayName: String? = nil,
                label: String? = nil,
                avatarInitials: String? = nil) {
        let resolvedName = Self.trimmed(name) ?? id
        let resolvedDisplay = Self.trimmed(displayName) ?? resolvedName
        self.id = id
        self.name = resolvedName
        self.displayName = resolvedDisplay
        self.label = Self.trimmed(label) ?? resolvedDisplay
        self.avatarInitials = Self.trimmed(avatarInitials) ?? Self.initials(for: resolvedDisplay)
    }

    /// First letter of the name, or of its first two words ("cody" → "C", "night-shift" → "NS").
    /// An avatar is never sent on the wire, so it is derived rather than decoded.
    static func initials(for text: String) -> String {
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.count >= 2, let first = words[0].first, let second = words[1].first {
            return String([first, second]).uppercased()
        }
        return String(text.prefix(1)).uppercased()
    }

    static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

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

    /// What a row should render when the host has no title yet.
    ///
    /// Measured on this host: 10 of the default bot's 17 sessions are untitled, so a sidebar that
    /// prints `title` draws a column of question marks and reads as broken. Titles arrive from the
    /// gateway only once a turn has been summarised, so the honest fallbacks are, in order: the
    /// first line of the preview, then an explicit "Untitled session".
    public var displayTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty { return trimmedTitle }
        if let preview {
            let line = preview.split(separator: "\n").first.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !line.isEmpty { return String(line.prefix(60)) }
        }
        return "Untitled session"
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

// MARK: - Defaults that keep the frozen contract source-compatible

public extension GatewayClientProtocol {
    /// Unscoped fallback for a client that cannot address a profile — today that is only the
    /// unpaired app, whose every verb already throws `noHost`.
    ///
    /// It delegates to the single-argument call *on purpose*: a client that can scope must
    /// implement this overload, because quietly ignoring `profile` is exactly how one bot's rows
    /// end up under another bot's name.
    func listSessions(limit: Int, profile: String?, includeHidden: Bool) async throws -> [SessionSummary] {
        try await listSessions(limit: limit)
    }

    /// A client with no host cannot enumerate bots. Failing is honest; `[]` would render as
    /// "your host has no bots", which is a different and wrong story.
    func listBots() async throws -> [Bot] {
        throw GatewayError.notConnected
    }

    /// Unscoped fallback for a client that cannot address a profile (the unpaired app, previews).
    /// A client that *can* scope must implement the profile-aware overload.
    func createSession(model: String?, provider: String?, profile: String?) async throws -> SessionID {
        try await createSession(model: model, provider: provider)
    }
}
