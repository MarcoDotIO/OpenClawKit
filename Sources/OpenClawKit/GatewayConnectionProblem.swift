import Foundation

/// Structured, user-facing guidance for a failed gateway login or connect.
///
/// Map errors with ``GatewayConnectionProblemMapper/map(error:preserving:)`` (or ``from(_:)``).
/// Strings are English defaults; the `*Presentation` values carry localization keys so apps
/// can resolve them against their own string tables with ``PresentationText/resolvedString(bundle:)``.
public struct GatewayConnectionProblem: Equatable, Sendable {
    /// Localizable presentation of a string.
    public enum PresentationText: Equatable, Sendable {
        /// A localization key whose English text is the key itself.
        case localized(String)
        /// A localized format key (`%@` placeholders) plus its arguments.
        case localizedFormat(String, [String])
        /// Text supplied by the gateway, shown as-is.
        case verbatim(String)

        /// Resolves the text against a bundle's `Localizable` table, falling back to the English key.
        /// - Parameter bundle: Bundle holding translations; defaults to the OpenClawKit resource bundle.
        /// - Returns: Localized text.
        public func resolvedString(bundle: Bundle = OpenClawKitResources.bundle) -> String {
            switch self {
            case let .localized(key):
                return bundle.localizedString(forKey: key, value: key, table: nil)
            case let .localizedFormat(key, arguments):
                let format = bundle.localizedString(forKey: key, value: key, table: nil)
                return String(format: format, arguments: arguments.map { $0 as CVarArg })
            case let .verbatim(text):
                return text
            }
        }
    }

    /// Problem classification.
    public enum Kind: String, Equatable, Sendable {
        /// The gateway requires a token the client did not send.
        case gatewayAuthTokenMissing
        /// The shared token does not match.
        case gatewayAuthTokenMismatch
        /// Token auth is enabled but no token is configured on the gateway.
        case gatewayAuthTokenNotConfigured
        /// The gateway requires a password the client did not send.
        case gatewayAuthPasswordMissing
        /// The password does not match.
        case gatewayAuthPasswordMismatch
        /// Password auth is enabled but no password is configured on the gateway.
        case gatewayAuthPasswordNotConfigured
        /// The setup code (bootstrap token) expired.
        case bootstrapTokenInvalid
        /// The stored device token was rejected.
        case deviceTokenMismatch
        /// The device token is valid but new scopes need approval.
        case deviceTokenScopeMismatch
        /// The device must be approved.
        case pairingRequired
        /// A new role needs approval.
        case pairingRoleUpgradeRequired
        /// New scopes need approval.
        case pairingScopeUpgradeRequired
        /// Changed identity metadata needs re-approval.
        case pairingMetadataUpgradeRequired
        /// Client and gateway protocol versions are incompatible.
        case protocolMismatch
        /// A signed device identity is required.
        case deviceIdentityRequired
        /// The device signature expired.
        case deviceSignatureExpired
        /// The challenge nonce was missing.
        case deviceNonceRequired
        /// The challenge nonce was stale or mismatched.
        case deviceNonceMismatch
        /// The device signature did not verify.
        case deviceSignatureInvalid
        /// The device public key did not verify.
        case devicePublicKeyInvalid
        /// The device id did not match its key.
        case deviceIdMismatch
        /// Tailscale identity headers were missing.
        case tailscaleIdentityMissing
        /// The Tailscale auth proxy is missing.
        case tailscaleProxyMissing
        /// Tailscale whois failed.
        case tailscaleWhoisFailed
        /// The Tailscale identity did not match.
        case tailscaleIdentityMismatch
        /// Too many failed auth attempts.
        case authRateLimited
        /// The connection timed out.
        case timeout
        /// The gateway refused the connection.
        case connectionRefused
        /// The gateway is not reachable.
        case reachabilityFailed
        /// The WebSocket was interrupted before setup completed.
        case websocketCancelled
        /// The TLS certificate no longer matches the stored pin.
        case tlsPinMismatch
        /// The TLS certificate is not trusted.
        case tlsCertificateUntrusted
        /// The TLS certificate could not be read or its pin saved.
        case tlsCertificateUnavailable
        /// Any other failure.
        case unknown
    }

    /// Who has to act to resolve the problem.
    public enum Owner: String, Equatable, Sendable {
        /// The gateway operator.
        case gateway
        /// This client device. The raw value `iphone` is kept for wire parity with upstream;
        /// prefer ``clientDevice`` in SDK code.
        case iphone
        /// Both sides.
        case both
        /// The network path.
        case network
        /// Unknown.
        case unknown

        /// This client device (alias of ``iphone``).
        public static var clientDevice: Owner {
            .iphone
        }
    }

