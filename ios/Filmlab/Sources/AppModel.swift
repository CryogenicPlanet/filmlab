import CoreImage
import Foundation
import Observation
import SwiftUI
import UIKit

struct StartupError: Error {
    let message: String
}

enum Status: Equatable {
    case starting
    case ready
    case failed(String)
}

/// One stop on the look dial: a saved preset (C1, C2) or a plain look.
struct StripItem: Identifiable, Hashable, Sendable {
    let id: String
    let edge: String // small marking above the name: C1, C2, 1, 2, ...
    let title: String
    let base: Recipe
}

/// User preferences that persist between launches.
struct CameraSettings: Codable, Equatable, Sendable {
    var aspect = "4:3"
    var format = "HEIF"
    var keepRAW = true
    var highRes = true
    var grid = false
    var level = true
    var geotag = true
    var mirrorFront = true

    static let key = "camera.settings"

    static func load() -> CameraSettings {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(CameraSettings.self, from: $0) } ?? CameraSettings()
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// The look in use when the app was last closed.
struct LastLook: Codable, Sendable {
    let itemID: String
    let recipe: Recipe
    static let key = "camera.lastLook"

    static func load() -> LastLook? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(LastLook.self, from: $0) }
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

@MainActor
@Observable
final class AppModel {
    let library: LookLibrary
    let renderer: LookRenderer
    let camera = Camera()
    let location = LocationTagger()
    let level = Level()
    let shots = ShotStore()

    let items: [StripItem]
    private(set) var selectedID: String {
        didSet { LastLook(itemID: selectedID, recipe: recipe).save() }
    }
    var recipe: Recipe {
        didSet { LastLook(itemID: selectedID, recipe: recipe).save() }
    }

    private(set) var status: Status = .starting
    private(set) var toast: String?
    private(set) var lastShot: UIImage?
    var viewing = false
    private(set) var developing = 0
    private(set) var blink = 0

    private(set) var zoomFactor: Double = 1 // rear virtual device videoZoomFactor
    private(set) var front = false
    var adjusting = false
    var adjustParam: RecipeParam = .exposure

    var flash: FlashMode = .off
    var timer = 0 // seconds: 0, 3, 10
    private(set) var countdown: Int?
    var settings = CameraSettings.load() {
        didSet {
            settings.save()
            settings.geotag ? location.start() : location.stop()
            settings.level ? level.start() : level.stop()
        }
    }

    private(set) var focusPoint: CGPoint?
    private(set) var locked = false
    private(set) var bias: Double = 0
    private var focusToken = 0

    private init(library: LookLibrary, renderer: LookRenderer) {
        self.library = library
        self.renderer = renderer
        let native = StripItem(id: Recipe.nativeID, edge: "", title: "iPhone", base: Recipe(lookID: Recipe.nativeID))
        let looks = library.looks.enumerated().map { i, look in
            StripItem(id: look.id, edge: String(i + 1), title: look.displayName, base: Recipe(lookID: look.id))
        }
        let presets = Preset.builtIn.map { StripItem(id: $0.id, edge: $0.id.uppercased(), title: $0.name, base: $0.recipe) }
        items = [native] + looks + presets
        let saved = LastLook.load()
        let start = items.first { $0.id == saved?.itemID } ?? native
        selectedID = start.id
        recipe = saved.flatMap { $0.itemID == start.id ? $0.recipe : nil } ?? start.base
        lastShot = shots.shots.first.flatMap { UIImage(contentsOfFile: $0.photoURL.path())?.preparingThumbnail(of: CGSize(width: 240, height: 240)) }
    }

    static func make() -> Result<AppModel, StartupError> {
        do {
            let library = try LookLibrary()
            let renderer = try LookRenderer(library: library)
            return .success(AppModel(library: library, renderer: renderer))
        } catch {
            return .failure(StartupError(message: "Filmlab couldn't load its looks (\(error)). Reinstall the app."))
        }
    }

    var aspect: Aspect { Aspect(rawValue: settings.aspect) ?? .standard }
    var format: OutputFormat { OutputFormat(rawValue: settings.format) ?? .heic }
    var selectedItem: StripItem { items.first { $0.id == selectedID } ?? items[0] }
    var isEdited: Bool { recipe != selectedItem.base }
    var optics: Optics { camera.optics }
    var zoomReadout: (zoom: Double, mm: Int) { optics.describe(zoomFactor) }

