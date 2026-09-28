import CryptoKit
import Foundation
import OpenClawProtocol

/// APNs environment of a push registration or test.
public enum GatewayAPNsEnvironment: String, Codable, Sendable, CaseIterable {
    /// Development (sandbox) APNs.
    case sandbox
    /// Production APNs.
    case production

    /// Validates a raw environment: `nil` means "use the node's default"; an empty or unknown value
    /// throws before contacting the gateway (upstream #144687).
    public static func validated(_ raw: String?) throws -> GatewayAPNsEnvironment? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let environment = GatewayAPNsEnvironment(rawValue: trimmed) else {
            throw GatewayRPCClientError.invalidParams(
                method: "push.test",
                reason: "environment must be sandbox or production")
        }
        return environment
    }
}

/// How the gateway delivers pushes to this node.
public enum GatewayPushTransport: String, Codable, Sendable {
    /// The gateway calls APNs directly with its own credentials (the default for third-party apps).
    case direct
    /// A hosted relay delivers pushes (official OpenClaw builds only; see ``PushRelayClient``).
    case relay
}

/// Notification categories the gateway sends; use them as `UNNotificationCategory` identifiers.
public enum OpenClawNotificationCategory: String, Codable, Sendable, CaseIterable {
    /// An exec or plugin approval needs a decision.
    case approvalRequested = "approval-requested"
    /// An agent run finished.
    case agentFinished = "agent-finished"
    /// An agent asked a question.
    case agentQuestion = "agent-question"
    /// A human mentioned the user.
    case humanMentioned = "human-mentioned"
    /// A scheduled task failed.
    case scheduledTaskFailed = "scheduled-task-failed"
    /// A background task failed.
    case backgroundTaskFailed = "background-task-failed"
}

/// `push.apns.register` payload for direct APNs delivery.
public struct DirectGatewayPushRegistrationPayload: Codable, Sendable, Equatable {
    /// Always `direct`.
    public var transport: String = GatewayPushTransport.direct.rawValue
    /// Hex-encoded APNs device token.
    public var token: String
    /// APNs topic (the app bundle identifier).
    public var topic: String
    /// APNs environment.
    public var environment: String

    /// Creates a direct registration payload.
    public init(token: String, topic: String, environment: GatewayAPNsEnvironment) {
        self.token = token
        self.topic = topic
        self.environment = environment.rawValue
    }
}

/// `push.apns.register` payload for relay delivery.
public struct RelayGatewayPushRegistrationPayload: Codable, Sendable, Equatable {
    /// Always `relay`.
    public var transport: String = GatewayPushTransport.relay.rawValue
    /// Relay handle issued by the relay for this installation.
    public var relayHandle: String
    /// Send grant scoped to the gateway identity.
    public var sendGrant: String
    /// Gateway device identifier the grant is scoped to (from `gateway.identity.get`).
    public var gatewayDeviceId: String
    /// Stable installation identifier.
    public var installationId: String
    /// APNs topic.
    public var topic: String
    /// APNs environment.
    public var environment: String
    /// Distribution channel (for example `official`).
    public var distribution: String
    /// Normalized relay origin URL.
    public var relayOrigin: String
    /// Last characters of the APNs token for diagnostics (never the full token).
    public var tokenDebugSuffix: String?

    /// Creates a relay registration payload.
    public init(
        relayHandle: String,
        sendGrant: String,
        gatewayDeviceId: String,
        installationId: String,
        topic: String,
        environment: GatewayAPNsEnvironment,
        distribution: String,
        relayOrigin: String,
        tokenDebugSuffix: String? = nil)
    {
        self.relayHandle = relayHandle
        self.sendGrant = sendGrant
        self.gatewayDeviceId = gatewayDeviceId
        self.installationId = installationId
        self.topic = topic
        self.environment = environment.rawValue
        self.distribution = distribution
        self.relayOrigin = relayOrigin
        self.tokenDebugSuffix = tokenDebugSuffix
    }
}

/// Relay registration returned by a ``PushRelayClient``.
public struct PushRelayRegistration: Sendable, Equatable {
    /// Relay handle.
    public var relayHandle: String
    /// Send grant.
    public var sendGrant: String
    /// Normalized relay origin.
    public var relayOrigin: String
    /// Handle expiry in milliseconds since the Unix epoch.
    public var expiresAtMs: Int64?
    /// Token suffix echoed by the relay.
    public var tokenSuffix: String?

