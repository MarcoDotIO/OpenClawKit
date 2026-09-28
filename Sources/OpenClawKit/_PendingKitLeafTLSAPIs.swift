// TEMPORARY SHIM (worker W1, release 2026.3.0).
//
// Declares exactly the upstream v2026.9.6 `GatewayTLSPinning.swift` types the gateway client
// consumes (typed TLS failures plus the three optional session provider protocols). Worker W2
// ports the real GatewayTLSPinning hardening with these same declarations; the orchestrator
// deletes this file at merge. Do not add other symbols here.
import Foundation

/// Classified reason a gateway TLS handshake was rejected.
public enum GatewayTLSValidationFailureKind: String, Sendable {
    /// The presented certificate does not match the stored or configured pin.
    case pinMismatch
    /// No certificate could be read from the handshake.
    case certificateUnavailable
    /// System trust rejected the certificate and no pin allowed it.
    case untrustedCertificate
    /// The first-use pin could not be saved.
    case pinStorageUnavailable
    /// The TLS challenge came from a different host or port than the requested gateway.
    case authorityMismatch
}

/// Typed TLS rejection evidence captured by a pinning session.
public struct GatewayTLSValidationFailure: Equatable, Sendable {
    /// Failure classification.
    public let kind: GatewayTLSValidationFailureKind
    /// Host that presented the certificate.
    public let host: String
    /// Pin store key for the endpoint, when one is configured.
    public let storeKey: String?
    /// Expected SHA-256 fingerprint, when a pin exists.
    public let expectedFingerprint: String?
    /// Observed SHA-256 fingerprint, when a certificate was presented.
    public let observedFingerprint: String?
    /// Whether system trust accepted the presented certificate.
    public let systemTrustOk: Bool
    /// Port of the TLS challenge, when known.
    public let port: Int?

    /// Creates a TLS failure record.
    public init(
        kind: GatewayTLSValidationFailureKind,
        host: String,
        storeKey: String?,
        expectedFingerprint: String?,
        observedFingerprint: String?,
        systemTrustOk: Bool,
        port: Int? = nil)
    {
        self.kind = kind
        self.host = host
        self.storeKey = storeKey
        self.expectedFingerprint = expectedFingerprint
        self.observedFingerprint = observedFingerprint
        self.systemTrustOk = systemTrustOk
        self.port = port
    }
}

/// Connect error surfaced when TLS validation rejected the gateway certificate.
public struct GatewayTLSValidationError: LocalizedError, Sendable {
    /// Captured TLS failure.
    public let failure: GatewayTLSValidationFailure
    /// Operation context (for example "connect to gateway @ wss://...").
    public let context: String

    /// Creates a TLS validation error.
    public init(failure: GatewayTLSValidationFailure, context: String) {
        self.failure = failure
        self.context = context
    }

    /// Human-readable description including expected and observed fingerprints for pin mismatches.
    public var errorDescription: String? {
        let prefix = self.context.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self.failure.kind {
        case .pinMismatch:
            let expected = self.failure.expectedFingerprint ?? "unknown"
            let observed = self.failure.observedFingerprint ?? "unknown"
            let mismatch = "expected \(expected), observed \(observed)"
            return "\(prefix): TLS certificate pin mismatch for \(self.failure.host) (\(mismatch))"
        case .certificateUnavailable:
            return "\(prefix): TLS certificate unavailable for \(self.failure.host)"
        case .untrustedCertificate:
            return "\(prefix): TLS certificate is not trusted for \(self.failure.host)"
        case .pinStorageUnavailable:
            return "\(prefix): TLS certificate pin could not be saved for \(self.failure.host)"
        case .authorityMismatch:
            return "\(prefix): TLS authority does not match the requested gateway for \(self.failure.host)"
        }
    }
}

/// Session adapters that expose typed TLS repair evidence to ``GatewayChannelActor``.
public protocol GatewayTLSFailureProviding: AnyObject {
    /// Returns and clears the most recent TLS failure.
    func consumeLastTLSFailure() -> GatewayTLSValidationFailure?
}

/// Session adapters that declare whether their TLS path permits device-token retry auth.
public protocol GatewayDeviceTokenRetryTrustProviding: AnyObject {
    /// `true` when the endpoint is trusted enough (for example a pin is enforced) to retry with a device token.
    var allowsDeviceTokenRetryAuth: Bool { get }
}

/// Session adapters that expose the TLS fingerprint accepted for the active route.
public protocol GatewayTLSRouteMetadataProviding: AnyObject {
    /// Accepted 64-hex SHA-256 leaf fingerprint, when the route is pinned.
    var effectiveTLSFingerprintSHA256: String? { get }
}