    // MARK: lifecycle

    func start() async {
        guard let rear = camera.rearLens else {
            status = .failed("No rear camera was found.")
            return
        }
        switch await camera.start(with: rear) {
        case .success:
            zoomFactor = optics.main
            status = .ready
            if settings.geotag { location.start() }
            if settings.level { level.start() }
        case .failure(.notAuthorized):
            status = .failed("Filmlab needs the camera. Turn it on in Settings → Privacy & Security → Camera.")
        case let .failure(error):
            status = .failed("The camera didn't start (\(error)).")
        }
    }

    // MARK: looks

    func select(_ item: StripItem) {
        guard item.id != selectedID else { return }
        selectedID = item.id
        recipe = item.base
        if item.base.isNative { adjusting = false }
    }

    func resetRecipe() { recipe = selectedItem.base }

    func selectNeighbour(_ offset: Int) {
        guard let i = items.firstIndex(where: { $0.id == selectedID }) else { return }
        select(items[min(max(i + offset, 0), items.count - 1)])
    }

    // MARK: lenses, focus, exposure

    /// Lens button: jump to that stop; tapping 1× again steps 24 → 28 → 35 mm.
    func choose(_ stop: Optics.Stop) {
        if stop.label == "1", let i = optics.mainFocalSteps.firstIndex(where: { abs($0 - zoomFactor) < 0.02 }) {
            let steps = optics.mainFocalSteps
            setZoom(steps[(i + 1) % steps.count], ramp: true)
        } else {
            setZoom(stop.factor, ramp: true)
        }
    }

    func setZoom(_ factor: Double, ramp: Bool = false) {
        zoomFactor = min(max(factor, optics.ultraWide ?? optics.main), optics.maxFactor)
        camera.setZoom(zoomFactor, ramp: ramp)
    }

    /// The stop the current zoom belongs to, for highlighting.
    var activeStop: Optics.Stop? {
        optics.stops.last { zoomFactor >= $0.factor - 0.02 }
    }

    func flipCamera() async {
        guard let target = front ? camera.rearLens : camera.lenses.first(where: \.isFront) else { return }
        guard case .success = await camera.switchTo(target) else { return flash(message: "That camera isn't available right now.") }
        front.toggle()
        zoomFactor = front ? 1 : optics.main
        clearFocus()
    }

    /// Tap: focus and expose there. Long press: same, then hold it.
    func focus(at point: CGPoint, lock: Bool) {
        focusPoint = point
        locked = lock
        bias = 0
        camera.focus(at: point, front: front)
        focusToken += 1
        let token = focusToken
        guard !lock else { return }
        Task {
            try? await Task.sleep(for: .seconds(4))
            if token == focusToken, !locked { focusPoint = nil }
        }
    }

    func clearFocus() {
        focusPoint = nil
        locked = false
        bias = 0
        camera.resetFocus()
    }

    func adjustBias(by delta: Double) {
        bias = min(max(bias + delta, -2), 2)
        camera.setBias(Float(bias))
        focusToken += 1
    }

    // MARK: shooting

    func shutter() {
        guard status == .ready, countdown == nil else { return }
        if timer == 0 {
            Task { await shoot() }
            return
        }
        Task {
            for remaining in stride(from: timer, to: 0, by: -1) {
                countdown = remaining
                try? await Task.sleep(for: .seconds(1))
            }
            countdown = nil
            await shoot()
        }
    }