    /// Problem classification.
    public let kind: Kind
    /// Who has to act.
    public let owner: Owner
    /// English title.
    public let title: String
    /// English message.
    public let message: String
    /// English action label.
    public let actionLabel: String?
    /// Localizable title.
    public let titlePresentation: PresentationText
    /// Localizable message.
    public let messagePresentation: PresentationText
    /// Localizable action label.
    public let actionLabelPresentation: PresentationText?
    /// Command the gateway operator can run (for example `openclaw devices approve <id>`).
    public let actionCommand: String?
    /// Documentation link.
    public let docsURL: URL?
    /// Pairing or protocol request id.
    public let requestId: String?
    /// Whether retrying without changes can succeed.
    public let retryable: Bool
    /// Whether automatic reconnect should pause.
    public let pauseReconnect: Bool
    /// Technical details joined with " · ".
    public let technicalDetails: String?
    /// TLS pin store key for pin problems.
    public let tlsStoreKey: String?
    /// Expected TLS fingerprint for pin problems.
    public let tlsExpectedFingerprint: String?
    /// Observed TLS fingerprint for pin problems.
    public let tlsObservedFingerprint: String?
    /// Whether system trust accepted the presented certificate.
    public let tlsSystemTrustOk: Bool

    /// Creates a problem value; presentations default to the English strings.
    public init(
        kind: Kind,
        owner: Owner,
        title: String,
        message: String,
        actionLabel: String? = nil,
        titlePresentation: PresentationText? = nil,
        messagePresentation: PresentationText? = nil,
        actionLabelPresentation: PresentationText? = nil,
        actionCommand: String? = nil,
        docsURL: URL? = nil,
        requestId: String? = nil,
        retryable: Bool,
        pauseReconnect: Bool,
        technicalDetails: String? = nil,
        tlsStoreKey: String? = nil,
        tlsExpectedFingerprint: String? = nil,
        tlsObservedFingerprint: String? = nil,
        tlsSystemTrustOk: Bool = false)
    {
        self.kind = kind
        self.owner = owner
        self.title = title
        self.message = message
        self.actionLabel = Self.trimmedOrNil(actionLabel)
        self.titlePresentation = titlePresentation ?? .localized(title)
        self.messagePresentation = messagePresentation ?? .localized(message)
        self.actionLabelPresentation = actionLabelPresentation
            ?? self.actionLabel.map(PresentationText.localized)
        self.actionCommand = Self.trimmedOrNil(actionCommand)
        self.docsURL = docsURL
        self.requestId = Self.trimmedOrNil(requestId)
        self.retryable = retryable
        self.pauseReconnect = pauseReconnect
        self.technicalDetails = Self.trimmedOrNil(technicalDetails)
        self.tlsStoreKey = Self.trimmedOrNil(tlsStoreKey)
        self.tlsExpectedFingerprint = Self.trimmedOrNil(tlsExpectedFingerprint)
        self.tlsObservedFingerprint = Self.trimmedOrNil(tlsObservedFingerprint)
        self.tlsSystemTrustOk = tlsSystemTrustOk
    }

    /// Maps any gateway error to guidance (see ``GatewayConnectionProblemMapper``).
    /// - Returns: `nil` for errors that carry no actionable guidance.
    public static func from(_ error: Error) -> GatewayConnectionProblem? {
        GatewayConnectionProblemMapper.map(error: error)
    }

    /// Whether the gateway operator must approve this device.
    public var needsPairingApproval: Bool {
        switch self.kind {
        case .pairingRequired, .pairingRoleUpgradeRequired, .pairingScopeUpgradeRequired,
             .pairingMetadataUpgradeRequired, .deviceTokenScopeMismatch:
            true
        default:
            false
        }
    }

    /// Whether the client's saved credentials must change.
    public var needsCredentialUpdate: Bool {
        switch self.kind {
        case .gatewayAuthTokenMissing,
             .gatewayAuthTokenMismatch,
             .gatewayAuthTokenNotConfigured,
             .gatewayAuthPasswordMissing,
             .gatewayAuthPasswordMismatch,
             .gatewayAuthPasswordNotConfigured,
             .bootstrapTokenInvalid,
             .deviceTokenMismatch:
            true
        default:
            false
        }
    }

    /// Whether re-running onboarding is the likely fix.
    public var suggestsOnboardingReset: Bool {
        self.kind == .gatewayAuthTokenMismatch
    }

    /// Title plus the request id for pairing and protocol problems.
    public var statusText: String {
        switch self.kind {
        case .pairingRequired, .pairingRoleUpgradeRequired, .pairingScopeUpgradeRequired,
             .pairingMetadataUpgradeRequired, .protocolMismatch:
            if let requestId {
                return "\(self.title) (request ID: \(requestId))"
            }
            return self.title
        default:
            return self.title
        }
    }

    /// Whether the app may offer to trust a rotated, system-trusted certificate.
    public var canTrustRotatedCertificate: Bool {
        self.kind == .tlsPinMismatch
            && self.tlsSystemTrustOk
            && self.tlsStoreKey != nil
            && self.tlsObservedFingerprint != nil
    }

