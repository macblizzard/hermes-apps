import HermesAppKit
import OpenBotUI
import SwiftUI

/// The window: a `Tokens.frame` surround with the workspace clipped inside it.
///
/// The surround is the app's one piece of theatre and it is exact — 8 pt on three sides,
/// 28 pt on top so the hidden title bar's traffic lights sit on the frame colour rather than
/// on the canvas.
///
/// Inside is the phone's information architecture, not a desktop three-pane one: **one panel on
/// the left listing bots, the chat on the right**. There is no session list to browse, no session
/// search and no third inspector column — picking a bot opens that bot's single endless
/// conversation, exactly as the iPhone does.
struct WorkspaceRoot: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        ZStack {
            Tokens.frame
                .ignoresSafeArea()

            WorkspaceShell(model: store.model, store: store)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(Tokens.borderStrong, lineWidth: 1)
                )
                .padding(.horizontal, 8)
                .padding(.top, 28)
                .padding(.bottom, 8)

            paletteOverlay
        }
        // One animation owner for the palette's whole lifecycle: the backdrop fades, the panel
        // rises a few points, and closing is the same motion in reverse.
        .animation(.easeOut(duration: 0.14), value: store.isPalettePresented)
        .sheet(isPresented: $store.isPairSheetPresented) {
            PairHostSheet(store: store)
        }
        // One sheet, two doors: the bot list's context menu and the conversation's menu both set
        // `botSettingsBot`, so the per-bot settings live in a single place. (Settings → Bots has
        // a third door, and presents the same sheet from its own window.)
        .sheet(item: $store.botSettingsBot) { bot in
            MacBotSettingsSheet(model: store.model,
                                store: store,
                                bot: bot,
                                conversationIsOpen: store.model.selectedBotID == bot.id)
        }
    }

    // MARK: - Command palette (⌘K)

    /// A floating palette, not a sheet.
    ///
    /// Sheets are window-modal on macOS: clicking the dimmed area behind one does nothing, and a
    /// verb picker that will not go away when you click outside it reads as a stuck window. So the
    /// palette is an overlay — a tappable backdrop plus the panel above it — rendered only while
    /// `isPalettePresented`, which means it covers nothing and captures nothing once closed.
    @ViewBuilder
    private var paletteOverlay: some View {
        if store.isPalettePresented {
            ZStack(alignment: .top) {
                // The backdrop dismisses; the panel is a sibling drawn above it, so its own
                // clicks never reach the backdrop's gesture.
                Color.black.opacity(0.34)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { store.closePalette() }
                    .transition(.opacity)
                    .accessibilityLabel("Close the command palette")

                CommandPaletteView(store: store)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Tokens.borderStrong, lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.42), radius: 26, y: 14)
                    .padding(.top, 64)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
            .onExitCommand { store.closePalette() }
        }
    }
}

/// Bot panel, conversation — in that order, at that geometry.
struct WorkspaceShell: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: WorkspaceStore

    private var sidebarBinding: Binding<CGFloat> {
        Binding(get: { store.sidebarWidth },
                set: { store.setSidebarWidth($0) })
    }

    var body: some View {
        HStack(spacing: 0) {
            BotSidebarView(model: model, store: store)
                .frame(width: store.sidebarWidth)

            PaneDivider(width: sidebarBinding,
                        range: WorkspaceStore.sidebarFloor...Geometry.sidebarMax,
                        onCommit: { store.endSidebarDrag() })

            Hairline(.vertical)

            ConversationPane(model: model, store: store)
                .frame(minWidth: Geometry.conversationMin, maxWidth: .infinity, maxHeight: .infinity)
                // A new bot is a new conversation: re-creating the pane drops the old scroll
                // position and any approval sheet that belonged to the last bot.
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

private struct WorkspaceRootPalettePreview: View {
    @StateObject private var store = PreviewWorkspace.store()

    var body: some View {
        WorkspaceRoot(store: store)
            .frame(width: 1280, height: 820)
            .preferredColorScheme(.dark)
            .task {
                await store.attachPreviewHost()
                store.openPalette()
            }
    }
}

#Preview("Workspace") {
    WorkspaceRootPreview()
}

#Preview("Workspace · approval waiting") {
    WorkspaceRootApprovalPreview()
}

#Preview("Workspace · palette open") {
    WorkspaceRootPalettePreview()
}
