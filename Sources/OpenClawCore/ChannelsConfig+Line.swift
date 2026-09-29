import Foundation
import OpenClawProtocol

/// LINE Messaging API channel configuration (upstream `channels.line`).
///
/// Stored losslessly in ``ChannelsConfig/extensionChannels`` and read through ``ChannelsConfig/line``.
/// Policy keys (`dmPolicy` default `pairing`, `groupPolicy` default `allowlist`, `allowFrom`,
/// `groupAllowFrom`, `mediaMaxMb`, `replyToMode`, `historyLimit`, `joinIntro`, `groups`) live in
/// ``policy``.
public struct LineChannelConfig: ChannelSectionConfig {
    /// Default inbound webhook path (upstream `LINE_DEFAULT_WEBHOOK_PATH`).
    public static let defaultWebhookPath = "/line/webhook"
    /// Reason reported when credentials are missing.
    public static let unconfiguredReason = "LINE requires channelAccessToken and channelSecret (or tokenFile and secretFile)."

    /// Whether the channel is enabled.
    public var enabled: Bool
    /// Channel access token (plaintext, env template or SecretRef).
    public var channelAccessTokenInput: SecretInput?
    /// Channel secret used to verify `X-Line-Signature`.
    public var channelSecretInput: SecretInput?
    /// File holding the channel access token.
    public var tokenFile: String?
    /// File holding the channel secret.
    public var secretFile: String?
    /// Inbound webhook path (default `/line/webhook`).
    public var webhookPath: String
    /// Shared messaging policy keys.
    public var policy: ChannelMessagingPolicyConfig
    /// Per-account overrides.
    public var accounts: [String: ChannelAccountOverride]
    /// Default account id.
    public var defaultAccount: String?
    /// Upstream keys without a typed SDK field.
    public var additionalProperties: [String: AnyCodable]

    /// Plaintext channel access token.
    public var channelAccessToken: String? {
        get { self.channelAccessTokenInput?.stringValue }
        set { self.channelAccessTokenInput = newValue.map(SecretInput.string) }
    }

    /// Plaintext channel secret.
    public var channelSecret: String? {
        get { self.channelSecretInput?.stringValue }
        set { self.channelSecretInput = newValue.map(SecretInput.string) }
    }

    /// Creates LINE settings.
    /// - Parameters:
    ///   - enabled: Whether the channel is enabled.
    ///   - channelAccessToken: Channel access token.
    ///   - channelSecret: Channel secret.
    ///   - webhookPath: Inbound webhook path.
    ///   - policy: Shared messaging policy keys.
    public init(
        enabled: Bool = false,
        channelAccessToken: String? = nil,
        channelSecret: String? = nil,
        webhookPath: String = LineChannelConfig.defaultWebhookPath,
        policy: ChannelMessagingPolicyConfig = ChannelMessagingPolicyConfig()
    ) {
        self.enabled = enabled
        self.channelAccessTokenInput = channelAccessToken.map(SecretInput.string)
        self.channelSecretInput = channelSecret.map(SecretInput.string)
        self.tokenFile = nil
        self.secretFile = nil
        self.webhookPath = Self.normalizeWebhookPath(webhookPath)
        self.policy = policy
        self.accounts = [:]
        self.defaultAccount = nil
        self.additionalProperties = [:]
    }

    /// Key spellings that name the same setting.
    public static let keyAliasGroups: [[String]] = []

    private static let writtenKeys: Set<String> = [
        "enabled", "channelAccessToken", "channelSecret", "tokenFile", "secretFile", "webhookPath",
    ]

    /// Policy with LINE defaults applied (`dmPolicy: pairing`, `groupPolicy: allowlist`).
    public var effectivePolicy: ChannelMessagingPolicyConfig {
        var policy = self.policy
        policy.dmPolicy = policy.dmPolicy ?? .pairing
        policy.groupPolicy = policy.groupPolicy ?? .allowlist
        return policy
    }

    /// Whether a token and a secret are configured (inline or through files).
    public var isConfigured: Bool {
        (self.channelAccessTokenInput != nil || self.tokenFile != nil) && (self.channelSecretInput != nil || self.secretFile != nil)
    }

    /// Normalizes a webhook path like upstream `resolveLineWebhookPath` (leading slash, no trailing slash).
    /// - Parameter path: Configured path.
    /// - Returns: Normalized path (default when blank).
    public static func normalizeWebhookPath(_ path: String?) -> String {
        var trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        while trimmed.count > 1, trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard !trimmed.isEmpty, trimmed != "/" else { return self.defaultWebhookPath }
        return trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
    }

    /// Decodes upstream-shaped LINE settings leniently.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        var reader = try ChannelConfigReader(decoder: decoder)
        self.enabled = reader.value(Bool.self, "enabled") ?? true
        self.channelAccessTokenInput = reader.secret("channelAccessToken")
        self.channelSecretInput = reader.secret("channelSecret")
        self.tokenFile = reader.value(String.self, "tokenFile")
        self.secretFile = reader.value(String.self, "secretFile")
        self.webhookPath = Self.normalizeWebhookPath(reader.value(String.self, "webhookPath"))
        self.policy = ChannelMessagingPolicyConfig(reader: &reader)
        self.accounts = reader.value([String: ChannelAccountOverride].self, "accounts") ?? [:]
        self.defaultAccount = reader.value(String.self, "defaultAccount")
        self.additionalProperties = reader.remaining()
    }

    /// Encodes LINE settings with upstream keys.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var writer = ChannelConfigWriter(encoder: encoder)
        try writer.encode(self.enabled, "enabled")
        try writer.encodeIfPresent(self.channelAccessTokenInput, "channelAccessToken")
        try writer.encodeIfPresent(self.channelSecretInput, "channelSecret")
        try writer.encodeIfPresent(self.tokenFile, "tokenFile")
        try writer.encodeIfPresent(self.secretFile, "secretFile")
        if self.webhookPath != Self.defaultWebhookPath {
            try writer.encode(self.webhookPath, "webhookPath")
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
    /// Typed view of `channels.line` (stored in ``extensionChannels`` so it round-trips losslessly).
    var line: LineChannelConfig {
        get { ChannelsConfig.typedExtensionSection(LineChannelConfig.self, raw: self.rawSection(named: "line")) ?? LineChannelConfig() }
        set { self.setExtensionSection(newValue, named: "line") }
    }
}
