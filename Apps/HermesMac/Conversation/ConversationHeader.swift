import Foundation
import HermesAppKit
import HermesKit
import OpenBotUI
import SwiftUI

/// The strip above the transcript: which conversation, whether a turn is live, and the two
/// controls that shape the window (context panel, more actions).
struct ConversationHeader: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: WorkspaceStore

    private var title: String {
        model.selectedSession?.title ?? "New conversation"
    }

    private var subtitle: String {
        guard let session = model.selectedSession else {
            return store.isPaired ? "not connected" : "no host paired"
        }
        var parts: [String] = [store.selectedBot?.displayName ?? model.hostName]
        if let updated = session.updatedAt {
            parts.append("updated \(RelativeTime.short(updated))")
        }
        if !model.transcript.isEmpty {
            parts.append(model.transcript.count == 1 ? "1 entry" : "\(model.transcript.count) entries")
        }
        return parts.joined(separator: " · ")
    }

    private var presence: Avatar.Presence {
        if model.hasPendingRequests { return .needsYou }
        if model.isStreaming { return .running }
        return .idle
    }

    /// `deepseek-v4.1-flash` fits; a provider-qualified id does not, and the chip is `fixedSize`,
    /// so it is shortened here rather than pushing the header's controls out of the strip.
    private var modelChipLabel: String? {
        guard let raw = store.openBotModelLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let words = raw.split(separator: " ")
        let short = words.prefix(2).joined(separator: " ")
        guard !short.isEmpty else { return nil }
        return short.count <= 22 ? short : String(short.prefix(21)) + "…"
    }

    var body: some View {
        HStack(spacing: 9) {
            Avatar(title, size: .small, presence: presence)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(TypeScale.font(Tokens.textLG, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(subtitle)
                    .font(TypeScale.font(TypeScale.label))
                    .foregroundStyle(Tokens.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            // The open bot's own model, from the profile-scoped catalogue — never the gateway's
            // default, which is what a chip reading an unscoped call names.
            if let label = modelChipLabel {
                StatusChip(label, tone: .neutral, size: .small)
            }

            if model.isStreaming {
                StatusChip("running", tone: .success, showsDot: true, size: .small)
            }

            if model.hasPendingRequests {
                StatusChip("needs you", tone: .warning, showsDot: true, size: .small)
            }

            OpenBotIconButton("magnifyingglass",
                              label: "Command palette (⌘K)",
                              size: .small) {
                store.openPalette()
            }

            OpenBotIconButton("sidebar.right",
                              label: store.showsContextPanel ? "Hide the context panel" : "Show the context panel",
                              size: .small) {
                store.toggleContextPanel()
            }

            moreMenu
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .frame(height: 48)
        .background(Tokens.canvas)
    }

    private var moreMenu: some View {
        Menu {
            if let bot = store.selectedBot {
                Button("Bot settings") { store.openBotSettings(bot) }
                Divider()
            }
            if !model.bots.isEmpty {
                Menu("Switch bot") {
                    ForEach(model.orderedBots) { bot in
                        Button(bot.id == model.selectedBotID ? "✓ \(bot.displayName)" : bot.displayName) {
                            store.selectBot(bot.id)
                        }
                    }
                }
                Divider()
            }
            Button("Command palette…") { store.openPalette() }
            Button("New session") { store.newSession() }
                .disabled(!model.connection.isLive)
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Reload sessions") { store.reloadSessions() }
                .disabled(!model.connection.isLive)
            Button("Pair host…") { store.isPairSheetPresented = true }
            Divider()
            if model.connection.isLive {
                Button("Disconnect") { Task { await store.disconnect() } }
            } else {
                Button("Connect") { Task { await store.connect() } }
                    .disabled(!store.isPaired)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Tokens.textMuted)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More actions")
    }
}

// MARK: - Previews

private struct ConversationHeaderPreview: View {
    @StateObject private var store = PreviewWorkspace.store()

    var body: some View {
        VStack(spacing: 0) {
            ConversationHeader(model: store.model, store: store)
            Hairline()
            Spacer()
        }
        .frame(width: Geometry.conversationMeasure + 200, height: 200)
        .background(Tokens.canvas)
        .task { await store.attachPreviewHost() }
        .preferredColorScheme(.dark)
    }
}

#Preview("Conversation header") {
    ConversationHeaderPreview()
}
