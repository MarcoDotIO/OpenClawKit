import Foundation
import OpenClawProtocol

/// A route lease became stale before its request touched the channel.
///
/// Unlike a socket cancellation, this proves the payload was never dispatched.
public enum GatewayNodeSessionRequestError: Error, Sendable {
    /// The captured ``GatewayNodeSessionRoute`` changed before the request was sent.
    case routeChangedBeforeDispatch
}

/// Structured connect-error codes carried in gateway error `details.code`.
public enum GatewayConnectAuthDetailCode: String, Sendable {
    /// Auth is required.
    case authRequired = "AUTH_REQUIRED"
    /// The client is not authorized.
    case authUnauthorized = "AUTH_UNAUTHORIZED"
    /// The shared token does not match.
    case authTokenMismatch = "AUTH_TOKEN_MISMATCH"
    /// The bootstrap (setup-code) token is invalid or expired.
    case authBootstrapTokenInvalid = "AUTH_BOOTSTRAP_TOKEN_INVALID"
    /// The stored device token was rejected.
    case authDeviceTokenMismatch = "AUTH_DEVICE_TOKEN_MISMATCH"
    /// The device token is valid but the requested scopes need approval.
    case authScopeMismatch = "AUTH_SCOPE_MISMATCH"
    /// The gateway requires a token the client did not send.
    case authTokenMissing = "AUTH_TOKEN_MISSING"
    /// The gateway uses token auth but has no token configured.
    case authTokenNotConfigured = "AUTH_TOKEN_NOT_CONFIGURED"
    /// The gateway requires a password the client did not send.
    case authPasswordMissing = "AUTH_PASSWORD_MISSING"
    /// The password does not match.
    case authPasswordMismatch = "AUTH_PASSWORD_MISMATCH"
    /// The gateway uses password auth but has no password configured.
    case authPasswordNotConfigured = "AUTH_PASSWORD_NOT_CONFIGURED"
    /// Too many failed auth attempts.
    case authRateLimited = "AUTH_RATE_LIMITED"
    /// Tailscale identity headers were missing.
    case authTailscaleIdentityMissing = "AUTH_TAILSCALE_IDENTITY_MISSING"
    /// The Tailscale auth proxy is not configured.
    case authTailscaleProxyMissing = "AUTH_TAILSCALE_PROXY_MISSING"
    /// The Tailscale whois lookup failed.
    case authTailscaleWhoisFailed = "AUTH_TAILSCALE_WHOIS_FAILED"
    /// The forwarded Tailscale identity did not match.
    case authTailscaleIdentityMismatch = "AUTH_TAILSCALE_IDENTITY_MISMATCH"
    /// A trusted identity header was required but missing.
    case authIdentityHeaderRequired = "AUTH_IDENTITY_HEADER_REQUIRED"
    /// A verified user identity is required.
    case authVerifiedUserRequired = "AUTH_VERIFIED_USER_REQUIRED"
    /// The authenticated user profile is unavailable.
    case authenticatedProfileUnavailable = "AUTHENTICATED_PROFILE_UNAVAILABLE"
    /// The Control UI build does not match the gateway.
    case controlUiBuildMismatch = "CONTROL_UI_BUILD_MISMATCH"
    /// The Control UI origin is not allowed.
    case controlUiOriginNotAllowed = "CONTROL_UI_ORIGIN_NOT_ALLOWED"
    /// Pairing approval is required.
    case pairingRequired = "PAIRING_REQUIRED"
    /// The client and gateway protocol ranges do not overlap.
    case protocolMismatch = "PROTOCOL_MISMATCH"
    /// The Control UI must present a device identity.
    case controlUiDeviceIdentityRequired = "CONTROL_UI_DEVICE_IDENTITY_REQUIRED"
    /// A device identity is required.
    case deviceIdentityRequired = "DEVICE_IDENTITY_REQUIRED"
    /// The device auth payload is invalid.
    case deviceAuthInvalid = "DEVICE_AUTH_INVALID"
    /// The device id does not match the presented key.
    case deviceAuthDeviceIdMismatch = "DEVICE_AUTH_DEVICE_ID_MISMATCH"
    /// The device signature is too old.
    case deviceAuthSignatureExpired = "DEVICE_AUTH_SIGNATURE_EXPIRED"
    /// The challenge nonce was missing.
    case deviceAuthNonceRequired = "DEVICE_AUTH_NONCE_REQUIRED"
    /// The challenge nonce did not match.
    case deviceAuthNonceMismatch = "DEVICE_AUTH_NONCE_MISMATCH"
    /// The device signature did not verify.
    case deviceAuthSignatureInvalid = "DEVICE_AUTH_SIGNATURE_INVALID"
    /// The device public key is invalid.
    case deviceAuthPublicKeyInvalid = "DEVICE_AUTH_PUBLIC_KEY_INVALID"
    /// The client version is not accepted.
    case clientVersionMismatch = "CLIENT_VERSION_MISMATCH"
}

