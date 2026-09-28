import Foundation

/// Structured error reason used while gateway startup sidecars are still initializing
/// (upstream `packages/gateway-protocol/src/startup-unavailable.ts`).
public let GATEWAY_STARTUP_UNAVAILABLE_REASON = "startup-sidecars"

/// Default retry delay, in milliseconds, for startup-unavailable errors without a hint.
public let GATEWAY_STARTUP_RETRY_AFTER_MS = 500

/// Typed accessors over the upstream `ErrorShape` wire error.
public extension ErrorShape {
    /// Upstream error code, or `nil` for codes this SDK version does not know.
    var errorCode: ErrorCode? {
        ErrorCode(rawValue: self.code)
    }

    /// Structured details decoded as the upstream `GatewayErrorDetails` union.
    ///
    /// Returns `nil` when details are absent or use a discriminator this SDK version does not know.
    var typedDetails: GatewayErrorDetails? {
        guard let details = self.details else {
            return nil
        }
        return try? GatewayPayloadCodec.decode(GatewayErrorDetails.self, from: details)
    }

    /// Whether this is the retryable `UNAVAILABLE` error gateways return until startup sidecars are ready.
    var isStartupUnavailable: Bool {
        self.code == ErrorCode.unavailable.rawValue
            && self.retryable == true
            && self.details?.dictionaryValue?["reason"]?.stringValue == GATEWAY_STARTUP_UNAVAILABLE_REASON
    }

    /// Bounded retry delay for startup-unavailable errors (100...2000 ms), or `nil` for other errors.
    var startupRetryAfterMs: Int? {
        guard self.isStartupUnavailable else {
            return nil
        }
        return min(max(self.retryafterms ?? GATEWAY_STARTUP_RETRY_AFTER_MS, 100), 2_000)
    }
}
