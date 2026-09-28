import Foundation
import OpenClawKit

/// Minimal gateway RPC surface used by ``GatewayOpenClawIntentHost``.
///
/// `GatewayChannelActor` conforms (see `GatewayChannelActor+OpenClawIntentGatewayRequesting.swift`);
/// tests and custom transports can supply their own implementation.
public protocol OpenClawIntentGatewayRequesting: Sendable {
    /// Sends a request frame and returns the response payload JSON.
    /// - Parameters:
    ///   - method: Gateway method name.
    ///   - params: Request parameters.
    ///   - timeoutMs: Request timeout in milliseconds, or `nil` for the transport default.
    /// - Returns: Encoded response payload.
    func request(method: String, params: [String: AnyCodable]?, timeoutMs: Double?) async throws -> Data
}
