import Foundation

/// Per-bot composer drafts for a window.
///
/// The asynchronous part of a bot switch is the dangerous part: an open for the bot the user
/// selected *first* can finish after an open for the bot they selected *second*. A completion
/// token makes that stale task unable to write its draft over the current one.
///
/// Parking is deliberately conservative. A rapid second switch can call `beginSwitch` before the
/// first switch has attached its bot, so the composer it sees is empty even though the bot being
/// left has a real parked draft. An empty composition never replaces a non-empty parked one unless
/// the caller explicitly says the bot was attached and the user really cleared it.
///
/// The ledger is deliberately value-typed and Foundation-only so the ordering rules can be tested
/// without a SwiftUI window or a socket.
public struct BotDraftLedger {

    private var drafts: [String: String] = [:]
    private var generation = 0

    public init() {}

    /// The token belonging to the current selection.
    public var currentToken: Int { generation }

    /// Start an explicit switch and invalidate any switch that was already in flight.
    ///
    /// This overload is the safe default for callers that cannot say whether the composer was
    /// attached: empty text does not erase an existing parked draft. Use the explicit overload to
    /// record a deliberate clear from an attached composer.
    @discardableResult
    public mutating func beginSwitch(from botID: String?, draft: String) -> Int {
        beginSwitch(from: botID, draft: draft, replacingParkedDraft: !draft.isEmpty)
    }

    /// Start an explicit switch.
    ///
    /// - Parameters:
    ///   - botID: The bot the text belonged to. `nil` means the composer was unscoped.
    ///   - draft: The current composer text.
    ///   - replacingParkedDraft: `true` only when the caller knows the composer was attached to
    ///     `botID` (so an empty string is a deliberate clear). While an open is still pending,
    ///     pass `false`: an empty box is not evidence that the bot had no parked draft.
    @discardableResult
    public mutating func beginSwitch(from botID: String?,
                                     draft: String,
                                     replacingParkedDraft: Bool) -> Int {
        if let botID, !draft.isEmpty || replacingParkedDraft {
            drafts[botID] = draft
        }
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

    /// Put a composition back after its send failed.
    ///
    /// A failure can land after the user switched away from the bot. The failed text must not
    /// replace anything they typed for that bot afterwards, so only an empty slot is filled.
    public mutating func restoreFailedDraft(botID: String, text: String) {
        guard !text.isEmpty else { return }
        guard (drafts[botID] ?? "").isEmpty else { return }
        drafts[botID] = text
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
