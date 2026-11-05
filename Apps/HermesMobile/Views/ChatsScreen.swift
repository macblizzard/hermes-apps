import SwiftUI
import HermesKit
import HermesAppKit
import OpenBotUI

/// Chats: the list of sessions on the paired host.
///
/// A plain `List` on the canvas — large title, search, one row per session with its
/// avatar, name, state tag, two lines of preview and a relative time. The tab bar is the
/// system one; nothing here imitates chrome.
struct ChatsScreen: View {
    @ObservedObject var model: AppModel
    /// Called when a row (or a brand-new session) should be pushed onto the stack.
    var onOpenSession: (SessionID) -> Void = { _ in }

    @EnvironmentObject private var app: AppEnvironment

    @State private var query = ""

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filtered: [SessionSummary] {
        guard !trimmedQuery.isEmpty else { return model.sessions }
        return model.sessions.filter { session in
            session.title.localizedCaseInsensitiveContains(trimmedQuery)
                || (session.preview?.localizedCaseInsensitiveContains(trimmedQuery) ?? false)
        }
    }

    var body: some View {
        List {
            if model.sessionsLoading && model.sessions.isEmpty {
                loadingRow
            } else if filtered.isEmpty {
                emptySection
            } else {
                ForEach(filtered) { session in
                    row(for: session)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Tokens.canvas)
        .navigationTitle("Chats")
        .searchable(text: $query,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search sessions")
        .refreshable {
            // `loadBots` re-lists the profile directory and the selected bot's sessions,
            // so a pull-to-refresh cannot leave rows from a directory that changed.
            await app.loadBots()
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $app.isBotSwitcherPresented) {
            BotSwitcherSheet(model: model)
        }
        .mobileConnectionBanner(connection: app.visibleConnection,
                                turnRunning: model.isStreaming,
                                host: app.hostLabel,
                                retry: { Task { await app.reconnect() } })
    }

    /// The nav-bar avatar is the bot in use, not the host: switching bots is the only
    /// navigation this screen needs, and the host is named in the connection banner.
    private var botPresence: Avatar.Presence {
        if model.hasPendingRequests { return .needsYou }
        if model.isStreaming { return .running }
        return .idle
    }

    // MARK: Rows

    private func row(for session: SessionSummary) -> some View {
        NavigationLink(value: session.id) {
            SessionRow(title: session.displayTitle,
                       preview: session.preview,
                       updatedAt: session.updatedAt,
                       presence: presence(for: session),
                       showsProgress: presence(for: session) == .running,
                       now: Date())
        }
        .listRowBackground(Tokens.canvas)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
    }

    /// `AppModel` knows more than `SessionSummary.running`: `runningSessions` and
    /// `pendingRequests` are live. A row says "needs you" first, then "running".
    private func presence(for session: SessionSummary) -> Avatar.Presence {
        if app.needsYou(session) { return .needsYou }
        if session.running || model.runningSessions.contains(session.id) { return .running }
        return .idle
    }

    private var loadingRow: some View {
        HStack(spacing: 10) {
            SpinningRing(color: Tokens.textMuted, size: 12, lineWidth: 1.5)
            Text("Loading sessions…")
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
                                 body: "Nothing in your sessions matches “\(trimmedQuery)”.")
                } else if !app.isPaired {
                    unpairedState
                } else if model.bots.isEmpty {
                    botsState
                } else if app.selectedBot == nil {
                    noBotState
                } else {
                    messageBlock(icon: "bubble.left.and.bubble.right",
                                 title: "No sessions yet",
                                 body: "\(app.selectedBotName) has no sessions yet. Start one from the Mac, or send the first message from this phone once a session exists.")
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

    /// The host answered and named no bots. Not a spinner: a sentence, and one way to
    /// check again once the host has a profile.
    @ViewBuilder
    private var botsState: some View {
        if model.botsLoading {
            VStack(spacing: 10) {
                SpinningRing(color: Tokens.textMuted, size: 14, lineWidth: 1.5)
                Text("Looking for bots…")
                    .font(TypeScale.font(TypeScale.lg))
                    .foregroundStyle(Tokens.textMuted)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 56)
        } else if let error = model.botsError {
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
        } else {
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
    }

    /// The host listed bots but none is chosen. The nav-bar avatar is the way back, so
    /// this says that rather than showing one bot's sessions under no bot's name.
    private var noBotState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(Tokens.textDim)
            Text("No bot selected")
                .font(TypeScale.font(TypeScale.xl, weight: .semibold))
                .foregroundStyle(Tokens.textPrimary)
            Text("Open the bot list in the top-left corner and pick the assistant you want to talk to.")
                .font(TypeScale.font(TypeScale.lg))
                .foregroundStyle(Tokens.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            OpenBotButton("Choose a bot",
                          systemImage: "person.2",
                          kind: .secondary,
                          corners: .capsule) {
                app.isBotSwitcherPresented = true
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
        ToolbarItem(placement: .topBarLeading) {
            Button {
                Haptics.selection()
                app.isBotSwitcherPresented = true
            } label: {
                HStack(spacing: 4) {
                    Avatar(app.selectedBotName,
                           size: .medium,
                           presence: botPresence,
                           initials: app.selectedBot?.avatarInitials)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Tokens.textMuted)
                }
            }
            .accessibilityLabel("Switch bot, now \(app.selectedBotName)")
        }

        ToolbarItem(placement: .topBarTrailing) {
            if app.isPaired {
                Button {
                    Task {
                        let previous = model.selectedSessionID
                        await model.newSession()
                        // Only push a session this tap actually created *and* that belongs to
                        // the bot on screen: `session.create` has no profile argument in the
                        // client contract, so a session created in another profile must not
                        // be opened under this bot's header.
                        if let created = model.selectedSessionID,
                           created != previous,
                           model.sessions.contains(where: { $0.id == created }) {
                            onOpenSession(created)
                        }
                    }
                } label: {
                    Image(systemName: "square.and.pencil")
                        .foregroundStyle(Tokens.accentText)
                }
                .disabled(model.sessionsLoading)
                .accessibilityLabel("New session")
            } else {
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

#Preview("Chats · paired") {
    let environment = AppEnvironment.preview()
    NavigationStack {
        ChatsScreen(model: environment.model)
            .navigationDestination(for: SessionID.self) { id in
                ConversationScreen(model: environment.model, sessionID: id)
            }
    }
    .environmentObject(environment)
    .preferredColorScheme(.dark)
    .task { await environment.start() }
}

#Preview("Chats · unpaired") {
    let environment = AppEnvironment.preview(paired: false)
    NavigationStack {
        ChatsScreen(model: environment.model)
    }
    .environmentObject(environment)
    .preferredColorScheme(.dark)
}
