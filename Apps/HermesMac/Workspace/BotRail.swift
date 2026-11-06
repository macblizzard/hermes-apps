import Foundation
import HermesAppKit
import HermesKit
import OpenBotUI
import SwiftUI

/// The bots column: the 72 pt rail's top block, one avatar per bot the gateway serves.
///
/// A bot is a Hermes profile. This column is the only switcher on the Mac: clicking an
/// avatar re-scopes the session list and the conversation to that bot. The rail keeps the
/// rest of its shape below the list, so the column still reads as one rail rather than a
/// sidebar inside a sidebar.
///
/// Density: `Avatar.medium` is 34 pt, drawn in the same 38 pt control slot as
/// `IconRail.railButton` so the bot column and the marks under it sit on one rhythm.
struct BotRail: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        Group {
            if model.bots.isEmpty {
                emptyMark
            } else {
                botList
            }
        }
    }

    // MARK: Bots

    private var botList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 4) {
                    ForEach(model.orderedBots) { bot in
                        botButton(bot)
                            .id(bot.id)
                    }
                }
                .padding(.vertical, 2)
            }
            .onAppear {
                // After the first layout pass; a scroll before the list is measured is a no-op.
                DispatchQueue.main.async { revealSelected(proxy) }
            }
            .onChange(of: model.selectedBotID) { _ in
                revealSelected(proxy)
            }
        }
    }

    private func botButton(_ bot: Bot) -> some View {
        let isSelected = bot.id == model.selectedBotID
        let isPinned = model.isPinned(botID: bot.id)
        return Button {
            guard !isSelected else { return }
            Haptics.selection()
            store.selectBot(bot.id)
        } label: {
            Avatar(bot.displayName,
                   size: .medium,
                   presence: presence(for: bot),
                   initials: bot.avatarInitials)
                .frame(width: 38, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                        .fill(isSelected ? Tokens.controlActive : .clear)
                )
                .overlay(alignment: .topTrailing) {
                    // The same green dot as the list: a reply arrived for a bot that was not open.
                    if model.hasUnread(bot.id) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                            .offset(x: 2, y: -2)
                            .accessibilityHidden(true)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(Tokens.textMuted)
                            .offset(x: 3, y: 1)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
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
        .accessibilityLabel(bot.displayName)
        .accessibilityValue(isSelected ? "Current bot" : "")
    }

    /// Live state is only known for the bot whose sessions are loaded. The others stay
    /// `idle` rather than borrowing the selected bot's ring or dot.
    private func presence(for bot: Bot) -> Avatar.Presence {
        guard bot.id == model.selectedBotID else { return .idle }
        if model.hasPendingRequests { return .needsYou }
        if model.isStreaming { return .running }
        return .idle
    }

    private func revealSelected(_ proxy: ScrollViewProxy) {
        guard let id = model.selectedBotID else { return }
        proxy.scrollTo(id, anchor: .center)
    }

    // MARK: No bots

    /// The mark stays where the bot list would be, and says why it is alone: a host that
    /// advertises no profiles gets an honest tooltip here and the full sentence in the
    /// session pane, never an empty column that looks broken.
    private var emptyMark: some View {
        let paired = store.isPaired
        let label: String
        let symbol: String
        if !paired {
            label = "No host paired"
            symbol = "link.badge.plus"
        } else if model.botsError != nil {
            label = "Could not list bots"
            symbol = "exclamationmark.triangle"
        } else {
            label = "No bots found on this host"
            symbol = "person.2.slash"
        }
        return RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(Tokens.surfaceRaised)
            .frame(width: 34, height: 34)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Tokens.textDim)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Tokens.borderStrong, lineWidth: 1)
            )
            .help(label)
            .accessibilityLabel(label)
    }
}

// MARK: - Previews

private struct BotRailPreview: View {
    @StateObject private var store = PreviewWorkspace.store()

    var body: some View {
        HStack(spacing: 0) {
            BotRail(model: store.model, store: store)
                .frame(width: Geometry.serverRailMacOS)
            Hairline(.vertical)
        }
        .frame(height: 520)
        .background(Tokens.sidebar)
        .task { await store.attachPreviewHost() }
        .preferredColorScheme(.dark)
    }
}

#Preview("Bot rail · several bots") {
    BotRailPreview()
}
