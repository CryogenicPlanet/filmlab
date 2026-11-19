import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum RenderError: Error, Sendable {
    case kernelsMissing
    case kernel(String)
    case unknownLook(String)
    case decode
    case encode
}

enum Aspect: String, CaseIterable, Sendable, Identifiable {
    case standard = "4:3", film = "3:2", square = "1:1", wide = "16:9"

    var id: String { rawValue }

    /// long side / short side
    var ratio: Double {
        switch self {
        case .standard: 4.0 / 3
        case .film: 3.0 / 2
        case .square: 1
        case .wide: 16.0 / 9
        }
    }
}

enum OutputFormat: String, CaseIterable, Sendable, Identifiable {
    case heic = "HEIF", jpeg = "JPEG"
    var id: String { rawValue }
    var uti: UTType { self == .heic ? .heic : .jpeg }
}

struct GeoTag: Codable, Hashable, Sendable {
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let timestamp: Date
}

struct DevelopOptions: Sendable {
    var aspect: Aspect = .standard
    var format: OutputFormat = .heic
    var mirror = false
    var geo: GeoTag?
    /// Per-channel geometric mean of the corrected viewfinder frame at the shutter press (linear Rec.2020).
    /// The capture is scaled per channel to match it, so exposure and white balance are what you saw.
    var whiteReference: [Double]?
}

/// Scene-linear Rec.2020 in, finished image out. Shared by live preview, the look strip and full-resolution capture.
final class LookRenderer: Sendable {
    static let workingSpace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
    static let outputSpace = CGColorSpace(name: CGColorSpace.displayP3)!
    static let thumbSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// The iPhone exposes its RAW per shot (up to ~4 stops under on bright scenes) and lifts it in processing, so
    /// captures are matched to the viewfinder frame per channel (`whiteReference`).
    /// Without a reference, ProRAW is lifted by the typical gap measured on 2026-11-16 (~1.7 stops).
    static let rawFallbackScale = 3.25
    /// Scales viewfinder-matched linear light into the looks' 0.18 mid-grey anchor. Apple renders mid grey a little
    /// brighter than a Fuji JPEG; −0.4 stop puts typical scenes where the X-S20 would meter them.
    static let lookAnchor = 0.75

    /// Viewfinder/RAW fit (calibrate/preview_fit.py): log2 stops [c0, c1, c2, c3], one curve shared by all channels
    /// so it changes tone only; white balance follows the viewfinder per shot (`whiteReference`).
    static let previewCurve: [CIVector] = [
        CIVector(x: -0.2704, y: 0.9886, z: 0.1204, w: 0.0090),
        CIVector(x: -0.2704, y: 0.9886, z: 0.1204, w: 0.0090),
        CIVector(x: -0.2704, y: 0.9886, z: 0.1204, w: 0.0090),
    ]

    let library: LookLibrary
    let context: CIContext
    private let shaper: CIColorKernel
    private let finish: CIColorKernel
    private let grain: CIColorKernel
    private let linearize: CIColorKernel
    private let logRGB: CIColorKernel

