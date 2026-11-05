import Foundation

// MARK: - JSON conveniences

extension JSONValue {
    /// A number whatever the encoder chose. `started_at` and `timestamp` arrive as floats on one
    /// build and integers on another, and neither is worth a failed decode.
    var numberValue: Double? {
        switch self {
        case .int(let v): return Double(v)
        case .double(let v): return v
        default: return nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let v) = self { return v }
        return nil
    }
}

extension RPCID {
    /// Ids the gateway mints are strings (`srq-<12 hex>`) and ids we mint are integers; a server
    /// request replayed from `open_requests` must round-trip either way.
    init?(json: JSONValue?) {
        guard let json else { return nil }
        switch json {
        case .string(let s): self = .string(s)
        case .int(let i): self = .int(i)
        default: return nil
        }
    }
}

enum GatewayJSON {
    /// Best-effort text for a field that may be a string, a number, or a whole object.
    static func text(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .null: return nil
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .array, .object:
            return try? JSONRPCCodec.encodeToString(value)
        }
    }

    static func date(_ value: JSONValue?) -> Date? {
        guard let seconds = value?.numberValue, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

// MARK: - Event envelope

/// Unwraps the gateway's event envelope.
///
/// Every event on the wire is `{"method":"event","params":{"type":<name>,"session_id":<sid>,
/// "payload":<body>,"seq":<n>}}` — **not** `{"method":"message.delta"}`. A client that switches on
/// the notification method never fires a single delta; that is the bug `fixtures/NOTES.md` exists to
/// prevent, and `Fixtures.swift` pins it.
enum GatewayEventDecoder {

    /// `nil` means "an event we do not model yet" and the caller emits `.unknown` rather than
    /// dropping it — a Hermes upgrade must never make the transcript go quiet.
    static func event(type: String, session: SessionID, payload: JSONValue) -> ClientEvent? {
        switch type {
        case "message.delta":
            // A null `text` is the reply-segment boundary, not an empty chunk: emitting "" would
            // make a renderer insert a break where the model wrote nothing.
            guard let text = payload["text"]?.stringValue else { return nil }
            return .messageDelta(session: session, text: text)

        case "message.complete":
            return .messageComplete(session: session, text: GatewayJSON.text(payload["text"]) ?? "")

        case "tool.start":
            guard let callID = payload["tool_id"]?.stringValue ?? payload["tool_call_id"]?.stringValue
            else { return nil }
            return .toolStart(session: session,
                              name: payload["name"]?.stringValue ?? "",
                              callID: callID,
                              input: payload["args"] ?? payload["input"])

        case "tool.progress":
            guard let callID = payload["tool_id"]?.stringValue else { return nil }
            return .toolProgress(session: session, callID: callID, text: progressText(payload))

        case "tool.complete":
            guard let callID = payload["tool_id"]?.stringValue else { return nil }
            return .toolComplete(session: session,
                                 callID: callID,
                                 output: GatewayJSON.text(payload["result_text"])
                                     ?? payload["summary"]?.stringValue
                                     ?? GatewayJSON.text(payload["result"]),
                                 ok: succeeded(payload),
                                 durationMS: payload["duration_s"]?.numberValue.map { Int(($0 * 1000).rounded()) })

        // The backend has no single "session changed" event; these are the three that move a row in
        // the rail, and one repaint signal covers all of them.
        case "session.info", "session.title", "session.reclaimed", "session.control.update":
            return .sessionUpdated(session)

        case "error":
            return .error(code: payload["code"]?.intValue.map { Int($0) },
                          message: payload["message"]?.stringValue ?? "unknown gateway error")

        default:
            return nil
        }
    }

    private static func progressText(_ payload: JSONValue) -> String {
        if let message = payload["message"]?.stringValue, !message.isEmpty { return message }
        if let percent = payload["percent"]?.intValue { return "\(percent)%" }
        let progress = payload["progress"]?.numberValue ?? 0
        if let total = payload["total"]?.numberValue, total > 0 {
            return String(format: "%.0f/%.0f", progress, total)
        }
        return String(format: "%.0f", progress)
    }

    /// The wire carries no explicit `ok`: a failed tool reports itself inside `result`. Infer it,
    /// and default to success so an unrecognised shape never paints a good call as failed.
    private static func succeeded(_ payload: JSONValue) -> Bool {
        guard let result = payload["result"]?.objectValue else { return true }
        if let success = result["success"]?.boolValue { return success }
        if let ok = result["ok"]?.boolValue { return ok }
        if result["is_error"]?.boolValue == true { return false }
        if let error = result["error"], error != .null,
           let text = GatewayJSON.text(error), !text.isEmpty { return false }
        return true
    }
}

// MARK: - Result payloads

/// Decoding of result *bodies*. Kept out of `GatewayClient` so the client file is only about
/// sequencing — correlation, timeouts, handshake, reconnect.
enum GatewayPayloadDecoder {

    struct Resume {
        let resume: SessionResume
        let storedID: SessionID
        let runtimeID: SessionID
    }

    static func sessionResume(_ result: JSONValue?, requestedID: SessionID) throws -> Resume {
        guard let result, result.objectValue != nil else {
            throw GatewayError.malformedResponse(method: "session.resume")
        }
        // `session_id` in the reply is the RUNTIME id (what every session-scoped call needs);
        // `stored_session_id` is the durable key, and the only thing a later resume accepts.
        let runtimeID = result["session_id"]?.stringValue ?? requestedID
        let storedID = result["stored_session_id"]?.stringValue ?? requestedID
        let resume = SessionResume(id: runtimeID,
                                   entries: transcript(result["messages"]?.arrayValue ?? []),
                                   inflight: inflight(result["inflight"]),
                                   openRequests: (result["open_requests"]?.arrayValue ?? []).compactMap(serverRequest))
        return Resume(resume: resume, storedID: storedID, runtimeID: runtimeID)
    }

    static func inflight(_ value: JSONValue?) -> InflightTurn? {
        guard let value, let object = value.objectValue else { return nil }
        let assistant = object["assistant"]?.stringValue ?? ""
        let user = object["user"]?.stringValue ?? ""
        if assistant.isEmpty && user.isEmpty { return nil }
        return InflightTurn(userText: user, assistantText: assistant, streaming: object["streaming"]?.boolValue ?? false)
    }

    static func serverRequest(_ value: JSONValue) -> ServerRequest? {
        guard let id = RPCID(json: value["id"]), let method = value["method"]?.stringValue else { return nil }
        return ServerRequest(id: id, method: method, params: value["params"] ?? .null)
    }

    static func transcript(_ messages: [JSONValue]) -> [TranscriptEntry] {
        messages.enumerated().map { index, message in
            let rowID = message["row_id"]?.intValue
            let role = TranscriptEntry.Role(rawValue: message["role"]?.stringValue ?? "") ?? .system
            // Row ids are the durable identity a rewind targets and the UI diffs against; without
            // one, a tool call id is stable across reloads, and a positional id is the last resort.
            let id: String
            if let rowID {
                id = "r\(rowID)"
            } else if let callID = message["tool_call_id"]?.stringValue {
                id = "t\(callID)"
            } else {
                id = "\(role.rawValue)-\(index)"
            }
            let text = GatewayJSON.text(message["text"]) ?? GatewayJSON.text(message["content"]) ?? ""
            return TranscriptEntry(id: id,
                                   rowID: rowID,
                                   role: role,
                                   text: text,
                                   at: GatewayJSON.date(message["timestamp"]))
        }
    }

    static func sessionSummaries(_ result: JSONValue?) throws -> [SessionSummary] {
        guard let rows = result?["sessions"]?.arrayValue else {
            throw GatewayError.malformedResponse(method: "session.list")
        }
        return rows.compactMap { row in
            guard let id = row["id"]?.stringValue else { return nil }
            // The listing row carries `started_at` and no last-active field, so that is the only
            // timestamp there is; `updatedAt` is where the rail sorts it.
            return SessionSummary(id: id,
                                  title: row["title"]?.stringValue ?? "",
                                  updatedAt: GatewayJSON.date(row["started_at"]),
                                  preview: row["preview"]?.stringValue,
                                  running: row["running"]?.boolValue ?? false)
        }
    }

    static func history(_ result: JSONValue?, limit: Int) throws -> [TranscriptEntry] {
        guard let messages = result?["messages"]?.arrayValue else {
            throw GatewayError.malformedResponse(method: "session.history")
        }
        let entries = transcript(messages)
        return limit > 0 ? Array(entries.suffix(limit)) : entries
    }

    static func modelOptions(_ result: JSONValue?) throws -> [ModelOption] {
        guard let providers = result?["providers"]?.arrayValue else {
            throw GatewayError.malformedResponse(method: "model.options")
        }
        var options: [ModelOption] = []
        for provider in providers {
            guard let slug = provider["slug"]?.stringValue else { continue }
            for model in provider["models"]?.arrayValue ?? [] {
                guard let name = model.stringValue, !name.isEmpty else { continue }
                options.append(ModelOption(id: name, provider: slug, label: name))
            }
        }
        return options
    }

    struct EventReplay {
        let events: [JSONValue]
        let latestSeq: Int
        let truncated: Bool
        let epoch: String
    }

    static func eventReplay(_ result: JSONValue?) throws -> EventReplay {
        guard let result, result.objectValue != nil else {
            throw GatewayError.malformedResponse(method: "session.events.since")
        }
        return EventReplay(events: result["events"]?.arrayValue ?? [],
                           latestSeq: Int(result["latest_seq"]?.intValue ?? 0),
                           truncated: result["truncated"]?.boolValue ?? false,
                           epoch: result["epoch"]?.stringValue ?? "")
    }
}