    /// Creates a relay registration.
    public init(relayHandle: String, sendGrant: String, relayOrigin: String, expiresAtMs: Int64? = nil, tokenSuffix: String? = nil) {
        self.relayHandle = relayHandle
        self.sendGrant = sendGrant
        self.relayOrigin = relayOrigin
        self.expiresAtMs = expiresAtMs
        self.tokenSuffix = tokenSuffix
    }
}

/// Pluggable hosted-relay client.
///
/// The upstream hosted relay (`https://ios-push-relay.openclaw.ai`) only serves official OpenClaw
/// builds (App Attest and receipt proof). Custom builds must run a relay whose URL matches the
/// gateway's relay configuration; the SDK never hard-codes a relay URL. Third-party apps normally use
/// ``GatewayPushTransport/direct``.
public protocol PushRelayClient: Sendable {
    /// Registers the APNs token with the relay for one gateway identity.
    func register(
        apnsTokenHex: String,
        topic: String,
        environment: GatewayAPNsEnvironment,
        gatewayIdentity: GatewayRelayIdentity) async throws -> PushRelayRegistration
}

/// User consent inputs that gate push enrollment.
public struct GatewayPushConsent: Sendable, Equatable {
    /// Whether the user accepted the app's push/relay disclosure.
    public var disclosureAccepted: Bool
    /// Current notification authorization.
    public var authorization: NotificationAuthorizationStatus

    /// Creates consent inputs.
    public init(disclosureAccepted: Bool, authorization: NotificationAuthorizationStatus) {
        self.disclosureAccepted = disclosureAccepted
        self.authorization = authorization
    }
}

/// Why a push registration was skipped. Reported through the diagnostics hook; never includes tokens.
public enum GatewayPushRegistrationSkipReason: String, Sendable, Equatable {
    /// The user has not accepted the enrollment disclosure.
    case enrollmentDisclosureNotAccepted = "enrollment_disclosure_not_accepted"
    /// Notifications are not authorized.
    case notificationsNotAuthorized = "notifications_not_authorized"
    /// No gateway node session is connected.
    case gatewayOffline = "gateway_offline"
    /// No APNs token is available yet.
    case missingAPNsToken = "missing_apns_token"
    /// No APNs topic (bundle identifier) is available.
    case missingTopic = "missing_topic"
    /// Relay registration needs an operator session for `gateway.identity.get`.
    case operatorOffline = "operator_offline"
    /// The same direct token was already registered with this gateway.
    case unchanged
}

/// Outcome of ``GatewayPushRegistrar/register(apnsTokenHex:topic:environment:consent:gatewayKey:)``.
public enum GatewayPushRegistrationOutcome: Sendable, Equatable {
    /// `push.apns.register` was sent.
    case registered(GatewayPushTransport)
    /// Registration was skipped.
    case skipped(GatewayPushRegistrationSkipReason)
    /// Building the registration failed (for example the relay rejected it).
    case failed(String)
}

