import CoreLocation
import CoreMotion
import Foundation
import Observation

/// Last known location for geotagging. Only runs while the app has permission and the setting is on.
@MainActor
@Observable
final class LocationTagger: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var latest: GeoTag?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    func start() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
        latest = nil
    }

    nonisolated func locationManager(_: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        let tag = GeoTag(latitude: l.coordinate.latitude, longitude: l.coordinate.longitude, altitude: l.altitude, timestamp: l.timestamp)
        Task { @MainActor in self.latest = tag }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            if status == .authorizedWhenInUse || status == .authorizedAlways { self.manager.startUpdatingLocation() }
        }
    }
}

/// Device roll for the level line, in degrees (0 = level in portrait).
@MainActor
@Observable
final class Level {
    private let motion = CMMotionManager()
    private(set) var roll: Double = 0

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let g = data?.gravity else { return }
            MainActor.assumeIsolated { self?.roll = atan2(g.x, -g.y) * 180 / .pi }
        }
    }

    func stop() { motion.stopDeviceMotionUpdates() }
}
