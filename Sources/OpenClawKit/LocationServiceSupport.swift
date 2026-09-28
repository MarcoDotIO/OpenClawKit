import CoreLocation
import Foundation

/// Shared Core Location behaviors used by the location command helpers.
@MainActor
public protocol LocationServiceCommon: AnyObject, CLLocationManagerDelegate {
    /// Backing location manager instance.
    var locationManager: CLLocationManager { get }
    /// Continuation resumed when a one-shot location request finishes.
    var locationRequestContinuation: CheckedContinuation<CLLocation, Error>? { get set }
}

/// Location service that supports several concurrent one-shot waiters.
///
/// `CLLocationManager` coalesces `requestLocation()` calls into one pending fix, so every active waiter
/// shares the next delegate result. Conformers call ``completeLocationRequests(with:)`` from their
/// `locationManager(_:didUpdateLocations:)` and `locationManager(_:didFailWithError:)` callbacks.
@MainActor
public protocol ConcurrentLocationServiceCommon: LocationServiceCommon, Sendable {
    /// Pending waiters keyed by request.
    var locationRequestContinuations: [UUID: CheckedContinuation<CLLocation, Error>] { get set }
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

public extension ConcurrentLocationServiceCommon {
    /// Resumes every pending waiter (concurrent and legacy single-slot) with the same result.
    func completeLocationRequests(with result: Result<CLLocation, Error>) {
        let continuations = Array(self.locationRequestContinuations.values) + [self.locationRequestContinuation]
            .compactMap(\.self)
        // Drain both stores before resuming so a later result cannot complete any waiter twice.
        self.locationRequestContinuations.removeAll()
        self.locationRequestContinuation = nil
        for continuation in continuations {
            continuation.resume(with: result)
        }
    }

    /// Requests a single location update shared with any other active waiters.
    ///
    /// Cancellation resumes only this waiter with `CancellationError`; the platform request is stopped
    /// only when no other waiter remains.
    func requestLocationOnce() async throws -> CLLocation {
        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await LocationServiceSupport.requestLocation(manager: self.locationManager) { continuation in
                self.locationRequestContinuations[requestID] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self,
                      let continuation = self.locationRequestContinuations.removeValue(forKey: requestID)
                else {
                    return
                }
                if self.locationRequestContinuations.isEmpty,
                   self.locationRequestContinuation == nil
                {
                    self.locationManager.stopUpdatingLocation()
                }
                continuation.resume(throwing: CancellationError())
            }
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
            guard !Task.isCancelled else {
                continuation.resume(throwing: CancellationError())
                return
            }
            setContinuation(continuation)
            manager.requestLocation()
        }
    }
}
