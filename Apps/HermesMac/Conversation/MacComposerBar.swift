import HermesAppKit
import HermesKit
import OpenBotUI
import SwiftUI

/// The composer, wired to the model's single draft.
///
/// `Composer` (design system) owns the field and the send/interrupt swap; this bar owns the
/// things the shell adds: the failed-send strip, the pending attachments, the paperclip's compact
/// menu, the ⌘↩/⌘. bindings the menu exposes, and the per-session draft the store restores.
struct MacComposerBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: WorkspaceStore

    /// The paperclip opens a popover with two items, never a page: the phone's action menu, at
    /// desktop density.
    @State private var showsAttachmentMenu = false

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

            // Picked attachments wait here until the user sends, so cancelling uploads nothing.
            if !model.pendingAttachments.isEmpty {
                pendingAttachmentsBar
            }

            Composer(text: $model.draft,
                     placeholder: store.isPaired
                        ? "Ask \(store.selectedBot?.displayName ?? model.hostName) anything"
                        : "Pair a host to start a conversation",
                     isSending: model.isStreaming,
                     isDisabled: model.selectedSessionID == nil,
                     hint: hint,
                     onSend: { store.send() },
                     onAttach: { showsAttachmentMenu = true },
                     onMic: nil,
                     onInterrupt: interrupt)
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .padding(.bottom, 14)
                .frame(maxWidth: Geometry.conversationMeasure)
                .frame(maxWidth: .infinity)
                // Anchored under the bar, where the paperclip that opened it sits.
                .popover(isPresented: $showsAttachmentMenu, arrowEdge: .bottom) {
                    MacAttachmentMenu(model: model, isPresented: $showsAttachmentMenu)
                }
        }
        .background(Tokens.canvas)
    }

    private var pendingAttachmentsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.pendingAttachments) { attachment in
                    HStack(spacing: 5) {
                        Image(systemName: attachment.isImage ? "photo" : "doc")
                            .font(.system(size: 9))
                            .foregroundStyle(Tokens.textSecondary)

                        Text(attachment.name)
                            .font(TypeScale.font(TypeScale.caption))
                            .foregroundStyle(Tokens.textSecondary)
                            .lineLimit(1)

                        Button {
                            model.removePendingAttachment(attachment.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(Tokens.textMuted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(attachment.name)")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Tokens.surface))
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
