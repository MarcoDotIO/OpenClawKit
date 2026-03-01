import Foundation

#if canImport(CryptoKit)
import CryptoKit
#endif

#if canImport(Security)
import Security
#endif

/// Signature primitive for replay-ledger event integrity.
public protocol ReplayLedgerSigner {
    /// Signature algorithm identifier.
    var algorithm: String { get }
    /// Logical key identifier.
    var keyID: String { get }

    /// Produces a detached signature over payload bytes.
    /// - Parameter payload: Canonical payload bytes.
    /// - Returns: Signature bytes.
    func sign(_ payload: Data) throws -> Data

    /// Verifies a detached signature.
    /// - Parameters:
    ///   - signature: Signature bytes.
    ///   - payload: Canonical payload bytes.
    /// - Returns: `true` when signature validates.
    func verify(signature: Data, for payload: Data) -> Bool
}

/// Cross-platform HMAC fallback signer for replay-ledger integrity.
public struct HMACReplayLedgerSigner: ReplayLedgerSigner {
    public let algorithm = "hmac-sha256"
    public let keyID: String
    private let secretKey: Data

    /// Creates an HMAC replay signer.
    /// - Parameters:
    ///   - secret: Shared-secret key material.
    ///   - keyID: Logical key identifier.
    public init(secret: Data, keyID: String = "fallback-hmac") {
        self.secretKey = secret
        self.keyID = keyID
    }

    public func sign(_ payload: Data) throws -> Data {
        OpenClawCrypto.hmacSHA256(key: self.secretKey, data: payload)
    }

    public func verify(signature: Data, for payload: Data) -> Bool {
        guard let expected = try? self.sign(payload) else {
            return false
        }
        return expected == signature
    }
}

/// Signature-verification output for replay-ledger validation.
public struct ReplayLedgerVerificationResult: Codable, Sendable, Equatable {
    public let isValid: Bool
    public let validatedEventCount: Int
    public let firstInvalidIndex: Int?
    public let failureReason: String?

    /// Creates a replay-ledger verification result.
    public init(
        isValid: Bool,
        validatedEventCount: Int,
        firstInvalidIndex: Int? = nil,
        failureReason: String? = nil
    ) {
        self.isValid = isValid
        self.validatedEventCount = max(0, validatedEventCount)
        self.firstInvalidIndex = firstInvalidIndex
        self.failureReason = failureReason
    }
}

/// Replay-ledger signing and verification helpers.
public enum ReplayLedgerVerifier {
    /// Computes the deterministic event hash for one replay event.
    /// - Parameters:
    ///   - event: Replay event payload.
    ///   - previousEventHash: Previous chain hash.
    /// - Returns: Hex-encoded hash.
    public static func eventHashHex(for event: ReplayEvent, previousEventHash: String?) -> String {
        let payload = LedgerHashPayload(event: event, previousEventHash: previousEventHash)
        let data = (try? canonicalEncoder.encode(payload)) ?? Data()
        return OpenClawCrypto.sha256Hex(data)
    }

    /// Produces a signed replay envelope with linked hash metadata.
    /// - Parameters:
    ///   - event: Replay event.
    ///   - previousEventHash: Previous chain hash.
    ///   - signer: Signer implementation.
    /// - Returns: Signed replay envelope.
    public static func signedEnvelope(
        for event: ReplayEvent,
        previousEventHash: String?,
        signer: any ReplayLedgerSigner
    ) throws -> ReplayEventEnvelope {
        let eventHash = self.eventHashHex(for: event, previousEventHash: previousEventHash)
        let signatureBytes = try signer.sign(Data(eventHash.utf8))
        let signature = ReplayEventSignature(
            algorithm: signer.algorithm,
            keyID: signer.keyID,
            value: signatureBytes.base64EncodedString()
        )
        return ReplayEventEnvelope(
            event: event,
            previousEventHash: previousEventHash,
            eventHash: eventHash,
            signature: signature
        )
    }

