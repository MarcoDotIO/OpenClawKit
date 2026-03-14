import Foundation
#if canImport(Security)
import Security
#endif

/// Security-related helpers used by transport and trust validation layers.
public enum OpenClawSecurity {
    /// Normalizes a SHA-256 fingerprint by removing prefixes and separators.
    /// - Parameter value: Fingerprint string in any common format.
    /// - Returns: Lowercased hex-only fingerprint.
    public static func normalizeFingerprint(_ value: String) -> String {
        let stripped = value.replacingOccurrences(
            of: #"(?i)^sha-?256\s*:?\s*"#,
            with: "",
            options: .regularExpression
        )
        return stripped.lowercased().filter(\.isHexDigit)
    }

    #if canImport(Security)
    /// Computes SHA-256 fingerprint for a trust chain leaf certificate.
    /// - Parameter trust: TLS trust object from Security framework.
    /// - Returns: Lowercase hex fingerprint when available.
    public static func tlsLeafCertificateSHA256(trust: SecTrust) -> String? {
        guard
            let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
            let cert = chain.first
        else {
            return nil
        }

        let data = SecCertificateCopyData(cert) as Data
        return OpenClawCrypto.sha256Hex(data)
    }
    #endif
}
