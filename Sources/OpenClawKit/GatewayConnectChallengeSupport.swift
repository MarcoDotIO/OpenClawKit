import Foundation
import OpenClawProtocol

/// Helpers for reading and waiting on gateway connect challenges.
public enum GatewayConnectChallengeSupport {
    /// Reads the nonce value from a `connect.challenge` payload.
    public static func nonce(from payload: [String: OpenClawProtocol.AnyCodable]?) -> String? {
        guard let nonce = payload?["nonce"]?.stringValue else { return nil }
        let trimmed = nonce.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Waits for a non-empty connect nonce while applying a timeout.
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
}
