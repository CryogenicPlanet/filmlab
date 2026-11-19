import Foundation
import Observation
import Photos
import UIKit

/// A photo taken in Filmlab. The developed file and (for recent shots) the RAW live in Caches so the viewer
/// can show and re-develop them without reading the whole photo library.
struct Shot: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let date: Date
    let itemID: String
    let title: String
    let recipe: Recipe
    let aspect: String
    let mirror: Bool
    let geo: GeoTag?
    let format: String
    var assetID: String?
    var hasRAW: Bool
    var whiteReference: [Double]?

    var photoURL: URL { ShotFiles.folder.appending(path: "\(id.uuidString).\(format == "JPEG" ? "jpg" : "heic")") }
    var rawURL: URL { ShotFiles.folder.appending(path: "\(id.uuidString).dng") }

    var options: DevelopOptions {
        DevelopOptions(aspect: Aspect(rawValue: aspect) ?? .standard, format: OutputFormat(rawValue: format) ?? .heic, mirror: mirror, geo: geo, whiteReference: whiteReference)
    }
}


enum ShotFiles {
    static let folder: URL = {
        let url = URL.cachesDirectory.appending(path: "shots", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}

@MainActor
@Observable
final class ShotStore {

    private static let index = URL.applicationSupportDirectory.appending(path: "shots.json")
    private static let keepPhotos = 60
    private static let keepRAWs = 12 // 48 MP ProRAW is ~75 MB each

    /// Newest first.
    private(set) var shots: [Shot] = []

    init() {
        shots = (try? JSONDecoder().decode([Shot].self, from: Data(contentsOf: Self.index))) ?? []
        shots = shots.filter { FileManager.default.fileExists(atPath: $0.photoURL.path()) }
    }

    func add(_ shot: Shot, photo: Data, raw: Data?) {
        try? photo.write(to: shot.photoURL)
        var shot = shot
        if let raw { shot.hasRAW = (try? raw.write(to: shot.rawURL)) != nil }
        shots.insert(shot, at: 0)
        prune()
        persist()
    }

    func setAsset(_ assetID: String?, for id: UUID) {
        guard let i = shots.firstIndex(where: { $0.id == id }) else { return }
        shots[i].assetID = assetID
        persist()
    }

    func remove(_ id: UUID) {
        guard let shot = shots.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: shot.photoURL)
        try? FileManager.default.removeItem(at: shot.rawURL)
        shots.removeAll { $0.id == id }
        persist()
    }

    func raw(for shot: Shot) -> Data? { shot.hasRAW ? try? Data(contentsOf: shot.rawURL) : nil }

    private func prune() {
        for (i, shot) in shots.enumerated() {
            if i >= Self.keepRAWs, shot.hasRAW {
                try? FileManager.default.removeItem(at: shot.rawURL)
                shots[i].hasRAW = false
            }
            if i >= Self.keepPhotos { try? FileManager.default.removeItem(at: shot.photoURL) }
        }
        shots = Array(shots.prefix(Self.keepPhotos))
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(shots).write(to: Self.index)
    }
}

enum LibraryActions {
    /// Deletes from the photo library (iOS shows its own confirmation). Returns false if the person declined.
    static func delete(assetID: String) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { return false }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard assets.count > 0 else { return true }
        do {
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets) }
            return true
        } catch {
            return false
        }
    }
}
