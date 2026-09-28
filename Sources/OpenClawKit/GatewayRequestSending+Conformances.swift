import Foundation

// Kept in its own file so gateway-core changes to GatewayChannelActor / GatewayNodeSession only need a
// local fix-up here. The node-session witnesses forward to the route-unbound form of the upstream APIs.

extension GatewayChannelActor: GatewayRequestSending {}

extension GatewayNodeSession: GatewayNodeRequestSending {
    /// Forwards to ``GatewayNodeSession/request(method:paramsJSON:timeoutSeconds:ifCurrentRoute:distinguishPreDispatchRouteChange:)``
    /// without binding the request to a route lease.
    public func sendNodeRequest(method: String, paramsJSON: String?, timeoutSeconds: Int) async throws -> Data {
        try await self.request(
            method: method,
            paramsJSON: paramsJSON,
            timeoutSeconds: timeoutSeconds,
            ifCurrentRoute: nil,
            distinguishPreDispatchRouteChange: false)
    }
}

extension GatewayNodeSession: GatewayNodeEventSending {
    /// Forwards to ``GatewayNodeSession/sendEvent(event:payloadJSON:ifCurrentRoute:)`` without a route lease;
    /// delivery failures are logged by the session.
    public func sendNodeEvent(event: String, payloadJSON: String?) async {
        await self.sendEvent(event: event, payloadJSON: payloadJSON, ifCurrentRoute: nil)
    }
}

extension TalkGatewayRequesting where Self: GatewayRequestSending {
    /// Talk requests reuse the shared ``GatewayRequestSending`` seam, so a gateway client only
    /// implements `talkServerEvents(bufferingNewest:)` to become a ``TalkGatewayRequesting``.
    /// - Parameters:
    ///   - method: Gateway method name.
    ///   - params: JSON object parameters.
    ///   - timeoutMs: Timeout in milliseconds.
    public func talkRequest(method: String, params: [String: AnyCodable]?, timeoutMs: Double) async throws -> Data {
        try await self.request(method: method, params: params, timeoutMs: timeoutMs)
    }
}
