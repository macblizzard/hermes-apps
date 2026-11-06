import SwiftUI
import OpenBotUI

/// Opt-in "speak replies" switch for one conversation.
///
/// Off by default and never turned on by the app itself. Turning it on does not replay
/// history: only replies that arrive while it is on are spoken. Turning it off stops
/// whatever is being spoken, and a reply already spoken is not repeated when the
/// transcript scrolls or re-renders.
struct VoiceSpeakerToggle: View {
    @ObservedObject var controller: VoiceController
    @Binding var isEnabled: Bool
    /// Whether this conversation has any assistant reply yet; without one there is
    /// nothing to opt into, so the control explains itself by staying disabled.
    var hasReply: Bool

    var body: some View {
        Button {
            isEnabled.toggle()
            if !isEnabled { controller.stopSpeaking() }
        } label: {
            Image(systemName: isEnabled ? "speaker.wave.2.fill" : "speaker.slash")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isEnabled ? Tokens.accentText : Tokens.textSecondary)
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled && !hasReply)
        .accessibilityLabel(isEnabled ? "Stop speaking replies" : "Speak replies aloud")
        .accessibilityValue(isEnabled ? "On" : "Off")
    }
}
