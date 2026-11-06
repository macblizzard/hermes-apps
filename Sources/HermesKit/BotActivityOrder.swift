import Foundation

/// Orders a host's bots by how recently you actually exchanged messages with them.
///
/// Opening a chat is not activity: tapping in to read something and leaving again must not push a
/// bot above the one you were talking to five minutes ago. Only a message — yours or the bot's —
/// counts, and a bot that has never been used keeps the host's own order at the bottom.
public enum BotActivityOrder {
    public static func order(_ bots: [Bot], activity: [String: Date]) -> [Bot] {
        // `sorted` is not stable, so rank each bot first and break ties on its host position.
        let indexed = bots.enumerated().map { (index, bot) -> (Bot, Date?, Int) in
            (bot, activity[bot.id], index)
        }
        return indexed.sorted { lhs, rhs in
            switch (lhs.1, rhs.1) {
            case let (left?, right?):
                if left != right { return left > right }
                return lhs.2 < rhs.2
            case (nil, _?):
                return false        // never used sinks below anything with activity
            case (_?, nil):
                return true
            case (nil, nil):
                return lhs.2 < rhs.2
            }
        }.map(\.0)
    }
}
