@preconcurrency import AVFoundation
import CoreImage
import os

enum CameraError: Error, Sendable {
    case notAuthorized
    case noCamera
    case cannotAddInput
    case cannotAddOutput
    case captureFailed(String)
}

struct Lens: Identifiable, Hashable, Sendable {
    let id: String // AVCaptureDevice.uniqueID
    let isFront: Bool
}

/// Zoom geometry of the rear camera. Factors are the virtual device's videoZoomFactor
/// (1 = widest lens); display values follow Apple's naming (.5, 1, 2, 4, 8 and 13/24/100 mm).
struct Optics: Hashable, Sendable {
    let ultraWide: Double? // factor where the ultra-wide is native (1 when present)
    let main: Double // factor where the main camera is native
    let tele: Double? // factor where the telephoto is native
    let maxFactor: Double

    struct Stop: Identifiable, Hashable, Sendable {
        let label: String
        let factor: Double
        var id: String { label }
    }

    var stops: [Stop] {
        var all: [Stop] = []
        if let ultraWide { all.append(Stop(label: ".5", factor: ultraWide)) }
        all.append(Stop(label: "1", factor: main))
        all.append(Stop(label: "2", factor: main * 2))
        if let tele {
            all.append(Stop(label: "4", factor: tele))
            all.append(Stop(label: "8", factor: tele * 2))
        }
        return all.filter { $0.factor <= maxFactor + 0.01 }
    }

    /// Main camera at 24, 28 and 35 mm, like the built-in camera's 1× button.
    var mainFocalSteps: [Double] { [main, main * 28 / 24, main * 35 / 24] }

    /// Display zoom ("1.5") and 35 mm-equivalent focal length for a device factor.
    func describe(_ factor: Double) -> (zoom: Double, mm: Int) {
        if let tele, factor >= tele - 0.01 { return (4 * factor / tele, Int((100 * factor / tele).rounded())) }
        if let ultraWide, factor < main - 0.01 { return (0.5 * factor / ultraWide, Int((13 * factor / ultraWide).rounded())) }
        return (factor / main, Int((24 * factor / main).rounded()))
    }
}

enum FlashMode: String, CaseIterable, Sendable {
    case off, auto, on

    var next: FlashMode {
        switch self {
        case .off: .auto
        case .auto: .on
        case .on: .off
        }
    }

    var avMode: AVCaptureDevice.FlashMode {
        switch self {
        case .off: .off
        case .auto: .auto
        case .on: .on
        }
    }
}

/// What the shutter produced: a RAW DNG for the accurate path, or a processed HEIC where RAW isn't offered (front camera).
enum Captured: Sendable {
    case raw(Data)
    case processed(Data)
}

/// Latest preview frame, written on the video queue and read by renderers.
final class FrameSink: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, Sendable {
    private let latest = OSAllocatedUnfairLock<CVPixelBuffer?>(uncheckedState: nil)

    func captureOutput(_: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from _: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        latest.withLockUnchecked { $0 = buffer }
    }

    func frame() -> CVPixelBuffer? { latest.withLockUnchecked { $0 } }

    func clear() { latest.withLockUnchecked { $0 = nil } }
}

/// Bridges one photo capture to async/await.
private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate, Sendable {
    private let continuation: CheckedContinuation<AVCapturePhoto, any Error>

    init(_ continuation: CheckedContinuation<AVCapturePhoto, any Error>) { self.continuation = continuation }

    func photoOutput(_: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: (any Error)?) {
        if let error {
            continuation.resume(throwing: CameraError.captureFailed(error.localizedDescription))
        } else {
            continuation.resume(returning: photo)
        }
    }
}

/// Owns the capture session. All device and session work happens on `queue`.
private let log = Logger(subsystem: "dev.cryogenicplanet.filmlab", category: "camera")

