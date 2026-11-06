import HermesAppKit
import HermesKit
import OpenBotUI
import SwiftUI

/// The bots block at the top of the left pane.
///
/// The rail's avatars stay the fastest switch; this list is the phone's bot list brought to the
/// desktop: the profile's description under its name, a green dot for a reply that arrived while
/// the conversation was not on screen, pin/hide from the row's context menu, and one filter in the
/// block's own caption row so a hidden bot is never out of reach.
///
/// Ordering is `AppModel.orderedBots` — pinned first, then last activity — so both surfaces agree.
struct SidebarBotList: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: WorkspaceStore
    /// View preference, not a stored one: hidden bots stay hidden across launches via the model.
    @Binding var showsHiddenBots: Bool
    /// True when this block *is* the left panel rather than a strip above a session list: the
    /// rows then take every point the window offers instead of stopping after about five.
    var fillsAvailableHeight: Bool = false

    /// Hidden bots are excluded by the model's ordering, so this is the visible list.
    private var visibleBots: [Bot] { model.orderedBots }

    private var hiddenBots: [Bot] {
        model.bots.filter { model.isHidden(botID: $0.id) }
    }

    private var rowCount: Int {
        visibleBots.count + (showsHiddenBots ? hiddenBots.count : 0)
    }

    /// The block sizes to its content and stops growing at about five rows, then scrolls.
    private var listHeight: CGFloat {
        let hiddenExtra = showsHiddenBots && !hiddenBots.isEmpty ? 24 : 0
        return min(CGFloat(max(rowCount, 1)) * 39 + CGFloat(hiddenExtra) + 2, 208)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            captionRow
                .padding(.horizontal, 2)

            if visibleBots.isEmpty, !(showsHiddenBots && !hiddenBots.isEmpty) {
                emptyRow
            } else {
                rows
            }
        }
    }

    // MARK: Caption and filter

    private var captionRow: some View {
        HStack(spacing: 6) {
            SectionCaption("BOTS")

            if model.botsLoading {
                SpinningRing(color: Tokens.textDim, size: 8, lineWidth: 1.3)
            }

            Spacer(minLength: 4)

            Menu {
                // Same control as the phone's list filter: a switch, not a second list.
                Toggle("Show hidden bots", isOn: $showsHiddenBots)
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(showsHiddenBots ? Tokens.accentText : Tokens.textDim)
                    .frame(width: 18, height: 16)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Bot list filters")
            .accessibilityLabel("Bot list filters")
        }
        .padding(.bottom, 1)
    }

    // MARK: Rows

    @ViewBuilder
    private var rows: some View {
        let rows = ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(visibleBots) { bot in
                    row(for: bot)
                }

                if showsHiddenBots, !hiddenBots.isEmpty {
                    SectionCaption("HIDDEN")
                        .padding(.horizontal, 8)
                        .padding(.top, 8)
                        .padding(.bottom, 2)

                    ForEach(hiddenBots) { bot in
                        hiddenRow(for: bot)
                    }
                }
            }
        }

        if fillsAvailableHeight {
            rows.frame(maxHeight: .infinity)
        } else {
            rows.frame(height: listHeight)
        }
    }

    private func row(for bot: Bot) -> some View {
        let isSelected = bot.id == model.selectedBotID
        let isPinned = model.isPinned(botID: bot.id)

        return Button {
            guard !isSelected else { return }
            Haptics.selection()
            store.selectBot(bot.id)
        } label: {
            HStack(alignment: .center, spacing: 8) {
                if let icon = store.botIcons[bot.id] {
                    BotIconPortrait(icon, size: 26, isWorking: bot.id == model.selectedBotID && model.isStreaming)
                } else {
                    Avatar(bot.displayName, size: .small, presence: presence(for: bot), initials: bot.avatarInitials)
                }

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(bot.displayName)
                            .font(TypeScale.font(Tokens.textSM, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(Tokens.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(Tokens.textMuted)
                                .accessibilityHidden(true)
                        }
                    }

                    Text(subtitle(for: bot))
                        .font(TypeScale.font(TypeScale.caption))
                        .foregroundStyle(Tokens.textMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 4)

                if model.hasUnread(bot.id) {
                    // The phone's green dot: a reply that landed while this bot was not on screen.
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(height: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(rest: isSelected ? Tokens.controlActive : .clear,
                   hover: isSelected ? Tokens.controlActive : Tokens.controlHover)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous))
        .contextMenu {
            Button { store.openBotSettings(bot) } label: {
                Label("Bot Settings", systemImage: "gearshape")
            }

            Button {
                model.togglePin(botID: bot.id)
            } label: {
                Label(isPinned ? "Unpin" : "Pin to top",
                      systemImage: isPinned ? "pin.slash" : "pin")
            }

            Button(role: .destructive) {
                model.toggleHidden(botID: bot.id)
            } label: {
                Label("Hide bot", systemImage: "eye.slash")
            }
        }
        .help(bot.displayName)
        .accessibilityLabel(accessibilityLabel(for: bot))
    }

    /// A hidden bot is not gone: the filter reveals it here, and one click puts it back.
    private func hiddenRow(for bot: Bot) -> some View {
        Button {
            model.toggleHidden(botID: bot.id)
        } label: {
            HStack(spacing: 8) {
                Text(bot.displayName)
                    .font(TypeScale.font(Tokens.textSM))
                    .foregroundStyle(Tokens.textMuted)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text("Show")
                    .font(TypeScale.font(TypeScale.caption, weight: .semibold))
                    .foregroundStyle(Tokens.accentText)
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill()
        .clipShape(RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous))
        .contextMenu {
            Button {
                model.toggleHidden(botID: bot.id)
            } label: {
                Label("Show bot", systemImage: "eye")
            }
            Button { store.openBotSettings(bot) } label: {
                Label("Bot Settings", systemImage: "gearshape")
            }
        }
        .help("Show \(bot.displayName) in the bot list")
        .accessibilityLabel("Show \(bot.displayName)")
    }

    private var emptyRow: some View {
        Text(model.botsLoading ? "Asking the host which bots it serves…" : (hiddenBots.isEmpty ? "No bots found on this host." : "All bots are hidden. Use the filter to show them."))
            .font(TypeScale.font(TypeScale.caption))
            .foregroundStyle(Tokens.textDim)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
    }

    // MARK: Facts

    /// A description written on the host is the useful line; without one, name what the row is.
    private func subtitle(for bot: Bot) -> String {
        if let description = bot.description, !description.isEmpty { return description }
        return bot.id == bot.displayName ? "Hermes profile" : bot.id
    }

    /// Live state is only known for the bot whose sessions are loaded; the rest stay idle rather
    /// than borrowing the selected bot's ring.
    private func presence(for bot: Bot) -> Avatar.Presence {
        guard bot.id == model.selectedBotID else { return .idle }
        if model.hasPendingRequests { return .needsYou }
        if model.isStreaming { return .running }
        return .idle
    }

    private func accessibilityLabel(for bot: Bot) -> String {
        var parts = [bot.displayName, "bot"]
        if model.isPinned(botID: bot.id) { parts.append("pinned") }
        if model.hasUnread(bot.id) { parts.append("unread") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Previews

private struct SidebarBotListPreview: View {
    @StateObject private var store = PreviewWorkspace.store()
    @State private var showsHidden = false

    var body: some View {
        SidebarBotList(model: store.model, store: store, showsHiddenBots: $showsHidden)
            .padding(.horizontal, 6)
            .frame(width: Geometry.sidebarDefault)
            .background(Tokens.sidebar)
            .task { await store.attachPreviewHost() }
            .preferredColorScheme(.dark)
    }
}

#Preview("Sidebar bots") {
    SidebarBotListPreview()
}
