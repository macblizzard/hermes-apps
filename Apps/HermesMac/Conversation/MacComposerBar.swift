import HermesAppKit
import OpenBotUI
import SwiftUI

/// The composer, wired to the model's single draft.
///
/// `Composer` (design system) owns the field and the send/interrupt swap; this bar owns the
/// three things the shell adds: the failed-send strip, the ⌘↩/⌘. bindings the menu exposes,
/// and the per-session draft the store restores on selection.
struct MacComposerBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: WorkspaceStore

    private var interrupt: (() -> Void)? {
        model.isStreaming ? { store.interrupt() } : nil
    }

    private var hint: String {
        if model.isStreaming {
            return "streaming · ⌘. interrupt · ⇧⏎ newline"
        }
        return "⏎ or ⌘↩ send · ⇧⏎ newline · ⌘K commands"
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.lastSendError {
                MacErrorStrip(message: error,
                              onRetry: store.canSend ? { store.retrySend() } : nil,
                              onDismiss: { model.clearSendError() })
            }

            Composer(text: $model.draft,
                     placeholder: store.isPaired
                        ? "Ask \(store.selectedBot?.displayName ?? model.hostName) anything"
                        : "Pair a host to start a conversation",
                     isSending: model.isStreaming,
                     isDisabled: model.selectedSessionID == nil,
                     hint: hint,
                     onSend: { store.send() },
                     onAttach: nil,
                     onMic: nil,
                     onInterrupt: interrupt)
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .padding(.bottom, 14)
                .frame(maxWidth: Geometry.conversationMeasure)
                .frame(maxWidth: .infinity)
        }
        .background(Tokens.canvas)
    }
}

// MARK: - Previews

private struct MacComposerBarPreview: View {
    @StateObject private var store = PreviewWorkspace.store()

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            MacComposerBar(model: store.model, store: store)
        }
        .frame(width: Geometry.conversationMeasure + 200, height: 260)
        .background(Tokens.canvas)
        .task { await store.attachPreviewHost() }
        .preferredColorScheme(.dark)
    }
}

#Preview("Composer bar") {
    MacComposerBarPreview()
}