/// Builds and publishes APNs registrations over `node.event` (`push.apns.register`).
///
/// Enrollment is consent-gated: nothing is published until the user accepted the disclosure and
/// notifications are authorized, provisional or ephemeral. Direct registrations are deduplicated per
/// gateway and token; call ``register(apnsTokenHex:topic:environment:consent:gatewayKey:)`` again when
/// the token or the gateway changes.
public actor GatewayPushRegistrar {
    /// Node event name.
    public static let eventName = "push.apns.register"

    private let node: (any GatewayNodeEventSending)?
    private let transport: GatewayPushTransport
    private let relayClient: (any PushRelayClient)?
    private let operatorClient: GatewayOperatorClient?
    private let installationId: String
    private let diagnostics: @Sendable (String) -> Void
    private var lastRegistrationKey: String?

    /// Creates a registrar.
    ///
    /// - Parameters:
    ///   - node: Connected node session (`nil` while offline).
    ///   - transport: Push transport; relay needs `relayClient` and `operatorClient`.
    ///   - relayClient: Hosted relay client (relay transport only).
    ///   - operatorClient: Operator client used for `gateway.identity.get` (relay transport only).
    ///   - installationId: Stable installation identifier (defaults to ``InstanceIdentity/instanceId``).
    ///   - diagnostics: Receives stage and skip messages; never receives tokens.
    public init(
        node: (any GatewayNodeEventSending)?,
        transport: GatewayPushTransport = .direct,
        relayClient: (any PushRelayClient)? = nil,
        operatorClient: GatewayOperatorClient? = nil,
        installationId: String = InstanceIdentity.instanceId,
        diagnostics: @escaping @Sendable (String) -> Void = { _ in })
    {
        self.node = node
        self.transport = transport
        self.relayClient = relayClient
        self.operatorClient = operatorClient
        self.installationId = installationId
        self.diagnostics = diagnostics
    }

    /// Direct-registration `payloadJSON`.
    public static func directPayloadJSON(tokenHex: String, topic: String, environment: GatewayAPNsEnvironment) throws -> String {
        try self.encode(DirectGatewayPushRegistrationPayload(token: tokenHex, topic: topic, environment: environment))
    }

    /// Relay-registration `payloadJSON`.
    public static func relayPayloadJSON(_ payload: RelayGatewayPushRegistrationPayload) throws -> String {
        try self.encode(payload)
    }

    /// First reason consent or inputs block enrollment, or `nil` when registration may proceed.
    public static func blockingReason(
        consent: GatewayPushConsent,
        apnsTokenHex: String?,
        topic: String?) -> GatewayPushRegistrationSkipReason?
    {
        guard consent.disclosureAccepted else { return .enrollmentDisclosureNotAccepted }
        guard consent.authorization.allowsPosting else { return .notificationsNotAuthorized }
        guard let apnsTokenHex, !apnsTokenHex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .missingAPNsToken
        }
        guard let topic, !topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .missingTopic }
        return nil
    }

    /// Publishes a registration when consent and inputs allow it.
    ///
    /// - Parameter gatewayKey: Stable identity of the connected gateway, used to re-register after a
    ///   gateway change and to skip unchanged direct tokens.
    public func register(
        apnsTokenHex: String?,
        topic: String?,
        environment: GatewayAPNsEnvironment,
        consent: GatewayPushConsent,
        gatewayKey: String) async -> GatewayPushRegistrationOutcome
    {
        if let reason = Self.blockingReason(consent: consent, apnsTokenHex: apnsTokenHex, topic: topic) {
            return self.skip(reason)
        }
        guard let node = self.node else { return self.skip(.gatewayOffline) }
        guard let token = apnsTokenHex?.trimmingCharacters(in: .whitespacesAndNewlines),
              let topic = topic?.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return self.skip(.missingAPNsToken) }

        let registrationKey = [gatewayKey, self.transport.rawValue, environment.rawValue, topic, Self.sha256Hex(token)]
            .joined(separator: "|")
        if self.transport == .direct, registrationKey == self.lastRegistrationKey {
            return self.skip(.unchanged)
        }

        let payloadJSON: String
        do {
            switch self.transport {
            case .direct:
                payloadJSON = try Self.directPayloadJSON(tokenHex: token, topic: topic, environment: environment)
            case .relay:
                guard let operatorClient = self.operatorClient, let relayClient = self.relayClient else {
                    return self.skip(.operatorOffline)
                }
                let identity = try await operatorClient.gatewayIdentity()
                let registration = try await relayClient.register(
                    apnsTokenHex: token,
                    topic: topic,
                    environment: environment,
                    gatewayIdentity: identity)
                payloadJSON = try Self.relayPayloadJSON(RelayGatewayPushRegistrationPayload(
                    relayHandle: registration.relayHandle,
                    sendGrant: registration.sendGrant,
                    gatewayDeviceId: identity.deviceId,
                    installationId: self.installationId,
                    topic: topic,
                    environment: environment,
                    distribution: "official",
                    relayOrigin: registration.relayOrigin,
                    tokenDebugSuffix: registration.tokenSuffix))
            }
        } catch {
            self.diagnostics("push registration failed: \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }

        await node.sendEvent(event: Self.eventName, payloadJSON: payloadJSON)
        self.lastRegistrationKey = registrationKey
        self.diagnostics("push registration published transport=\(self.transport.rawValue) env=\(environment.rawValue)")
        return .registered(self.transport)
    }

    /// Forgets the last registration so the next call publishes again.
    public func reset() {
        self.lastRegistrationKey = nil
    }

    private func skip(_ reason: GatewayPushRegistrationSkipReason) -> GatewayPushRegistrationOutcome {
        self.diagnostics("push registration skipped reason=\(reason.rawValue)")
        return .skipped(reason)
    }

    private static func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension GatewayOperatorClient {
    /// `push.test` (operator.write): sends a test notification to one node. `environment` `nil` uses the
    /// node's registered environment.
    public func pushTest(
        nodeId: String,
        title: String? = nil,
        body: String? = nil,
        environment: GatewayAPNsEnvironment? = nil) async throws -> PushTestResult
    {
        try await self.sender.request(
            method: "push.test",
            params: PushTestParams(nodeid: nodeId, title: title, body: body, environment: environment?.rawValue),
            timeoutMs: self.timeoutMs)
    }
}