final class Camera: Sendable {
    let frames = FrameSink()
    /// Apple's per-device rotation helper; replaced whenever the input changes.
    private let rotation = OSAllocatedUnfairLock<AVCaptureDevice.RotationCoordinator?>(uncheckedState: nil)
    let lenses: [Lens]
    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "filmlab.camera")
    private let videoQueue = DispatchQueue(label: "filmlab.frames", qos: .userInteractive)
    private let inFlight = OSAllocatedUnfairLock<[PhotoDelegate]>(initialState: [])

    let optics: Optics

    init() {
        let rear = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        lenses = [rear.map { Lens(id: $0.uniqueID, isFront: false) }, front.map { Lens(id: $0.uniqueID, isFront: true) }].compactMap { $0 }
        let switches = (rear?.virtualDeviceSwitchOverVideoZoomFactors ?? []).map { $0.doubleValue }
        let types = rear?.constituentDevices.map(\.deviceType) ?? []
        let hasUltraWide = types.contains(.builtInUltraWideCamera)
        let hasTele = types.contains(.builtInTelephotoCamera)
        let maxFactor = min(rear.map { Double($0.activeFormat.videoMaxZoomFactor) } ?? 1, 30)
        optics = Optics(
            ultraWide: hasUltraWide ? 1 : nil,
            main: hasUltraWide ? (switches.first ?? 2) : 1,
            tele: hasTele ? switches.last : nil,
            maxFactor: maxFactor
        )
    }

    var rearLens: Lens? { lenses.first { !$0.isFront } }

    func start(with lens: Lens) async -> Result<Void, CameraError> {
        guard await AVCaptureDevice.requestAccess(for: .video) else { return .failure(.notAuthorized) }
        return await onQueue { [self] in
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            session.sessionPreset = .photo
            guard session.canAddOutput(photoOutput), session.canAddOutput(videoOutput) else { return .failure(.cannotAddOutput) }
            session.addOutput(photoOutput)
            session.addOutput(videoOutput)
            // 10-bit frames: the looks add contrast, and 8-bit viewfinder frames band visibly in skies and skin.
            let tenBit = kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            let format = videoOutput.availableVideoPixelFormatTypes.contains(tenBit) ? tenBit : kCVPixelFormatType_32BGRA
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: format]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(frames, queue: videoQueue)
            photoOutput.maxPhotoQualityPrioritization = .quality
            let result = attach(lens)
            if case .success = result { queue.async { [session] in session.startRunning() } }
            return result
        }
    }

    func switchTo(_ lens: Lens) async -> Result<Void, CameraError> {
        await onQueue { [self] in
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            return attach(lens)
        }
    }

    /// Replaces the input and re-applies everything that depends on the active device. Call inside a configuration block.
    private func attach(_ lens: Lens) -> Result<Void, CameraError> {
        guard let device = AVCaptureDevice(uniqueID: lens.id) else { return .failure(.noCamera) }
        session.inputs.forEach(session.removeInput)
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return .failure(.cannotAddInput) }
        session.addInput(input)
        // The 17's square front sensor defaults to landscape framing; ask for portrait like the built-in camera.
        // The default .photo format has no dynamic aspect ratios, so pick the largest format that offers 3:4.
        if lens.isFront {
            let pixels = { (f: AVCaptureDevice.Format) -> Int32 in
                f.supportedMaxPhotoDimensions.map { $0.width * $0.height }.max() ?? 0
            }
            let portraitFormats = device.formats.filter { $0.supportedDynamicAspectRatios.contains(.ratio3x4) }
            log.notice("front formats with 3:4: \(portraitFormats.count) of \(device.formats.count)")
            if let best = portraitFormats.max(by: { pixels($0) < pixels($1) }), (try? device.lockForConfiguration()) != nil {
                device.activeFormat = best
                device.setDynamicAspectRatio(.ratio3x4, completionHandler: nil)
                device.unlockForConfiguration()
            }
        }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotation.withLockUnchecked { $0 = coordinator }
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        log.notice("attach \(lens.isFront ? "front" : "rear", privacy: .public) format \(dims.width)x\(dims.height) aspects \(device.activeFormat.supportedDynamicAspectRatios.map(\.rawValue).joined(separator: ","), privacy: .public) dynamic \(device.dynamicDimensions.width)x\(device.dynamicDimensions.height) previewAngle \(coordinator.videoRotationAngleForHorizonLevelPreview) captureAngle \(coordinator.videoRotationAngleForHorizonLevelCapture)")
        if let connection = videoOutput.connection(with: .video) {
            // The UI is portrait-only, so the viewfinder needs the portrait angle for this sensor.
            let portrait = Self.portraitAngle(for: device)
            if connection.isVideoRotationAngleSupported(portrait) { connection.videoRotationAngle = portrait }
            log.notice("preview connection angle \(connection.videoRotationAngle)")
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = lens.isFront
            }
        }
        if let largest = device.activeFormat.supportedMaxPhotoDimensions.max(by: { $0.width * $0.height < $1.width * $1.height }) {
            photoOutput.maxPhotoDimensions = largest
        }
        photoOutput.isAppleProRAWEnabled = photoOutput.isAppleProRAWSupported
        if !lens.isFront, (try? device.lockForConfiguration()) != nil {
            device.videoZoomFactor = optics.main
            device.unlockForConfiguration()
        }
        frames.clear()
        return .success(())
    }

    /// Focus and expose at a point in portrait-normalised preview coordinates (0...1, origin top-left).
    func focus(at point: CGPoint, front: Bool) {
        queue.async { [self] in
            guard let device = activeDevice(), (try? device.lockForConfiguration()) != nil else { return }
            defer { device.unlockForConfiguration() }
            // Sensor space is landscape: rotate the portrait point back.
            let p = CGPoint(x: point.y, y: front ? point.x : 1 - point.x)
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = p
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
                device.exposurePointOfInterest = p
                device.exposureMode = .autoExpose
            }
            device.setExposureTargetBias(0)
        }
    }

    /// Back to continuous auto focus / exposure (after a lens switch or a long idle).
    func resetFocus() {
        queue.async { [self] in
            guard let device = activeDevice(), (try? device.lockForConfiguration()) != nil else { return }
            defer { device.unlockForConfiguration() }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            device.setExposureTargetBias(0)
        }
    }

    func setBias(_ ev: Float) {
        queue.async { [self] in
            guard let device = activeDevice(), (try? device.lockForConfiguration()) != nil else { return }
            defer { device.unlockForConfiguration() }
            device.setExposureTargetBias(min(max(ev, device.minExposureTargetBias), device.maxExposureTargetBias))
        }
    }

    /// Sets the virtual device's zoom factor; `ramp` animates like the built-in camera's lens buttons.
    func setZoom(_ factor: Double, ramp: Bool) {
        queue.async { [self] in
            guard let device = activeDevice(), (try? device.lockForConfiguration()) != nil else { return }
            defer { device.unlockForConfiguration() }
            let clamped = min(max(factor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            if ramp {
                device.ramp(toVideoZoomFactor: clamped, withRate: 24)
            } else {
                device.cancelVideoZoomRamp()
                device.videoZoomFactor = clamped
            }
        }
    }

    func capture(flash: FlashMode, rotation: CGFloat, highRes: Bool, raw: Bool) async -> Result<Captured, CameraError> {
        let formats = raw ? photoOutput.availableRawPhotoPixelFormatTypes : []
        let rawFormat = formats.first { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) } ?? formats.first
        let settings: AVCapturePhotoSettings
        if let rawFormat {
            settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
        } else {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            settings.photoQualityPrioritization = .quality
        }
        let sizes = activeDevice()?.activeFormat.supportedMaxPhotoDimensions ?? []
        let pixels = { (d: CMVideoDimensions) -> Int in Int(d.width) * Int(d.height) }
        let twelve = sizes.min { abs(pixels($0) - 12_000_000) < abs(pixels($1) - 12_000_000) }
        settings.maxPhotoDimensions = highRes ? photoOutput.maxPhotoDimensions : (twelve ?? photoOutput.maxPhotoDimensions)
        if photoOutput.supportedFlashModes.contains(flash.avMode) { settings.flashMode = flash.avMode }
        if let connection = photoOutput.connection(with: .video) {
            connection.videoRotationAngle = rotation
        }
        do {
            let photo = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<AVCapturePhoto, any Error>) in
                let delegate = PhotoDelegate(cont)
                inFlight.withLock { $0.append(delegate) }
                photoOutput.capturePhoto(with: settings, delegate: delegate)
            }
            _ = inFlight.withLock { $0.removeFirst() }
            guard let data = photo.fileDataRepresentation() else { return .failure(.captureFailed("The camera returned no image.")) }
            return .success(photo.isRawPhoto ? .raw(data) : .processed(data))
        } catch {
            _ = inFlight.withLock { $0.removeFirst() }
            return .failure(error as? CameraError ?? .captureFailed(error.localizedDescription))
        }
    }

    /// Rotation that shows this sensor upright on a portrait screen. Rear sensors are landscape-mounted (90°);
    /// the coordinator knows the front sensor's mounting, read while the device is held portrait.
    private static func portraitAngle(for device: AVCaptureDevice) -> CGFloat {
        guard device.position == .front else { return 90 }
        let c = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        return c.videoRotationAngleForHorizonLevelCapture
    }

    /// Capture angle for how the phone is held right now (keeps the horizon level in the saved photo).
    var captureAngle: CGFloat? { rotation.withLockUnchecked { $0?.videoRotationAngleForHorizonLevelCapture } }

    private func activeDevice() -> AVCaptureDevice? {
        (session.inputs.first as? AVCaptureDeviceInput)?.device
    }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { cont in queue.async { cont.resume(returning: work()) } }
    }
}
