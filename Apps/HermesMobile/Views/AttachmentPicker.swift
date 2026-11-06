import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// The three things the paperclip offers. The menu renders them in this order, and each one
/// maps to exactly one system picker.
enum AttachmentSource: String, CaseIterable, Identifiable {
    case camera, photos, files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .camera: return "Camera"
        case .photos: return "Photo Library"
        case .files: return "File"
        }
    }

    var systemImage: String {
        switch self {
        case .camera: return "camera"
        case .photos: return "photo.on.rectangle"
        case .files: return "folder"
        }
    }
}

enum AttachmentPickerError: LocalizedError {
    case cameraUnavailable, noImage, unsupportedPhoto
    var errorDescription: String? {
        switch self {
        case .cameraUnavailable: return "The camera is unavailable on this device."
        case .noImage: return "The camera did not provide a photo."
        case .unsupportedPhoto: return "That photo could not be loaded."
        }
    }
}

/// Reading one file the document picker handed back.
///
/// The picker's URL is security-scoped and only valid for the duration of its callback, and
/// providers (iCloud Drive, third-party storage) may not have downloaded the item yet. The
/// read therefore goes through `NSFileCoordinator`, which also triggers the download, and the
/// scope is released only after the bytes are in memory. Every failure is thrown — nothing is
/// swallowed with `try?` — so the composer can say what went wrong.
enum AttachmentRead {
    static func file(at url: URL) throws -> AttachmentPayload {
        // `ubiquitousItemIsDownloaded` is macOS-only; iOS exposes the download status instead.
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentTypeKey,
                                         .nameKey, .isUbiquitousItemKey,
                                         .ubiquitousItemDownloadingStatusKey]
        var values = try? url.resourceValues(forKeys: keys)
        if values?.isDirectory == true { throw AttachmentBudgetError.unsupportedFile }

        // An iCloud Drive item that is not on the device is a placeholder: every read of it
        // fails with ENOENT until something asks a coordinator for it. That is why picking a
        // file from Files could appear to do nothing at all.
        let isPlaceholder = values?.isUbiquitousItem == true
            && values?.ubiquitousItemDownloadingStatus != .current
        if isPlaceholder || values?.fileSize == nil {
            try ensureMaterialised(url)
            values = try? url.resourceValues(forKeys: keys)
        }

        let isImage = self.isImage(url: url, contentType: values?.contentType)
        if isImage {
            do {
                return try AttachmentImageEncoder.payload(from: url)
            } catch AttachmentBudgetError.unsupportedFile {
                // A file the image pipeline cannot decode is still sendable as raw bytes.
            }
        }

        if let declared = values?.fileSize, declared > AttachmentBudget.maximumBytes {
            throw AttachmentBudgetError.tooLarge(byteCount: declared,
                                                 maximumBytes: AttachmentBudget.maximumBytes)
        }

        let data = try coordinatedRead(url, limit: AttachmentBudget.maximumBytes)

