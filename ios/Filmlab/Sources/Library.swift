import Foundation
import Photos
import UniformTypeIdentifiers

enum SaveError: Error, Sendable {
    case notAuthorized
    case failed(String)
}

enum PhotoSaver {
    /// Saves the developed photo. When a DNG is given, tries to attach it as the RAW alternate; if Photos
    /// refuses the pairing, the developed photo is saved on its own so the shot is never lost.
    /// Returns the new asset's local identifier.
    static func save(photo: Data, type: UTType, raw: Data?) async -> Result<String?, SaveError> {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return .failure(.notAuthorized) }
        if let raw, case let .success(id) = await perform(photo: photo, type: type, raw: raw) { return .success(id) }
        return await perform(photo: photo, type: type, raw: nil)
    }

    private final class Placeholder: @unchecked Sendable {
        var id: String?
    }

    private static func perform(photo: Data, type: UTType, raw: Data?) async -> Result<String?, SaveError> {
        let placeholder = Placeholder()
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                placeholder.id = request.placeholderForCreatedAsset?.localIdentifier
                let photoOptions = PHAssetResourceCreationOptions()
                photoOptions.uniformTypeIdentifier = type.identifier
                request.addResource(with: .photo, data: photo, options: photoOptions)
                if let raw {
                    let rawOptions = PHAssetResourceCreationOptions()
                    rawOptions.uniformTypeIdentifier = UTType.dng.identifier
                    request.addResource(with: .alternatePhoto, data: raw, options: rawOptions)
                }
            }
            return .success(placeholder.id)
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
    }
}
