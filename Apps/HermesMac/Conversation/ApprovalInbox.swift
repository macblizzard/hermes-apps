import HermesAppKit
import HermesKit
import OpenBotUI
import SwiftUI

/// The blocking queue: every request the agent is waiting on, pinned above the composer.
///
/// Above the composer rather than inside the scrolled transcript because a blocked turn is
/// not history — it is the thing the next keystroke belongs to. When it is empty the view
/// draws nothing at all, so the conversation keeps its full height.
struct ApprovalInbox: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        if model.pendingRequests.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    SectionCaption(countLabel, color: Tokens.warning)
                    Spacer(minLength: 0)
                }

                ForEach(model.pendingRequests) { request in
                    ApprovalRequestView(request: request, store: store)
                }
            }
            .frame(maxWidth: Geometry.conversationMeasure, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .center)
            .background(Tokens.canvas)
            .overlay(alignment: .top) { Hairline(color: Tokens.warningSoft) }
            .transition(.opacity)
            .animation(Motion.approvalArrival, value: model.pendingRequests.count)
        }
    }

    private var countLabel: String {
        let count = model.pendingRequests.count
        return count == 1 ? "1 REQUEST WAITING" : "\(count) REQUESTS WAITING"
    }
}

// MARK: - Previews

private struct ApprovalInboxPreview: View {
    @StateObject private var store = PreviewWorkspace.store(.approval)

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ApprovalInbox(model: store.model, store: store)
        }
        .frame(width: Geometry.conversationMeasure + 120, height: 420)
        .background(Tokens.canvas)
        .task { await store.attachPreviewHost() }
        .preferredColorScheme(.dark)
    }
}

#Preview("Approval inbox") {
    ApprovalInboxPreview()
}
