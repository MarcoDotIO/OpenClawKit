import Foundation
import OSLog

extension GatewayNodeSession {
    static let defaultInvokeTimeoutMs = 30000
    static let maxInvokeTimeoutMs = Int(Int32.max)

    /// Runs one node invoke against its deadline.
    ///
    /// `timeoutMs` is clamped to `0...Int32.max`; `nil` uses 30 s and `0` disables the deadline.
    /// A timeout replies `UNAVAILABLE: node invoke timed out` without waiting for the device work,
    /// which may ignore cancellation. The deadline runs on the monotonic clock.
    static func invokeWithTimeout(
        request: BridgeInvokeRequest,
        timeoutMs: Int?,
        onInvoke: @escaping @Sendable (BridgeInvokeRequest) async -> BridgeInvokeResponse,
        onOperationSettled: (@Sendable () async -> Void)? = nil) async -> BridgeInvokeResponse
    {
        let timeoutLogger = Logger(subsystem: "ai.openclaw", category: "node.gateway")
        let timeout = timeoutMs.map { min(max(0, $0), Self.maxInvokeTimeoutMs) } ?? Self.defaultInvokeTimeoutMs
        guard timeout > 0 else {
            let response = await onInvoke(request)
            await onOperationSettled?()
            return response
        }

        // Keep the wrapper detached: this nonthrowing API historically lets the invoke/timeout
        // race settle even when its caller is cancelled.
        let response = await Task.detached {
            await (try? AsyncTimeout.withTimeoutMs(
                timeoutMs: timeout,
                onTimeout: {
                    timeoutLogger.info("node invoke timeout fired id=\(request.id, privacy: .public)")
                    return CancellationError()
                },
                operation: {
                    let response = await onInvoke(request)
                    await onOperationSettled?()
                    return response
                })) ?? BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(
                    code: .unavailable,
                    message: "node invoke timed out"))
        }.value
        timeoutLogger
            .info("node invoke race resolved id=\(request.id, privacy: .public) ok=\(response.ok, privacy: .public)")
        return response
    }
}
