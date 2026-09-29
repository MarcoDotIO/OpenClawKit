import Foundation
import OpenClawProtocol
import Testing
@testable import OpenClawKit

@Suite("Gateway errors and connection problems")
struct GatewayConnectionProblemMapperTests {
    @Test
    func responseErrorReadsStructuredMissingScope() throws {
        let error = GatewayResponseError(
            method: "question.list",
            code: "FORBIDDEN",
            message: "permission denied",
            details: [
                "code": AnyCodable("MISSING_SCOPE"),
                "missingScope": AnyCodable("operator.questions"),
                "requiredScopes": AnyCodable([AnyCodable("operator.read"), AnyCodable("operator.questions")]),
            ])
        let details = try #require(error.missingScopeDetails)
        #expect(details.missingScope == "operator.questions")
        #expect(details.requiredScopes == ["operator.read", "operator.questions"])
        #expect(error.missingScope == "operator.questions")
        #expect(error.isAuthorizationFailure)
    }

    @Test
    func responseErrorKeepsLegacyMissingScopeCompatibility() {
        let legacy = GatewayResponseError(
            method: "question.list",
            code: "INVALID_REQUEST",
            message: "missing scope: operator.questions",
            details: nil)
        let unrelated = GatewayResponseError(
            method: "question.list",
            code: "UNAVAILABLE",
            message: "missing scope: operator.questions",
            details: nil)
        let role = GatewayResponseError(
            method: "node.invoke",
            code: "INVALID_REQUEST",
            message: "unauthorized role: operator",
            details: nil)
        #expect(legacy.missingScope == "operator.questions")
        #expect(unrelated.missingScope == nil)
        #expect(legacy.isAuthorizationFailure)
        #expect(!unrelated.isAuthorizationFailure)
        #expect(role.isAuthorizationFailure)
    }

    @Test
    func startupAndProfileBindingDetailsAreTyped() {
        let startup = GatewayResponseError(
            method: "sessions.send",
            code: "UNAVAILABLE",
            message: "gateway starting",
            details: [
                "reason": AnyCodable("startup-sidecars"),
                "retryable": AnyCodable(true),
                "retryAfterMs": AnyCodable(9000),
            ])
        #expect(startup.isStartupUnavailable)
        #expect(startup.startupRetryAfterMs == 2000)

        let mismatch = GatewayResponseError(
            method: "chat.send",
            code: "INVALID_REQUEST",
            message: "Selected account changed",
            details: ["reason": AnyCodable("EXPECTED_PROFILE_MISMATCH"), "execution": AnyCodable("may_have_executed")])
        #expect(mismatch.expectedProfileMismatch == .mayHaveExecuted)
        #expect(startup.expectedProfileMismatch == nil)
    }

