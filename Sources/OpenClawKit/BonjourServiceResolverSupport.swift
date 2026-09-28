import Foundation

/// Bonjour service resolution helpers shared by gateway discovery flows.
public enum BonjourServiceResolverSupport {
    #if !os(watchOS)
    /// Starts resolution for a service on the main run loop.
    ///
    /// Unavailable on watchOS, where `NetService` does not exist.
    public static func start(_ service: NetService, timeout: TimeInterval = 2.0) {
        service.schedule(in: .main, forMode: .common)
        service.resolve(withTimeout: timeout)
    }
    #endif

    /// Normalizes a resolved Bonjour hostname by trimming whitespace and a trailing dot.
    public static func normalizeHost(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return trimmed.hasSuffix(".") ? String(trimmed.dropLast()) : trimmed
    }
}
