import Foundation
import Security

/// Why a certificate failed system trust for the requested gateway hostname.
public enum GatewayTLSTrustFailureReason: String, Sendable, Equatable {
    /// The chain does not lead to a trusted root (self-signed, private CA, missing intermediate).
    case untrustedChain
    /// The certificate is valid but not for the requested hostname.
    case hostnameMismatch
    /// The certificate is expired or not yet valid.
    case expired
    /// Any other Security.framework trust failure.
    case other

    /// Maps a `SecTrustEvaluateWithError` error to a reason.
    public init(trustError: CFError?) {
        guard let trustError else {
            self = .other
            return
        }
        switch OSStatus(CFErrorGetCode(trustError)) {
        case errSecHostNameMismatch:
            self = .hostnameMismatch
        case errSecCertificateExpired, errSecCertificateNotValidYet:
            self = .expired
        case errSecNotTrusted, errSecCreateChainFailed, errSecCertificateRevoked,
             errSecIncompleteCertRevocationCheck, errSecMissingRequiredExtension:
            self = .untrustedChain
        default:
            self = .other
        }
    }
}

/// Precise, user-facing classification of a gateway TLS failure (upstream #98429, #146267).
///
/// Apps use it to choose the next step: `pinMismatch` must stop auto-reconnect and ask the user to
/// re-trust the presented fingerprint (never replace a pin silently); the trust cases need a valid
/// certificate or an explicit fingerprint; `handshakeFailed` is a transport problem.
public enum GatewayTLSFailureClassification: Sendable, Equatable {
    /// The chain is not trusted by the system.
    case untrustedChain
    /// The certificate does not cover the requested hostname.
    case hostnameMismatch
    /// The certificate is expired or not yet valid.
    case expired
    /// The presented certificate does not match the pinned SHA-256 fingerprint.
    case pinMismatch(expected: String?, presented: String?)
    /// The TLS handshake failed before a certificate decision (or for another reason).
    case handshakeFailed

    /// Classifies a typed pinning failure.
    public init(failure: GatewayTLSValidationFailure) {
        switch failure.kind {
        case .pinMismatch:
            self = .pinMismatch(expected: failure.expectedFingerprint, presented: failure.observedFingerprint)
        case .untrustedCertificate:
            switch failure.trustFailureReason {
            case .hostnameMismatch: self = .hostnameMismatch
            case .expired: self = .expired
            case .untrustedChain, .other, nil: self = .untrustedChain
            }
        case .certificateUnavailable, .pinStorageUnavailable, .authorityMismatch:
            self = .handshakeFailed
        }
    }

    /// Classifies a connect error: ``GatewayTLSValidationError`` and TLS-related `URLError`s map to a
    /// case; unrelated errors return `nil`.
    public init?(error: any Error) {
        if let validation = error as? GatewayTLSValidationError {
            self.init(failure: validation.failure)
            return
        }
        guard let urlError = error as? URLError else { return nil }
        switch urlError.code {
        case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot:
            self = .untrustedChain
        case .serverCertificateHasBadDate, .serverCertificateNotYetValid:
            self = .expired
        case .secureConnectionFailed, .clientCertificateRejected, .clientCertificateRequired:
            self = .handshakeFailed
        default:
            return nil
        }
    }

    /// Whether automatic reconnects should stop until the user acts.
    public var requiresUserAction: Bool {
        switch self {
        case .pinMismatch, .untrustedChain, .hostnameMismatch, .expired: true
        case .handshakeFailed: false
        }
    }
}

/// A request to re-trust a gateway whose certificate no longer matches the stored pin.
///
/// Present ``currentFingerprint`` and ``presentedFingerprint`` to the user; only after they confirm,
/// call ``GatewayTLSStore/acceptRotation(_:)``. ``isSystemTrusted`` tells the UI whether the new
/// certificate also passes system trust (a renewal) or not (possible interception).
public struct GatewayTLSPinRotationRequest: Sendable, Equatable {
    /// Pin storage key of the gateway.
    public let storeKey: String
    /// Gateway host from the TLS challenge.
    public let host: String
    /// Gateway port from the TLS challenge.
    public let port: Int?
    /// Currently stored (enforced) fingerprint.
    public let currentFingerprint: String
    /// Fingerprint of the certificate the gateway presented.
    public let presentedFingerprint: String
    /// Whether the presented certificate passed system trust for the hostname.
    public let isSystemTrusted: Bool

    /// Builds a rotation request from a pin-mismatch failure with a store key and both fingerprints;
    /// returns `nil` for any other failure.
    public init?(failure: GatewayTLSValidationFailure) {
        guard failure.kind == .pinMismatch,
              let storeKey = failure.storeKey, !storeKey.isEmpty,
              let current = failure.expectedFingerprint, !current.isEmpty,
              let presented = failure.observedFingerprint, !presented.isEmpty
        else { return nil }
        self.storeKey = storeKey
        self.host = failure.host
        self.port = failure.port
        self.currentFingerprint = current
        self.presentedFingerprint = presented
        self.isSystemTrusted = failure.systemTrustOk
    }
}

extension GatewayTLSStore {
    /// Replaces the stored pin with the presented fingerprint, but only if the stored pin is still the
    /// one the user reviewed (compare-and-swap). Call only after explicit user confirmation.
    @discardableResult
    public static func acceptRotation(_ request: GatewayTLSPinRotationRequest) -> Bool {
        let accepted = self.replaceFingerprint(
            request.presentedFingerprint,
            ifCurrent: request.currentFingerprint,
            stableID: request.storeKey)
        if accepted {
            _ = self.clearStagedNextFingerprint(stableID: request.storeKey)
        }
        return accepted
    }
}
