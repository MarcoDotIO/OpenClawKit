import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Webhook signature primitives shared by the native channel adapters.
///
/// Every channel that verifies inbound webhooks (Twilio SMS, Slack HTTP Events, LINE) signs with an
/// HMAC; these helpers compute the platform's exact signature string and compare signatures in
/// constant time (upstream `safeEqualSecret`). Backed by CryptoKit on Apple platforms and
/// swift-crypto on Linux.
public enum ChannelWebhookSignature {
    /// Computes an HMAC-SHA1 authentication code (Twilio request signing).
    /// - Parameters:
    ///   - key: HMAC key bytes.
    ///   - message: Message bytes.
    /// - Returns: Raw authentication code.
    public static func hmacSHA1(key: Data, message: Data) -> Data {
        Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    /// Computes an HMAC-SHA256 authentication code (Slack and LINE request signing).
    /// - Parameters:
    ///   - key: HMAC key bytes.
    ///   - message: Message bytes.
    /// - Returns: Raw authentication code.
    public static func hmacSHA256(key: Data, message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    /// Twilio `X-Twilio-Signature`: base64(HMAC-SHA1(authToken, url + sorted form `key + value` pairs)).
    ///
    /// `url` must be the exact URL Twilio requested (the configured public webhook URL including its
    /// query string); keys are sorted by their UTF-8 code units like upstream `Array.toSorted()`.
    /// - Parameters:
    ///   - authToken: Twilio auth token.
    ///   - url: Signed URL.
    ///   - form: Decoded form fields (first value per key).
    /// - Returns: Base64 signature.
    public static func twilioSignature(authToken: String, url: String, form: [String: String]) -> String {
        var payload = url
        for key in form.keys.sorted(by: { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }) {
            payload += key + (form[key] ?? "")
        }
        return self.hmacSHA1(key: Data(authToken.utf8), message: Data(payload.utf8)).base64EncodedString()
    }

    /// Slack `X-Slack-Signature`: `"v0=" + hex(HMAC-SHA256(signingSecret, "v0:<timestamp>:<body>"))`.
    /// - Parameters:
    ///   - signingSecret: Slack signing secret.
    ///   - timestamp: `X-Slack-Request-Timestamp` header value.
    ///   - body: Raw request body.
    /// - Returns: Signature string including the `v0=` prefix.
    public static func slackSignature(signingSecret: String, timestamp: String, body: Data) -> String {
        var message = Data("v0:\(timestamp):".utf8)
        message.append(body)
        let digest = self.hmacSHA256(key: Data(signingSecret.utf8), message: message)
        return "v0=" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// LINE `X-Line-Signature`: base64(HMAC-SHA256(channelSecret, raw body)).
    /// - Parameters:
    ///   - channelSecret: LINE channel secret.
    ///   - body: Raw request body.
    /// - Returns: Base64 signature.
    public static func lineSignature(channelSecret: String, body: Data) -> String {
        self.hmacSHA256(key: Data(channelSecret.utf8), message: body).base64EncodedString()
    }

    /// Meta (WhatsApp Cloud) `X-Hub-Signature-256`: `"sha256=" + hex(HMAC-SHA256(appSecret, raw body))`.
    /// - Parameters:
    ///   - appSecret: Meta app secret.
    ///   - body: Raw request body.
    /// - Returns: Signature string including the `sha256=` prefix.
    public static func metaSignature(appSecret: String, body: Data) -> String {
        "sha256=" + self.hmacSHA256(key: Data(appSecret.utf8), message: body).map { String(format: "%02x", $0) }.joined()
    }

    /// Compares two secrets in constant time with respect to their contents.
    ///
    /// Both values are hashed with SHA-256 first (upstream `safeEqualSecret`), so the comparison
    /// time does not depend on the length or content of either secret.
    /// - Parameters:
    ///   - lhs: First secret.
    ///   - rhs: Second secret.
    /// - Returns: `true` when both secrets are byte-for-byte equal.
    public static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        self.constantTimeEquals(Data(lhs.utf8), Data(rhs.utf8))
    }

    /// Compares two byte strings in constant time with respect to their contents.
    /// - Parameters:
    ///   - lhs: First value.
    ///   - rhs: Second value.
    /// - Returns: `true` when both values are equal.
    public static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        let left = Array(SHA256.hash(data: lhs))
        let right = Array(SHA256.hash(data: rhs))
        var difference: UInt8 = lhs.count == rhs.count ? 0 : 1
        for index in 0..<min(left.count, right.count) {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }
}
