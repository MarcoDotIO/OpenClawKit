import CoreLocation
import Foundation

/// Helpers for resolving one-shot location requests with caching and timeout behavior.
public enum LocationCurrentRequest {
    /// Closure used to wrap one-shot location requests with timeout behavior.
    public typealias TimeoutRunner = @Sendable (
        _ timeoutMs: Int,
        _ operation: @escaping @Sendable () async throws -> CLLocation
    ) async throws -> CLLocation

    /// Resolves a location, reusing a fresh cached value when it satisfies the requested age budget.
    @MainActor
    public static func resolve(
        manager: CLLocationManager,
        desiredAccuracy: OpenClawLocationAccuracy,
        maxAgeMs: Int?,
        timeoutMs: Int?,
        request: @escaping @Sendable () async throws -> CLLocation,
        withTimeout: TimeoutRunner) async throws -> CLLocation
    {
        let now = Date()
        if let maxAgeMs,
           let cached = manager.location,
           now.timeIntervalSince(cached.timestamp) * 1000 <= Double(maxAgeMs)
        {
            return cached
        }

        manager.desiredAccuracy = self.accuracyValue(desiredAccuracy)
        let timeout = max(0, timeoutMs ?? 10000)
        return try await withTimeout(timeout) {
            try await request()
        }
    }

    /// Maps the public location-accuracy enum onto Core Location constants.
    public static func accuracyValue(_ accuracy: OpenClawLocationAccuracy) -> CLLocationAccuracy {
        switch accuracy {
        case .coarse:
            kCLLocationAccuracyKilometer
        case .balanced:
            kCLLocationAccuracyHundredMeters
        case .precise:
            kCLLocationAccuracyBest
        }
    }
}