/// Suggested client-side recovery action for structured connect errors.
public enum GatewayConnectRecoveryNextStep: String, Sendable {
    /// Retry once with the stored device token.
    case retryWithDeviceToken = "retry_with_device_token"
    /// The gateway auth configuration must change.
    case updateAuthConfiguration = "update_auth_configuration"
    /// The client credentials must change.
    case updateAuthCredentials = "update_auth_credentials"
    /// Wait, then retry.
    case waitThenRetry = "wait_then_retry"
    /// Review the gateway auth configuration.
    case reviewAuthConfiguration = "review_auth_configuration"
}

/// Structured websocket connect-auth rejection surfaced before the channel is usable.
public struct GatewayConnectAuthError: LocalizedError, Sendable {
    /// Gateway message (trimmed; defaults to "gateway connect failed").
    public let message: String
    /// Raw `details.code`.
    public let detailCodeRaw: String?
    /// Raw `details.recommendedNextStep`.
    public let recommendedNextStepRaw: String?
    /// Whether the gateway allows one retry with the stored device token.
    public let canRetryWithDeviceToken: Bool
    /// Pairing request id (`details.requestId`).
    public let requestId: String?
    /// Detail reason (`details.reason`, for example `scope-upgrade`).
    public let detailsReason: String?
    /// Gateway-supplied owner hint (`details.owner`).
    public let ownerRaw: String?
    /// Gateway-supplied title override (`details.title`).
    public let titleOverride: String?
    /// Gateway-supplied user message override (`details.userMessage`).
    public let userMessageOverride: String?
    /// Gateway-supplied action label (`details.actionLabel`).
    public let actionLabel: String?
    /// Gateway-supplied action command (`details.actionCommand`).
    public let actionCommand: String?
    /// Gateway-supplied docs URL (`details.docsUrl`).
    public let docsURLString: String?
    /// Gateway-supplied retryable override (`details.retryable`).
    public let retryableOverride: Bool?
    /// Gateway-supplied pause-reconnect override (`details.pauseReconnect`).
    public let pauseReconnectOverride: Bool?
    /// Client minimum protocol echoed by protocol-mismatch rejections.
    public let clientMinProtocol: Int?
    /// Client maximum protocol echoed by protocol-mismatch rejections.
    public let clientMaxProtocol: Int?
    /// Protocol the gateway speaks.
    public let expectedProtocol: Int?
    /// Lowest protocol the gateway still answers probes with.
    public let minimumProbeProtocol: Int?

    /// Creates a connect-auth error from raw detail values (every optional string is trimmed-or-nil).
    public init(
        message: String,
        detailCodeRaw: String?,
        canRetryWithDeviceToken: Bool,
        recommendedNextStepRaw: String? = nil,
        requestId: String? = nil,
        detailsReason: String? = nil,
        ownerRaw: String? = nil,
        titleOverride: String? = nil,
        userMessageOverride: String? = nil,
        actionLabel: String? = nil,
        actionCommand: String? = nil,
        docsURLString: String? = nil,
        retryableOverride: Bool? = nil,
        pauseReconnectOverride: Bool? = nil,
        clientMinProtocol: Int? = nil,
        clientMaxProtocol: Int? = nil,
        expectedProtocol: Int? = nil,
        minimumProbeProtocol: Int? = nil)
    {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        self.message = trimmedMessage.isEmpty ? "gateway connect failed" : trimmedMessage
        self.detailCodeRaw = Self.trimmedOrNil(detailCodeRaw)
        self.canRetryWithDeviceToken = canRetryWithDeviceToken
        self.recommendedNextStepRaw = Self.trimmedOrNil(recommendedNextStepRaw)
        self.requestId = Self.trimmedOrNil(requestId)
        self.detailsReason = Self.trimmedOrNil(detailsReason)
        self.ownerRaw = Self.trimmedOrNil(ownerRaw)
        self.titleOverride = Self.trimmedOrNil(titleOverride)
        self.userMessageOverride = Self.trimmedOrNil(userMessageOverride)
        self.actionLabel = Self.trimmedOrNil(actionLabel)
        self.actionCommand = Self.trimmedOrNil(actionCommand)
        self.docsURLString = Self.trimmedOrNil(docsURLString)
        self.retryableOverride = retryableOverride
        self.pauseReconnectOverride = pauseReconnectOverride
        self.clientMinProtocol = clientMinProtocol
        self.clientMaxProtocol = clientMaxProtocol
        self.expectedProtocol = expectedProtocol
        self.minimumProbeProtocol = minimumProbeProtocol
    }

