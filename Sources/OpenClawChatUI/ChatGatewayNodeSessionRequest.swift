import Foundation
import OpenClawKit

/// Anything that can send an ``OpenClawChatGatewayRequest`` over a gateway connection.
///
/// This is the chat surface's small seam onto the kit's gateway clients: conformances live here so
/// gateway-side signature changes stay local to this file.
public protocol OpenClawChatGatewayRequestSending: Sendable {
    /// Sends a request and returns the raw response payload.
    func sendChatGatewayRequest(_ request: OpenClawChatGatewayRequest) async throws -> Data
}

/// Client timeouts for requests that ask for none (`timeoutMs == 0`, e.g. `sessions.compact`).
private let chatGatewayUnboundedRequestTimeoutMs: Double = 10 * 60 * 1000

extension GatewayNodeSession: OpenClawChatGatewayRequestSending {
    /// Sends a chat gateway request on the session's current connection.
    public func request(_ request: OpenClawChatGatewayRequest) async throws -> Data {
        let paramsJSON: String? = if request.params.isEmpty {
            nil
        } else {
            String(decoding: try JSONEncoder().encode(request.params), as: UTF8.self)
        }
        let timeoutMs = request.timeoutMs > 0 ? request.timeoutMs : chatGatewayUnboundedRequestTimeoutMs
        return try await self.request(
            method: request.method,
            paramsJSON: paramsJSON,
            timeoutSeconds: max(1, Int((timeoutMs / 1000).rounded(.up))))
    }

    /// Sends a chat gateway request on the session's current connection.
    public func sendChatGatewayRequest(_ request: OpenClawChatGatewayRequest) async throws -> Data {
        try await self.request(request)
    }
}

extension GatewayChannelActor: OpenClawChatGatewayRequestSending {
    /// Sends a chat gateway request on the channel.
    public func sendChatGatewayRequest(_ request: OpenClawChatGatewayRequest) async throws -> Data {
        try await self.request(
            method: request.method,
            params: request.params.isEmpty ? nil : request.params,
            timeoutMs: request.timeoutMs > 0 ? request.timeoutMs : chatGatewayUnboundedRequestTimeoutMs)
    }
}
