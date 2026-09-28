import Foundation
import OpenClawProtocol

/// A server `connect.challenge`: the one-time nonce plus the server-clock issue time.
///
/// Device proofs sign ``issuedAtMs`` (the server clock) instead of the local clock, so device
/// clock skew cannot produce `DEVICE_AUTH_SIGNATURE_EXPIRED`.
public struct GatewayConnectChallenge: Sendable, Equatable {
    /// Trimmed, non-empty challenge nonce.
    public let nonce: String
    /// Server issue time in milliseconds since the Unix epoch.
    public let issuedAtMs: Int64

    /// Creates a challenge value.
    public init(nonce: String, issuedAtMs: Int64) {
        self.nonce = nonce
        self.issuedAtMs = issuedAtMs
    }
}

/// Helpers for reading gateway connect challenges.
public enum GatewayConnectChallengeSupport {
    /// Parses a `connect.challenge` payload.
    ///
    /// Requires a trimmed non-empty `nonce` and an integral, non-negative `ts`
    /// (integer or integral finite double).
    /// - Parameter payload: Event payload object.
    /// - Returns: The challenge, or `nil` when the payload is malformed.
    public static func challenge(
        from payload: [String: OpenClawProtocol.AnyCodable]?) -> GatewayConnectChallenge?
    {
        guard let nonce = payload?["nonce"]?.stringValue else { return nil }
        let trimmed = nonce.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let rawTimestamp = payload?["ts"],
              let issuedAtMs = self.integerMilliseconds(rawTimestamp),
              issuedAtMs >= 0
        else { return nil }
        return GatewayConnectChallenge(nonce: trimmed, issuedAtMs: issuedAtMs)
    }

    /// Reads the nonce value from a `connect.challenge` payload.
    @available(*, deprecated, message: "Use challenge(from:), which also returns the server issue time to sign.")
    public static func nonce(from payload: [String: OpenClawProtocol.AnyCodable]?) -> String? {
        guard let nonce = payload?["nonce"]?.stringValue else { return nil }
        let trimmed = nonce.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Waits for a non-empty connect nonce while applying a timeout.
    @available(*, deprecated, message: "The gateway channel parses challenges itself; use challenge(from:).")
    public static func waitForNonce<E: Error>(
        timeoutSeconds: Double,
        onTimeout: @escaping @Sendable () -> E,
        receiveNonce: @escaping @Sendable () async throws -> String?) async throws -> String
    {
        try await AsyncTimeout.withTimeout(
            seconds: timeoutSeconds,
            onTimeout: onTimeout,
            operation: {
                while true {
                    if let nonce = try await receiveNonce() {
                        return nonce
                    }
                }
            })
    }

    private static func integerMilliseconds(_ value: OpenClawProtocol.AnyCodable) -> Int64? {
        switch value.value {
        case let .int(int):
            Int64(exactly: int)
        case let .double(double) where double.isFinite && double.rounded() == double:
            Int64(exactly: double)
        default:
            nil
        }
    }
}
