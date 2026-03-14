import Foundation

/// Shared core error surface used across OpenClawKit modules.
public enum OpenClawCoreError: Error, LocalizedError, Sendable {
    /// Indicates a dependency or subsystem is currently unavailable.
    case unavailable(String)
    /// Indicates a caller supplied invalid or incomplete configuration.
    case invalidConfiguration(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail):
            return "Unavailable: \(detail)"
        case .invalidConfiguration(let detail):
            return "Invalid configuration: \(detail)"
        }
    }
}

/// Build metadata describing a linked OpenClawKit distribution.
public struct OpenClawBuildInfo: Sendable {
    /// Supported gateway protocol version.
    public let protocolVersion: Int

    /// Creates build metadata.
    /// - Parameter protocolVersion: Supported gateway protocol version.
    public init(protocolVersion: Int) {
        self.protocolVersion = protocolVersion
    }
}
