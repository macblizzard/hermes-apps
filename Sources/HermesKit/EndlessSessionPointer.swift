import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - The bridge's pointer

/// Which stored session is *this bot's* one conversation, as the bridge knows it.
///
/// The apps used to answer that question from their own `UserDefaults`, one key per bot per
/// device, so the phone and the Mac minted two different sessions for one bot. The bridge now
/// owns the answer (`GET`/`PUT /v1/bots/{profile}/session`, device-authenticated like `/v1/devices`)
/// and this protocol is the only thing `GatewayClient` needs from it.
///
/// Deliberately tiny and transport-shaped: the decision of *what to do* with the answer lives in
/// `EndlessSessionPolicy`, and the HTTP leg in `BridgeBotSessionPointer`, so both are testable
/// without a socket and without a device.
public protocol BotSessionPointerStore: Sendable {
    /// `GET /v1/bots/{profile}/session` — the shared stored session id, or `nil` when the bridge
    /// has none for this bot yet (unset, or a route the deployed bridge does not serve).
    func storedSessionID(for profile: String) async throws -> String?

    /// `PUT /v1/bots/{profile}/session` — publish `storedSessionID` so the other device adopts it.
    /// `nil` clears the pointer, which is what a reset means.
    func publish(storedSessionID: String?, for profile: String) async throws
}

/// The real pointer: one HTTP request, one freshly minted single-use ticket.
///
/// Same credential shape as `VoiceService` and `BotIconService` on the app side — the caller
/// resolves *where* the bridge is and *what* ticket to present at request time, because a ticket
/// that went to a websocket (or to the previous request) is already spent and the paired host can
/// change while the client lives. Nothing is cached here, and nothing throws for a merely missing
/// value: "no pointer" is a normal answer, not an error.
public struct BridgeBotSessionPointer: BotSessionPointerStore {

    /// Everything one request needs, resolved per request.
    public typealias Endpoint = @Sendable () async throws -> (baseURL: URL, ticket: String)

    public enum Failure: Error, Equatable, LocalizedError {
        case noProfile
        case notHTTP
        case rejected(status: Int, detail: String?)
        case malformedResponse

        public var errorDescription: String? {
            switch self {
            case .noProfile: return "no bot was named for the shared conversation"
            case .notHTTP: return "the host's shared-conversation answer was not HTTP"
            case .rejected(let status, let detail):
                if let detail, !detail.isEmpty { return "the host refused the shared conversation (\(status)): \(detail)" }
                return "the host refused the shared conversation (\(status))"
            case .malformedResponse: return "the host's shared-conversation answer was not readable"
            }
        }
    }

    private let endpoint: Endpoint
    private let session: URLSession

    public init(endpoint: @escaping Endpoint, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    public func storedSessionID(for profile: String) async throws -> String? {
        // Resolved once: a ticket is single-use, so asking the provider twice would mint a second
        // ticket that no request ever spends.
        let endpoint = try await endpoint()
        let url = try Self.url(for: profile, base: endpoint.baseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(endpoint.ticket)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.notHTTP }
        // An older bridge has no such route; an unset pointer may also be spelled 404. Neither is
        // an error the user should ever see — it just means "ask the local cache instead".
        if http.statusCode == 404 || http.statusCode == 204 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.rejected(status: http.statusCode, detail: Self.detail(from: data))
        }
        // A body this client cannot read is "no usable answer", not a failure: the pointer is an
        // optimisation, and opening a conversation must never depend on parsing it.
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        // `stored_session_id` is the contract; `session_id` is tolerated because the bridge's own
        // session rows spell it that way and a mixed deployment must not fork the conversation.
        let raw = (object["stored_session_id"] as? String) ?? (object["session_id"] as? String)
        return EndlessSessionPolicy.storedID(raw)
    }

    public func publish(storedSessionID: String?, for profile: String) async throws {
        let endpoint = try await endpoint()
        let url = try Self.url(for: profile, base: endpoint.baseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(endpoint.ticket)", forHTTPHeaderField: "Authorization")
        // Explicit `null` clears the pointer; the key is always present so the bridge never has to
        // guess whether an absent field meant "leave it alone".
        let body: [String: Any] = ["stored_session_id": storedSessionID.map { $0 as Any } ?? NSNull()]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.notHTTP }
        if storedSessionID == nil, http.statusCode == 400 || http.statusCode == 422 {
            // The deployed route has no "clear": a null is rejected rather than deleting the row
            // ("never a delete" in `bot_sessions.py`). Nothing the caller can act on — the reset
            // device keeps a local tombstone — and a bridge that learns to clear simply answers 2xx.
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.rejected(status: http.statusCode, detail: Self.detail(from: data))
        }
    }

