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

    /// Resume inside a named bot.
    ///
    /// A multiplexed gateway (every machine-level one is: 15 profiles here) resolves a **stored**
    /// session id only within an explicit profile. Measured: `session.resume` with the stored id and
    /// no `profile` answers `4007 session not found` in under a second, while the same call with
    /// `"profile": "cody"` succeeds — which presented as "the conversation will not open" right after
    /// creating it. Implementations that have no profile to give fall back to the single-argument form.
    func resumeSession(_ id: SessionID, profile: String?) async throws -> SessionResume
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

    /// `model.options` as the host answered it: the catalogue **and** which entry is current.
    ///
    /// The catalogue alone cannot say what the app is talking to — the reply names it in
    /// `model` + `provider`, and the first catalogue entry is just the first provider's first
    /// model (measured: `anthropic/claude-fable`, while the live turn ran `deepseek-v4.1-flash`
    /// on `opencode-go`). Reading `providers[0].models[0]` is what put the wrong chip on screen.
    func modelCatalog() async throws -> ModelCatalog

    // Compaction
    /// `session.compress` — ask the host to summarise the session into a smaller context.
    ///
    /// `session_id` must be the **runtime** id (`GatewayClient` translates a stored id), and the
    /// call is slow by nature: the host runs a real model turn to write the summary.
    func compress(session: SessionID) async throws

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

public extension GatewayClientProtocol {
    /// Conformers with no notion of a bot (previews, the unpaired stub, tests) keep the plain call.
    func resumeSession(_ id: SessionID, profile: String?) async throws -> SessionResume {
        try await resumeSession(id)
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

    /// Whether a turn is *still running* on the host, as the resume reported it.
    ///
    /// This is the authority the UI has to adopt after a resume: a turn that finished while the
    /// socket was down leaves no `message.complete` for us to receive, so a client that keeps its
    /// own streaming flag sits on "Thinking…" forever. `inflight` nil (nothing running) and
    /// `streaming: false` (a finished-but-unflushed turn) both mean "nothing more is coming".
    public var isStreaming: Bool { inflight?.streaming == true }

    /// The partial assistant text worth keeping when `isStreaming` is false — a turn that settled
    /// unattended still wrote something, and dropping it would blank the last bubble.
    public var liveText: String { inflight?.assistantText ?? "" }
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
    public enum Role: String, Sendable {
        case user, assistant, tool, system
        /// The model's reasoning for the turn. Never sent by the host as a row — the client
        /// synthesises it when a turn ends, so the reasoning stops vanishing with the answer.
        case reasoning
    }

    /// What a `role: "tool"` row carries besides its text.
    ///
    /// The host's projection for a tool row is `{role, name, context, args?, labels?, tool_call_id,
    /// content?}` — there is no `text` at all, and `content` (the result) is only included for the
    /// editing tools. A decoder that reads `text`/`content` alone therefore renders every one of
    /// these as a nameless "Tool" card with nothing behind it, which is exactly what it did.
    public struct ToolDetail: Hashable, Sendable {
        /// The wire `name`: `terminal`, `read_file`, `patch`.
        public let name: String
        /// The host's ~80-character preview of the arguments, for the card's one-line summary.
        public let context: String?
        /// The arguments in full (pretty JSON) — the call itself, so it is always worth showing.
        public let args: String?
        /// The tool's own result, when this projection included one (edit tools only).
        public let content: String?
        /// Display labels the host pre-composed for the call, in its own order.
        public let labels: [String]

        public init(name: String,
                    context: String? = nil,
                    args: String? = nil,
                    content: String? = nil,
                    labels: [String] = []) {
            self.name = name
            self.context = context
            self.args = args
            self.content = content
            self.labels = labels
        }

        /// What a tapped card should open: the result when the host sent one, else the call itself.
        public var detail: String? {
            if let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return content
            }
            return args
        }
    }

    public let id: String
    public let rowID: Int64?
    public let role: Role
    public let text: String
    public let at: Date?
    /// Present on `role: "tool"` rows that came from the host's projection.
    public let tool: ToolDetail?

    public init(id: String,
                rowID: Int64? = nil,
                role: Role,
                text: String,
                at: Date? = nil,
                tool: ToolDetail? = nil) {
        self.id = id
        self.rowID = rowID
        self.role = role
        self.text = text
        self.at = at
        self.tool = tool
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

/// What `model.options` actually answers: everything the host can run, plus the one it *is*
/// running.
///
/// Measured body: `{"providers":[{"slug":"anthropic","models":["claude-fable",…]}, …],
/// "model":"deepseek-v4.1-flash", "provider":"opencode-go"}`. The top-level pair is the answer to
/// "what am I talking to"; `providers[].models[]` is a menu, in host order, and its first entry is
/// not the current model.
public struct ModelCatalog: Equatable, Sendable {
    /// The model the next turn will use. `nil` when the host did not name one.
    public let current: ModelOption?
    public let options: [ModelOption]

    public init(current: ModelOption?, options: [ModelOption]) {
        self.current = current
        self.options = options
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
    /// The model's reasoning, a stream of its own: `thinking.delta` arrives *without*
    /// `message.delta` text and with an empty `text` heartbeat. Mixing it into the reply would
    /// show the model thinking out loud in the answer bubble.
    case thinkingDelta(session: SessionID, text: String)
    case toolStart(session: SessionID, name: String, callID: String, input: String)
    case toolProgress(session: SessionID, callID: String, text: String)
    case toolComplete(session: SessionID, name: String?, callID: String, output: String?, ok: Bool, durationMS: Int?)
    /// `message.complete`'s `usage`: how full the context is. `percent` is the host's own rounded
    /// figure when it sent one.
    case contextUsage(session: SessionID, used: Int, max: Int, percent: Double?)
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

    /// A client that cannot tell which model is current only has its menu. Reported as "no current
    /// model" rather than guessing `options.first` — guessing is the chip bug.
    func modelCatalog() async throws -> ModelCatalog {
        ModelCatalog(current: nil, options: try await modelOptions())
    }

    /// Compaction is a host capability this build may not have (an unpaired client has no host at
    /// all). Failing honestly keeps "compacted" from being shown over a transcript nothing touched.
    func compress(session: SessionID) async throws {
        throw GatewayError.notConnected
    }
}
