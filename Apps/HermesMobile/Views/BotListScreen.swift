import SwiftUI
import HermesKit
import HermesAppKit
import OpenBotUI

/// The app's main screen: every bot this host serves.
///
/// A Hermes host is not one assistant. One gateway serves every profile, and each profile
/// is a bot with exactly one endless conversation. So the list is the *bots*, not
/// sessions: avatar, name, and a neutral subtitle that names the profile — never a
/// fabricated preview or a status the phone cannot know.
///
/// Tapping a row selects that bot and pushes its conversation. There is no switcher to
/// open and no sheet: leaving a conversation is the way back to this list.
struct BotListScreen: View {
    @ObservedObject var model: AppModel
    /// Called when a row is chosen, so the tab can push that bot's conversation.
    var onOpenBot: (Bot) -> Void = { _ in }
    @EnvironmentObject private var app: AppEnvironment

    @State private var query = ""
    /// Hidden bots are a view preference; this reveals them so nothing becomes unreachable.
    @State private var showHidden = false
    @State private var iconBot: Bot?
    /// Long-press → Bot Settings. Presented from this screen so the settings flow needs no
    /// plumbing from the tab, and so a long-press can never accidentally open the chat.
    @State private var settingsBot: Bot?
    @AppStorage("lastOpenedBotsByHost") private var lastOpenedBotsJSON = "{}"

    private var lastOpenedBots: [String: String] {
        guard let data = lastOpenedBotsJSON.data(using: .utf8),
              let bots = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return bots
    }

    private var hostKey: String? { app.store.host?.baseURL.absoluteString }

    private var lastOpenedID: String? {
        guard let hostKey else { return nil }
        return lastOpenedBots[hostKey]
    }

    private func recordOpened(_ bot: Bot) {
        guard let hostKey else { return }
        var bots = lastOpenedBots
        bots[hostKey] = bot.id
        guard let data = try? JSONEncoder().encode(bots),
              let json = String(data: data, encoding: .utf8) else { return }
        lastOpenedBotsJSON = json
    }

