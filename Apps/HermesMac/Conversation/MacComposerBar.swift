import AppKit
import HermesAppKit
import HermesKit
import OpenBotUI
import SwiftUI
import UniformTypeIdentifiers

/// The composer, wired to the model's single draft.
///
/// `Composer` (design system) owns the field and, while a turn runs, the send/steer/interrupt
/// swap; this bar owns the things the shell adds: the failed-send strip, the pending attachments,
/// the paperclip's compact menu, image paste from the native pasteboard, the ⌘↩/⌘. bindings the
/// menu exposes, and the per-bot draft the store restores.
struct MacComposerBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: WorkspaceStore

    /// The paperclip opens a small menu with two items, never a page: the phone's action menu, at
    /// desktop density and above the input.
    @State private var showsAttachmentMenu = false

    private var interrupt: (() -> Void)? {
        model.isStreaming ? { store.interrupt() } : nil
    }

    private var hint: String {
        if model.isStreaming || model.isSteering {
            if model.isSteering { return "steering · ⌘. interrupt · ⇧⏎ newline" }
            if model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "streaming · ⌘. interrupt · ⇧⏎ newline"
            }
            return "⏎ steer the running turn · ⌘. interrupt · ⇧⏎ newline"
        }
        return "⏎ or ⌘↩ send · ⇧⏎ newline · ⌘K commands"
    }

    private var retryAction: (() -> Void)? {
        if model.isStreaming || model.isSteering {
            return store.canSteer && model.pendingAttachments.isEmpty ? { store.steer() } : nil
        }
        return store.canSend ? { store.retrySend() } : nil
    }

    private var placeholder: String {
        if !store.isPaired { return "Pair a host to start a conversation" }
        if model.isStreaming || model.isSteering { return "Steer the running turn…" }
        return "Ask \(store.selectedBot?.displayName ?? model.hostName) anything"
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.lastSendError {
                MacErrorStrip(message: error,
                              onRetry: retryAction,
                              onDismiss: { model.clearSendError() })
            }

            // Picked attachments wait here until the user sends, so cancelling uploads nothing.
            if !model.pendingAttachments.isEmpty {
                pendingAttachmentsBar
            }

            // `session.steer` is text-only. Say so before the click, and keep the files in
            // place; the model repeats the explanation if the button is pressed anyway.
            if model.isStreaming && !model.pendingAttachments.isEmpty {
                MacInlineNotice(message: "Attachments can't join a running turn. They will stay here — steer text now, or wait for the turn to finish before sending them.")
                    .frame(maxWidth: Geometry.conversationMeasure)
                    .frame(maxWidth: .infinity)
            }

            Composer(text: $model.draft,
                     placeholder: placeholder,
                     isSending: model.isStreaming || model.isSteering,
                     isSteering: model.isSteering,
                     isDisabled: model.selectedSessionID == nil,
                     hasAttachments: !model.pendingAttachments.isEmpty,
                     hint: hint,
                     onSend: { store.send() },
                     onSteer: { store.steer() },
                     onAttach: {
                         withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                             showsAttachmentMenu.toggle()
                         }
                     },
                     onMic: nil,
                     onInterrupt: interrupt)
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .padding(.bottom, 14)
                .frame(maxWidth: Geometry.conversationMeasure)
                // An overlay, not a popover: it opens above the input at the paperclip's leading
                // edge, where the user just clicked. The menu itself has no permanent outline.
                .overlay(alignment: .topLeading) {
                    if showsAttachmentMenu {
                        MacAttachmentMenu(model: model, isPresented: $showsAttachmentMenu)
                            .padding(.leading, 8)
                            .offset(y: -(MacAttachmentMenu.height + 8))
                            .transition(.scale(scale: 0.92, anchor: .bottomLeading)
                                .combined(with: .opacity))
                            .zIndex(2)
                    }
                }
                // A pasted image goes through the same pending-attachment path as the picker:
                // validation, thumbnail and upload are unchanged. Text-only paste never reaches
                // this command, so the field keeps its ordinary paste behaviour.
                .onPasteCommand(of: [.image]) { _ in
                    guard let pasted = MacAttachmentFile.pastedImage() else { return }
                    model.addPendingAttachment(name: pasted.name,
                                               data: pasted.data,
                                               isImage: true)
                }
                .frame(maxWidth: .infinity)
        }
        .background(Tokens.canvas)
    }

    private var pendingAttachmentsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.pendingAttachments) { attachment in
                    HStack(spacing: 5) {
                        if attachment.isImage, let image = NSImage(data: attachment.data) {
                            Image(nsImage: image).resizable().scaledToFill()
                                .frame(width: 26, height: 26).clipped().cornerRadius(4)
                        } else {
                            Image(systemName: attachment.isImage ? "photo" : "doc")
                                .font(.system(size: 9)).foregroundStyle(Tokens.textSecondary)
                        }

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