    // MARK: Plumbing

    private static func url(for profile: String, base: URL) throws -> URL {
        let name = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw Failure.noProfile }
        // Component by component, so a profile with a space or a slash is percent-encoded rather
        // than reshaping the path.
        return base
            .appendingPathComponent("v1")
            .appendingPathComponent("bots")
            .appendingPathComponent(name)
            .appendingPathComponent("session")
    }

    private static func detail(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["detail"] as? String
    }
}

// MARK: - What to do with the answer

/// What the bridge said about this bot's conversation.
public enum EndlessSessionPointerState: Equatable, Sendable {
    /// The bridge answered with an id. It is authoritative — the other device may be on it now.
    case value(SessionID)
    /// The bridge answered, and has no id for this bot yet.
    case absent
    /// The bridge could not be asked (offline, no route, unreadable answer). Not an error the user
    /// sees: the local cache answers instead and nothing is published, so a read we could not
    /// trust never overwrites the other device's pointer.
    case unavailable
}

/// The decision `AppModel.endlessSession(for:)` carries out.
public struct EndlessSessionPlan: Equatable, Sendable {

    public enum Step: Equatable, Sendable {
        /// Resume this stored id (never a runtime id — see the design note §5.6).
        case resume(SessionID)
        /// Mint a new conversation.
        case create
    }

    public enum Origin: Equatable, Sendable {
        /// The bridge's pointer.
        case host
        /// This device's `UserDefaults` cache.
        case local
        /// Neither: the conversation is about to be created.
        case none
    }

    public let step: Step
    public let origin: Origin
    /// Whether the resulting stored id must be written back to the bridge, so the other device
    /// adopts it on its next open.
    public let publish: Bool

    public init(step: Step, origin: Origin, publish: Bool) {
        self.step = step
        self.origin = origin
        self.publish = publish
    }

    public var resumedID: SessionID? {
        if case .resume(let id) = step { return id }
        return nil
    }
}

/// Which stored session to open, given the bridge's pointer and this device's cache.
///
/// The rules, in the order they matter:
///
/// 1. **Host wins.** A value the bridge holds is the shared answer; a stale local key is replaced.
/// 2. **Local is the fallback.** With no host value (or an unaskable host) the last id this device
///    used still opens — that is what keeps the app working offline and on an older bridge.
/// 3. **Publish what the host does not know.** After a create, and after a local id was adopted
///    because the bridge answered "nothing", the result is written back so the other device
///    converges. Nothing is published when the host supplied the id (it already knows) nor when
///    the read failed (that value may exist and must not be clobbered).
public enum EndlessSessionPolicy {

    /// A usable stored id, or `nil` for anything a resume could not be trusted with.
    ///
    /// The host's stored keys look like `20261106_165329_293f4b`; a trimmed, non-empty token of
    /// path-safe characters is the whole contract. Empty strings, whitespace, embedded newlines,
    /// path separators and absurdly long values are treated as "no pointer" rather than passed
    /// through to `session.resume` — a malformed answer must degrade to the local cache, never
    /// break the open.
    public static func storedID(_ raw: String?) -> SessionID? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...128).contains(trimmed.count) else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
        guard trimmed.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        guard !trimmed.hasPrefix(".") else { return nil }
        return trimmed
    }

    public static func plan(host: EndlessSessionPointerState, local: String?) -> EndlessSessionPlan {
        let localID = storedID(local)

        switch host {
        case .value(let raw):
            guard let id = storedID(raw) else {
                // The bridge answered with something unusable; fall through to the same rules as
                // "no value", including publishing whatever we end up on so it is repaired.
                return planWithoutHost(localID)
            }
            return EndlessSessionPlan(step: .resume(id), origin: .host, publish: false)

        case .absent:
            return planWithoutHost(localID)

        case .unavailable:
            // Fail open: the local id still opens the conversation, but a read we could not
            // trust must not overwrite a pointer that may exist.
            if let localID {
                return EndlessSessionPlan(step: .resume(localID), origin: .local, publish: false)
            }
            return EndlessSessionPlan(step: .create, origin: .none, publish: true)
        }
    }

    private static func planWithoutHost(_ localID: SessionID?) -> EndlessSessionPlan {
        if let localID {
            return EndlessSessionPlan(step: .resume(localID), origin: .local, publish: true)
        }
        return EndlessSessionPlan(step: .create, origin: .none, publish: true)
    }
}
