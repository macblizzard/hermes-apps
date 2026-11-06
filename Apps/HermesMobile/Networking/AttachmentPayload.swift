import Foundation

/// Encodes the byte-only subset of the gateway's attachment RPCs. The caller must
/// use the existing authenticated websocket and its runtime session identifier.
struct AttachmentPayload {
    static let maximumBytes = 512 * 1024
    let name: String
    let data: Data
    let isImage: Bool

    enum Failure: LocalizedError {
        case empty, tooLarge, invalidName, invalidResponse
        var errorDescription: String? {
            switch self {
            case .empty: return "The selected attachment is empty."
            case .tooLarge: return "The attachment exceeds the 512 KiB upload limit."
            case .invalidName: return "The attachment has an invalid file name."
            case .invalidResponse: return "The host did not confirm the attachment."
            }
        }
    }

    func request(sessionID: String) throws -> (method: String, params: [String: String]) {
        guard !data.isEmpty else { throw Failure.empty }
        guard data.count <= Self.maximumBytes else { throw Failure.tooLarge }
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
              name.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\\0\n\r")) == nil else {
            throw Failure.invalidName
        }
        let encoded = data.base64EncodedString()
        if isImage {
            return ("image.attach_bytes", ["session_id": sessionID, "filename": name, "content_base64": encoded])
        }
        return ("file.attach", ["session_id": sessionID, "name": name,
                                "data_url": "data:application/octet-stream;base64," + encoded])
    }

    /// `file.attach` returns an @file reference; it must be included in the next
    /// prompt. Images are queued by the gateway and do not need a reference.
    static func reference(from result: [String: Any], isImage: Bool) throws -> String? {
        guard result["attached"] as? Bool == true else { throw Failure.invalidResponse }
        if isImage { return nil }
        guard let ref = result["ref_text"] as? String, !ref.isEmpty else { throw Failure.invalidResponse }
        return ref
    }
}
