import HermesAppKit
import OpenBotUI
import SwiftUI

/// The window: a `Tokens.frame` surround with the workspace clipped inside it.
///
/// The surround is the app's one piece of theatre and it is exact — 8 pt on three sides,
/// 28 pt on top so the hidden title bar's traffic lights sit on the frame colour rather than
/// on the canvas. Everything inside is the three-pane workspace at OpenBot's geometry.
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
        }
        .sheet(isPresented: $store.isPalettePresented) {
            CommandPaletteView(store: store)
        }
        .sheet(isPresented: $store.isPairSheetPresented) {
            PairHostSheet(store: store)
        }
    }
}

/// Rail, session list, conversation, context panel — in that order, at that geometry.
struct WorkspaceShell: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: WorkspaceStore

    private var sidebarBinding: Binding<CGFloat> {
        Binding(get: { store.sidebarWidth },
                set: { store.setSidebarWidth($0) })
    }

    var body: some View {
        HStack(spacing: 0) {
            IconRail(model: model, store: store)

            Hairline(.vertical)

            SessionSidebarView(model: model, store: store)
                .frame(width: store.sidebarWidth)

            PaneDivider(width: sidebarBinding,
                        range: 64...Geometry.sidebarMax,
                        onCommit: { store.endSidebarDrag() })

            Hairline(.vertical)

            ConversationPane(model: model, store: store)
                .frame(minWidth: Geometry.conversationMin, maxWidth: .infinity, maxHeight: .infinity)

            if store.showsContextPanel {
                Hairline(.vertical)
                ContextPanelView(model: model, store: store)
            }
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
