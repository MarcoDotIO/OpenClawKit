#if canImport(AVFAudio) && (os(iOS) || os(macOS) || os(visionOS))
import Foundation
import OpenClawProtocol

// Gateway wiring for the relay transport, kept separate from the session so connection API
// changes (route leases, request overloads) stay local to this file.
extension RealtimeTalkRelayTransport {
    /// Builds a relay transport over any Talk-capable gateway connection.
    ///
    /// Requests fail with `CancellationError` once `isCurrent` reports that the originating
    /// connection was replaced, so relay cleanup never retargets a new connection.
    /// - Parameters:
    ///   - gateway: Gateway connection.
    ///   - isCurrent: Route-currency probe for the connection that owns the relay.
    /// - Returns: A transport for ``RealtimeTalkRelaySession``.
    public static func gateway(
        _ gateway: some TalkGatewayRequesting,
        isCurrent: @escaping @Sendable () async -> Bool = { true }) -> Self
    {
        Self(
            subscribeServerEvents: { bufferingNewest in
                await gateway.talkServerEvents(bufferingNewest: bufferingNewest)
            },
            request: { method, params, timeoutMs in
                guard await isCurrent() else { throw CancellationError() }
                let response = try await gateway.talkRequest(method: method, params: params, timeoutMs: timeoutMs)
                guard await isCurrent() else { throw CancellationError() }
                return response
            },
            isCurrent: isCurrent)
    }

    /// Builds a relay transport over a ``GatewayNodeSession`` (the upstream iOS `.ios(gateway:route:)` helper).
    /// - Parameters:
    ///   - session: Connected gateway session with the `operator.talk` scope.
    ///   - isCurrent: Route-currency probe; pass the session's route check when available.
    /// - Returns: A transport for ``RealtimeTalkRelaySession``.
    public static func gatewayNodeSession(
        _ session: GatewayNodeSession,
        isCurrent: @escaping @Sendable () async -> Bool = { true }) -> Self
    {
        .gateway(session, isCurrent: isCurrent)
    }
}
#endif
