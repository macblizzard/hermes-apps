import Foundation

/// The bridge's voice payloads are not frozen. Inject the final HTTP implementation;
/// do not send audio to the host-machine microphone RPC or invent a transcript.
/// Each implementation must obtain a fresh single-use ticket for each HTTPS request,
/// use it as an Authorization bearer, reject redirects, and never log credentials/audio.
struct VoiceTransport {
    /// AAC in an MPEG-4 container (audio/mp4). Returns the actual recognized text.
    var transcribe: (Data) async throws -> String
    /// Returns audio bytes in a format AVAudioPlayer supports.
    var synthesize: (String) async throws -> Data

    static let unavailable = VoiceTransport(
        transcribe: { _ in throw VoiceTransportError.unavailable },
        synthesize: { _ in throw VoiceTransportError.unavailable }
    )
}

enum VoiceTransportError: LocalizedError {
    case unavailable
    case emptyTranscript
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Voice is unavailable: the paired host's voice service is not configured."
        case .emptyTranscript: return "The voice service returned an empty transcript."
        case .emptyAudio: return "The voice service returned no audio."
        }
    }
}
