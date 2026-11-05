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
            Text("Hermes")
                .font(TypeScale.font(15, weight: .semibold))
                .foregroundStyle(Tokens.textPrimary)

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
        } else if model.sessions.isEmpty {
            emptyState
        } else if sections.isEmpty {
            noMatchesState
        } else {
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
    }

    private func row(for session: SessionSummary) -> some View {
        let needsYou = SessionGrouping.needsYou(selected: model.selectedSessionID,
                                                hasPendingRequests: model.hasPendingRequests) == session.id
        let isRunning = session.running || model.runningSessions.contains(session.id)
        return Button {
            store.select(session.id)
        } label: {
            SessionRow(title: session.title,
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
                            Avatar(session.title,
                                   size: .small,
                                   presence: session.running ? .running : .idle)
                                .padding(4)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(model.selectedSessionID == session.id ? Tokens.controlActive : .clear)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(session.title)
                        .accessibilityLabel(session.title)
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
            SectionCaption(store.connectAttempted ? "NO SESSIONS" : "NOT LOADED")
                .padding(.horizontal, 14)
            Text(store.connectAttempted
                 ? "The host answered, but has no sessions yet. Start one."
                 : "Connect to \(store.pairing?.displayHost ?? model.hostName) to list its conversations.")
                .font(TypeScale.font(Tokens.textSM))
                .foregroundStyle(Tokens.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
            OpenBotButton(store.connectAttempted ? "New session" : "Connect",
                          systemImage: store.connectAttempted ? "square.and.pencil" : "bolt.horizontal",
                          kind: .secondary,
                          size: .small,
                          isDisabled: store.connectAttempted && !model.connection.isLive) {
                if store.connectAttempted {
                    store.newSession()
                } else {
                    Task { await store.connect() }
                }
            }
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

#Preview("Session sidebar") {
    SessionSidebarPreview()
}

#Preview("Session sidebar · collapsed") {
    CompactSessionSidebarPreview()
}
