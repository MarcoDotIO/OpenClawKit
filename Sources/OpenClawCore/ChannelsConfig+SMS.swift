import Foundation
import OpenClawProtocol

/// Transport used by the native SMS channel (SDK extension key `transport`).
public enum SMSTransportKind: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// Twilio Programmable Messaging REST API plus signed webhooks (upstream default).
    case twilio
    /// On-device carrier messaging through TelephonyMessagingKit (iOS 26+, entitlement-gated).
    case carrier
}

/// SMS channel configuration (upstream `channels.sms`, Twilio SMS/MMS).
///
/// The section is stored losslessly in ``ChannelsConfig/extensionChannels`` (it is a plugin
/// channel upstream) and read through ``ChannelsConfig/sms``. Messaging policy keys (`dmPolicy`
/// default `pairing`, `allowFrom`, `textChunkLimit`, `mediaMaxMb`, `defaultTo`, ...) live in
/// ``policy``.
///
/// - Note: US carriers require A2P 10DLC registration for application-to-person SMS; unregistered
///   long-code traffic is filtered or blocked by the carriers, not by Twilio or OpenClawKit.
public struct SMSChannelConfig: ChannelSectionConfig {
    /// Default inbound webhook path.
    public static let defaultWebhookPath = "/webhooks/sms"
    /// Default outbound chunk limit (characters).
    public static let defaultTextChunkLimit = 1_500
    /// Reason reported when the channel lacks credentials (upstream wording).
    public static let unconfiguredReason = "SMS requires accountSid, authToken, and fromNumber or messagingServiceSid."

    /// Whether the channel is enabled.
    public var enabled: Bool
    /// Twilio Account SID.
    public var accountSid: String?
    /// Twilio auth token (plaintext, env template or SecretRef).
    public var authTokenInput: SecretInput?
    /// Sending phone number in E.164 format; wins over ``messagingServiceSid`` when both are set.
    public var fromNumber: String?
    /// Twilio Messaging Service SID used instead of a dedicated number.
    public var messagingServiceSid: String?
    /// Gateway path receiving Twilio webhooks (default `/webhooks/sms`; distinct per account).
    public var webhookPath: String
    /// Public URL configured in Twilio; must equal the URL Twilio signs.
    public var publicWebhookUrl: String?
    /// Skips `X-Twilio-Signature` validation (never enable on a public endpoint).
    public var dangerouslyDisableSignatureValidation: Bool
    /// SMS transport (SDK extension; default ``SMSTransportKind/twilio``).
    public var transport: SMSTransportKind
    /// Shared messaging policy keys.
    public var policy: ChannelMessagingPolicyConfig
    /// Per-account overrides.
    public var accounts: [String: ChannelAccountOverride]
    /// Default account id.
    public var defaultAccount: String?
    /// Upstream keys without a typed SDK field.
    public var additionalProperties: [String: AnyCodable]

    /// Plaintext auth token (`nil` when unset or a SecretRef).
    public var authToken: String? {
        get { self.authTokenInput?.stringValue }
        set { self.authTokenInput = newValue.map(SecretInput.string) }
    }

    /// Creates SMS channel settings.
    /// - Parameters:
    ///   - enabled: Whether the channel is enabled.
    ///   - accountSid: Twilio Account SID.
    ///   - authToken: Twilio auth token.
    ///   - fromNumber: Sending number (E.164).
    ///   - messagingServiceSid: Messaging Service SID.
    ///   - webhookPath: Inbound webhook path.
    ///   - publicWebhookUrl: Public webhook URL signed by Twilio.
    ///   - dangerouslyDisableSignatureValidation: Skip signature validation.
    ///   - transport: SMS transport.
    ///   - policy: Shared messaging policy keys.
    public init(
        enabled: Bool = false,
        accountSid: String? = nil,
        authToken: String? = nil,
        fromNumber: String? = nil,
        messagingServiceSid: String? = nil,
        webhookPath: String = SMSChannelConfig.defaultWebhookPath,
        publicWebhookUrl: String? = nil,
        dangerouslyDisableSignatureValidation: Bool = false,
        transport: SMSTransportKind = .twilio,
        policy: ChannelMessagingPolicyConfig = ChannelMessagingPolicyConfig()
    ) {
        self.enabled = enabled
        self.accountSid = accountSid
        self.authTokenInput = authToken.map(SecretInput.string)
        self.fromNumber = fromNumber
        self.messagingServiceSid = messagingServiceSid
        self.webhookPath = webhookPath
        self.publicWebhookUrl = publicWebhookUrl
        self.dangerouslyDisableSignatureValidation = dangerouslyDisableSignatureValidation
        self.transport = transport
        self.policy = policy
        self.accounts = [:]
        self.defaultAccount = nil
        self.additionalProperties = [:]
    }

