import Foundation
import OpenClawProtocol

// Kept in its own file so gateway-session API changes stay local to this conformance.
extension GatewayNodeSession: TalkGatewayRequesting {
    /// Sends a Talk request over this session (``TalkGatewayRequesting`` conformance).
    /// - Parameters:
    ///   - method: Gateway method name.
    ///   - params: JSON object parameters.
    ///   - timeoutMs: Timeout in milliseconds, rounded up to whole seconds.
    public func talkRequest(method: String, params: [String: AnyCodable]?, timeoutMs: Double) async throws -> Data {
        let paramsJSON: String? = try params.map { params in
            String(decoding: try JSONEncoder().encode(params), as: UTF8.self)
        }
        let timeoutSeconds = max(1, Int((max(0, timeoutMs) / 1000).rounded(.up)))
        return try await self.request(method: method, paramsJSON: paramsJSON, timeoutSeconds: timeoutSeconds)
    }

    /// Subscribes to server events forwarded by this session (``TalkGatewayRequesting`` conformance).
    /// - Parameter bufferingNewest: Number of newest events retained for a slow consumer.
    public func talkServerEvents(bufferingNewest: Int) async -> AsyncStream<EventFrame> {
        self.subscribeServerEvents(bufferingNewest: bufferingNewest)
    }
}