        // The path component carries the extension; `nameKey` is only a fallback for the rare
        // URL whose last component is empty.
        let rawName = url.lastPathComponent.isEmpty ? (values?.name ?? "") : url.lastPathComponent
        guard let name = AttachmentName.sanitized(rawName) else {
            throw AttachmentBudgetError.invalidName
        }
        return AttachmentPayload(name: name, data: data, isImage: isImage)
    }

    /// `contentType` is often `nil` on provider URLs, so the extension is the fallback rather
    /// than the answer.
    static func isImage(url: URL, contentType: UTType?) -> Bool {
        if let contentType { return contentType.conforms(to: .image) }
        if let type = UTType(filenameExtension: url.pathExtension) { return type.conforms(to: .image) }
        return false
    }

    /// Opens the item through a coordinator and reads a byte, which is enough to make the
    /// provider materialise it locally.
    private static func ensureMaterialised(_ url: URL) throws {
        var coordinationError: NSError?
        var readError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            do {
                let handle = try FileHandle(forReadingFrom: readable)
                defer { try? handle.close() }
                _ = try handle.read(upToCount: 1)
            } catch {
                readError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let readError { throw readError }
    }

    /// Reads at most `limit + 1` bytes, so an unknown-size 2 GB video cannot be pulled into
    /// memory before it is refused.
    private static func coordinatedRead(_ url: URL, limit: Int) throws -> Data {
        var coordinationError: NSError?
        var readError: Error?
        var data = Data()
        var overLimit = false
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            do {
                let handle = try FileHandle(forReadingFrom: readable)
                defer { try? handle.close() }
                let chunkSize = 1024 * 1024
                while data.count <= limit {
                    guard let chunk = try handle.read(upToCount: min(chunkSize, limit + 1 - data.count)),
                          !chunk.isEmpty else { break }
                    data.append(chunk)
                }
                overLimit = data.count > limit
            } catch {
                readError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let readError { throw readError }
        if overLimit || data.count > limit {
            throw AttachmentBudgetError.tooLarge(byteCount: data.count, maximumBytes: limit)
        }
        try AttachmentBudget.validate(byteCount: data.count)
        return data
    }
}

struct AttachmentPhotos: UIViewControllerRepresentable {
    let completion: (Result<AttachmentPayload, Error>) -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion, cancel: cancel) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let completion: (Result<AttachmentPayload, Error>) -> Void
        let cancel: () -> Void

        init(completion: @escaping (Result<AttachmentPayload, Error>) -> Void,
             cancel: @escaping () -> Void) {
            self.completion = completion
            self.cancel = cancel
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider else {
                // Cancelled: without this the SwiftUI sheet stays up forever.
                DispatchQueue.main.async { self.cancel() }
                return
            }
            guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) else {
                DispatchQueue.main.async { self.completion(.failure(AttachmentPickerError.unsupportedPhoto)) }
                return
            }
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                // The provider's file is deleted when this closure returns, so the encode
                // happens here and only the resulting payload crosses back to the main queue.
                let result: Result<AttachmentPayload, Error>
                do {
                    guard let url else { throw error ?? AttachmentPickerError.unsupportedPhoto }
                    result = .success(try AttachmentImageEncoder.payload(from: url))
                } catch {
                    result = .failure(error)
                }
                DispatchQueue.main.async { self.completion(result) }
            }
        }
    }
}

struct AttachmentFiles: UIViewControllerRepresentable {
    let completion: (Result<AttachmentPayload, Error>) -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion, cancel: cancel) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // `asCopy: true` hands back a file this app owns. The provider's original URL is
        // security-scoped, and an iCloud item can still be a placeholder: reading it without a
        // copy is what made "pick a file from Files" look like nothing happened at all.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (Result<AttachmentPayload, Error>) -> Void
        let cancel: () -> Void

        init(completion: @escaping (Result<AttachmentPayload, Error>) -> Void,
             cancel: @escaping () -> Void) {
            self.completion = completion
            self.cancel = cancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                DispatchQueue.main.async { self.cancel() }
                return
            }
            // A coordinated read of a large file is long enough to freeze the composer, so the
            // bytes are read off the main thread and only the payload crosses back.
            DispatchQueue.global(qos: .userInitiated).async {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let result: Result<AttachmentPayload, Error>
                do { result = .success(try AttachmentRead.file(at: url)) }
                catch { result = .failure(error) }
                DispatchQueue.main.async { self.completion(result) }
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            cancel()
        }
    }
}

struct AttachmentCamera: UIViewControllerRepresentable {
    let completion: (Result<AttachmentPayload, Error>) -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion, cancel: cancel) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let completion: (Result<AttachmentPayload, Error>) -> Void
        let cancel: () -> Void

        init(completion: @escaping (Result<AttachmentPayload, Error>) -> Void,
             cancel: @escaping () -> Void) {
            self.completion = completion
            self.cancel = cancel
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            cancel()
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage else {
                completion(.failure(AttachmentPickerError.noImage))
                return
            }
            do {
                completion(.success(try AttachmentImageEncoder.payload(from: image)))
            } catch {
                completion(.failure(error))
            }
        }
    }
}