    /// Key spellings that name the same setting.
    public static let keyAliasGroups: [[String]] = []

    private static let writtenKeys: Set<String> = [
        "enabled", "accountSid", "authToken", "fromNumber", "messagingServiceSid", "webhookPath", "publicWebhookUrl",
        "dangerouslyDisableSignatureValidation", "transport",
    ]

    /// Policy with the SMS defaults applied (`dmPolicy: pairing`, `textChunkLimit: 1500`).
    public var effectivePolicy: ChannelMessagingPolicyConfig {
        var policy = self.policy
        policy.dmPolicy = policy.dmPolicy ?? .pairing
        policy.textChunkLimit = policy.textChunkLimit.flatMap { $0 > 0 ? $0 : nil } ?? Self.defaultTextChunkLimit
        return policy
    }

    /// Effective outbound chunk limit.
    public var textChunkLimit: Int {
        self.effectivePolicy.textChunkLimit ?? Self.defaultTextChunkLimit
    }

    /// Whether the resolved account has Twilio credentials and a sender
    /// (`accountSid`, `authToken`, and `fromNumber` or `messagingServiceSid`).
    public var isConfigured: Bool {
        guard self.transport == .twilio else { return true }
        let sid = self.accountSid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let token = self.authToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let from = self.fromNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let service = self.messagingServiceSid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !sid.isEmpty && !token.isEmpty && (!from.isEmpty || !service.isEmpty)
    }

    /// Applies upstream's environment fallbacks (default account only): `TWILIO_ACCOUNT_SID`,
    /// `TWILIO_AUTH_TOKEN`, `TWILIO_PHONE_NUMBER` or `TWILIO_SMS_FROM`, `TWILIO_MESSAGING_SERVICE_SID`,
    /// `SMS_WEBHOOK_PATH`, `SMS_PUBLIC_WEBHOOK_URL`.
    /// - Parameters:
    ///   - environment: Process environment.
    ///   - accountID: Account being resolved (`nil`/`default` receives the fallbacks).
    /// - Returns: A copy with blank fields filled from the environment.
    public func applyingEnvironmentFallbacks(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        accountID: String? = nil
    ) -> SMSChannelConfig {
        let normalizedAccount = accountID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard normalizedAccount.isEmpty || normalizedAccount == "default" else { return self }
        func env(_ keys: String...) -> String? {
            for key in keys {
                if let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                    return value
                }
            }
            return nil
        }
        func blank(_ value: String?) -> Bool {
            (value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        }
        var copy = self
        if blank(copy.accountSid) { copy.accountSid = env("TWILIO_ACCOUNT_SID") ?? copy.accountSid }
        if copy.authTokenInput == nil, let token = env("TWILIO_AUTH_TOKEN") { copy.authTokenInput = .string(token) }
        if blank(copy.fromNumber) { copy.fromNumber = env("TWILIO_PHONE_NUMBER", "TWILIO_SMS_FROM") ?? copy.fromNumber }
        if blank(copy.messagingServiceSid) {
            copy.messagingServiceSid = env("TWILIO_MESSAGING_SERVICE_SID") ?? copy.messagingServiceSid
        }
        if copy.webhookPath == Self.defaultWebhookPath, let path = env("SMS_WEBHOOK_PATH") { copy.webhookPath = path }
        if blank(copy.publicWebhookUrl) { copy.publicWebhookUrl = env("SMS_PUBLIC_WEBHOOK_URL") ?? copy.publicWebhookUrl }
        return copy
    }

