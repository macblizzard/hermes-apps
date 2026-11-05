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

    // MARK: Bots

    /// Every bot (Hermes profile) this host serves, in the host's own order.
    ///
    /// Empty until `loadBots()` succeeds. A host that predates `profiles.list` leaves this empty
    /// and the app falls back to one unscoped session list — degraded, but not broken.
    @Published public private(set) var bots: [Bot] = []
    @Published public private(set) var botsLoading = false
    /// The bot whose sessions and transcript are on screen. `nil` means "not chosen yet", which
    /// is also what an unscoped `session.list` means.
    @Published public private(set) var selectedBotID: String?
    /// Why the bot directory could not be read. The bot pane says so rather than "no bots".
    @Published public private(set) var botsError: String?

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
    /// Bumped whenever the selected bot changes. An in-flight `session.list` compares it before
    /// publishing, so a slow answer for the bot we left cannot overwrite the bot we are on.
    private var botEpoch = 0

    public init(client: GatewayClientProtocol, hostName: String = "hermes") {
        self.client = client
        self.hostName = hostName
    }

    // MARK: Lifecycle

    /// Connect, then learn the bots, then read the selected bot's sessions.
    ///
    /// The order is the contract: every session row is scoped to one profile, so a list fetched
    /// before the bot is known would have to be thrown away (or worse, shown).
    public func start() async {
        connection = .connecting
        do {
            try await client.connect()
            connection = .connected
            await observeEvents()
            await loadBots()
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

    /// Read the bot directory (Hermes profiles) and settle on a default selection.
    ///
    /// Not fatal on failure: an older host answers `session.list` but not `profiles.list`, and one
    /// unscoped list is still better than a dead window. The reason is kept in `botsError` so the
    /// bot pane can say what happened instead of implying this host has no bots.
    public func loadBots() async {
        botsLoading = true
        defer { botsLoading = false }
        do {
            let loaded = try await client.listBots()
            bots = loaded
            botsError = nil
            if selectedBotID == nil || !loaded.contains(where: { $0.id == selectedBotID }) {
                selectedBotID = Self.defaultBot(in: loaded, hostName: hostName)?.id
            }
        } catch {
            botsError = error.localizedDescription
        }
    }

    /// The bot to open with: the host name itself when it is also a profile (a host paired as
    /// `cody` should land on `cody`), otherwise the first bot the host listed.
    static func defaultBot(in bots: [Bot], hostName: String) -> Bot? {
        let wanted = hostName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return bots.first { $0.id.lowercased() == wanted || $0.name.lowercased() == wanted }
            ?? bots.first
    }

    /// The selected bot's sessions.
    ///
    /// `includeHidden` is deliberately not exposed here: on this backend a normal profile returns
    /// zero rows without it, so a bots surface that omits it shows every bot as empty.
    public func loadSessions() async {
        let bot = selectedBotID
        let epoch = botEpoch
        sessionsLoading = true
        defer { if epoch == botEpoch { sessionsLoading = false } }
        do {
            let loaded = try await client.listSessions(limit: 50, profile: bot, includeHidden: true)
            // Rows requested for the bot we have since left are *another bot's* sessions. Landing
            // them under this name is exactly the mix the switcher exists to prevent.
            guard epoch == botEpoch else { return }
            sessions = loaded
        } catch {
            guard epoch == botEpoch else { return }
            // A silent gateway must not look like "no sessions" — surface it.
            connection = .failed("could not load sessions: \(error.localizedDescription)")
        }
    }

    /// Switch bots.
    ///
    /// Everything on screen belongs to the bot it came from — the transcript, the pending
    /// questions, the half-streamed turn, the running set — so all of it is dropped *before* the
    /// new bot's list is fetched. A failed load therefore leaves an empty pane, never the previous
    /// bot's conversation under the new bot's name.
    public func selectBot(_ id: String?) async {
        let resolved = id ?? Self.defaultBot(in: bots, hostName: hostName)?.id
        guard resolved != selectedBotID else {
            await loadSessions()
            return
        }
        resetForBotSwitch()
        selectedBotID = resolved
        await loadSessions()
    }

    private func resetForBotSwitch() {
        botEpoch += 1
        selectedSessionID = nil
        sessions = []
        transcript = []
        streamingText = ""
        isStreaming = false
        runningSessions = []
        pendingRequests = []
        sending = false
        lastSendError = nil
    }

    public func select(_ id: SessionID) async {
        selectedSessionID = id
        transcript = []
        streamingText = ""
        isStreaming = false
        pendingRequests = []
        // A resume that is still in flight when the bot (or the session) changes must not land:
        // it carries the transcript of the thing the user just left.
        let epoch = botEpoch
        do {
            let resumed = try await client.resumeSession(id)
            guard epoch == botEpoch, selectedSessionID == id else { return }
            transcript = resumed.entries
            pendingRequests = resumed.openRequests
            if let inflight = resumed.inflight {
                streamingText = inflight.assistantText
                isStreaming = inflight.streaming
                if inflight.streaming { runningSessions.insert(id) }
            }
        } catch {
            guard epoch == botEpoch, selectedSessionID == id else { return }
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
        let optimisticID = UUID().uuidString
        transcript.append(TranscriptEntry(id: optimisticID, role: .user, text: text))
        streamingText = ""
        isStreaming = true
        runningSessions.insert(sid)
        do {
            try await client.submit(session: sid, text: text)
        } catch {
            isStreaming = false
            lastSendError = error.localizedDescription
            draft = text // never lose what the user typed
            // By id, not by position: switching bots or sessions while the submit was in flight
            // empties the transcript, and a blind `removeLast()` would trap on it.
            transcript.removeAll { $0.id == optimisticID }
        }
        sending = false
    }

    public func interrupt() async {
        guard let sid = selectedSessionID else { return }
        try? await client.interrupt(session: sid)
    }

    // MARK: Sessions (macOS workspace additions)

    /// Start a fresh session on the host and open it.
    ///
    /// The list is reloaded *before* selecting so the new row exists in the sidebar by the
    /// time the conversation pane switches to it.
    public func newSession(model: String? = nil, provider: String? = nil) async {
        sessionsLoading = true
        defer { sessionsLoading = false }
        do {
            let created = try await client.createSession(model: model, provider: provider, profile: selectedBotID)
            sessions = try await client.listSessions(limit: 50, profile: selectedBotID, includeHidden: true)
            await select(created)
        } catch {
            lastSendError = "could not start a session: \(error.localizedDescription)"
        }
    }

    /// Retry a dropped connection without losing the open session.
    public func retryConnection() async {
        let previous = selectedSessionID
        await start()
        if let previous, sessions.contains(where: { $0.id == previous }) {
            await select(previous)
        }
    }

    // MARK: Latency

    /// Round-trip time of one real request, for the connection chip.
    ///
    /// This is a `ping`: the gateway answers `{"pong": true}` without touching the session
    /// database, so the number measures the wire and not how warm the profile happens to be.
    /// (`session.list` was the earlier probe and it is exactly the call observed taking 60 s
    /// on a cold profile — `fixtures/NOTES.md` §4.) A host that never answers publishes
    /// **nothing**: the chip keeps its label without a number instead of inventing one.
    public func refreshLatency(budget: TimeInterval = 6) async {
        guard connection.isLive else {
            latencyMS = nil
            return
        }
        let client = self.client
        let started = Date()
        let answered = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                do { try await client.ping(); return true } catch { return false }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0.5, budget) * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        guard answered else { return }
        latencyMS = max(0, Int(Date().timeIntervalSince(started) * 1000))
    }

    // MARK: Derived state

    /// The bot whose pane is on screen, for the switcher's title and avatar.
    public var selectedBot: Bot? {
        guard let selectedBotID else { return nil }
        return bots.first { $0.id == selectedBotID }
    }

    public var selectedSession: SessionSummary? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }

    public var hasPendingRequests: Bool { !pendingRequests.isEmpty }

    /// The turn is live or the submit is still in flight.
    public var isBusy: Bool { isStreaming || sending }

    public func clearSendError() { lastSendError = nil }

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

    /// Refuse a request the client cannot render *at all*.
    ///
    /// This sends JSON-RPC `-32601`, and Hermes deliberately reads that as "no client here can
    /// answer this" — it *withdraws* the queued approval and tells the agent to update the app.
    /// It is NOT a denial: nothing was refused. Use `deny(_:)` when the user pressed Deny.
    public func decline(_ request: ServerRequest) async {
        try? await client.decline(request.id, with: .methodNotFound)
        pendingRequests.removeAll { $0.id == request.id }
    }

    // MARK: Answering an approval

    /// The tokens the host offers for this request, in the host's own order.
    ///
    /// `tui_gateway/server.py::_approval_request_payload` computes `choices` as `["once"]`,
    /// plus `"session"` unless `smart_denied`/`allow_session is False`, plus `"always"` unless
    /// `allow_permanent is False`, then always `"deny"`. The client renders exactly these: a
    /// smart-denied command legitimately arrives with only `["once","deny"]`.
    public static func choices(for request: ServerRequest) -> [String] {
        guard case .array(let values)? = request.params["choices"] else { return [] }
        return values.compactMap { $0.stringValue }
    }

    /// The session a server request is about. `approval`/`clarify` carry `session`; a resumed
    /// `open_requests` entry carries `session_id`. `nil` means the host did not say.
    public static func sessionID(of request: ServerRequest) -> SessionID? {
        request.params["session_id"]?.stringValue ?? request.params["session"]?.stringValue
    }

    /// Answer with one of `choices(for:)`.
    ///
    /// The wire shape is `{"choice": <token>, "all": <bool>}` — verified in
    /// `tui_gateway/server.py::_emit_approval_request`, which does
    /// `choice = str(result.get("choice") or "deny")`. Any other key is ignored, so a client
    /// that sends `{"approved": true}` is read as a **deny**. That is why this method takes a
    /// token rather than a boolean.
    public func respond(_ request: ServerRequest, choice: String, all: Bool = false) async {
        let params: JSONValue = .object([
            "choice": .string(choice),
            "all": .bool(all),
        ])
        try? await client.answer(request.id, with: params)
        pendingRequests.removeAll { $0.id == request.id }
    }

    /// Allow, in the strongest form the host offered (`once` by default).
    public func approve(_ request: ServerRequest) async {
        let offered = Self.choices(for: request)
        let choice = offered.first { $0 == "once" } ?? offered.first ?? "once"
        await respond(request, choice: choice)
    }

    /// Refuse. An explicit `deny` token, never `-32601`: the user said no, and the agent must
    /// be told no rather than "this client cannot answer".
    public func deny(_ request: ServerRequest) async {
        await respond(request, choice: "deny")
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
            // A question about a session the user is not looking at would sit under the wrong
            // conversation. Only filtered when we can tell: a request that names no session (or
            // arrives with nothing open) is still surfaced, because the agent is blocked on it.
            if let selected = selectedSessionID,
               let named = Self.sessionID(of: request),
               named != selected {
                return
            }
            guard !pendingRequests.contains(where: { $0.id == request.id }) else { return }
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
///
/// The `scenario` only changes *what the canned stream says*: every case is offline, the
/// same sessions are returned, and no case opens a socket. A preview that needs a pending
/// approval or a half-streamed answer therefore gets it from the event stream — the same
/// path the real client uses — rather than by poking `AppModel`'s state from outside.
public final class PreviewGatewayClient: GatewayClientProtocol, @unchecked Sendable {
    public enum Scenario: String, Sendable {
        /// Sessions and a resume, nothing live.
        case sessions
        /// No sessions at all — the first-launch / unpaired sidebar.
        case empty
        /// A turn that is still streaming when the preview settles.
        case streaming
        /// A turn blocked on an approval.
        case approval
        /// A wire that keeps dropping.
        case offline
    }

    public var state: TransportState { get async { .open } }

    public let events: AsyncStream<ClientEvent>
    private let continuation: AsyncStream<ClientEvent>.Continuation
    private let scenario: Scenario

    public init(scenario: Scenario = .sessions) {
        self.scenario = scenario
        var captured: AsyncStream<ClientEvent>.Continuation!
        events = AsyncStream { captured = $0 }
        continuation = captured
    }

    public func connect() async throws {
        continuation.yield(.ready(replayEpoch: nil))

        // Anything that must land *after* the shell has opened a session is deferred: a
        // delta for a session that is not selected yet is dropped by `AppModel`, which is
        // the correct behaviour and would make these previews look inert.
        let continuation = self.continuation
        switch scenario {
        case .offline:
            continuation.yield(.state(.reconnecting(attempt: 2)))
        case .streaming:
            Task {
                for chunk in ["Snapshotting the vault first, ",
                              "then I'll diff the docs tree.\n\n",
                              "```sh\nrsync -a --delete ~/vault/ ~/backup/vault/\n```"] {
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    continuation.yield(.messageDelta(session: "preview-1", text: chunk))
                }
            }
        case .approval:
            Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                continuation.yield(.request(ServerRequest(
                    id: .string("srq-7"),
                    method: "approval",
                    params: .object([
                        "kind": .string("shell"),
                        "prompt": .string("rm -rf ~/jobs/hermes-apps/.build"),
                        "reason": .string("Clears the stale build cache before a clean build. The source tree is untouched."),
                        "session": .string("preview-1"),
                    ])
                )))
            }
        case .sessions, .empty:
            break
        }
    }

    public func disconnect() async {}

    public func ping() async throws {}

    /// Four plausible bots, deliberately different lengths and initials, so a preview of the
    /// switcher shows the real thing: several assistants, one host, one row selected.
    public func listBots() async throws -> [Bot] {
        PreviewGatewayClient.bots
    }

    static let bots: [Bot] = [
        Bot(id: "cody", displayName: "Cody"),
        Bot(id: "atlas", displayName: "Atlas"),
        Bot(id: "scribe", displayName: "Scribe"),
        Bot(id: "night-shift", displayName: "Night shift"),
    ]

    public func listSessions(limit: Int) async throws -> [SessionSummary] {
        try await listSessions(limit: limit, profile: nil, includeHidden: true)
    }

    /// Deterministic per-bot slices: the first bot keeps the full list (previews elsewhere hard
    /// code `preview-1`, which must exist), while the others get shorter, disjoint sets so a row
    /// leaking between bots would be visible on screen rather than plausible.
    public func listSessions(limit: Int, profile: String?, includeHidden: Bool) async throws -> [SessionSummary] {
        guard scenario != .empty else { return [] }
        let rows = PreviewGatewayClient.sessions
        switch profile {
        case "atlas": return Array(rows.prefix(2))
        case "scribe": return Array(rows.suffix(1))
        case "night-shift": return []
        default: return rows
        }
    }

    /// Deterministic, so two preview renderings of the same scenario are the same picture.
    static let sessions: [SessionSummary] = {
        let now = Date()
        return [
            SessionSummary(id: "preview-1",
                           title: "Vault backup + docs sync",
                           updatedAt: now.addingTimeInterval(-42),
                           preview: "Snapshotting the vault first",
                           running: true),
            SessionSummary(id: "preview-2",
                           title: "Tailscale ACL audit",
                           updatedAt: now.addingTimeInterval(-3 * 3_600),
                           preview: "Reviewed 3 tags · no drift"),
            SessionSummary(id: "preview-3",
                           title: "Gateway handshake retry",
                           updatedAt: now.addingTimeInterval(-30 * 3_600),
                           preview: "The ticket is only valid once"),
            SessionSummary(id: "preview-4",
                           title: "Sparse routing notes",
                           updatedAt: now.addingTimeInterval(-5 * 86_400),
                           preview: "Draft is in Obsidian under research/"),
        ]
    }()

    public func resumeSession(_ id: SessionID) async throws -> SessionResume {
        SessionResume(id: id,
                      entries: [
                        TranscriptEntry(id: "1", role: .user,
                                        text: "Back up the vault and re-sync docs."),
                        TranscriptEntry(id: "2", role: .assistant,
                                        text: "Snapshotting the vault first, then I'll diff the docs tree.\n\n**Plan**\n\n1. `rsync` the vault to `~/backup/vault`\n2. Diff `docs/` against the backup\n3. Report only files that changed\n\n> Nothing is deleted until the diff is reviewed."),
                        TranscriptEntry(id: "3", role: .tool,
                                        text: "bash · rsync -a ~/vault/ ~/backup/vault/ · 0.8s · exit 0"),
                        TranscriptEntry(id: "4", role: .assistant,
                                        text: "Backup is in place — 1,204 files, no errors. Diffing next."),
                      ],
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