    private var hiddenBots: [Bot] {
        model.bots.filter { model.isHidden(botID: $0.id) }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filtered: [Bot] {
        // Pinned first, then by last message; hidden bots are excluded by the model's ordering.
        let ordered = model.orderedBots
        guard !trimmedQuery.isEmpty else { return ordered }
        return ordered.filter { bot in
            bot.displayName.localizedCaseInsensitiveContains(trimmedQuery)
                || bot.id.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    var body: some View {
        List {
            if let error = app.botIconsError {
                Text("Could not refresh bot icons: \(error)").font(.caption).foregroundStyle(.red)
            }
            if model.botsLoading && model.bots.isEmpty {
                loadingRow
            } else if filtered.isEmpty && !(showHidden && !hiddenBots.isEmpty) {
                emptySection
            } else {
                ForEach(filtered) { bot in
                    row(for: bot)
                }

                if showHidden, !hiddenBots.isEmpty {
                    Section("Hidden") {
                        ForEach(hiddenBots) { bot in
                            Button {
                                model.toggleHidden(botID: bot.id)
                            } label: {
                                HStack {
                                    Text(bot.displayName).foregroundStyle(Tokens.textPrimary)
                                    Spacer()
                                    Text("Show").foregroundStyle(Tokens.accentText)
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Tokens.canvas)
        .navigationTitle("Hermes Bots")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search bots")
        .refreshable {
            await app.loadBots()
            // A pull-to-refresh is a request for what is on the host *now*, so the cached preview
            // lines are dropped rather than trusted.
            await model.loadBotPreviews(force: true)
        }
        // First fill: one `session.list` per bot, bounded and cached, so the rows get their third
        // line without a pull.
        .task { await model.loadBotPreviews() }
        .toolbar { toolbarContent }
        .sheet(item: $settingsBot) { bot in
            BotModelSettingsScreen(
                bot: bot,
                load: { botID in try await model.modelCatalog(for: botID) },
                conversationIsOpen: model.selectedBotID == bot.id,
                resetConversation: { model.resetEndlessSession(for: bot.id) },
                save: { botID, option, confirmed in
                    switch try await model.configureModel(botID: botID,
                                                          model: option.id,
                                                          provider: option.provider,
                                                          confirm: confirmed) {
                    case .applied:
                        return .saved
                    case .confirmationRequired(let message):
                        return .confirmationRequired(message)
                    }
                },
                saveDescription: { botID, text in
                    try await model.configureDescription(botID: botID, description: text)
                })
        }
        .sheet(item: $iconBot) { bot in
            BotIconPicker(botName: bot.displayName, selected: app.botIcons[bot.id]) { icon in
                try await app.saveBotIcon(botID: bot.id, icon: icon)
            }
        }
        .mobileConnectionBanner(connection: app.visibleConnection,
                                turnRunning: model.isStreaming,
                                host: app.hostLabel,
                                retry: { Task { await app.reconnect() } })
    }

    // MARK: Rows

    private func row(for bot: Bot) -> some View {
        Button {
            Haptics.selection()
            recordOpened(bot)
            onOpenBot(bot)
        } label: {
            HStack(spacing: 12) {
                if let icon = app.botIcons[bot.id] {
                    BotIconPortrait(icon, size: 48,
                                    isWorking: model.isStreaming && model.selectedBotID == bot.id)
                } else {
                    Avatar(bot.displayName,
                       size: .large,
                       presence: .idle,
                       initials: bot.avatarInitials)
                        .overlay {
                            BotWorkingSparks(size: 44, color: Tokens.accentText,
                                             isWorking: model.isStreaming && model.selectedBotID == bot.id)
                        }
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(bot.displayName)
                            .font(TypeScale.font(TypeScale.sessionTitle, weight: .semibold))
                            .foregroundStyle(Tokens.textPrimary)
                            .lineLimit(1)

                        if model.isPinned(botID: bot.id) {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Tokens.textMuted)
                                .accessibilityHidden(true)
                        }
                    }

                    Text(subtitle(for: bot))
                        .font(TypeScale.font(TypeScale.sessionPreview))
                        .foregroundStyle(Tokens.textMuted)
                        .lineLimit(1)

                    // Third line: the newest thing this bot said, straight from the host. Omitted
                    // rather than faked when the host has no line for this bot yet.
                    if let preview = model.botPreviews[bot.id] {
                        Text(preview)
                            .font(TypeScale.font(TypeScale.sessionPreview))
                            .foregroundStyle(Tokens.textDim)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer(minLength: 8)

                if model.hasUnread(bot.id) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tokens.textDim)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { iconBot = bot } label: { Label("Bot icon", systemImage: "person.crop.circle") }
            Button { settingsBot = bot } label: { Label("Bot Settings", systemImage: "gearshape") }
            Button {
                model.togglePin(botID: bot.id)
            } label: {
                Label(model.isPinned(botID: bot.id) ? "Unpin" : "Pin to top",
                      systemImage: model.isPinned(botID: bot.id) ? "pin.slash" : "pin")
            }
            Button(role: .destructive) {
                model.toggleHidden(botID: bot.id)
            } label: {
                Label("Hide bot", systemImage: "eye.slash")
            }
        }
        .listRowBackground(Tokens.canvas)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .accessibilityLabel(accessibilityLabel(for: bot))
        .accessibilityHint("Opens the conversation with this bot")
    }

    /// A description written on the host is the useful line; without one, name what the row is.
    /// A profile whose id is its own name has nothing worth printing twice, so it gets a label
    /// rather than a repeat of the title.
    private func subtitle(for bot: Bot) -> String {
        if let description = bot.description, !description.isEmpty { return description }
        return bot.id == bot.displayName ? "Hermes profile" : bot.id
    }

    private func accessibilityLabel(for bot: Bot) -> String {
        var parts = [bot.displayName, "bot"]
        if model.isPinned(botID: bot.id) { parts.append("pinned") }
        if bot.id == lastOpenedID { parts.append("last opened") }
        return parts.joined(separator: ", ")
    }

    private var loadingRow: some View {
        HStack(spacing: 10) {
            SpinningRing(color: Tokens.textMuted, size: 12, lineWidth: 1.5)
            Text("Loading bots…")
                .font(TypeScale.font(TypeScale.lg))
                .foregroundStyle(Tokens.textMuted)
        }
        .listRowBackground(Tokens.canvas)
        .listRowSeparator(.hidden)
        .padding(.vertical, 8)
    }

    // MARK: Empty states

    @ViewBuilder
    private var emptySection: some View {
        Section {
            Group {
                if !trimmedQuery.isEmpty {
                    messageBlock(icon: "magnifyingglass",
                                 title: "No matches",
                                 body: "No bot on this host matches “\(trimmedQuery)”.")
                } else if !app.isPaired {
                    unpairedState
                } else if model.botsLoading {
                    loadingBlock
                } else if let error = model.botsError {
                    errorState(error)
                } else {
                    noBotsState
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
        }
    }

    private var unpairedState: some View {
        VStack(spacing: 14) {
            Avatar("Hermes", size: .hero, presence: .idle)
            Text("Pair with your host")
                .font(TypeScale.font(TypeScale.xl, weight: .semibold))
                .foregroundStyle(Tokens.textPrimary)
            Text("Scan the pairing code from `hermes-bridge pair`, or paste the code your host printed.")
                .font(TypeScale.font(TypeScale.lg))
                .foregroundStyle(Tokens.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            OpenBotButton("Pair a device",
                          systemImage: "qrcode",
                          kind: .primary,
                          corners: .capsule) {
                app.isPairingPresented = true
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.top, 56)
    }

    private var loadingBlock: some View {
        VStack(spacing: 10) {
            SpinningRing(color: Tokens.textMuted, size: 14, lineWidth: 1.5)
            Text("Looking for bots…")
                .font(TypeScale.font(TypeScale.lg))
                .foregroundStyle(Tokens.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 56)
    }

    private func errorState(_ error: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(Tokens.textDim)
            Text("Could not list this host's bots")
                .font(TypeScale.font(TypeScale.xl, weight: .semibold))
                .foregroundStyle(Tokens.textPrimary)
            Text(error)
                .font(TypeScale.font(TypeScale.lg))
                .foregroundStyle(Tokens.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            OpenBotButton("Try again",
                          systemImage: "arrow.clockwise",
                          kind: .secondary,
                          corners: .capsule) {
                Task { await app.loadBots() }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 56)
    }

    private var noBotsState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(Tokens.textDim)
            Text("No bots found on this host")
                .font(TypeScale.font(TypeScale.xl, weight: .semibold))
                .foregroundStyle(Tokens.textPrimary)
            Text("The gateway answered, but listed no profiles. Check that this host has a Hermes bot to talk to, then look again.")
                .font(TypeScale.font(TypeScale.lg))
                .foregroundStyle(Tokens.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            OpenBotButton("Check again",
                          systemImage: "arrow.clockwise",
                          kind: .secondary,
                          corners: .capsule) {
                Task { await app.loadBots() }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 56)
    }

    private func messageBlock(icon: String, title: String, body: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(Tokens.textDim)
            Text(title)
                .font(TypeScale.font(TypeScale.xl, weight: .semibold))
                .foregroundStyle(Tokens.textPrimary)
            Text(body)
                .font(TypeScale.font(TypeScale.lg))
                .foregroundStyle(Tokens.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 56)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if app.isPaired {
            // Top-right, opposite the title: the leading corner is where iOS puts Back on the
            // next screen, and a filter sitting there reads like navigation.
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showHidden.toggle()
                    } label: {
                        Label("Show hidden bots", systemImage: showHidden ? "checkmark" : "circle")
                    }
                    .accessibilityValue(showHidden ? "On" : "Off")
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Bot list filters")
            }
        }
        if !app.isPaired {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    app.isPairingPresented = true
                } label: {
                    Label("Pair", systemImage: "link.badge.plus")
                }
                .tint(Tokens.accentText)
            }
        }
    }
}

// MARK: - Previews

#Preview("Bots · paired") {
    let environment = AppEnvironment.preview()
    NavigationStack {
        BotListScreen(model: environment.model)
            .navigationDestination(for: Bot.self) { bot in
                ConversationScreen(model: environment.model, bot: bot)
            }
    }
    .environmentObject(environment)
    .preferredColorScheme(.dark)
    .task { await environment.start() }
}

#Preview("Bots · unpaired") {
    let environment = AppEnvironment.preview(paired: false)
    NavigationStack {
        BotListScreen(model: environment.model)
    }
    .environmentObject(environment)
    .preferredColorScheme(.dark)
}
