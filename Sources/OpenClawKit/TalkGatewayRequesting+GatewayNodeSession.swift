import Foundation
import OpenClawProtocol

// Kept in its own file so gateway-session API changes stay local to this conformance.
extension GatewayNodeSession: TalkGatewayRequesting {
    /// Sends a Talk request over this session (``TalkGatewayRequesting`` conformance).
    ///
    /// Params go out as-is (no JSON-string round trip) and the timeout keeps millisecond precision;
    /// `0` leaves the deadline to the gateway.
    /// - Parameters:
    ///   - method: Gateway method name.
    ///   - params: JSON object parameters.
    ///   - timeoutMs: Timeout in milliseconds.
    public func talkRequest(method: String, params: [String: AnyCodable]?, timeoutMs: Double) async throws -> Data {
        try await self.request(method: method, params: params, timeoutMs: max(0, timeoutMs))
    }

    /// Subscribes to server events forwarded by this session (``TalkGatewayRequesting`` conformance).
    /// - Parameter bufferingNewest: Number of newest events retained for a slow consumer.
    public func talkServerEvents(bufferingNewest: Int) async -> AsyncStream<EventFrame> {
        self.subscribeServerEvents(bufferingNewest: bufferingNewest)
    }
}
