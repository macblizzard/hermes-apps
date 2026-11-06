import HermesAppKit
import HermesKit
import OpenBotUI
import SwiftUI

/// The conversation column: header, optional wire banner, the transcript, the blocking
/// requests, the composer.
///
/// Vertical order is the priority order. A banner sits directly under the header so a
/// reconnecting wire is the first thing read; approvals sit directly above the composer
/// because that is where the user's next action is.
struct ConversationPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: WorkspaceStore

    /// The bot this pane last announced as visible, so a teardown cannot clear the dot of the bot
    /// that replaced it (the shell re-creates the pane per bot).
    @State private var shownBotID: String?

    var body: some View {
        VStack(spacing: 0) {
            ConversationHeader(model: model, store: store)
            Hairline()

            if let banner = bannerKind {
                ConnectionBanner(banner,
                                 host: model.hostName,
                                 turnRunning: model.isStreaming,
                                 onRetry: { Task { await store.reconnect() } })
            }

            // The banner's copy is per transport state; a refused token or a malformed
            // ticket response needs the host's own sentence, and the way to fix it.
            if case .failed(let why) = model.connection, store.isPaired {
                MacInlineNotice(message: why, actionTitle: "Pair host…") {
                    store.isPairSheetPresented = true
                }
            }

            if openSession == nil {
                ConversationEmptyState(model: model, store: store)
            } else {
                TranscriptScroll(model: model)
            }

            ApprovalInbox(model: model, store: store)
            MacComposerBar(model: model, store: store)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.canvas)
        // Mirrors the phone: the conversation that is on screen is the one whose replies count as
        // read; leaving it (or switching bots) hands the unread dot back to the list.
        .onAppear {
            shownBotID = model.selectedBotID
            model.setVisibleBot(model.selectedBotID)
        }
        .onChange(of: model.selectedBotID) { _, botID in
            shownBotID = botID
            model.setVisibleBot(botID)
        }
        .onDisappear {
            // Only if this pane's bot is still the visible one: a teardown that lands after the
            // next bot's appearance must not erase the dot state for the bot now on screen.
            if model.visibleBotID == shownBotID {
                model.setVisibleBot(nil)
            }
        }
        // Bot change and appearance both land here, so the chip is never a bot behind.
        .task(id: model.selectedBotID) {
            await store.refreshOpenBotModelLabel()
        }
        .onChange(of: model.connection) { _ in
            // The chip is a host fact: re-ask when the wire comes back.
            Task { await store.refreshOpenBotModelLabel() }
        }
    }

    /// The transcript is only drawn for a session that is in the *current* bot's list.
    /// A stale id left over from another bot must not paint one bot's messages under
    /// another bot's header, so "open" means "present in `sessions`", not just non-nil.
    private var openSession: SessionSummary? {
        guard let id = model.selectedSessionID else { return nil }
        return model.sessions.first { $0.id == id }
    }

    private var bannerKind: ConnectionBanner.Kind? {
        guard store.isPaired || store.connectAttempted else { return nil }
        // `.failed` has a real message of its own, which the inline notice below shows
        // verbatim; the banner would only repeat it in vaguer words.
        if case .failed = model.connection { return nil }
        return ConnectionBanner.kind(for: model.connection.transportState)
    }
}

/// Nothing open yet: the two doors (pair, connect) plus the shortcuts worth learning.
private struct ConversationEmptyState: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: WorkspaceStore

    private var title: String {
        if !store.isPaired { return "No host paired" }
        if !model.connection.isLive { return "Not connected" }
        if model.bots.isEmpty { return "No bots found on this host" }
        if model.sessionsLoading && model.sessions.isEmpty {
            return "Loading \(store.botTitle)'s conversations…"
        }
        if model.sessions.isEmpty { return "\(store.botTitle) has no sessions yet" }
        return "No conversation selected"
    }

    private var subtitle: String {
        if !store.isPaired {
            return "Paste your host's wss:// URL and device token. Nothing leaves this Mac until you do."
        }
        if !model.connection.isLive {
            return "Connect to \(store.pairing?.displayHost ?? model.hostName) to load its sessions."
        }
        if model.bots.isEmpty {
            return "The gateway answered, but listed no profiles. Check that this host has a Hermes bot to talk to, then check again."
        }
        if model.sessionsLoading && model.sessions.isEmpty {
            return "The host is listing this bot's sessions."
        }
        if model.sessions.isEmpty {
            return "Start one here, or switch bots in the rail."
        }
        return "Pick a session in the list, or start a new one."
    }

    private var icon: String {
        if !store.isPaired { return "link.badge.plus" }
        if model.connection.isLive && model.bots.isEmpty { return "person.2.slash" }
        return "bubble.left.and.bubble.right"
    }

    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)

            Image(systemName: icon)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Tokens.textDim)

            Text(title)
                .font(TypeScale.font(Tokens.textLG, weight: .medium))
                .foregroundStyle(Tokens.textSecondary)

            Text(subtitle)
                .font(TypeScale.font(Tokens.textSM))
                .foregroundStyle(Tokens.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
                .fixedSize(horizontal: false, vertical: true)

            if !store.isPaired {
                OpenBotButton("Pair host…", systemImage: "link", kind: .primary, size: .small) {
                    store.isPairSheetPresented = true
                }
            } else if !model.connection.isLive {
                OpenBotButton("Connect",
                              systemImage: "bolt.horizontal",
                              kind: .primary,
                              size: .small,
                              isBusy: model.connection == .connecting) {
                    Task { await store.connect() }
                }
            } else if model.bots.isEmpty {
                OpenBotButton("Check again", systemImage: "arrow.clockwise", kind: .secondary, size: .small) {
                    Task { await store.loadBots() }
                }
            } else {
                OpenBotButton("New session", systemImage: "square.and.pencil", kind: .secondary, size: .small) {
                    store.newSession()
                }
            }

            Text("⌘K commands · ⌘↩ send · ⌘. interrupt")
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.textDim)
                .padding(.top, 4)

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.canvas)
    }
}

// MARK: - Previews

private struct ConversationPanePreview: View {
    @StateObject private var store = PreviewWorkspace.store()

    var body: some View {
        ConversationPane(model: store.model, store: store)
            .frame(width: Geometry.conversationMeasure + 240, height: 720)
            .task { await store.attachPreviewHost() }
            .preferredColorScheme(.dark)
    }
}

private struct ConversationPaneEmptyPreview: View {
    @StateObject private var store = PreviewWorkspace.store(.empty)

    var body: some View {
        ConversationPane(model: store.model, store: store)
            .frame(width: Geometry.conversationMeasure + 240, height: 600)
            .task { await store.attachPreviewHost() }
            .preferredColorScheme(.dark)
    }
}

#Preview("Conversation") {
    ConversationPanePreview()
}

#Preview("Conversation · nothing open") {
    ConversationPaneEmptyPreview()
}