    @Test
    func terminalAuthErrorsAreNonRecoverable() {
        for detail in [
            GatewayConnectAuthDetailCode.authBootstrapTokenInvalid,
            .authVerifiedUserRequired,
            .authScopeMismatch,
            .protocolMismatch,
        ] {
            let error = GatewayConnectAuthError(
                message: "authentication failed",
                detailCode: detail.rawValue,
                canRetryWithDeviceToken: false)
            #expect(error.isNonRecoverable)
            #expect(error.detail == detail)
        }
        #expect(!GatewayConnectAuthError(
            message: "mismatch",
            detailCode: GatewayConnectAuthDetailCode.authDeviceTokenMismatch.rawValue,
            canRetryWithDeviceToken: false).isNonRecoverable)
    }

    @Test
    func connectAuthErrorParsesAndTrimsStructuredDetails() {
        let error = GatewayConnectAuthError(message: " pairing required ", details: [
            "code": AnyCodable(" PAIRING_REQUIRED "),
            "requestId": AnyCodable("req-123"),
            "reason": AnyCodable("scope-upgrade"),
            "owner": AnyCodable("gateway"),
            "title": AnyCodable("  "),
            "docsUrl": AnyCodable("https://docs.openclaw.ai/gateway/pairing"),
            "pauseReconnect": AnyCodable(true),
            "clientMinProtocol": AnyCodable(4),
            "clientMaxProtocol": AnyCodable(4.0),
            "expectedProtocol": AnyCodable("5"),
            "canRetryWithDeviceToken": AnyCodable(false),
        ])
        #expect(error.message == "pairing required")
        #expect(error.detail == .pairingRequired)
        #expect(error.requestId == "req-123")
        #expect(error.detailsReason == "scope-upgrade")
        #expect(error.ownerRaw == "gateway")
        #expect(error.titleOverride == nil)
        #expect(error.docsURLString == "https://docs.openclaw.ai/gateway/pairing")
        #expect(error.pauseReconnectOverride == true)
        #expect(error.clientMinProtocol == 4)
        #expect(error.clientMaxProtocol == 4)
        #expect(error.expectedProtocol == 5)
        #expect(error.protocolUpdateOwner == .client)
    }

    @Test
    func appOwnedCopyStaysLocalizableAndGatewayCopyStaysVerbatim() throws {
        let appOwned = GatewayConnectAuthError(
            message: "pairing required",
            detailCode: GatewayConnectAuthDetailCode.pairingRequired.rawValue,
            canRetryWithDeviceToken: false,
            requestId: "req-123")
        let problem = try #require(GatewayConnectionProblemMapper.map(error: appOwned))
        #expect(problem.titlePresentation == .localized("This device is not approved yet"))
        #expect(problem.actionLabelPresentation == .localized("Approve on gateway"))
        #expect(problem.titlePresentation.resolvedString() == "This device is not approved yet")
        #expect(problem.statusText == "This device is not approved yet (request ID: req-123)")

        let gatewayCopy = GatewayConnectAuthError(
            message: "pairing required",
            detailCode: GatewayConnectAuthDetailCode.pairingRequired.rawValue,
            canRetryWithDeviceToken: false,
            titleOverride: "Custom gateway title",
            userMessageOverride: "Custom gateway instructions",
            actionLabel: "Custom gateway action")
        let custom = try #require(GatewayConnectionProblemMapper.map(error: gatewayCopy))
        #expect(custom.titlePresentation == .verbatim("Custom gateway title"))
        #expect(custom.messagePresentation == .verbatim("Custom gateway instructions"))
        #expect(custom.actionLabelPresentation == .verbatim("Custom gateway action"))
        #expect(GatewayConnectionProblem.PresentationText.localizedFormat("Host %@ failed", ["a"]).resolvedString()
            == "Host a failed")
    }

    @Test(arguments: [
        (URLError.Code.timedOut, GatewayConnectionProblem.Kind.timeout),
        (.cannotConnectToHost, .connectionRefused),
        (.cannotFindHost, .reachabilityFailed),
        (.dnsLookupFailed, .reachabilityFailed),
        (.notConnectedToInternet, .reachabilityFailed),
        (.networkConnectionLost, .reachabilityFailed),
        (.dataNotAllowed, .reachabilityFailed),
        (.cancelled, .websocketCancelled),
    ])
    func typedTransportErrorsMapToNetworkProblems(code: URLError.Code, kind: GatewayConnectionProblem.Kind) throws {
        let error = NSError(
            domain: URLError.errorDomain,
            code: code.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "typed \(code.rawValue)"])
        let problem = try #require(GatewayConnectionProblemMapper.map(error: error))
        #expect(problem.kind == kind)
        #expect(problem.owner == .network)
        #expect(problem.retryable)
        #expect(!problem.pauseReconnect)
        #expect(problem.technicalDetails == "typed \(code.rawValue)")
    }

    @Test
    func textualTransportFallbackIsDomainGated() throws {
        let wrongDomain = NSError(
            domain: "GatewayTransport",
            code: URLError.timedOut.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "neutral failure"])
        #expect(GatewayConnectionProblemMapper.map(error: wrongDomain) == nil)
        for (message, kind) in [
            ("gateway timed out", GatewayConnectionProblem.Kind.timeout),
            ("connection refused", .connectionRefused),
            ("network is unreachable", .reachabilityFailed),
            ("operation canceled", .websocketCancelled),
        ] {
            let error = NSError(domain: "GatewayTransport", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            #expect(GatewayConnectionProblemMapper.map(error: error)?.kind == kind)
        }
    }

    @Test(arguments: [
        ("INVALID_REQUEST", 3, 4...4, true),
        ("INVALID_REQUEST", 3, 3...4, false),
        ("INVALID_REQUEST", 5, 3...4, true),
        ("PROTOCOL_MISMATCH", 4, 4...4, true),
        ("AUTH_TOKEN_MISSING", 5, 4...4, false),
    ])
    func protocolMismatchRespectsTheAdvertisedRoleRange(
        detailCode: String,
        expected: Int,
        supported: ClosedRange<Int>,
        mismatch: Bool)
    {
        let error = GatewayConnectAuthError(
            message: "rejected",
            detailCode: detailCode,
            canRetryWithDeviceToken: false,
            expectedProtocol: expected)
        #expect(error.isProtocolMismatch(supportedProtocols: supported) == mismatch)
    }

    @Test
    func protocolMismatchNamesWhichSideMustUpdate() {
        let olderApp = GatewayConnectionProblemMapper.map(error: GatewayConnectAuthError(
            message: "protocol mismatch",
            detailCode: "PROTOCOL_MISMATCH",
            canRetryWithDeviceToken: false,
            clientMinProtocol: 4,
            clientMaxProtocol: 4,
            expectedProtocol: 5,
            minimumProbeProtocol: 4))
        #expect(olderApp?.owner == .clientDevice)
        #expect(olderApp?.title == "App update required")
        #expect(olderApp?.technicalDetails?.contains("clientProtocol=4") == true)
        #expect(olderApp?.technicalDetails?.contains("gatewayProtocol=5") == true)
        #expect(olderApp?.pauseReconnect == true)

        let olderGateway = GatewayConnectionProblemMapper.map(error: GatewayConnectAuthError(
            message: "protocol mismatch",
            detailCode: "PROTOCOL_MISMATCH",
            canRetryWithDeviceToken: false,
            clientMinProtocol: 4,
            clientMaxProtocol: 4,
            expectedProtocol: 3))
        #expect(olderGateway?.owner == .gateway)
        #expect(olderGateway?.actionCommand == "openclaw update")

        let unknown = GatewayConnectionProblemMapper.map(error: GatewayConnectAuthError(
            message: "protocol mismatch",
            detailCode: "PROTOCOL_MISMATCH",
            canRetryWithDeviceToken: false))
        #expect(unknown?.owner == .both)
        #expect(unknown?.statusText == "OpenClaw update required")
    }

    @Test
    func pairingAndScopeProblemsCarryApprovalCommands() {
        let scopeUpgrade = GatewayConnectionProblemMapper.map(error: GatewayConnectAuthError(
            message: "pairing required",
            detailCode: "PAIRING_REQUIRED",
            canRetryWithDeviceToken: false,
            requestId: "req-123",
            detailsReason: "scope-upgrade"))
        #expect(scopeUpgrade?.kind == .pairingScopeUpgradeRequired)
        #expect(scopeUpgrade?.actionCommand == "openclaw devices approve req-123")
        #expect(scopeUpgrade?.needsPairingApproval == true)

        let scopeMismatch = GatewayConnectionProblemMapper.map(error: GatewayConnectAuthError(
            message: "scope mismatch",
            detailCode: "AUTH_SCOPE_MISMATCH",
            canRetryWithDeviceToken: false))
        #expect(scopeMismatch?.kind == .deviceTokenScopeMismatch)
        #expect(scopeMismatch?.actionCommand == "openclaw devices list")
        #expect(scopeMismatch?.needsCredentialUpdate == false)

        let notPaired = GatewayConnectionProblemMapper.map(error: GatewayResponseError(
            method: "node.invoke",
            code: "NOT_PAIRED",
            message: "not paired",
            details: ["requestId": AnyCodable("req-7")]))
        #expect(notPaired?.kind == .pairingRequired)
        #expect(notPaired?.requestId == "req-7")

        let tokenMismatch = GatewayConnectionProblem.from(GatewayConnectAuthError(
            message: "token mismatch",
            detailCode: "AUTH_TOKEN_MISMATCH",
            canRetryWithDeviceToken: false))
        #expect(tokenMismatch?.suggestsOnboardingReset == true)
        #expect(tokenMismatch?.needsCredentialUpdate == true)
    }

    @Test
    func newerGatewayCodesDegradeToTheGenericRejection() {
        for code in ["CLIENT_VERSION_MISMATCH", "CONTROL_UI_ORIGIN_NOT_ALLOWED", "SOMETHING_FROM_THE_FUTURE"] {
            let problem = GatewayConnectionProblemMapper.map(error: GatewayConnectAuthError(
                message: "rejected by gateway",
                detailCode: code,
                canRetryWithDeviceToken: false))
            #expect(problem?.kind == .unknown)
            #expect(problem?.message == "rejected by gateway")
            #expect(problem?.messagePresentation == .verbatim("rejected by gateway"))
        }
    }

    @Test
    func cancelledTransportPreservesAStructuredProblem() {
        let previous = GatewayConnectionProblemMapper.map(error: GatewayConnectAuthError(
            message: "pairing required",
            detailCode: "PAIRING_REQUIRED",
            canRetryWithDeviceToken: false,
            requestId: "req-123"))
        let cancelled = NSError(
            domain: URLError.errorDomain,
            code: URLError.cancelled.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "gateway receive: cancelled"])
        #expect(GatewayConnectionProblemMapper.map(error: cancelled, preserving: previous)?.kind == .pairingRequired)
        let unknown = NSError(
            domain: NSURLErrorDomain,
            code: -1202,
            userInfo: [NSLocalizedDescriptionKey: "certificate chain validation failed"])
        #expect(GatewayConnectionProblemMapper.map(error: unknown, preserving: previous) == nil)
        if let previous {
            #expect(GatewayConnectionProblemMapper.shouldPreserve(previousProblem: previous, overDisconnectReason: "socket canceled"))
            #expect(!GatewayConnectionProblemMapper.shouldPreserve(previousProblem: previous, overDisconnectReason: "tick missed"))
        }
    }

    @Test
    func tlsFailuresMapToActionableProblems() {
        let rotated = GatewayConnectionProblemMapper.map(error: GatewayTLSValidationError(
            failure: GatewayTLSValidationFailure(
                kind: .pinMismatch,
                host: "gateway.example.ts.net",
                storeKey: "gateway.example.ts.net:443",
                expectedFingerprint: "old",
                observedFingerprint: "new",
                systemTrustOk: true),
            context: "connect to gateway"))
        #expect(rotated?.kind == .tlsPinMismatch)
        #expect(rotated?.canTrustRotatedCertificate == true)
        #expect(rotated?.messagePresentation == .localizedFormat(
            "The saved TLS certificate pin for %@ no longer matches the gateway certificate. "
                + "The new certificate is trusted by this device; this is commonly caused by certificate rotation.",
            ["gateway.example.ts.net"]))

        let untrustedRotation = GatewayConnectionProblemMapper.map(error: GatewayTLSValidationError(
            failure: GatewayTLSValidationFailure(
                kind: .pinMismatch,
                host: "gateway.example.ts.net",
                storeKey: "gateway.example.ts.net:443",
                expectedFingerprint: "old",
                observedFingerprint: "new",
                systemTrustOk: false),
            context: "connect"))
        #expect(untrustedRotation?.canTrustRotatedCertificate == false)

        let storage = GatewayConnectionProblemMapper.map(error: GatewayTLSValidationError(
            failure: GatewayTLSValidationFailure(
                kind: .pinStorageUnavailable,
                host: "gateway.example.com",
                storeKey: nil,
                expectedFingerprint: nil,
                observedFingerprint: "observed",
                systemTrustOk: true),
            context: "connect"))
        #expect(storage?.kind == .tlsCertificateUnavailable)
        #expect(storage?.retryable == true)
        #expect(storage?.pauseReconnect == false)

        let authority = GatewayConnectionProblemMapper.map(error: GatewayTLSValidationError(
            failure: GatewayTLSValidationFailure(
                kind: .authorityMismatch,
                host: "redirect.example.com",
                storeKey: nil,
                expectedFingerprint: nil,
                observedFingerprint: nil,
                systemTrustOk: false,
                port: 443),
            context: "connect"))
        #expect(authority?.kind == .tlsCertificateUntrusted)
        #expect(authority?.pauseReconnect == true)
    }
}
