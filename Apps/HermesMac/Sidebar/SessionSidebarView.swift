import HermesAppKit
import HermesKit
import OpenBotUI
import SwiftUI

/// The left pane after the workspace became bot-first.
///
/// It is deliberately only the bot directory: every bot this host serves, with its icon and name,
/// and a working animation on the row whose turn is running. There is no session browser, no
/// session search field and no host-status block competing with the bots; pairing and settings are
/// reachable from the native menu bar and the conversation's own menu.
struct SessionSidebarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: WorkspaceStore

    /// Hidden bots are a view preference; this reveals them so nothing becomes unreachable.
    @State private var showsHiddenBots = false

    var body: some View {
        VStack(spacing: 0) {
            if !store.isPaired {
                unpairedState
            } else if model.bots.isEmpty {
                botDirectoryState
            } else if store.sidebarIsCompact {
                compactBotStrip
            } else {
                SidebarBotList(model: model,
                               store: store,
                               showsHiddenBots: $showsHiddenBots,
                               fillsAvailableHeight: true)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.horizontal, 6)
                    .padding(.top, 12)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Tokens.sidebar)
    }

    // MARK: Compact strip

    /// At 88 pt a name cannot be read, so the strip is one icon per bot. The full list is one
    /// drag away, and every icon still carries the bot's name as its accessible label/tooltip.
    private var compactBotStrip: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                OpenBotIconButton("sidebar.left", label: "Expand the bot list", size: .small) {
                    store.setSidebarWidth(Geometry.sidebarDefault)
                    store.endSidebarDrag()
                }

                OpenBotIconButton("magnifyingglass",
                                  label: "Command palette (⌘K)",
                                  size: .small) {
                    store.openPalette()
                }

                OpenBotIconButton("link", label: "Pair host…", size: .small) {
                    store.isPairSheetPresented = true
                }
            }
            .padding(.top, 8)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(model.orderedBots) { bot in
                        Button {
                            guard bot.id != model.selectedBotID else { return }
                            Haptics.selection()
                            store.selectBot(bot.id)
                        } label: {
                            Group {
                                if let icon = store.botIcons[bot.id] {
                                    BotIconPortrait(icon, size: 30,
                                                    isWorking: model.isBotWorking(bot.id))
                                } else {
                                    Avatar(bot.displayName, size: .small,
                                           presence: presence(for: bot),
                                           initials: bot.avatarInitials)
                                }
                            }
                            .padding(5)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(bot.id == model.selectedBotID ? Tokens.controlActive : .clear)
                            )
                        }
                        .buttonStyle(.plain)
                        .help(bot.displayName)
                        .accessibilityLabel(accessibilityLabel(for: bot))
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: Empty states

    private var unpairedState: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption("NO HOST")
                .padding(.horizontal, 14)
            Text("Pair this Mac with your Hermes host to load its bots. Nothing is sent until you do.")
                .font(TypeScale.font(Tokens.textSM))
                .foregroundStyle(Tokens.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
            OpenBotButton("Pair host…", systemImage: "link", kind: .secondary, size: .small) {
                store.isPairSheetPresented = true
            }
            .padding(.horizontal, 14)
        }
        .padding(.top, 16)
    }

    @ViewBuilder
    private var botDirectoryState: some View {
        if model.botsLoading {
            stateBlock(caption: "FINDING BOTS",
                       title: "Asking the host which bots it serves…",
                       showsSpinner: true)
        } else if let error = model.botsError {
            stateBlock(caption: "BOTS UNAVAILABLE",
                       title: "Could not list this host's bots.",
                       detail: error,
                       actionTitle: "Try again",
                       actionSymbol: "arrow.clockwise",
                       isDisabled: !model.connection.isLive) {
                Task { await store.loadBots() }
            }
        } else if model.connection.isLive {
            stateBlock(caption: "NO BOTS",
                       title: "No bots found on this host.",
                       detail: "The gateway answered, but listed no profiles.",
                       actionTitle: "Check again",
                       actionSymbol: "arrow.clockwise") {
                Task { await store.loadBots() }
            }
        } else {
            stateBlock(caption: "NOT LOADED",
                       title: "Connect to \(store.pairing?.displayHost ?? model.hostName) to list its bots.",
                       actionTitle: "Connect",
                       actionSymbol: "bolt.horizontal",
                       isDisabled: !store.isPaired) {
                Task { await store.connect() }
            }
        }
    }

    private func stateBlock(caption: String,
                            title: String,
                            detail: String? = nil,
                            showsSpinner: Bool = false,
                            actionTitle: String? = nil,
                            actionSymbol: String? = nil,
                            isDisabled: Bool = false,
                            action: @escaping () -> Void = {}) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption(caption)
                .padding(.horizontal, 14)
            HStack(spacing: 8) {
                if showsSpinner {
                    SpinningRing(color: Tokens.textDim, size: 10, lineWidth: 1.4)
                }
                Text(title)
                    .font(TypeScale.font(Tokens.textSM))
                    .foregroundStyle(Tokens.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            if let detail {
                Text(detail)
                    .font(TypeScale.font(Tokens.textSM))
                    .foregroundStyle(Tokens.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
            }
            if let actionTitle, let actionSymbol {
                OpenBotButton(actionTitle,
                              systemImage: actionSymbol,
                              kind: .secondary,
                              size: .small,
                              isDisabled: isDisabled,
                              action: action)
                    .padding(.horizontal, 14)
            }
        }
        .padding(.top, 16)
    }

    // MARK: Facts

    private func presence(for bot: Bot) -> Avatar.Presence {
        guard bot.id == model.selectedBotID else { return .idle }
        if model.hasPendingRequests { return .needsYou }
        if model.isBotWorking(bot.id) { return .running }
        return .idle
    }

    private func accessibilityLabel(for bot: Bot) -> String {
        var parts = [bot.displayName, "bot"]
        if bot.id == model.selectedBotID { parts.append("selected") }
        if model.isBotWorking(bot.id) { parts.append("working") }
        if model.hasUnread(bot.id) { parts.append("unread") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Previews

private struct SessionSidebarPreview: View {
    @StateObject private var store = PreviewWorkspace.store()

    var body: some View {
        SessionSidebarView(model: store.model, store: store)
            .frame(width: Geometry.sidebarDefault, height: 640)
            .task { await store.attachPreviewHost() }
            .preferredColorScheme(.dark)
    }
}

private struct CompactBotSidebarPreview: View {
    @StateObject private var store = PreviewWorkspace.store()

    var body: some View {
        SessionSidebarView(model: store.model, store: store)
            .frame(width: Geometry.sidebarCompact, height: 640)
            .onAppear { store.setSidebarWidth(Geometry.sidebarCompact) }
            .task { await store.attachPreviewHost() }
            .preferredColorScheme(.dark)
    }
}

#Preview("Bot sidebar") {
    SessionSidebarPreview()
}

#Preview("Bot sidebar · collapsed") {
    CompactBotSidebarPreview()
}
