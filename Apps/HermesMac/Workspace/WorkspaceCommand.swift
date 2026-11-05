import Foundation

/// One row of the ⌘K palette.
///
/// The catalogue is built from live state (`WorkspaceStore.commands`), so the palette can
/// never offer "Interrupt" when no turn is running, or "Connect" when the wire is already
/// open. Nothing here is a placeholder that lies about what the app can do.
struct WorkspaceCommand: Identifiable {
    enum Group: String, CaseIterable {
        case session = "Session"
        case go = "Go"
        case host = "Host"
        case view = "View"
        case bot = "Bots"
    }

    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let shortcut: String?
    let group: Group
    let isEnabled: Bool
    let run: () -> Void

    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        return title.lowercased().contains(needle)
            || subtitle.lowercased().contains(needle)
            || group.rawValue.lowercased().contains(needle)
    }
}
