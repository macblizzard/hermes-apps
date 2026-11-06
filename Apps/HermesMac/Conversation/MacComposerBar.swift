import AppKit
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

    /// One capture per composer: the transcript lands in the draft that was on screen when the
    /// microphone was pressed, and nothing outlives this bar.
    @StateObject private var voice = MacVoiceController()

    private var interrupt: (() -> Void)? {
        model.isStreaming ? { store.interrupt() } : nil
    }

    /// Voice needs a device pairing and a session to dictate into. A ticket-only pairing cannot
    /// mint the fresh ticket each request needs, so the control stays dimmed rather than failing
    /// after the recording.
    private var canRecordVoice: Bool {
        store.canTranscribeVoice && model.selectedSessionID != nil
    }

    private var hint: String {
        if model.isStreaming {
            return "streaming · ⌘. interrupt · ⇧⏎ newline"
        }
        return "⏎ or ⌘↩ send · ⇧⏎ newline · ⌘K commands"
    }

    var body: some View {
        VStack(spacing: 0) {
            // A failed transcription uses the strip a failed send uses: one place to look when
            // the composer did not do what was asked. No retry — the audio is already gone.
            if let error = voice.errorMessage {
                MacErrorStrip(message: error,
                              onRetry: nil,
                              onDismiss: { voice.clearError() })
            }

            if let error = model.lastSendError {
                MacErrorStrip(message: error,
                              onRetry: store.canSend ? { store.retrySend() } : nil,
                              onDismiss: { model.clearSendError() })
            }

            // Picked attachments wait here until the user sends, so cancelling uploads nothing.
            if !model.pendingAttachments.isEmpty {
                pendingAttachmentsBar
            }

            if store.isPaired {
                MacVoiceRow(controller: voice, isEnabled: canRecordVoice)
                    .frame(maxWidth: Geometry.conversationMeasure)
                    .frame(maxWidth: .infinity)
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
                     // `Composer` keeps the hook but draws no microphone glyph, so the visible
                     // control is `MacVoiceRow` above; both call the same toggle.
                     onMic: { toggleVoice() },
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
        .onAppear { wireVoice() }
        // A re-pair must not leave the controller minting tickets for the old host.
        .onChange(of: store.pairing) { _, _ in wireVoice() }
        // The draft belongs to the session that was open when recording started, so leaving it
        // drops the capture instead of typing into somebody else's message.
        .onChange(of: model.selectedSessionID) { _, _ in voice.cancel() }
        .onDisappear { voice.cancel() }
    }

    // MARK: Voice

    /// Point the controller at the host this window is paired with, and at the field the
    /// transcript belongs in. Re-run on a pairing change; the closure reads the pairing at call
    /// time, so a host switch cannot send audio to the old one.
    private func wireVoice() {
        voice.transcribe = { [weak store] audio, mimeType in
            guard let store else { throw MacVoiceFailure.notConfigured }
            return try await store.transcribeVoice(audio, mimeType: mimeType)
        }
        // Appended to the draft, never sent: the user reads the words before they leave the Mac.
        voice.transcriptSink = { text in
            let existing = model.draft
            if existing.isEmpty {
                model.draft = text
            } else if existing.hasSuffix(" ") || existing.hasSuffix("\n") {
                model.draft = existing + text
            } else {
                model.draft = existing + " " + text
            }
        }
    }

    private func toggleVoice() {
        guard canRecordVoice else { return }
        if voice.isRecording {
            voice.stopAndTranscribe()
        } else {
            voice.startRecording()
        }
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

// MARK: - Voice control

/// The composer's microphone: tap to record, tap again to transcribe.
///
/// `Composer` (OpenBotUI) keeps an `onMic` hook but draws no microphone glyph, so the control
/// lives here, on the quiet line above the field — the phone's layout at desktop density. The
/// transcript is appended to the draft and never sent: misrecognition is common enough that the
/// words should be read before they leave the Mac.
private struct MacVoiceRow: View {
    @ObservedObject var controller: MacVoiceController
    /// False while there is no session to dictate into, or the pairing cannot mint a ticket.
    var isEnabled: Bool

    private var canTap: Bool { isEnabled && !controller.isBusy }

    private var symbol: String {
        switch controller.state {
        case .recording: return "stop.circle.fill"
        case .requestingPermission, .transcribing: return "waveform"
        case .idle: return "mic"
        }
    }

    private var accessibilityText: String {
        switch controller.state {
        case .recording: return "Stop and transcribe"
        case .requestingPermission: return "Waiting for microphone permission"
        case .transcribing: return "Transcribing"
        case .idle: return "Record a voice message"
        }
    }

    private var status: String? {
        switch controller.state {
        case .requestingPermission: return "microphone permission…"
        case .recording: return "recording · tap the square to transcribe"
        case .transcribing: return "transcribing…"
        case .idle: return nil
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: tap) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(controller.isRecording ? Tokens.danger : Tokens.textSecondary)
                    .frame(width: 22, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canTap)
            .help(accessibilityText)
            .accessibilityLabel(accessibilityText)
            .accessibilityIdentifier("composer.mic")

            if let line = status {
                Text(line)
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(controller.isRecording ? Tokens.danger : Tokens.textDim)
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 34)
        .padding(.bottom, 2)
        .opacity(isEnabled ? 1 : 0.55)
    }

    private func tap() {
        if controller.isRecording {
            controller.stopAndTranscribe()
        } else {
            controller.startRecording()
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
