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

extension GatewayNodeSession: OpenClawChatGatewayRequestSending {
    /// Sends a chat gateway request, optionally bound to a route lease.
    ///
    /// A `timeoutMs` of `0` (for example `sessions.compact`) leaves the deadline to the gateway.
    /// - Parameters:
    ///   - request: The request to send.
    ///   - expectedRoute: When set, the request never reconnects and fails with `CancellationError`
    ///     (or ``GatewayNodeSessionRequestError/routeChangedBeforeDispatch`` when
    ///     `distinguishPreDispatchRouteChange` is set) if the route is no longer current.
    ///   - distinguishPreDispatchRouteChange: Report a pre-dispatch route change as a typed error,
    ///     which proves the request never left the client.
    public func request(
        _ request: OpenClawChatGatewayRequest,
        ifCurrentRoute expectedRoute: GatewayNodeSessionRoute? = nil,
        distinguishPreDispatchRouteChange: Bool = false) async throws -> Data
    {
        try await self.request(
            method: request.method,
            params: request.params.isEmpty ? nil : request.params,
            timeoutMs: request.timeoutMs,
            ifCurrentRoute: expectedRoute,
            distinguishPreDispatchRouteChange: distinguishPreDispatchRouteChange)
    }

    /// Sends a chat gateway request on the session's current connection.
    public func sendChatGatewayRequest(_ request: OpenClawChatGatewayRequest) async throws -> Data {
        try await self.request(request)
    }
}

extension GatewayChannelActor: OpenClawChatGatewayRequestSending {
    /// Sends a chat gateway request on the channel (`timeoutMs == 0` leaves the deadline to the gateway).
    public func sendChatGatewayRequest(_ request: OpenClawChatGatewayRequest) async throws -> Data {
        try await self.request(
            method: request.method,
            params: request.params.isEmpty ? nil : request.params,
            timeoutMs: request.timeoutMs)
    }
}