    /// Decodes upstream-shaped SMS settings leniently.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        var reader = try ChannelConfigReader(decoder: decoder)
        self.enabled = reader.value(Bool.self, "enabled") ?? true
        self.accountSid = reader.value(String.self, "accountSid")
        self.authTokenInput = reader.secret("authToken")
        self.fromNumber = reader.value(ChannelLooseStringEntry.self, "fromNumber")?.value
        self.messagingServiceSid = reader.value(String.self, "messagingServiceSid")
        let path = reader.value(String.self, "webhookPath")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.webhookPath = path.isEmpty ? Self.defaultWebhookPath : path
        self.publicWebhookUrl = reader.value(String.self, "publicWebhookUrl")
        self.dangerouslyDisableSignatureValidation = reader.value(Bool.self, "dangerouslyDisableSignatureValidation") ?? false
        self.transport = reader.value(SMSTransportKind.self, "transport") ?? .twilio
        self.policy = ChannelMessagingPolicyConfig(reader: &reader)
        self.accounts = reader.value([String: ChannelAccountOverride].self, "accounts") ?? [:]
        self.defaultAccount = reader.value(String.self, "defaultAccount")
        self.additionalProperties = reader.remaining()
    }

    /// Encodes SMS settings with upstream key names (`transport` only when not Twilio).
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var writer = ChannelConfigWriter(encoder: encoder)
        try writer.encode(self.enabled, "enabled")
        try writer.encodeIfPresent(self.accountSid, "accountSid")
        try writer.encodeIfPresent(self.authTokenInput, "authToken")
        try writer.encodeIfPresent(self.fromNumber, "fromNumber")
        try writer.encodeIfPresent(self.messagingServiceSid, "messagingServiceSid")
        if self.webhookPath != Self.defaultWebhookPath {
            try writer.encode(self.webhookPath, "webhookPath")
        }
        try writer.encodeIfPresent(self.publicWebhookUrl, "publicWebhookUrl")
        if self.dangerouslyDisableSignatureValidation {
            try writer.encode(true, "dangerouslyDisableSignatureValidation")
        }
        if self.transport != .twilio {
            try writer.encode(self.transport, "transport")
        }
        try ChannelSectionCoding.encodeCommon(
            to: encoder,
            policy: self.policy,
            excluding: [],
            accounts: self.accounts,
            defaultAccount: self.defaultAccount,
            additionalProperties: self.additionalProperties,
            written: Self.writtenKeys
        )
    }
}

public extension ChannelsConfig {
    /// Typed view of `channels.sms` (stored in ``extensionChannels`` so it round-trips losslessly).
    ///
    /// Reading an absent section returns a disabled default; assigning writes the section back.
    var sms: SMSChannelConfig {
        get { ChannelsConfig.typedExtensionSection(SMSChannelConfig.self, raw: self.rawSection(named: "sms")) ?? SMSChannelConfig() }
        set { self.setExtensionSection(newValue, named: "sms") }
    }

    /// Decodes a raw extension section into a typed config.
    internal static func typedExtensionSection<T: Decodable>(_ type: T.Type, raw: [String: AnyCodable]?) -> T? {
        guard let raw else { return nil }
        return ChannelConfigJSON.decode(type, from: raw)
    }

    /// Writes a typed section into ``extensionChannels`` under `name`.
    internal mutating func setExtensionSection(_ value: some Encodable, named name: String) {
        guard let object = ChannelConfigJSON.object(from: value) else { return }
        let existingKey = self.extensionChannels.keys.first { $0.lowercased() == name } ?? name
        self.extensionChannels[existingKey] = AnyCodable(AnySendableValue.object(object))
    }
}