    private static func trimmedOrNil(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Maps gateway connect, response, TLS, and transport errors to ``GatewayConnectionProblem``.
public enum GatewayConnectionProblemMapper {
    private struct AuthProblemDefaults {
        let kind: GatewayConnectionProblem.Kind
        let owner: GatewayConnectionProblem.Owner
        let title: String
        let message: String
        let actionLabel: String?
        let actionCommand: String?
        let docsURLString: String?
        let retryable: Bool
        let pauseReconnect: Bool
    }

    private static let authenticationDocs = "https://docs.openclaw.ai/gateway/authentication"
    private static let pairingDocs = "https://docs.openclaw.ai/gateway/pairing"
    private static let troubleshootingDocs = "https://docs.openclaw.ai/gateway/troubleshooting"
    private static let tailscaleDocs = "https://docs.openclaw.ai/gateway/tailscale"
    private static let iosDocs = "https://docs.openclaw.ai/platforms/ios"

    /// Maps an error, keeping a more specific previous problem over a generic interruption.
    /// - Parameters:
    ///   - error: Connect or request error.
    ///   - previousProblem: Problem currently shown, if any.
    /// - Returns: The problem to show, or `nil` when the error carries no guidance.
    public static func map(
        error: Error,
        preserving previousProblem: GatewayConnectionProblem? = nil) -> GatewayConnectionProblem?
    {
        guard let nextProblem = self.rawMap(error) else {
            return nil
        }
        guard let previousProblem else {
            return nextProblem
        }
        if self.shouldPreserve(previousProblem: previousProblem, over: nextProblem) {
            return previousProblem
        }
        return nextProblem
    }

    /// Whether `previousProblem` should stay visible instead of `nextProblem`.
    public static func shouldPreserve(
        previousProblem: GatewayConnectionProblem,
        over nextProblem: GatewayConnectionProblem) -> Bool
    {
        if nextProblem.kind == .websocketCancelled {
            return previousProblem.pauseReconnect || previousProblem.requestId != nil
        }
        return false
    }

    /// Whether `previousProblem` should stay visible after a disconnect with `reason`.
    public static func shouldPreserve(
        previousProblem: GatewayConnectionProblem,
        overDisconnectReason reason: String) -> Bool
    {
        let normalized = reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        if normalized.contains("cancelled") || normalized.contains("canceled") {
            return previousProblem.pauseReconnect || previousProblem.requestId != nil
        }
        return false
    }

    private static func rawMap(_ error: Error) -> GatewayConnectionProblem? {
        if let authError = error as? GatewayConnectAuthError {
            return self.map(authError)
        }
        if let responseError = error as? GatewayResponseError {
            return self.map(responseError)
        }
        if let tlsError = error as? GatewayTLSValidationError {
            return self.map(tlsError)
        }
        return self.mapTransportError(error)
    }

    private static func map(_ authError: GatewayConnectAuthError) -> GatewayConnectionProblem {
        switch authError.detail {
        case .authTokenMissing,
             .authTokenMismatch,
             .authTokenNotConfigured,
             .authPasswordMissing,
             .authPasswordMismatch,
             .authPasswordNotConfigured:
            self.gatewayCredentialProblem(for: authError)
        case .authBootstrapTokenInvalid, .authDeviceTokenMismatch, .authScopeMismatch:
            self.deviceCredentialProblem(for: authError)
        case .pairingRequired:
            self.pairingProblem(for: authError)
        case .protocolMismatch:
            self.protocolMismatchProblem(for: authError)
        case .controlUiDeviceIdentityRequired,
             .deviceIdentityRequired,
             .deviceAuthSignatureExpired,
             .deviceAuthNonceRequired,
             .deviceAuthNonceMismatch,
             .deviceAuthSignatureInvalid,
             .deviceAuthInvalid,
             .deviceAuthPublicKeyInvalid,
             .deviceAuthDeviceIdMismatch:
            self.deviceIdentityProblem(for: authError)
        case .authTailscaleIdentityMissing:
            self.problem(
                .init(
                    kind: .tailscaleIdentityMissing,
                    owner: .network,
                    title: "Tailscale identity check failed",
                    message: "This connection expected Tailscale identity headers, but they were not available.",
                    actionLabel: "Turn on Tailscale",
                    actionCommand: nil,
                    docsURLString: self.tailscaleDocs,
                    retryable: false,
                    pauseReconnect: true),
                authError: authError)
        case .authTailscaleProxyMissing:
            self.problem(
                .init(
                    kind: .tailscaleProxyMissing,
                    owner: .network,
                    title: "Tailscale identity check failed",
                    message: "The gateway expected a Tailscale auth proxy, but it was not configured.",
                    actionLabel: "Review Tailscale setup",
                    actionCommand: nil,
                    docsURLString: self.tailscaleDocs,
                    retryable: false,
                    pauseReconnect: true),
                authError: authError)
        case .authTailscaleWhoisFailed:
            self.problem(
                .init(
                    kind: .tailscaleWhoisFailed,
                    owner: .network,
                    title: "Tailscale identity check failed",
                    message: "The gateway could not verify this Tailscale client identity.",
                    actionLabel: "Review Tailscale setup",
                    actionCommand: nil,
                    docsURLString: self.tailscaleDocs,
                    retryable: false,
                    pauseReconnect: true),
                authError: authError)
        case .authTailscaleIdentityMismatch:
            self.problem(
                .init(
                    kind: .tailscaleIdentityMismatch,
                    owner: .network,
                    title: "Tailscale identity check failed",
                    message: "The forwarded Tailscale identity did not match the verified identity.",
                    actionLabel: "Review Tailscale setup",
                    actionCommand: nil,
                    docsURLString: self.tailscaleDocs,
                    retryable: false,
                    pauseReconnect: true),
                authError: authError)
        case .authRateLimited:
            self.problem(
                .init(
                    kind: .authRateLimited,
                    owner: .gateway,
                    title: "Too many failed attempts",
                    message: "The gateway is temporarily refusing new auth attempts after repeated failures.",
                    actionLabel: "Wait and retry",
                    actionCommand: nil,
                    docsURLString: self.troubleshootingDocs,
                    retryable: false,
                    pauseReconnect: true),
                authError: authError)
        case .authRequired, .authUnauthorized, .authVerifiedUserRequired, .authIdentityHeaderRequired,
             .authenticatedProfileUnavailable, .controlUiBuildMismatch, .controlUiOriginNotAllowed,
             .clientVersionMismatch, .none:
            self.genericRejection(for: authError)
        }
    }

    private static func genericRejection(for authError: GatewayConnectAuthError) -> GatewayConnectionProblem {
        self.problem(
            .init(
                kind: .unknown,
                owner: .unknown,
                title: "Gateway rejected the connection",
                message: authError.message,
                actionLabel: nil,
                actionCommand: nil,
                docsURLString: nil,
                retryable: false,
                pauseReconnect: authError.isNonRecoverable),
            authError: authError)
    }

    private static func gatewayCredentialProblem(
        for authError: GatewayConnectAuthError) -> GatewayConnectionProblem
    {
        switch authError.detail {
        case .authTokenMissing:
            self.problem(
                .init(
                    kind: .gatewayAuthTokenMissing,
                    owner: .both,
                    title: "Gateway token required",
                    message: "This gateway requires an auth token, but this device did not send one.",
                    actionLabel: "Open Settings",
                    actionCommand: nil,
                    docsURLString: self.authenticationDocs,
                    retryable: false,
                    pauseReconnect: true),
                authError: authError)
        case .authTokenMismatch:
            self.problem(
                .init(
                    kind: .gatewayAuthTokenMismatch,
                    owner: .both,
                    title: "Gateway token is out of date",
                    message: "The token on this device does not match the gateway token.",
                    actionLabel: authError.canRetryWithDeviceToken ? "Retry once" : "Update gateway token",
                    actionCommand: nil,
                    docsURLString: self.authenticationDocs,
                    retryable: authError.canRetryWithDeviceToken,
                    pauseReconnect: !authError.canRetryWithDeviceToken),
                authError: authError)
        case .authTokenNotConfigured:
            self.problem(
                .init(
                    kind: .gatewayAuthTokenNotConfigured,
                    owner: .gateway,
                    title: "Gateway token is not configured",
                    message: "This gateway is set to token auth, but no gateway token is configured on the gateway.",
                    actionLabel: "Fix on gateway",
                    actionCommand: "openclaw config set gateway.auth.token <new-token>",
                    docsURLString: self.authenticationDocs,
                    retryable: false,
                    pauseReconnect: true),
                authError: authError)
        case .authPasswordMissing:
            self.problem(
                .init(
                    kind: .gatewayAuthPasswordMissing,
                    owner: .both,
                    title: "Gateway password required",
                    message: "This gateway requires a password, but this device did not send one.",
                    actionLabel: "Open Settings",
                    actionCommand: nil,
                    docsURLString: self.authenticationDocs,
                    retryable: false,
                    pauseReconnect: true),
                authError: authError)
        case .authPasswordMismatch:
            self.problem(
                .init(
                    kind: .gatewayAuthPasswordMismatch,
                    owner: .both,
                    title: "Gateway password is out of date",
                    message: "The saved password on this device does not match the gateway password.",
                    actionLabel: "Update password",
                    actionCommand: nil,
                    docsURLString: self.authenticationDocs,
                    retryable: false,
                    pauseReconnect: true),
                authError: authError)
        case .authPasswordNotConfigured:
            self.problem(
                .init(
                    kind: .gatewayAuthPasswordNotConfigured,
                    owner: .gateway,
                    title: "Gateway password is not configured",
                    message:
                    "This gateway is set to password auth, but no gateway password is configured on the gateway.",
                    actionLabel: "Fix on gateway",
                    actionCommand: "openclaw config set gateway.auth.password <new-password>",
                    docsURLString: self.authenticationDocs,
                    retryable: false,
                    pauseReconnect: true),
                authError: authError)
        default:
            // The dispatcher owns this category boundary; unrouted codes degrade to the generic rejection.
            self.genericRejection(for: authError)
        }
    }

    private static func deviceCredentialProblem(
        for authError: GatewayConnectAuthError) -> GatewayConnectionProblem
    {
        let pairingCommand = self.approvalCommand(requestId: authError.requestId)

        return switch authError.detail {
        case .authBootstrapTokenInvalid:
            self.problem(
                .init(
                    kind: .bootstrapTokenInvalid,
                    owner: .iphone,
                    title: "Setup code expired",
                    message: "The setup QR or bootstrap token is no longer valid.",
                    actionLabel: "Scan QR again",
                    actionCommand: nil,
                    docsURLString: self.iosDocs,
                    retryable: false,
                    pauseReconnect: true),
                authError: authError)
        case .authDeviceTokenMismatch:
            self.problem(
                .init(
                    kind: .deviceTokenMismatch,
                    owner: .both,
                    title: "This device's saved device token is no longer valid",
                    message: "The gateway rejected the stored device token for this role.",
                    actionLabel: "Repair pairing",
                    actionCommand: pairingCommand,
                    docsURLString: self.pairingDocs,
                    retryable: false,
                    pauseReconnect: true),
                authError: authError)
        case .authScopeMismatch:
            self.problem(
                .init(
                    kind: .deviceTokenScopeMismatch,
                    owner: .both,
                    title: "Device permissions need approval",
                    message: "The gateway accepted this device token but rejected the requested operator scopes.",
                    actionLabel: "Review pairing",
                    actionCommand: pairingCommand,
                    docsURLString: self.pairingDocs,
                    retryable: false,
                    pauseReconnect: true),
                authError: authError)
        default:
            // The dispatcher owns this category boundary; unrouted codes degrade to the generic rejection.
            self.genericRejection(for: authError)
        }
    }

    private static func deviceIdentityProblem(
        for authError: GatewayConnectAuthError) -> GatewayConnectionProblem
    {
        switch authError.detail {
        case .controlUiDeviceIdentityRequired, .deviceIdentityRequired:
            self.problem(
                .init(
                    kind: .deviceIdentityRequired,
                    owner: .iphone,
                    title: "Secure device identity is required",
                    message: "This connection must include a signed device identity before the gateway can bind "
                        + "permissions to this device.",
                    actionLabel: "Retry from the app",
                    actionCommand: nil,
                    docsURLString: self.iosDocs,
                    retryable: false,
                    pauseReconnect: true),
                authError: authError)
        case .deviceAuthSignatureExpired:
            self.problem(
                .init(
                    kind: .deviceSignatureExpired,
                    owner: .iphone,
                    title: "Secure handshake expired",
                    message: "The device signature is too old to use.",
                    actionLabel: "Check device time",
                    actionCommand: nil,
                    docsURLString: self.troubleshootingDocs,
                    retryable: true,
                    pauseReconnect: true),
                authError: authError)
        case .deviceAuthNonceRequired:
            self.problem(
                .init(
                    kind: .deviceNonceRequired,
                    owner: .iphone,
                    title: "Secure handshake is incomplete",
                    message: "The gateway expected a one-time challenge response, but the nonce was missing.",
                    actionLabel: "Retry",
                    actionCommand: nil,
                    docsURLString: self.troubleshootingDocs,
                    retryable: true,
                    pauseReconnect: true),
                authError: authError)
        case .deviceAuthNonceMismatch:
            self.problem(
                .init(
                    kind: .deviceNonceMismatch,
                    owner: .iphone,
                    title: "Secure handshake did not match",
                    message: "The challenge response was stale or mismatched.",
                    actionLabel: "Retry",
                    actionCommand: nil,
                    docsURLString: self.troubleshootingDocs,
                    retryable: true,
                    pauseReconnect: true),
                authError: authError)
        case .deviceAuthSignatureInvalid, .deviceAuthInvalid:
            self.problem(
                .init(
                    kind: .deviceSignatureInvalid,
                    owner: .iphone,
                    title: "This device identity could not be verified",
                    message: "The gateway could not verify the identity this device presented.",
                    actionLabel: "Re-pair this device",
                    actionCommand: nil,
                    docsURLString: self.pairingDocs,
                    retryable: false,
                    pauseReconnect: true),
                authError: authError)
        case .deviceAuthPublicKeyInvalid:
            self.problem(
                .init(
                    kind: .devicePublicKeyInvalid,
                    owner: .iphone,
                    title: "This device identity could not be verified",
                    message: "The gateway could not verify the public key this device presented.",
                    actionLabel: "Re-pair this device",
                    actionCommand: nil,
                    docsURLString: self.pairingDocs,
                    retryable: false,
                    pauseReconnect: true),
                authError: authError)
        case .deviceAuthDeviceIdMismatch:
            self.problem(
                .init(
                    kind: .deviceIdMismatch,
                    owner: .iphone,
                    title: "This device identity could not be verified",
                    message: "The gateway rejected the device identity because the device ID did not match.",
                    actionLabel: "Re-pair this device",
                    actionCommand: nil,
                    docsURLString: self.pairingDocs,
                    retryable: false,
                    pauseReconnect: true),
                authError: authError)
        default:
            // The dispatcher owns this category boundary; unrouted codes degrade to the generic rejection.
            self.genericRejection(for: authError)
        }
    }
}

extension GatewayConnectionProblemMapper {
    private static func map(_ responseError: GatewayResponseError) -> GatewayConnectionProblem? {
        let code = responseError.code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if code == "NOT_PAIRED" || responseError.detailsReason == "not-paired" {
            let authError = GatewayConnectAuthError(
                message: responseError.message,
                detailCodeRaw: GatewayConnectAuthDetailCode.pairingRequired.rawValue,
                canRetryWithDeviceToken: false,
                recommendedNextStepRaw: nil,
                requestId: self.nonEmpty(responseError.details["requestId"]?.stringValue),
                detailsReason: responseError.detailsReason)
            return self.map(authError)
        }
        return nil
    }

    private static func map(_ tlsError: GatewayTLSValidationError) -> GatewayConnectionProblem {
        let failure = tlsError.failure
        switch failure.kind {
        case .pinMismatch:
            let trustedSuffix = failure.systemTrustOk
                ? " The new certificate is trusted by this device; this is commonly caused by certificate rotation."
                : " This device could not verify the new certificate."
            let message = "The saved TLS certificate pin for \(failure.host) "
                + "no longer matches the gateway certificate.\(trustedSuffix)"
            // Keep the extraction keys contiguous for the native localization inventory.
            // swiftlint:disable line_length
            let messagePresentation: GatewayConnectionProblem.PresentationText = failure.systemTrustOk
                ? .localizedFormat(
                    "The saved TLS certificate pin for %@ no longer matches the gateway certificate. The new certificate is trusted by this device; this is commonly caused by certificate rotation.",
                    [failure.host])
                : .localizedFormat(
                    "The saved TLS certificate pin for %@ no longer matches the gateway certificate. This device could not verify the new certificate.",
                    [failure.host])
            // swiftlint:enable line_length
            return GatewayConnectionProblem(
                kind: .tlsPinMismatch,
                owner: failure.systemTrustOk ? .network : .unknown,
                title: "Gateway certificate changed",
                message: message,
                actionLabel: "Review certificate",
                messagePresentation: messagePresentation,
                actionCommand: nil,
                docsURL: URL(string: self.troubleshootingDocs),
                retryable: false,
                pauseReconnect: true,
                technicalDetails: tlsError.localizedDescription,
                tlsStoreKey: failure.storeKey,
                tlsExpectedFingerprint: failure.expectedFingerprint,
                tlsObservedFingerprint: failure.observedFingerprint,
                tlsSystemTrustOk: failure.systemTrustOk)
        case .certificateUnavailable:
            return GatewayConnectionProblem(
                kind: .tlsCertificateUnavailable,
                owner: .network,
                title: "Gateway certificate unavailable",
                message: "OpenClaw could not read the gateway certificate for \(failure.host).",
                actionLabel: "Retry",
                messagePresentation: .localizedFormat(
                    "OpenClaw could not read the gateway certificate for %@.",
                    [failure.host]),
                actionCommand: nil,
                docsURL: URL(string: self.troubleshootingDocs),
                retryable: true,
                pauseReconnect: false,
                technicalDetails: tlsError.localizedDescription)
        case .untrustedCertificate:
            return GatewayConnectionProblem(
                kind: .tlsCertificateUntrusted,
                owner: .network,
                title: "Gateway certificate is not trusted",
                message: "This device does not trust the TLS certificate presented by \(failure.host).",
                actionLabel: "Check certificate",
                messagePresentation: .localizedFormat(
                    "This device does not trust the TLS certificate presented by %@.",
                    [failure.host]),
                actionCommand: nil,
                docsURL: URL(string: self.troubleshootingDocs),
                retryable: false,
                pauseReconnect: true,
                technicalDetails: tlsError.localizedDescription)
        case .pinStorageUnavailable:
            return GatewayConnectionProblem(
                kind: .tlsCertificateUnavailable,
                owner: .unknown,
                title: "Gateway certificate unavailable",
                message: "OpenClaw could not securely save the TLS certificate pin for \(failure.host).",
                actionLabel: "Retry",
                titlePresentation: .localized("Gateway certificate unavailable"),
                messagePresentation: .localizedFormat(
                    "OpenClaw could not securely save the TLS certificate pin for %@.",
                    [failure.host]),
                actionLabelPresentation: .localized("Retry"),
                actionCommand: nil,
                docsURL: URL(string: self.troubleshootingDocs),
                retryable: true,
                pauseReconnect: false,
                technicalDetails: tlsError.localizedDescription)
        case .authorityMismatch:
            return GatewayConnectionProblem(
                kind: .tlsCertificateUntrusted,
                owner: .network,
                title: "Gateway certificate is not trusted",
                message: "The TLS challenge came from a different host or port than the requested Gateway.",
                actionLabel: "Check certificate",
                titlePresentation: .localized("Gateway certificate is not trusted"),
                messagePresentation: .localized(
                    "The TLS challenge came from a different host or port than the requested Gateway."),
                actionLabelPresentation: .localized("Check certificate"),
                actionCommand: nil,
                docsURL: URL(string: self.troubleshootingDocs),
                retryable: false,
                pauseReconnect: true,
                technicalDetails: tlsError.localizedDescription)
        }
    }

    private static func mapTransportError(_ error: Error) -> GatewayConnectionProblem? {
        let nsError = error as NSError
        let rawMessage = nsError.userInfo[NSLocalizedDescriptionKey] as? String ?? nsError.localizedDescription
        let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !message.isEmpty else { return nil }

        let typedKind = nsError.domain == URLError.errorDomain
            ? self.transportKind(for: URLError.Code(rawValue: nsError.code))
            : nil
        guard let kind = typedKind ?? self.transportKind(for: message) else { return nil }
        return self.transportProblem(kind: kind, technicalDetails: rawMessage)
    }

    private static func transportKind(for code: URLError.Code) -> GatewayConnectionProblem.Kind? {
        switch code {
        case .timedOut: .timeout
        case .cannotConnectToHost: .connectionRefused
        case .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet, .networkConnectionLost,
             .internationalRoamingOff, .callIsActive, .dataNotAllowed: .reachabilityFailed
        case .cancelled: .websocketCancelled
        default: nil
        }
    }

    private static func transportKind(for message: String) -> GatewayConnectionProblem.Kind? {
        if message.contains("timed out") { return .timeout }
        if message.contains("refused") { return .connectionRefused }
        let unreachable = ["cannot find host", "could not connect", "network is unreachable"]
        if unreachable.contains(where: message.contains) { return .reachabilityFailed }
        if message.contains("cancelled") || message.contains("canceled") { return .websocketCancelled }
        return nil
    }

    private static func transportProblem(
        kind: GatewayConnectionProblem.Kind,
        technicalDetails: String) -> GatewayConnectionProblem
    {
        let facts: (title: String, message: String, actionLabel: String) = switch kind {
        case .timeout:
            ("Connection timed out", "The gateway did not respond before the connection timed out.", "Retry")
        case .connectionRefused:
            (
                "Gateway refused the connection",
                "The gateway host was reachable, but it refused the connection.",
                "Retry")
        case .reachabilityFailed:
            (
                "Gateway is not reachable",
                "OpenClaw could not reach the gateway over the current network.",
                "Check network")
        default:
            ("Connection interrupted", "The connection to the gateway was interrupted before setup completed.", "Retry")
        }
        return GatewayConnectionProblem(
            kind: kind,
            owner: .network,
            title: facts.title,
            message: facts.message,
            actionLabel: facts.actionLabel,
            docsURL: URL(string: self.troubleshootingDocs),
            retryable: true,
            pauseReconnect: false,
            technicalDetails: technicalDetails)
    }

    private static func pairingProblem(for authError: GatewayConnectAuthError) -> GatewayConnectionProblem {
        let kind: GatewayConnectionProblem.Kind
        let title: String
        let message: String
        switch authError.detailsReason {
        case "role-upgrade":
            kind = .pairingRoleUpgradeRequired
            title = "Additional approval required"
            message = "This device is already paired, but it is requesting a new role "
                + "that was not previously approved."
        case "scope-upgrade":
            kind = .pairingScopeUpgradeRequired
            title = "Additional permissions required"
            message = "This device is already paired, but it is requesting new permissions that require approval."
        case "metadata-upgrade":
            kind = .pairingMetadataUpgradeRequired
            title = "Device approval needs refresh"
            message = "The gateway detected a change in this device's approved identity metadata "
                + "and requires re-approval."
        default:
            kind = .pairingRequired
            title = "This device is not approved yet"
            message = "The gateway received the connection request, but this device must be approved first."
        }
        return self.problem(
            .init(
                kind: kind,
                owner: .gateway,
                title: title,
                message: message,
                actionLabel: "Approve on gateway",
                actionCommand: self.approvalCommand(requestId: authError.requestId),
                docsURLString: self.pairingDocs,
                retryable: false,
                pauseReconnect: true),
            authError: authError)
    }

    private static func protocolMismatchProblem(for authError: GatewayConnectAuthError) -> GatewayConnectionProblem {
        let title: String
        let message: String
        let owner: GatewayConnectionProblem.Owner
        let actionLabel: String
        let actionCommand: String?
        switch authError.protocolUpdateOwner {
        case .client:
            title = "App update required"
            message = "This app is older than the gateway. Update OpenClaw on this device, then retry."
            owner = .iphone
            actionLabel = "Update app"
            actionCommand = nil
        case .gateway:
            title = "Gateway update required"
            message = "The gateway is older than this app. Update OpenClaw on the gateway host, then retry."
            owner = .gateway
            actionLabel = "Copy update command"
            actionCommand = "openclaw update"
        case nil:
            title = "OpenClaw update required"
            message = "The app and gateway use incompatible protocol versions. Update OpenClaw on both, then retry."
            owner = .both
            actionLabel = "Update OpenClaw"
            actionCommand = nil
        }
        return self.problem(
            .init(
                kind: .protocolMismatch,
                owner: owner,
                title: title,
                message: message,
                actionLabel: actionLabel,
                actionCommand: actionCommand,
                docsURLString: self.troubleshootingDocs,
                retryable: false,
                pauseReconnect: true),
            authError: authError)
    }

    private static func problem(
        _ defaults: AuthProblemDefaults,
        authError: GatewayConnectAuthError)
        -> GatewayConnectionProblem
    {
        let title = authError.titleOverride ?? defaults.title
        let message = authError.userMessageOverride ?? defaults.message
        let actionLabel = authError.actionLabel ?? defaults.actionLabel
        return GatewayConnectionProblem(
            kind: defaults.kind,
            owner: authError.ownerRaw.flatMap(self.owner(from:)) ?? defaults.owner,
            title: title,
            message: message,
            actionLabel: actionLabel,
            titlePresentation: authError.titleOverride == nil
                ? .localized(title)
                : .verbatim(title),
            messagePresentation: authError.userMessageOverride == nil
                && message != authError.message
                ? .localized(message)
                : .verbatim(message),
            actionLabelPresentation: authError.actionLabel == nil
                ? actionLabel.map(GatewayConnectionProblem.PresentationText.localized)
                : actionLabel.map(GatewayConnectionProblem.PresentationText.verbatim),
            actionCommand: authError.actionCommand ?? defaults.actionCommand,
            docsURL: self.docsURL(authError.docsURLString, fallback: defaults.docsURLString),
            requestId: authError.requestId,
            retryable: authError.retryableOverride ?? defaults.retryable,
            pauseReconnect: authError.pauseReconnectOverride ?? defaults.pauseReconnect,
            technicalDetails: self.technicalDetails(for: authError))
    }

    private static func approvalCommand(requestId: String?) -> String {
        self.nonEmpty(requestId).map { "openclaw devices approve \($0)" }
            ?? "openclaw devices list"
    }

    private static func technicalDetails(for authError: GatewayConnectAuthError) -> String? {
        var parts: [String?] = [
            self.nonEmpty(authError.detailCodeRaw),
            self.nonEmpty(authError.detailsReason).map { "reason=\($0)" },
            self.nonEmpty(authError.requestId).map { "requestId=\($0)" },
            self.nonEmpty(authError.recommendedNextStepRaw).map { "next=\($0)" },
            self.protocolRange(min: authError.clientMinProtocol, max: authError.clientMaxProtocol)
                .map { "clientProtocol=\($0)" },
            authError.expectedProtocol.map { "gatewayProtocol=\($0)" },
            authError.minimumProbeProtocol.map { "probeMin=\($0)" },
        ]
        if authError.canRetryWithDeviceToken { parts.insert("deviceTokenRetry=true", at: 4) }
        let details = parts.compactMap(\.self)
        return details.isEmpty ? nil : details.joined(separator: " · ")
    }

    private static func protocolRange(min: Int?, max: Int?) -> String? {
        switch (min, max) {
        case (nil, nil):
            nil
        case let (min?, max?) where min == max:
            "\(min)"
        case let (min?, max?):
            "\(min)-\(max)"
        case let (min?, nil):
            "min \(min)"
        case let (nil, max?):
            "max \(max)"
        }
    }

    private static func docsURL(_ preferred: String?, fallback: String?) -> URL? {
        self.nonEmpty(preferred).flatMap { URL(string: $0) }
            ?? self.nonEmpty(fallback).flatMap { URL(string: $0) }
    }

    private static func owner(from raw: String) -> GatewayConnectionProblem.Owner? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ios", "device", "client": .iphone
        case "": .unknown
        case let normalized:
            GatewayConnectionProblem.Owner(rawValue: normalized)
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
