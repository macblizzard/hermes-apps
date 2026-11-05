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

            if model.selectedSessionID == nil {
                ConversationEmptyState(model: model, store: store)
            } else {
                TranscriptScroll(model: model)
            }

            ApprovalInbox(model: model, store: store)
            MacComposerBar(model: model, store: store)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.canvas)
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
        return "No conversation selected"
    }

    private var subtitle: String {
        if !store.isPaired {
            return "Paste your host's wss:// URL and device token. Nothing leaves this Mac until you do."
        }
        if !model.connection.isLive {
            return "Connect to \(store.pairing?.displayHost ?? model.hostName) to load its sessions."
        }
        return "Pick a session in the list, or start a new one."
    }

    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)

            Image(systemName: store.isPaired ? "bubble.left.and.bubble.right" : "link.badge.plus")
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
