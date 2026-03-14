import CoreLocation
import Foundation

@MainActor
/// Shared Core Location behaviors used by the location command helpers.
public protocol LocationServiceCommon: AnyObject, CLLocationManagerDelegate {
    /// Backing location manager instance.
    var locationManager: CLLocationManager { get }
    /// Continuation resumed when a one-shot location request finishes.
    var locationRequestContinuation: CheckedContinuation<CLLocation, Error>? { get set }
}

public extension LocationServiceCommon {
    /// Applies the standard OpenClawKit location-manager configuration.
    func configureLocationManager() {
        self.locationManager.delegate = self
        self.locationManager.desiredAccuracy = kCLLocationAccuracyBest
    }

    /// Returns the current authorization status from the manager.
    func authorizationStatus() -> CLAuthorizationStatus {
        self.locationManager.authorizationStatus
    }

    /// Returns the current reduced/full accuracy authorization when supported by the platform.
    func accuracyAuthorization() -> CLAccuracyAuthorization {
        LocationServiceSupport.accuracyAuthorization(manager: self.locationManager)
    }

    /// Requests a single location update and waits for the delegate callback.
    func requestLocationOnce() async throws -> CLLocation {
        try await LocationServiceSupport.requestLocation(manager: self.locationManager) { continuation in
            self.locationRequestContinuation = continuation
        }
    }
}

/// Standalone helpers for requesting one-shot Core Location fixes.
public enum LocationServiceSupport {
    /// Returns the best available accuracy authorization for a manager.
    public static func accuracyAuthorization(manager: CLLocationManager) -> CLAccuracyAuthorization {
        if #available(iOS 14.0, macOS 11.0, *) {
            return manager.accuracyAuthorization
        }
        return .fullAccuracy
    }

    /// Requests one location fix and resumes the provided continuation setter.
    @MainActor
    public static func requestLocation(
        manager: CLLocationManager,
        setContinuation: @escaping (CheckedContinuation<CLLocation, Error>) -> Void) async throws -> CLLocation
    {
        try await withCheckedThrowingContinuation { continuation in
            setContinuation(continuation)
            manager.requestLocation()
        }
    }
}
