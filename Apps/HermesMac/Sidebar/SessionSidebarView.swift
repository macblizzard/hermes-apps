import HermesAppKit
import HermesKit
import OpenBotUI
import SwiftUI

/// The session list pane: groups, run state, search, and the host chip at the foot.
///
/// Under 110 pt the same pane becomes the compact avatar strip — the collapse rule from
/// `Geometry.sidebarCollapseBelow`, not a separate mode the user has to find.
struct SessionSidebarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: WorkspaceStore

    private var sections: [SessionSection] {
        SessionGrouping.sections(sessions: model.sessions,
                                 running: model.runningSessions,
                                 needsYou: SessionGrouping.needsYou(selected: model.selectedSessionID,
                                                                    hasPendingRequests: model.hasPendingRequests),
                                 query: store.searchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.sidebarIsCompact {
                compactStrip
                hostDot
            } else {
                header
                MacSidebarSearchField(text: $store.searchText)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                list
                Spacer(minLength: 0)
                HostStatusBar(model: model, store: store)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Tokens.sidebar)
    }

    /// At 88 pt the host chip has no room for words, so the same information shrinks to the
    /// avatar's presence dot and its tooltip, with the one verb that still matters (re)connect.
    private var hostDot: some View {
        VStack(spacing: 4) {
            if !model.connection.isLive {
                OpenBotIconButton("bolt.horizontal",
                                  label: store.isPaired ? "Connect to the host" : "Pair a host",
                                  size: .small,
                                  isBusy: model.connection == .connecting) {
                    if store.isPaired {
                        Task { await store.connect() }
                    } else {
                        store.isPairSheetPresented = true
                    }
                }
            }

            Avatar(model.hostName,
                   size: .small,
                   presence: model.hasPendingRequests ? .needsYou : (model.connection.isLive ? .running : .idle))
                .help("\(model.hostName) — \(model.connection.label)")
        }
        .padding(.bottom, 10)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(store.botTitle)
                .font(TypeScale.font(15, weight: .semibold))
                .foregroundStyle(Tokens.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(store.botTitle)

            if model.sessionsLoading {
                SpinningRing(color: Tokens.textDim, size: 9, lineWidth: 1.4)
            }

            Spacer(minLength: 4)

            OpenBotIconButton("magnifyingglass", label: "Search every session (⌘K)", size: .small) {
                store.openPalette()
            }

            OpenBotIconButton("square.and.pencil",
                              label: "New session",
                              size: .small,
                              isDisabled: !model.connection.isLive) {
                store.newSession()
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        if !store.isPaired {
            unpairedState
        } else if model.sessions.isEmpty && model.bots.isEmpty {
            if model.botsLoading {
                discoveringBotsState
            } else if let error = model.botsError {
                botsErrorState(error)
            } else if model.connection.isLive {
                noBotsState
            } else {
                emptyState
            }
        } else if model.selectedBotID == nil && !model.bots.isEmpty {
            // A bot list with nothing chosen: the rail is the way out, not a spinner.
            noBotSelectedState
        } else if model.sessions.isEmpty {
            if model.sessionsLoading {
                loadingSessionsState
            } else {
                emptyState
            }
        } else if sections.isEmpty {
            noMatchesState
        } else {
            sessionList
        }
    }

    private var sessionList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(sections) { section in
                    SectionCaption(section.title)
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                        .padding(.bottom, 3)

                    ForEach(section.sessions) { session in
                        row(for: session)
                    }
                }

                Color.clear.frame(height: 8)
            }
            .padding(.horizontal, 6)
        }
    }

    private func row(for session: SessionSummary) -> some View {
        let needsYou = SessionGrouping.needsYou(selected: model.selectedSessionID,
                                                hasPendingRequests: model.hasPendingRequests) == session.id
        let isRunning = session.running || model.runningSessions.contains(session.id)
        return Button {
            store.select(session.id)
        } label: {
            SessionRow(title: session.displayTitle,
                       preview: session.preview,
                       updatedAt: session.updatedAt,
                       presence: needsYou ? .needsYou : (isRunning ? .running : .idle),
                       isSelected: model.selectedSessionID == session.id,
                       showsProgress: isRunning)
        }
        .buttonStyle(.plain)
    }

    // MARK: Compact strip

    private var compactStrip: some View {
        VStack(spacing: 4) {
            OpenBotIconButton("sidebar.left", label: "Expand the session list", size: .small) {
                store.setSidebarWidth(Geometry.sidebarDefault)
                store.endSidebarDrag()
            }
            .padding(.top, 8)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(Array(model.sessions.prefix(14))) { session in
                        Button {
                            store.select(session.id)
                        } label: {
                            Avatar(session.displayTitle,
                                   size: .small,
                                   presence: session.running ? .running : .idle)
                                .padding(4)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(model.selectedSessionID == session.id ? Tokens.controlActive : .clear)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(session.displayTitle)
                        .accessibilityLabel(session.displayTitle)
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
            Text("Pair this Mac with your Hermes host to load its sessions. Nothing is sent until you do.")
                .font(TypeScale.font(Tokens.textSM))
                .foregroundStyle(Tokens.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
            OpenBotButton("Pair host…", systemImage: "link", kind: .secondary, size: .small) {
                store.isPairSheetPresented = true
            }
            .padding(.horizontal, 14)
        }
        .padding(.top, 4)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption(model.connection.isLive ? "NO SESSIONS" : "NOT LOADED")
                .padding(.horizontal, 14)
            Text(model.connection.isLive
                 ? "\(store.botTitle) has no sessions yet. Start one."
                 : "Connect to \(store.pairing?.displayHost ?? model.hostName) to list its conversations.")
                .font(TypeScale.font(Tokens.textSM))
                .foregroundStyle(Tokens.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
            OpenBotButton(model.connection.isLive ? "New session" : "Connect",
                          systemImage: model.connection.isLive ? "square.and.pencil" : "bolt.horizontal",
                          kind: .secondary,
                          size: .small,
                          isDisabled: !model.connection.isLive) {
                if model.connection.isLive {
                    store.newSession()
                } else {
                    Task { await store.connect() }
                }
            }
            .padding(.horizontal, 14)
        }
        .padding(.top, 4)
    }

    /// The host answered `profiles.list` and named no bots. This is a state the user can
    /// act on, not a failure to retry forever, so it says what happened and offers one
    /// refresh rather than a spinner.
    private var noBotsState: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption("NO BOTS")
                .padding(.horizontal, 14)
            Text("No bots found on this host.")
                .font(TypeScale.font(Tokens.textSM, weight: .medium))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
            Text("The gateway answered, but listed no profiles. Check that this host has a Hermes bot to talk to, then check again.")
                .font(TypeScale.font(Tokens.textSM))
                .foregroundStyle(Tokens.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
            OpenBotButton("Check again",
                          systemImage: "arrow.clockwise",
                          kind: .secondary,
                          size: .small) {
                Task { await store.loadBots() }
            }
            .padding(.horizontal, 14)
        }
        .padding(.top, 4)
    }

    /// `profiles.list` failed and there are no rows to fall back to (an older host that
    /// also answers no sessions). Say which call failed and what it said, plus one retry.
    private func botsErrorState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption("BOTS UNAVAILABLE")
                .padding(.horizontal, 14)
            Text("Could not list this host's bots.")
                .font(TypeScale.font(Tokens.textSM, weight: .medium))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
            Text(message)
                .font(TypeScale.font(Tokens.textSM))
                .foregroundStyle(Tokens.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
            OpenBotButton("Try again",
                          systemImage: "arrow.clockwise",
                          kind: .secondary,
                          size: .small,
                          isDisabled: !model.connection.isLive) {
                Task { await store.loadBots() }
            }
            .padding(.horizontal, 14)
        }
        .padding(.top, 4)
    }

    /// A bot switch clears the list before the new one arrives. Say that, rather than
    /// telling the user the bot has no sessions while the answer is still in flight.
    private var loadingSessionsState: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption("LOADING SESSIONS")
                .padding(.horizontal, 14)
            HStack(spacing: 8) {
                SpinningRing(color: Tokens.textDim, size: 10, lineWidth: 1.4)
                Text("Reading \(store.botTitle)'s conversations…")
                    .font(TypeScale.font(Tokens.textSM))
                    .foregroundStyle(Tokens.textMuted)
            }
            .padding(.horizontal, 14)
        }
        .padding(.top, 4)
    }

    private var discoveringBotsState: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption("FINDING BOTS")
                .padding(.horizontal, 14)
            HStack(spacing: 8) {
                SpinningRing(color: Tokens.textDim, size: 10, lineWidth: 1.4)
                Text("Asking the host which bots it serves…")
                    .font(TypeScale.font(Tokens.textSM))
                    .foregroundStyle(Tokens.textMuted)
            }
            .padding(.horizontal, 14)
        }
        .padding(.top, 4)
    }

    private var noBotSelectedState: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption("NO BOT SELECTED")
                .padding(.horizontal, 14)
            Text("Pick a bot in the rail to see its conversations.")
                .font(TypeScale.font(Tokens.textSM))
                .foregroundStyle(Tokens.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
        }
        .padding(.top, 4)
    }

    private var noMatchesState: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionCaption("NO MATCHES")
                .padding(.horizontal, 14)
            Text("Nothing matches “\(store.searchText)”.")
                .font(TypeScale.font(Tokens.textSM))
                .foregroundStyle(Tokens.textMuted)
                .padding(.horizontal, 14)
        }
        .padding(.top, 4)
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

private struct CompactSessionSidebarPreview: View {
    @StateObject private var store = PreviewWorkspace.store()

    var body: some View {
        SessionSidebarView(model: store.model, store: store)
            .frame(width: Geometry.sidebarCompact, height: 640)
            .onAppear { store.setSidebarWidth(Geometry.sidebarCompact) }
            .task { await store.attachPreviewHost() }
            .preferredColorScheme(.dark)
    }
}

private struct BotWithoutSessionsPreview: View {
    @StateObject private var store = PreviewWorkspace.store(.empty)

    var body: some View {
        SessionSidebarView(model: store.model, store: store)
            .frame(width: Geometry.sidebarDefault, height: 640)
            .task { await store.attachPreviewHost() }
            .preferredColorScheme(.dark)
    }
}

#Preview("Session sidebar") {
    SessionSidebarPreview()
}

#Preview("Session sidebar · bot with no sessions") {
    BotWithoutSessionsPreview()
}

#Preview("Session sidebar · collapsed") {
    CompactSessionSidebarPreview()
}
