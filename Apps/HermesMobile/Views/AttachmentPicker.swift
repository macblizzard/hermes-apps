import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

/// Present as a sheet, then upload the returned payload through the paired socket.
/// Selection and transfer are intentionally separate: no attachment is sent on pick.
struct AttachmentPicker: View {
    let onResult: (Result<AttachmentPayload, Error>) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var source: Source?
    @State private var showFiles = false

    private enum Source: String, Identifiable {
        case camera, photos
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            List {
                Button("Camera", systemImage: "camera") {
                    guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                        finish(.failure(AttachmentPickerError.cameraUnavailable)); return
                    }
                    source = .camera
                }
                Button("Photos", systemImage: "photo") { source = .photos }
                Button("Files", systemImage: "folder") { showFiles = true }
            }
            .navigationTitle("Add attachment")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(item: $source) { choice in
                if choice == .camera {
                    AttachmentCamera { result in finish(result) }
                        .ignoresSafeArea()
                } else {
                    AttachmentPhotos { result in finish(result) }
                        .ignoresSafeArea()
                }
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item]) { result in
                do {
                    let url = try result.get()
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let image = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .image)) ?? false
                    finish(.success(try AttachmentRead.file(url, isImage: image)))
                } catch { finish(.failure(error)) }
            }
        }
    }

    private func finish(_ result: Result<AttachmentPayload, Error>) {
        onResult(result)
        dismiss()
    }
}

enum AttachmentPickerError: LocalizedError {
    case cameraUnavailable, noImage, unsupportedPhoto
    var errorDescription: String? {
        switch self {
        case .cameraUnavailable: return "The camera is unavailable on this device."
        case .noImage: return "The camera did not provide a photo."
        case .unsupportedPhoto: return "The selected photo could not be loaded."
        }
    }
}

enum AttachmentRead {
    static func file(_ url: URL, isImage: Bool) throws -> AttachmentPayload {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: AttachmentPayload.maximumBytes + 1) ?? Data()
        guard !bytes.isEmpty else { throw AttachmentPayload.Failure.empty }
        guard bytes.count <= AttachmentPayload.maximumBytes else { throw AttachmentPayload.Failure.tooLarge }
        return AttachmentPayload(name: url.lastPathComponent, data: bytes, isImage: isImage)
    }
}

struct AttachmentPhotos: UIViewControllerRepresentable {
    let completion: (Result<AttachmentPayload, Error>) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let completion: (Result<AttachmentPayload, Error>) -> Void
        init(completion: @escaping (Result<AttachmentPayload, Error>) -> Void) { self.completion = completion }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider else { picker.dismiss(animated: true); return }
            guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) else {
                completion(.failure(AttachmentPickerError.unsupportedPhoto)); return
            }
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                let result: Result<AttachmentPayload, Error>
                do {
                    guard let url else { throw error ?? AttachmentPickerError.unsupportedPhoto }
                    result = .success(try AttachmentRead.file(url, isImage: true))
                } catch { result = .failure(error) }
                DispatchQueue.main.async { self.completion(result) }
            }
        }
    }
}

struct AttachmentCamera: UIViewControllerRepresentable {
    let completion: (Result<AttachmentPayload, Error>) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let completion: (Result<AttachmentPayload, Error>) -> Void
        init(completion: @escaping (Result<AttachmentPayload, Error>) -> Void) { self.completion = completion }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { picker.dismiss(animated: true) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage else { completion(.failure(AttachmentPickerError.noImage)); return }
            for quality in [CGFloat(0.8), 0.6, 0.4, 0.2] {
                if let data = image.jpegData(compressionQuality: quality), data.count <= AttachmentPayload.maximumBytes {
                    completion(.success(AttachmentPayload(name: "camera.jpg", data: data, isImage: true))); return
                }
            }
            completion(.failure(AttachmentPayload.Failure.tooLarge))
        }
    }
}
