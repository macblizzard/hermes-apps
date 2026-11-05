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
        .refreshable { await model.loadSessions() }
        .toolbar { toolbarContent }
        .mobileConnectionBanner(connection: app.visibleConnection,
                                turnRunning: model.isStreaming,
                                host: app.hostLabel,
                                retry: { Task { await app.reconnect() } })
    }

    // MARK: Rows

    private func row(for session: SessionSummary) -> some View {
        NavigationLink(value: session.id) {
            SessionRow(title: session.title,
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
                } else {
                    messageBlock(icon: "bubble.left.and.bubble.right",
                                 title: "No sessions yet",
                                 body: "Start one from the Mac, or send the first message from this phone once a session exists.")
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
            Avatar(app.hostLabel,
                   size: .medium,
                   presence: model.isStreaming ? .running : .idle)
                .accessibilityLabel("Paired host \(app.hostLabel)")
        }

        ToolbarItem(placement: .topBarTrailing) {
            if app.isPaired {
                Button {
                    Task {
                        let previous = model.selectedSessionID
                        await model.newSession()
                        // Only push a session this tap actually created; a failed create
                        // leaves the previous selection in place.
                        if let created = model.selectedSessionID, created != previous {
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