    /// Creates a connect-auth error; `detailCode`/`recommendedNextStep` spelling of the raw initializer.
    public init(
        message: String,
        detailCode: String?,
        canRetryWithDeviceToken: Bool,
        recommendedNextStep: String? = nil,
        requestId: String? = nil,
        detailsReason: String? = nil,
        ownerRaw: String? = nil,
        titleOverride: String? = nil,
        userMessageOverride: String? = nil,
        actionLabel: String? = nil,
        actionCommand: String? = nil,
        docsURLString: String? = nil,
        retryableOverride: Bool? = nil,
        pauseReconnectOverride: Bool? = nil,
        clientMinProtocol: Int? = nil,
        clientMaxProtocol: Int? = nil,
        expectedProtocol: Int? = nil,
        minimumProbeProtocol: Int? = nil)
    {
        self.init(
            message: message,
            detailCodeRaw: detailCode,
            canRetryWithDeviceToken: canRetryWithDeviceToken,
            recommendedNextStepRaw: recommendedNextStep,
            requestId: requestId,
            detailsReason: detailsReason,
            ownerRaw: ownerRaw,
            titleOverride: titleOverride,
            userMessageOverride: userMessageOverride,
            actionLabel: actionLabel,
            actionCommand: actionCommand,
            docsURLString: docsURLString,
            retryableOverride: retryableOverride,
            pauseReconnectOverride: pauseReconnectOverride,
            clientMinProtocol: clientMinProtocol,
            clientMaxProtocol: clientMaxProtocol,
            expectedProtocol: expectedProtocol,
            minimumProbeProtocol: minimumProbeProtocol)
    }

    /// Parses a connect rejection from its flattened error details.
    init(message: String, details: [String: AnyCodable]) {
        self.init(
            message: message,
            detailCodeRaw: details["code"]?.stringValue,
            canRetryWithDeviceToken: details["canRetryWithDeviceToken"]?.boolValue ?? false,
            recommendedNextStepRaw: details["recommendedNextStep"]?.stringValue,
            requestId: details["requestId"]?.stringValue,
            detailsReason: details["reason"]?.stringValue,
            ownerRaw: details["owner"]?.stringValue,
            titleOverride: details["title"]?.stringValue,
            userMessageOverride: details["userMessage"]?.stringValue,
            actionLabel: details["actionLabel"]?.stringValue,
            actionCommand: details["actionCommand"]?.stringValue,
            docsURLString: details["docsUrl"]?.stringValue,
            retryableOverride: details["retryable"]?.boolValue,
            pauseReconnectOverride: details["pauseReconnect"]?.boolValue,
            clientMinProtocol: gatewayIntValue(details["clientMinProtocol"]),
            clientMaxProtocol: gatewayIntValue(details["clientMaxProtocol"]),
            expectedProtocol: gatewayIntValue(details["expectedProtocol"]),
            minimumProbeProtocol: gatewayIntValue(details["minimumProbeProtocol"]))
    }