    private func shoot() async {
        let recipe = recipe
        let item = selectedItem
        let keepRAW = settings.keepRAW
        let previewFrame = camera.frames.frame()
        let renderer = renderer
        let reference = previewFrame.map { renderer.whiteReference(for: $0) }
        let options = DevelopOptions(
            aspect: aspect, format: format, mirror: front && settings.mirrorFront,
            geo: settings.geotag ? location.latest : nil, whiteReference: reference
        )
        blink += 1
        // Instant thumbnail from the viewfinder, replaced once the real develop lands.
        if let previewFrame, let cg = renderer.snapshot(previewFrame, recipe: recipe, height: 240) {
            withAnimation(.snappy(duration: 0.25)) { lastShot = UIImage(cgImage: cg) }
        }
        guard case let .success(captured) = await camera.capture(flash: flash, rotation: camera.captureAngle ?? Self.captureRotation(), highRes: settings.highRes, raw: !recipe.isNative) else {
            return flash(message: "The photo didn't take. Try again.")
        }
        developing += 1
        defer { developing -= 1 }
        #if DEBUG
            if let previewFrame {
                let frame = UncheckedBuffer(buffer: previewFrame)
                let dir = URL.documentsDirectory.appending(path: "calib/\(Int(Date().timeIntervalSince1970))")
                Task.detached(priority: .background) { renderer.dumpCalibration(preview: frame.buffer, captured: captured, to: dir) }
            }
        #endif
        let developed = await Task.detached(priority: .userInitiated) { renderer.develop(captured, recipe: recipe, options: options) }.value
        guard case let .success(photo) = developed else { return flash(message: "This photo couldn't be developed.") }
        lastShot = UIImage(data: photo)?.preparingThumbnail(of: CGSize(width: 240, height: 240))
        let dng: Data? = if case let .raw(d) = captured { d } else { nil }
        let shot = Shot(
            id: UUID(), date: .now, itemID: item.id, title: item.title, recipe: recipe, aspect: options.aspect.rawValue,
            mirror: options.mirror, geo: options.geo, format: options.format.rawValue, assetID: nil, hasRAW: false,
            whiteReference: reference
        )
        shots.add(shot, photo: photo, raw: dng)
        await saveToLibrary(shot: shot, photo: photo, raw: keepRAW ? dng : nil)
    }

    /// Re-develop an earlier shot's RAW with another look and save it as a new photo.
    func saveCopy(of shot: Shot, as item: StripItem) async {
        guard let dng = shots.raw(for: shot) else { return flash(message: "The RAW for this photo is no longer kept.") }
        developing += 1
        defer { developing -= 1 }
        let renderer = renderer
        let options = shot.options
        let recipe = item.base
        let developed = await Task.detached(priority: .userInitiated) { renderer.develop(.raw(dng), recipe: recipe, options: options) }.value
        guard case let .success(photo) = developed else { return flash(message: "This photo couldn't be developed.") }
        let copy = Shot(
            id: UUID(), date: shot.date, itemID: item.id, title: item.title, recipe: recipe, aspect: shot.aspect,
            mirror: shot.mirror, geo: shot.geo, format: shot.format, assetID: nil, hasRAW: false,
            whiteReference: shot.whiteReference
        )
        shots.add(copy, photo: photo, raw: dng)
        lastShot = UIImage(data: photo)?.preparingThumbnail(of: CGSize(width: 240, height: 240))
        await saveToLibrary(shot: copy, photo: photo, raw: nil)
        flash(message: "Saved a copy in \(item.title)")
    }

    func delete(_ shot: Shot) async {
        if let id = shot.assetID, !(await LibraryActions.delete(assetID: id)) { return }
        shots.remove(shot.id)
        lastShot = shots.shots.first.flatMap { UIImage(contentsOfFile: $0.photoURL.path())?.preparingThumbnail(of: CGSize(width: 240, height: 240)) }
        if shots.shots.isEmpty { viewing = false }
    }

    private func saveToLibrary(shot: Shot, photo: Data, raw: Data?) async {
        let type = OutputFormat(rawValue: shot.format)?.uti ?? .heic
        switch await PhotoSaver.save(photo: photo, type: type, raw: raw) {
        case let .success(id): shots.setAsset(id, for: shot.id)
        case .failure(.notAuthorized): flash(message: "Allow Filmlab to add photos in Settings → Privacy & Security → Photos.")
        case let .failure(.failed(reason)): flash(message: "Not saved: \(reason)")
        }
    }

    func flash(message: String) {
        toast = message
        Task {
            try? await Task.sleep(for: .seconds(2.4))
            if toast == message { toast = nil }
        }
    }

    private static func captureRotation() -> CGFloat {
        switch UIDevice.current.orientation {
        case .landscapeLeft: 0
        case .landscapeRight: 180
        case .portraitUpsideDown: 270
        default: 90
        }
    }
}

/// A camera frame handed to a background task; the buffer is not written after capture.
struct UncheckedBuffer: @unchecked Sendable {
    let buffer: CVPixelBuffer
}
