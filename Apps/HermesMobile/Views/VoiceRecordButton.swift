import SwiftUI
import OpenBotUI

/// The composer's microphone: tap to record, tap again to transcribe.
///
/// The owner supplies a long-lived `VoiceController` and decides what happens to the
/// transcript (the conversation fills the draft; it never sends on its own). The
/// control hides itself behind a permission, a size or a provider error rather than
/// failing silently: the error line is part of the button's own row.
struct VoiceRecordButton: View {
    @ObservedObject var controller: VoiceController
    /// False while there is no open session to send into, or while the app is unpaired.
    var isEnabled: Bool = true
    var onTranscript: (String) -> Void

    @Environment(\.scenePhase) private var scenePhase

    private var canTap: Bool { isEnabled && !controller.isBusy }

    private var symbol: String {
        switch controller.state {
        case .recording: return "stop.circle.fill"
        case .requestingPermission, .transcribing: return "waveform"
        default: return "mic.fill"
        }
    }

    private var accessibilityText: String {
        switch controller.state {
        case .recording: return "Stop and transcribe"
        case .requestingPermission: return "Waiting for microphone permission"
        case .transcribing: return "Transcribing"
        default: return "Record a voice message"
        }
    }

    private var statusText: String? {
        switch controller.state {
        case .requestingPermission: return "Microphone permission…"
        case .recording: return "Recording — tap to stop"
        case .transcribing: return "Transcribing…"
        default: return nil
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: tap) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(controller.state == .recording ? Tokens.danger : Tokens.textSecondary)
                    .frame(width: 28, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canTap)
            .accessibilityLabel(accessibilityText)

            if let statusText {
                Text(statusText)
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(controller.state == .recording ? Tokens.danger : Tokens.textDim)
                    .lineLimit(1)
            } else if let error = controller.errorMessage {
                Text(error)
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.danger)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { controller.cancel() }
        }
        .onDisappear { controller.cancel() }
    }

    private func tap() {
        if controller.state == .recording {
            Haptics.impact()
            controller.stopAndTranscribe(onTranscript: onTranscript)
        } else {
            Haptics.impact()
            controller.startRecording()
        }
    }
}