    private static func trimmedOrNil(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Raw detail code (alias of ``detailCodeRaw``).
    public var detailCode: String? {
        self.detailCodeRaw
    }

    /// Raw recommended next step (alias of ``recommendedNextStepRaw``).
    public var recommendedNextStepCode: String? {
        self.recommendedNextStepRaw
    }

    /// Typed detail code, or `nil` for codes this SDK version does not know.
    public var detail: GatewayConnectAuthDetailCode? {
        guard let detailCodeRaw else { return nil }
        return GatewayConnectAuthDetailCode(rawValue: detailCodeRaw)
    }

    /// Typed recommended next step.
    public var recommendedNextStep: GatewayConnectRecoveryNextStep? {
        guard let recommendedNextStepRaw else { return nil }
        return GatewayConnectRecoveryNextStep(rawValue: recommendedNextStepRaw)
    }

    /// Gateway message.
    public var errorDescription: String? {
        self.message
    }

    /// Whether this rejection is a protocol mismatch for the given client range.
    ///
    /// Published protocol-3 gateways only send `INVALID_REQUEST` plus `expectedProtocol`; compare
    /// the advertised role range because node clients still accept protocol 3.
    public func isProtocolMismatch(supportedProtocols: ClosedRange<Int>) -> Bool {
        self.detail == .protocolMismatch ||
            (self.detailCode == "INVALID_REQUEST" &&
                self.expectedProtocol.map { !supportedProtocols.contains($0) } == true)
    }

    /// Which side needs an update for a protocol mismatch, when the echoed ranges say so.
    public var protocolUpdateOwner: GatewayProtocolUpdateOwner? {
        guard let expected = self.expectedProtocol else { return nil }
        if let clientMax = self.clientMaxProtocol, clientMax < expected { return .client }
        if let clientMin = self.clientMinProtocol, clientMin > expected { return .gateway }
        return nil
    }

    /// Whether automatic reconnect must stop until the user or host changes credentials.
    public var isNonRecoverable: Bool {
        switch self.detail {
        case .authTokenMissing,
             .authBootstrapTokenInvalid,
             .authTokenNotConfigured,
             .authPasswordMissing,
             .authPasswordMismatch,
             .authPasswordNotConfigured,
             .authRateLimited,
             .authScopeMismatch,
             .authVerifiedUserRequired,
             .pairingRequired,
             .protocolMismatch,
             .controlUiDeviceIdentityRequired,
             .deviceIdentityRequired:
            true
        default:
            false
        }
    }
}

/// Side that must update after a protocol mismatch.
public enum GatewayProtocolUpdateOwner: String, Sendable {
    /// This client is older than the gateway.
    case client
    /// The gateway is older than this client.
    case gateway
}

/// Structured `MISSING_SCOPE` error details.
public struct GatewayMissingScopeErrorDetails: Equatable, Sendable {
    /// Scope the request lacked.
    public let missingScope: String
    /// Scopes that would satisfy the request.
    public let requiredScopes: [String]

    /// Creates missing-scope details.
    public init(missingScope: String, requiredScopes: [String]) {
        self.missingScope = missingScope
        self.requiredScopes = requiredScopes
    }
}

/// Whether a request rejected for an expected-profile mismatch may already have run.
public enum GatewayProfileBindingExecution: String, Sendable {
    /// The gateway rejected the request before executing it; retrying is safe.
    case notStarted = "not_started"
    /// The request may have executed. Keep the original idempotency key and reconcile earlier
    /// acknowledgements before retrying.
    case mayHaveExecuted = "may_have_executed"
}

/// Client-side request errors raised before a frame is sent.
public enum GatewayRequestError: Error, Sendable, Equatable, LocalizedError {
    /// The caller asked for profile binding but hello-ok does not advertise `profile-binding-v1`.
    case profileBindingUnsupported(method: String)
    /// The expected profile id is not an opaque 1-128 character string.
    case invalidExpectedProfileID
    /// The encoded frame exceeds the gateway's advertised `policy.maxPayload`.
    case payloadTooLarge(method: String, bytes: Int, maximumBytes: Int)

    /// Human-readable description.
    public var errorDescription: String? {
        switch self {
        case let .profileBindingUnsupported(method):
            "\(method): gateway does not support profile binding"
        case .invalidExpectedProfileID:
            "expected profile id must be 1-128 characters"
        case let .payloadTooLarge(method, bytes, maximumBytes):
            "\(method): request frame of \(bytes) bytes exceeds the gateway limit of \(maximumBytes) bytes"
        }
    }
}

/// Structured error surfaced when the gateway responds with `{ ok: false }`.
public struct GatewayResponseError: LocalizedError, @unchecked Sendable {
    /// Method that failed.
    public let method: String
    /// Error code (defaults to `GATEWAY_ERROR`).
    public let code: String
    /// Error message (defaults to "gateway error").
    public let message: String
    /// Flattened error details (nested details plus code/message/retryable/retryAfterMs).
    public let details: [String: AnyCodable]

