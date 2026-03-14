import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Cross-platform cryptographic helpers backed by CryptoKit or swift-crypto.
public enum OpenClawCrypto {
    /// Computes the SHA-256 digest as a lowercase hexadecimal string.
    /// - Parameter data: Input bytes to hash.
    /// - Returns: Lowercase hex-encoded digest.
    public static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Computes an HMAC-SHA256 message authentication code.
    /// - Parameters:
    ///   - key: Raw HMAC key data.
    ///   - data: Message bytes to authenticate.
    /// - Returns: Raw authentication code bytes.
    public static func hmacSHA256(key: Data, data: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let auth = HMAC<SHA256>.authenticationCode(for: data, using: symmetricKey)
        return Data(auth)
    }
}
