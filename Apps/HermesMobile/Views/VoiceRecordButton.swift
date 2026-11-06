import SwiftUI

/// Tap to start, tap again to transcribe. The owner supplies a long-lived controller
/// and decides how to submit the resulting text or speak a later assistant reply.
struct VoiceRecordButton: View {
    @ObservedObject var controller: VoiceController
    var onTranscript: (String) -> Void
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if controller.state == .recording {
                    controller.stopAndTranscribe(onTranscript: onTranscript)
                } else {
                    controller.startRecording()
                }
            } label: {
                Label(controller.state == .recording ? "Stop and transcribe" : "Tap to speak",
                      systemImage: controller.state == .recording ? "stop.circle.fill" : "mic")
            }
            .disabled(controller.state != .idle && controller.state != .recording)
            if controller.state == .requestingPermission { Text("Waiting for microphone permission…").font(.caption) }
            if controller.state == .transcribing { Text("Transcribing…").font(.caption) }
            if let error = controller.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { controller.cancel() }
        }
        .onDisappear { controller.cancel() }
    }
}
