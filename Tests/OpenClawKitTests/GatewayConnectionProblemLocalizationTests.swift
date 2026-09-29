import Foundation
import Testing
@testable import OpenClawKit

private let missingMarker = "__openclaw_missing_localization__"

private func presentationKey(_ text: GatewayConnectionProblem.PresentationText?) -> String? {
    switch text {
    case let .localized(key)?: key
    case let .localizedFormat(key, _)?: key
    case .verbatim?, nil: nil
    }
}

private func isCatalogued(_ key: String) -> Bool {
    OpenClawKitResources.bundle.localizedString(forKey: key, value: missingMarker, table: nil) != missingMarker
}

@Suite("Gateway connection problem localization")
struct GatewayConnectionProblemLocalizationTests {
    private static let detailCodes = [
        "AUTH_TOKEN_MISMATCH", "AUTH_BOOTSTRAP_TOKEN_INVALID", "AUTH_DEVICE_TOKEN_MISMATCH", "AUTH_SCOPE_MISMATCH",
        "AUTH_TOKEN_MISSING", "AUTH_TOKEN_NOT_CONFIGURED", "AUTH_PASSWORD_MISSING", "AUTH_PASSWORD_MISMATCH",
        "AUTH_PASSWORD_NOT_CONFIGURED", "AUTH_RATE_LIMITED", "AUTH_TAILSCALE_IDENTITY_MISSING",
        "AUTH_TAILSCALE_PROXY_MISSING", "AUTH_TAILSCALE_WHOIS_FAILED", "AUTH_TAILSCALE_IDENTITY_MISMATCH",
        "PAIRING_REQUIRED", "PROTOCOL_MISMATCH", "CONTROL_UI_DEVICE_IDENTITY_REQUIRED", "DEVICE_IDENTITY_REQUIRED",
        "DEVICE_AUTH_INVALID", "DEVICE_AUTH_DEVICE_ID_MISMATCH", "DEVICE_AUTH_SIGNATURE_EXPIRED",
    ]

    private static func sampleProblems() -> [GatewayConnectionProblem] {
        var errors: [Error] = []
        for code in self.detailCodes {
            errors.append(GatewayConnectAuthError(message: "rejected", detailCode: code, canRetryWithDeviceToken: false))
            errors.append(GatewayConnectAuthError(message: "rejected", detailCode: code, canRetryWithDeviceToken: true))
        }
        for reason in ["role-upgrade", "scope-upgrade", "metadata-upgrade"] {
            errors.append(GatewayConnectAuthError(
                message: "pairing", detailCode: "PAIRING_REQUIRED", canRetryWithDeviceToken: false, detailsReason: reason))
        }
        for (clientMax, clientMin) in [(3, 3), (5, 5), (4, 3)] {
            errors.append(GatewayConnectAuthError(
                message: "protocol", detailCode: "PROTOCOL_MISMATCH", canRetryWithDeviceToken: false,
                clientMinProtocol: clientMin, clientMaxProtocol: clientMax, expectedProtocol: 4))
        }
        for kind in [GatewayTLSValidationFailureKind.pinMismatch, .certificateUnavailable, .untrustedCertificate,
                     .pinStorageUnavailable, .authorityMismatch]
        {
            for trusted in [false, true] {
                errors.append(GatewayTLSValidationError(
                    failure: GatewayTLSValidationFailure(
                        kind: kind, host: "gateway.example.com", storeKey: "k", expectedFingerprint: "a",
                        observedFingerprint: "b", systemTrustOk: trusted),
                    context: "connect"))
            }
        }
        for code in [URLError.Code.timedOut, .cannotConnectToHost, .notConnectedToInternet, .cancelled] {
            errors.append(URLError(code))
        }
        return errors.compactMap { GatewayConnectionProblemMapper.map(error: $0) }
    }

    @Test
    func everyPresentationKeyShipsInTheStringCatalog() {
        let problems = Self.sampleProblems()
        #expect(problems.count > 40)
        var missing: [String] = []
        for problem in problems {
            for text in [problem.titlePresentation, problem.messagePresentation, problem.actionLabelPresentation] {
                if let key = presentationKey(text), !isCatalogued(key) { missing.append(key) }
            }
        }
        #expect(missing.isEmpty, "missing from Localizable.xcstrings: \(Set(missing).sorted())")
    }

    @Test
    func resolvedStringsKeepTheEnglishKeyAndFormatArguments() {
        let problem = GatewayConnectionProblemMapper.map(error: GatewayTLSValidationError(
            failure: GatewayTLSValidationFailure(
                kind: .untrustedCertificate, host: "gw.example.com", storeKey: nil, expectedFingerprint: nil,
                observedFingerprint: nil, systemTrustOk: false),
            context: "connect"))
        #expect(problem?.messagePresentation.resolvedString()
            == "This device does not trust the TLS certificate presented by gw.example.com.")
        #expect(GatewayConnectionProblem.PresentationText.localized("Not in the catalog").resolvedString()
            == "Not in the catalog")
        #expect(isCatalogued("Searching…"))
        #expect(isCatalogued("Realtime failed"))
    }
}