    /// Verifies an ordered replay-ledger chain.
    /// - Parameters:
    ///   - envelopes: Ordered replay envelopes.
    ///   - signer: Optional signature verifier.
    ///   - requireSignatureVerification: Require valid signatures on all events.
    /// - Returns: Verification result.
    public static func verify(
        envelopes: [ReplayEventEnvelope],
        signer: (any ReplayLedgerSigner)? = nil,
        requireSignatureVerification: Bool = false
    ) -> ReplayLedgerVerificationResult {
        guard !envelopes.isEmpty else {
            return ReplayLedgerVerificationResult(isValid: true, validatedEventCount: 0)
        }

        var expectedPreviousHash: String?
        for (index, envelope) in envelopes.enumerated() {
            if envelope.previousEventHash != expectedPreviousHash {
                return ReplayLedgerVerificationResult(
                    isValid: false,
                    validatedEventCount: index,
                    firstInvalidIndex: index,
                    failureReason: "Previous event hash mismatch at index \(index)"
                )
            }

            let expectedHash = self.eventHashHex(for: envelope.event, previousEventHash: expectedPreviousHash)
            if envelope.eventHash != expectedHash {
                return ReplayLedgerVerificationResult(
                    isValid: false,
                    validatedEventCount: index,
                    firstInvalidIndex: index,
                    failureReason: "Event hash mismatch at index \(index)"
                )
            }

            if requireSignatureVerification || signer != nil || envelope.signature != nil {
                guard let signature = envelope.signature else {
                    return ReplayLedgerVerificationResult(
                        isValid: false,
                        validatedEventCount: index,
                        firstInvalidIndex: index,
                        failureReason: "Missing signature at index \(index)"
                    )
                }
                guard let signer else {
                    return ReplayLedgerVerificationResult(
                        isValid: false,
                        validatedEventCount: index,
                        firstInvalidIndex: index,
                        failureReason: "Signature verifier is required but unavailable"
                    )
                }
                guard signature.algorithm == signer.algorithm else {
                    return ReplayLedgerVerificationResult(
                        isValid: false,
                        validatedEventCount: index,
                        firstInvalidIndex: index,
                        failureReason: "Unexpected signature algorithm at index \(index)"
                    )
                }
                guard let signatureData = Data(base64Encoded: signature.value),
                      signer.verify(signature: signatureData, for: Data(expectedHash.utf8))
                else {
                    return ReplayLedgerVerificationResult(
                        isValid: false,
                        validatedEventCount: index,
                        firstInvalidIndex: index,
                        failureReason: "Signature verification failed at index \(index)"
                    )
                }
            }

            expectedPreviousHash = expectedHash
        }

        return ReplayLedgerVerificationResult(
            isValid: true,
            validatedEventCount: envelopes.count
        )
    }
}

#if canImport(CryptoKit) && canImport(Security)
/// Apple-first signer that prefers Secure Enclave and falls back to software P256 keys.
public struct AppleReplayLedgerSigner: ReplayLedgerSigner {
    public let algorithm: String
    public let keyID: String
    private let signer: SigningMaterial
    private let publicKeyData: Data

    private enum SigningMaterial {
        case secure(SecureEnclave.P256.Signing.PrivateKey)
        case software(P256.Signing.PrivateKey)
    }

    /// Creates an Apple replay-ledger signer.
    /// - Parameter keyID: Logical key identifier.
    public init(keyID: String = "apple-replay-ledger-key") throws {
        self.keyID = keyID
        if SecureEnclave.isAvailable,
           let secureKey = try? SecureEnclave.P256.Signing.PrivateKey(compactRepresentable: false) {
            self.signer = .secure(secureKey)
            self.publicKeyData = secureKey.publicKey.x963Representation
            self.algorithm = "secp256r1-sha256-secureenclave"
            return
        }

        let softwareKey = P256.Signing.PrivateKey()
        self.signer = .software(softwareKey)
        self.publicKeyData = softwareKey.publicKey.x963Representation
        self.algorithm = "secp256r1-sha256-software"
    }

    public func sign(_ payload: Data) throws -> Data {
        switch self.signer {
        case .secure(let key):
            return try key.signature(for: payload).derRepresentation
        case .software(let key):
            return try key.signature(for: payload).derRepresentation
        }
    }

    public func verify(signature: Data, for payload: Data) -> Bool {
        guard let parsed = try? P256.Signing.ECDSASignature(derRepresentation: signature),
              let publicKey = try? P256.Signing.PublicKey(x963Representation: self.publicKeyData)
        else {
            return false
        }
        return publicKey.isValidSignature(parsed, for: payload)
    }
}
#endif

private struct LedgerHashPayload: Codable {
    let event: ReplayEvent
    let previousEventHash: String?
}

private let canonicalEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .millisecondsSince1970
    return encoder
}()
