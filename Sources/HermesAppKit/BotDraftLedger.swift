import Foundation

/// Per-bot composer drafts for a window.
///
/// The asynchronous part of a bot switch is the dangerous part: an open for the bot the user
/// selected *first* can finish after an open for the bot they selected *second*. A completion
/// token makes that stale task unable to write its draft over the current one.
///
/// The ledger is deliberately value-typed and Foundation-only so the ordering rules can be tested
/// without a SwiftUI window or a socket.
public struct BotDraftLedger {

    private var drafts: [String: String] = [:]
    private var generation = 0

    public init() {}

    /// The token belonging to the current selection.
    public var currentToken: Int { generation }

    /// Start an explicit switch: park the draft with the bot it was typed for and invalidate any
    /// switch that was already in flight.
    @discardableResult
    public mutating func beginSwitch(from botID: String?, draft: String) -> Int {
        if let botID { drafts[botID] = draft }
        generation += 1
        return generation
    }

    /// True while the task holding `token` is still the newest selection.
    public func isCurrent(_ token: Int) -> Bool { token == generation }

    /// The draft to restore for `botID`, or `nil` when this task is stale. An explicit empty
    /// string means the bot has no parked draft.
    public func draft(for botID: String, token: Int) -> String? {
        guard isCurrent(token) else { return nil }
        return drafts[botID] ?? ""
    }

    /// The host accepted `text` from this bot's composer (a steer or a send). Drop the parked
    /// copy only when it is the same composition: text typed afterwards belongs to the user.
    public mutating func consumeAccepted(botID: String, text: String) {
        guard let parked = drafts[botID] else { return }
        guard parked.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
        drafts[botID] = ""
    }

    public mutating func removeAll() {
        drafts.removeAll()
        generation += 1
    }
}
