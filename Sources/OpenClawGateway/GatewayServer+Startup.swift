import Foundation
import OpenClawProtocol

// Startup gating (upstream `server-methods.ts` + `packages/gateway-protocol/src/startup-unavailable.ts`):
// while hosted subsystems (stores, runtimes, sidecars) start, methods marked `startupGated` in the
// catalog answer the retryable `UNAVAILABLE` error with `details.reason == "startup-sidecars"`, so
// clients (GatewayClient, GatewayChannelActor) retry instead of failing.
extension GatewayServer {
    /// Marks startup as pending: gated methods answer the startup `UNAVAILABLE` error until
    /// ``completeStartup()``.
    /// - Parameter methods: Methods to gate; `nil` gates every method whose descriptor (catalog or
    ///   registration) sets `startupGated`.
    public func beginStartup(gating methods: Set<String>? = nil) {
        if let methods {
            self.startupGatedMethods = methods
            self.startupGatesEveryDescriptor = false
        } else {
            self.startupGatedMethods = []
            self.startupGatesEveryDescriptor = true
        }
    }

    /// Marks hosted subsystems ready; gated methods dispatch normally again.
    public func completeStartup() {
        self.startupGatedMethods = nil
        self.startupGatesEveryDescriptor = false
    }

    /// Whether startup is still pending.
    public func isStartupPending() -> Bool {
        self.startupGatedMethods != nil
    }

    /// Runs `body` with startup pending and completes startup afterwards (also when `body` throws).
    /// - Parameters:
    ///   - methods: Methods to gate (`nil` = catalog `startupGated` methods).
    ///   - body: Startup work (for example loading stores and attaching runtimes).
    /// - Throws: Rethrows `body`'s error.
    public func runStartup(gating methods: Set<String>? = nil, _ body: @Sendable () async throws -> Void) async rethrows {
        self.beginStartup(gating: methods)
        defer { self.completeStartup() }
        try await body()
    }

    /// The retryable startup `UNAVAILABLE` error for a method (upstream wording and details).
    /// - Parameter method: Wire method name.
    /// - Returns: The error.
    public static func startupUnavailableError(method: String) -> GatewayMethodError {
        GatewayMethodError.unavailable(
            "\(method) unavailable during gateway startup",
            retryable: true,
            retryAfterMs: GATEWAY_STARTUP_RETRY_AFTER_MS,
            details: AnyCodable([
                "reason": AnyCodable(GATEWAY_STARTUP_UNAVAILABLE_REASON),
                "method": AnyCodable(method),
            ])
        )
    }

    func startupGateError(method: String, descriptor: GatewayMethodDescriptor?) -> GatewayMethodError? {
        guard let gated = self.startupGatedMethods else { return nil }
        if gated.contains(method) || (self.startupGatesEveryDescriptor && descriptor?.startupGated == true) {
            return Self.startupUnavailableError(method: method)
        }
        return nil
    }
}
