import HermesAppKit
import HermesKit
import OpenBotUI
import SwiftUI

/// The left panel: **bots, and nothing else**.
///
/// This is the phone's bot list on the desktop. One row per Hermes profile — name, description,
/// pin, hide, unread dot, context menu — and clicking a row opens that bot's single endless
/// conversation in the pane on the right. There is no session browser under it, no session
/// search, and no "new session" button: a bot has one conversation, and the app resumes it.
///
/// The host chip stays at the foot because connection, reconnect and latency have to be reachable
/// even when no bot is selected (or the host listed none).
struct BotSidebarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: WorkspaceStore

    /// Hidden bots are a view preference; this reveals them so nothing becomes unreachable.
    @State private var showsHiddenBots = false

    var body: some View {
        VStack(spacing: 0) {
            header
            // The list takes every point left between the header and the host chip: on this
            // screen the bots *are* the panel, not a block above a session list.
            content
                .padding(.horizontal, Geometry.sidebarInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            HostStatusBar(model: model, store: store)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Tokens.sidebar)
    }

    // MARK: Header

    /// No title of its own: the bot block's caption already says "BOTS", and a second heading
    /// over a list of three rows is one too many. The row holds the two verbs that are not
    /// attached to a particular bot — the palette and Settings.
    private var header: some View {
        HStack(spacing: 4) {
            if model.botsLoading {
                SpinningRing(color: Tokens.textDim, size: 9, lineWidth: 1.4)
            }

            Spacer(minLength: 0)

            OpenBotIconButton("magnifyingglass",
                              label: store.isPalettePresented
                                  ? "Close the command palette (⌘K)"
                                  : "Command palette (⌘K)",
                              size: .small) {
                store.togglePalette()
            }

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(TypeScale.font(TypeScale.label))
                    .foregroundStyle(Tokens.textMuted)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, Geometry.sidebarInset)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !store.isPaired {
            unpairedState
        } else if model.bots.isEmpty {
            if model.botsLoading {
                discoveringBotsState
            } else if let error = model.botsError {
                botsErrorState(error)
            } else if model.connection.isLive {
                noBotsState
            } else {
                notConnectedState
            }
        } else {
            SidebarBotList(model: model,
                           store: store,
                           showsHiddenBots: $showsHiddenBots,
                           fillsAvailableHeight: true)
                .padding(.bottom, 6)
        }
    }

    // MARK: Empty states

    private var unpairedState: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption("NO HOST")
                .padding(.horizontal, 8)
            Text("Pair this Mac with your Hermes host to list its bots. Nothing is sent until you do.")
                .font(TypeScale.font(Tokens.textSM))
                .foregroundStyle(Tokens.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
            OpenBotButton("Pair host…", systemImage: "link", kind: .secondary, size: .small) {
                store.isPairSheetPresented = true
            }
            .padding(.horizontal, 8)
        }
        .padding(.top, 8)
    }

    /// Paired with a host that has not been dialled yet — say so instead of "no bots", which
    /// would blame the host for a socket that was never opened.
    private var notConnectedState: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption("NOT CONNECTED")
                .padding(.horizontal, 8)
            Text("Connect to \(store.pairing?.displayHost ?? model.hostName) to list its bots.")
                .font(TypeScale.font(Tokens.textSM))
                .foregroundStyle(Tokens.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
            OpenBotButton("Connect",
                          systemImage: "bolt.horizontal",
                          kind: .secondary,
                          size: .small,
                          isBusy: model.connection == .connecting) {
                Task { await store.connect() }
            }
            .padding(.horizontal, 8)
        }
        .padding(.top, 8)
    }

    /// The host answered `profiles.list` and named no bots. This is a state the user can
    /// act on, not a failure to retry forever, so it says what happened and offers one
    /// refresh rather than a spinner.
    private var noBotsState: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption("NO BOTS")
                .padding(.horizontal, 8)
            Text("No bots found on this host.")
                .font(TypeScale.font(Tokens.textSM, weight: .medium))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
            Text("The gateway answered, but listed no profiles. Check that this host has a Hermes bot to talk to, then check again.")
                .font(TypeScale.font(Tokens.textSM))
                .foregroundStyle(Tokens.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
            OpenBotButton("Check again",
                          systemImage: "arrow.clockwise",
                          kind: .secondary,
                          size: .small) {
                Task { await store.loadBots() }
            }
            .padding(.horizontal, 8)
        }
        .padding(.top, 8)
    }

    /// `profiles.list` failed. Say which call failed and what it said, plus one retry.
    private func botsErrorState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption("BOTS UNAVAILABLE")
                .padding(.horizontal, 8)
            Text("Could not list this host's bots.")
                .font(TypeScale.font(Tokens.textSM, weight: .medium))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
            Text(message)
                .font(TypeScale.font(Tokens.textSM))
                .foregroundStyle(Tokens.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
            OpenBotButton("Try again",
                          systemImage: "arrow.clockwise",
                          kind: .secondary,
                          size: .small,
                          isDisabled: !model.connection.isLive) {
                Task { await store.loadBots() }
            }
            .padding(.horizontal, 8)
        }
        .padding(.top, 8)
    }

    private var discoveringBotsState: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption("FINDING BOTS")
                .padding(.horizontal, 8)
            HStack(spacing: 8) {
                SpinningRing(color: Tokens.textDim, size: 10, lineWidth: 1.4)
                Text("Asking the host which bots it serves…")
                    .font(TypeScale.font(Tokens.textSM))
                    .foregroundStyle(Tokens.textMuted)
            }
            .padding(.horizontal, 8)
        }
        .padding(.top, 8)
    }
}

// MARK: - Previews

private struct BotSidebarPreview: View {
    @StateObject private var store = PreviewWorkspace.store()

    var body: some View {
        BotSidebarView(model: store.model, store: store)
            .frame(width: Geometry.sidebarDefault, height: 640)
            .task { await store.attachPreviewHost() }
            .preferredColorScheme(.dark)
    }
}

private struct BotSidebarEmptyPreview: View {
    @StateObject private var store = PreviewWorkspace.store(.empty)

    var body: some View {
        BotSidebarView(model: store.model, store: store)
            .frame(width: Geometry.sidebarDefault, height: 640)
            .task { await store.attachPreviewHost() }
            .preferredColorScheme(.dark)
    }
}

#Preview("Bot panel") {
    BotSidebarPreview()
}

#Preview("Bot panel · no bots") {
    BotSidebarEmptyPreview()
}
