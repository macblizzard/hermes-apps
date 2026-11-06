import HermesAppKit
import OpenBotUI
import SwiftUI

/// The window: a `Tokens.frame` surround with the workspace clipped inside it.
///
/// The surround is the app's one piece of theatre and it is exact — 8 pt on three sides and a
/// 28 pt top strip for the hidden title bar's traffic lights. The strip counts the system
/// title-bar safe area instead of stacking on top of it, so the workspace is never pushed down
/// twice. Leaving that strip also keeps the title bar's drag area intact.
struct WorkspaceRoot: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Tokens.frame
                    .ignoresSafeArea()

                WorkspaceShell(model: store.model, store: store)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(Tokens.borderStrong, lineWidth: 1)
                    )
                    .padding(.horizontal, WorkspaceChrome.sideInset)
                    .padding(.top, WorkspaceChrome.topPadding(safeAreaTop: proxy.safeAreaInsets.top))
                    .padding(.bottom, WorkspaceChrome.bottomInset)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .sheet(isPresented: $store.isPalettePresented) {
            CommandPaletteView(store: store)
        }
        .sheet(isPresented: $store.isPairSheetPresented) {
            PairHostSheet(store: store)
        }
        // One sheet, two doors: the sidebar's context menu and the conversation's menu both set
        // `botSettingsBot`, so the per-bot settings live in a single place.
        .sheet(item: $store.botSettingsBot) { bot in
            MacBotSettingsSheet(model: store.model,
                                store: store,
                                bot: bot,
                                conversationIsOpen: store.model.selectedBotID == bot.id)
        }
    }
}

/// Bot directory, then the conversation — nothing on the right.
///
/// The app has one continuous conversation per bot, so a session browser and its context panel
/// would be two more places to look for the same thread. Pairing, devices, settings and the
/// command palette live in the native menu bar; the window itself is bots on the left and the
/// selected bot's chat on the right.
struct WorkspaceShell: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: WorkspaceStore

    private var sidebarBinding: Binding<CGFloat> {
        Binding(get: { store.sidebarWidth },
                set: { store.setSidebarWidth($0) })
    }

    var body: some View {
        HStack(spacing: 0) {
            SessionSidebarView(model: model, store: store)
                .frame(width: store.sidebarWidth)

            PaneDivider(width: sidebarBinding,
                        range: 64...Geometry.sidebarMax,
                        onCommit: { store.endSidebarDrag() })

            Hairline(.vertical)

            ConversationPane(model: model, store: store)
                .frame(minWidth: Geometry.conversationMin, maxWidth: .infinity, maxHeight: .infinity)
                // A new bot is a new conversation: re-creating the pane drops the old
                // scroll position and any approval sheet that belonged to the last bot.
                .id(model.selectedBotID ?? "no-bot")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.canvas)
    }
}

// MARK: - Previews

private struct WorkspaceRootPreview: View {
    @StateObject private var store = PreviewWorkspace.store()

    var body: some View {
        WorkspaceRoot(store: store)
            .frame(width: 1280, height: 820)
            .preferredColorScheme(.dark)
            .task { await store.attachPreviewHost() }
    }
}

private struct WorkspaceRootApprovalPreview: View {
    @StateObject private var store = PreviewWorkspace.store(.approval)

    var body: some View {
        WorkspaceRoot(store: store)
            .frame(width: 1280, height: 820)
            .preferredColorScheme(.dark)
            .task { await store.attachPreviewHost() }
    }
}

#Preview("Workspace") {
    WorkspaceRootPreview()
}

#Preview("Workspace · approval waiting") {
    WorkspaceRootApprovalPreview()
}