    init(library: LookLibrary) throws(RenderError) {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url)
        else { throw .kernelsMissing }
        do {
            shaper = try CIColorKernel(functionName: "filmlabShaper", fromMetalLibraryData: data)
            finish = try CIColorKernel(functionName: "filmlabFinish", fromMetalLibraryData: data)
            grain = try CIColorKernel(functionName: "filmlabGrain", fromMetalLibraryData: data)
            linearize = try CIColorKernel(functionName: "filmlabPreviewLinearize", fromMetalLibraryData: data)
            logRGB = try CIColorKernel(functionName: "filmlabLogRGB", fromMetalLibraryData: data)
        } catch {
            throw .kernel(String(describing: error))
        }
        self.library = library
        context = CIContext(options: [
            .workingColorSpace: LookRenderer.workingSpace,
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false,
        ])
    }

    /// Apple-processed image (viewfinder frame, front-camera HEIC) -> the linear light the RAW path sees, at look scale.
    func sceneLinear(fromProcessed image: CIImage) -> CIImage {
        let c = Self.previewCurve
        return linearize.apply(extent: image.extent, arguments: [image, c[0], c[1], c[2]]) ?? image
    }

    /// Renders a viewfinder frame through the recipe, matching what the capture path will produce.
    func preview(_ frame: CIImage, recipe: Recipe) -> Result<CIImage, RenderError> {
        if recipe.isNative { return .success(frame) }
        return apply(recipe, to: sceneLinear(fromProcessed: frame), inputScale: Self.lookAnchor, grainScale: 0.5)
    }

    /// - Parameters:
    ///   - linear: scene-linear image in the working space.
    ///   - inputScale: brings the source's mid grey to 0.18 (iPhone ProRAW ≈ 1).
    ///   - grainScale: grain size multiplier, so small renders get proportionate grain.
    func apply(_ recipe: Recipe, to linear: CIImage, inputScale: Double, grainScale: Double = 1) -> Result<CIImage, RenderError> {
        apply(recipe, to: linear, inputGains: [inputScale, inputScale, inputScale], grainScale: grainScale)
    }

    func apply(_ recipe: Recipe, to linear: CIImage, inputGains g: [Double], grainScale: Double = 1) -> Result<CIImage, RenderError> {
        if recipe.isNative { return .success(linear) }
        let m = library.manifest
        guard let cube = library.cube(for: recipe.lookID) else { return .failure(.unknownLook(recipe.lookID)) }
        let gain = pow(2, recipe.exposure)
        // Fuji WB shift steps are small; ~2.5% per step on the shifted channel.
        let gains = CIVector(x: g[0] * gain * pow(2, 0.035 * recipe.wbRed), y: g[1] * gain, z: g[2] * gain * pow(2, 0.035 * recipe.wbBlue))
        let extent = linear.extent
        guard let shaped = shaper.apply(extent: extent, arguments: [linear, gains, m.midGrey, m.logLo, m.logHi]) else {
            return .failure(.kernel("shaper"))
        }
        let lut = CIFilter.colorCube()
        lut.inputImage = shaped
        lut.cubeDimension = Float(m.gridSize)
        lut.cubeData = cube
        lut.extrapolate = false
        guard let looked = lut.outputImage,
              let finished = finish.apply(extent: extent, arguments: [looked, recipe.highlights, recipe.shadows, recipe.color, recipe.chrome])
        else { return .failure(.kernel("finish")) }

        let (amount, size) = recipe.grain.parameters
        guard amount > 0 else { return .success(finished) }
        let s = size * grainScale
        let noise = CIFilter.randomGenerator().outputImage!
            .transformed(by: CGAffineTransform(scaleX: s, y: s))
            .applyingGaussianBlur(sigma: 0.35 * s)
            .cropped(to: extent)
        guard let grained = grain.apply(extent: extent, arguments: [finished, noise, amount]) else {
            return .failure(.kernel("grain"))
        }
        return .success(grained)
    }

    /// Develop a capture: RAW goes through the linear path; processed photos are linearised first.
    func develop(_ captured: Captured, recipe: Recipe, options: DevelopOptions) -> Result<Data, RenderError> {
        let source: (image: CIImage, gains: [Double], metadata: [String: Any])
        switch captured {
        case let .raw(dng):
            guard let raw = CIRAWFilter(imageData: dng, identifierHint: UTType.dng.identifier) else { return .failure(.decode) }
            // Linear response, no Apple tone mapping: the look supplies the tone curve.
            raw.boostAmount = 0
            raw.localToneMapAmount = 0
            raw.extendedDynamicRangeAmount = 0
            raw.isLensCorrectionEnabled = true
            guard let image = raw.outputImage else { return .failure(.decode) }
            source = (image, matchingGains(image, reference: options.whiteReference), CIImage(data: dng)?.properties ?? [:])
        case let .processed(data):
            guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return .failure(.decode) }
            // Stills get different processing from the video feed; match them to the viewfinder too.
            let linear = sceneLinear(fromProcessed: image)
            let gains = options.whiteReference == nil ? [Self.lookAnchor, Self.lookAnchor, Self.lookAnchor] : matchingGains(linear, reference: options.whiteReference)
            source = (recipe.isNative ? image : linear, recipe.isNative ? [1, 1, 1] : gains, image.properties)
        }
        var image = source.image
        if options.mirror { image = image.oriented(.upMirrored) }
        image = Self.crop(image, to: options.aspect)
        let grainScale = max(1, image.extent.width / 4032)
        return apply(recipe, to: image, inputGains: source.gains, grainScale: grainScale).flatMap { looked in
            let tagged = looked.settingProperties(Self.metadata(source.metadata, recipe: recipe, library: library, geo: options.geo))
            let quality = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.92]
            let data = options.format == .heic
                ? context.heifRepresentation(of: tagged, format: .RGBA8, colorSpace: Self.outputSpace, options: quality)
                : context.jpegRepresentation(of: tagged, colorSpace: Self.outputSpace, options: quality)
            return data.map(Result.success) ?? .failure(.encode)
        }
    }

    #if DEBUG
        /// Saves the viewfinder frame and the RAW's linear develop side by side (linear Rec.2020, ×0.25, 16-bit TIFF)
        /// so the preview path can be calibrated against the capture path on a Mac.
        func dumpCalibration(preview: CVPixelBuffer, captured: Captured, to dir: URL) {
            let still: (String, CIImage)
            switch captured {
            case let .raw(dng):
                guard let raw = CIRAWFilter(imageData: dng, identifierHint: UTType.dng.identifier) else { return }
                raw.boostAmount = 0
                raw.localToneMapAmount = 0
                raw.extendedDynamicRangeAmount = 0
                raw.isLensCorrectionEnabled = true
                guard let image = raw.outputImage else { return }
                still = ("raw", image)
            case let .processed(data):
                guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return }
                still = ("processed", image)
            }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let pairs: [(String, CIImage)] = [("preview", CIImage(cvPixelBuffer: preview)), still]
            for (name, image) in pairs {
                let s = 480 / image.extent.width
                let small = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
                    .applyingFilter("CIColorMatrix", parameters: [
                        "inputRVector": CIVector(x: 0.25, y: 0, z: 0, w: 0),
                        "inputGVector": CIVector(x: 0, y: 0.25, z: 0, w: 0),
                        "inputBVector": CIVector(x: 0, y: 0, z: 0.25, w: 0),
                    ])
                try? context.writeTIFFRepresentation(
                    of: small.cropped(to: small.extent.integral),
                    to: dir.appendingPathComponent("\(name).tiff"),
                    format: .RGBA16,
                    colorSpace: CGColorSpace(name: CGColorSpace.linearITUR_2020)!
                )
            }
        }
    #endif

    /// Per-channel exp(mean(log)) of a linear image, measured on a small copy.
    func geometricMeans(_ image: CIImage) -> [Double] {
        let s = 256 / max(image.extent.width, 1)
        let small = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        guard let logged = logRGB.apply(extent: small.extent, arguments: [small]) else { return [0.18, 0.18, 0.18] }
        let average = logged.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: small.extent)])
        var px = [Float](repeating: 0, count: 4)
        context.render(average, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return px.prefix(3).map { Double(exp2($0)) }
    }

    /// What to record at the shutter press: the corrected viewfinder's per-channel geometric means.
    func whiteReference(for frame: CVPixelBuffer) -> [Double] {
        geometricMeans(sceneLinear(fromProcessed: CIImage(cvPixelBuffer: frame)))
    }

    /// Gains that bring `image` to the reference's exposure and white balance, then to the looks' anchor.
    func matchingGains(_ image: CIImage, reference: [Double]?) -> [Double] {
        guard let reference, reference.count == 3 else { return Array(repeating: Self.rawFallbackScale, count: 3) }
        let means = geometricMeans(image)
        return (0..<3).map { reference[$0] / max(means[$0], 1e-6) * Self.lookAnchor }
    }

    /// Fast screen-sized develop of a RAW for the viewer's look dial.
    func previewDevelop(dng: Data, recipe: Recipe, options: DevelopOptions, maxDimension: CGFloat) -> CGImage? {
        guard let raw = CIRAWFilter(imageData: dng, identifierHint: UTType.dng.identifier) else { return nil }
        raw.boostAmount = 0
        raw.localToneMapAmount = 0
        raw.extendedDynamicRangeAmount = 0
        raw.isLensCorrectionEnabled = true
        let full = raw.nativeSize
        raw.scaleFactor = Float(min(1, maxDimension / max(full.width, full.height)))
        guard var image = raw.outputImage else { return nil }
        if options.mirror { image = image.oriented(.upMirrored) }
        image = Self.crop(image, to: options.aspect)
        let gains = matchingGains(image, reference: options.whiteReference)
        guard case let .success(looked) = apply(recipe, to: image, inputGains: gains, grainScale: 0.6) else { return nil }
        return context.createCGImage(looked, from: looked.extent.integral, format: .RGBA8, colorSpace: Self.outputSpace)
    }

    /// The viewfinder frame through the recipe, small — the instant thumbnail before the real develop finishes.
    func snapshot(_ buffer: CVPixelBuffer, recipe: Recipe, height: CGFloat) -> CGImage? {
        let source = CIImage(cvPixelBuffer: buffer)
        let s = height / source.extent.height
        guard case let .success(img) = preview(source.transformed(by: CGAffineTransform(scaleX: s, y: s)), recipe: recipe) else { return nil }
        return context.createCGImage(img, from: img.extent.integral, format: .RGBA8, colorSpace: Self.thumbSpace)
    }

    static func crop(_ image: CIImage, to aspect: Aspect) -> CIImage {
        let e = image.extent
        let long = max(e.width, e.height), short = min(e.width, e.height)
        let current = long / short
        let (newLong, newShort): (Double, Double) = current > aspect.ratio
            ? (short * aspect.ratio, short) // too long: trim the long side
            : (long, long / aspect.ratio) // too square: trim the short side
        let (w, h) = e.width >= e.height ? (newLong, newShort) : (newShort, newLong)
        let rect = CGRect(x: e.midX - w / 2, y: e.midY - h / 2, width: w, height: h).integral
        return image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }

    /// Keeps the capture's EXIF (exposure, lens, date), resets orientation (pixels are already upright),
    /// records the look, and adds GPS when available.
    static func metadata(_ original: [String: Any], recipe: Recipe, library: LookLibrary, geo: GeoTag?) -> [String: Any] {
        var props = original
        props[kCGImagePropertyOrientation as String] = 1
        props.removeValue(forKey: kCGImagePropertyDNGDictionary as String)
        var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        tiff[kCGImagePropertyTIFFOrientation as String] = 1
        tiff[kCGImagePropertyTIFFSoftware as String] = "Filmlab"
        props[kCGImagePropertyTIFFDictionary as String] = tiff
        var exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        exif[kCGImagePropertyExifUserComment as String] = recipe.isNative ? "Filmlab" : "Filmlab look: \(library.look(id: recipe.lookID)?.displayName ?? recipe.lookID)"
        props[kCGImagePropertyExifDictionary as String] = exif
        if let geo {
            props[kCGImagePropertyGPSDictionary as String] = [
                kCGImagePropertyGPSLatitude as String: abs(geo.latitude),
                kCGImagePropertyGPSLatitudeRef as String: geo.latitude >= 0 ? "N" : "S",
                kCGImagePropertyGPSLongitude as String: abs(geo.longitude),
                kCGImagePropertyGPSLongitudeRef as String: geo.longitude >= 0 ? "E" : "W",
                kCGImagePropertyGPSAltitude as String: abs(geo.altitude),
                kCGImagePropertyGPSAltitudeRef as String: geo.altitude >= 0 ? 0 : 1,
                kCGImagePropertyGPSTimeStamp as String: Self.gpsTime.string(from: geo.timestamp),
                kCGImagePropertyGPSDateStamp as String: Self.gpsDate.string(from: geo.timestamp),
            ]
        }
        return props
    }

    private static let gpsTime: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "HH:mm:ss.SS"
        return f
    }()

    private static let gpsDate: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy:MM:dd"
        return f
    }()
}
