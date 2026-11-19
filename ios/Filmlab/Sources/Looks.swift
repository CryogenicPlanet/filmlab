import Foundation

/// One measured look: a 3D LUT from the shaper domain (log-encoded scene-linear Rec.2020) to sRGB.
struct Look: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let fujiName: String?
    let blurb: String
    let monochrome: Bool

    /// Debug builds (Rahul's phone) show the Fujifilm simulation it was measured from; release builds never do.
    var displayName: String {
        #if DEBUG
            fujiName ?? name
        #else
            name
        #endif
    }
}

struct LookManifest: Decodable, Sendable {
    let gridSize: Int
    let midGrey: Double
    let logLo: Double
    let logHi: Double
    let looks: [Look]
}

enum LookLibraryError: Error, Sendable {
    case missingManifest
    case badManifest(String)
    case missingCube(String)
    case wrongCubeSize(id: String, bytes: Int, expected: Int)
}

/// Loads the bundled looks once; immutable afterwards, so it is safe to share across threads.
final class LookLibrary: Sendable {
    let manifest: LookManifest
    private let cubes: [String: Data]

    init(bundle: Bundle = .main) throws(LookLibraryError) {
        guard let url = bundle.url(forResource: "looks", withExtension: "json") else { throw .missingManifest }
        let manifest: LookManifest
        do {
            manifest = try JSONDecoder().decode(LookManifest.self, from: Data(contentsOf: url))
        } catch {
            throw .badManifest(String(describing: error))
        }
        let expected = manifest.gridSize * manifest.gridSize * manifest.gridSize * 4 * MemoryLayout<Float32>.size
        var cubes: [String: Data] = [:]
        for look in manifest.looks {
            guard let cubeURL = bundle.url(forResource: look.id, withExtension: "cube"),
                  let data = try? Data(contentsOf: cubeURL)
            else { throw .missingCube(look.id) }
            guard data.count == expected else { throw .wrongCubeSize(id: look.id, bytes: data.count, expected: expected) }
            cubes[look.id] = data
        }
        self.manifest = manifest
        self.cubes = cubes
    }

    var looks: [Look] { manifest.looks }

    func look(id: String) -> Look? { manifest.looks.first { $0.id == id } }

    /// RGBA float32, red fastest — the layout CIColorCube expects.
    func cube(for id: String) -> Data? { cubes[id] }
}