    /// Creates a response error.
    public init(method: String, code: String?, message: String?, details: [String: AnyCodable]?) {
        self.method = method
        let trimmedCode = code?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.code = trimmedCode.isEmpty ? "GATEWAY_ERROR" : trimmedCode
        let trimmedMessage = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.message = trimmedMessage.isEmpty ? "gateway error" : trimmedMessage
        self.details = details ?? [:]
    }

    /// Trimmed `details.reason`.
    public var detailsReason: String? {
        let trimmed = self.details["reason"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Structured `MISSING_SCOPE` details, when every field is well formed.
    public var missingScopeDetails: GatewayMissingScopeErrorDetails? {
        guard self.details["code"]?.stringValue == "MISSING_SCOPE" else { return nil }
        let missingScope = self.details["missingScope"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !missingScope.isEmpty, let values = self.details["requiredScopes"]?.arrayValue else {
            return nil
        }
        let requiredScopes = values.compactMap { value -> String? in
            let scope = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return scope.isEmpty ? nil : scope
        }
        guard !requiredScopes.isEmpty, requiredScopes.count == values.count else { return nil }
        return GatewayMissingScopeErrorDetails(
            missingScope: missingScope,
            requiredScopes: requiredScopes)
    }

    /// Structured missing scope with a fallback for gateways predating error details.
    public var missingScope: String? {
        if let structured = self.missingScopeDetails { return structured.missingScope }
        guard self.code == "FORBIDDEN" || self.code == "INVALID_REQUEST" else { return nil }
        guard let marker = self.message.range(of: "missing scope:", options: .caseInsensitive) else {
            return nil
        }
        let suffix = self.message[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return suffix.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
    }

    /// Whether the request failed for authorization (missing scope or unauthorized role).
    public var isAuthorizationFailure: Bool {
        if self.missingScope != nil { return true }
        return self.code == "INVALID_REQUEST" &&
            self.message.localizedCaseInsensitiveContains("unauthorized role")
    }

    /// Execution state of an `EXPECTED_PROFILE_MISMATCH` rejection, or `nil` for other errors.
    ///
    /// A missing or unknown `details.execution` is treated as ``GatewayProfileBindingExecution/mayHaveExecuted``.
    public var expectedProfileMismatch: GatewayProfileBindingExecution? {
        guard self.detailsReason == "EXPECTED_PROFILE_MISMATCH" else { return nil }
        let raw = self.details["execution"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return GatewayProfileBindingExecution(rawValue: raw) ?? .mayHaveExecuted
    }

    /// Whether this is the retryable startup `UNAVAILABLE` error (`details.reason == "startup-sidecars"`).
    public var isStartupUnavailable: Bool {
        self.code == ErrorCode.unavailable.rawValue &&
            self.details["retryable"]?.boolValue == true &&
            self.detailsReason == GATEWAY_STARTUP_UNAVAILABLE_REASON
    }

    /// Bounded retry delay for startup-unavailable errors (100...2000 ms, default 500).
    public var startupRetryAfterMs: Int? {
        guard self.isStartupUnavailable else { return nil }
        let hinted = gatewayIntValue(self.details["retryAfterMs"]) ?? GATEWAY_STARTUP_RETRY_AFTER_MS
        return min(max(hinted, 100), 2000)
    }

    /// Method-prefixed description.
    public var errorDescription: String? {
        if self.code == "GATEWAY_ERROR" { return "\(self.method): \(self.message)" }
        return "\(self.method): [\(self.code)] \(self.message)"
    }
}

/// Payload decode failure for a gateway method.
public struct GatewayDecodingError: LocalizedError, Sendable {
    /// Method whose payload failed to decode.
    public let method: String
    /// Failure message.
    public let message: String

    /// Creates a decoding error.
    public init(method: String, message: String) {
        self.method = method
        self.message = message
    }

    /// Method-prefixed description.
    public var errorDescription: String? {
        "\(self.method): \(self.message)"
    }
}
