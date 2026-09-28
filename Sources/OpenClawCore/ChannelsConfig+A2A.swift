import Foundation
import OpenClawProtocol

/// One A2A peer (upstream `channels.a2a.peers.<name>`).
public struct A2APeerConfig: Codable, Sendable, Equatable {
    /// Bearer token the peer presents on inbound requests (required upstream).
    public var tokenInput: SecretInput?
    /// Peer JSON-RPC endpoint for outbound tasks.
    public var url: String?
    /// Bearer token sent to the peer on outbound requests.
    public var outboundTokenInput: SecretInput?

    /// Plaintext inbound token (`nil` when unset or a SecretRef).
    public var token: String? {
        get { self.tokenInput?.stringValue }
        set { self.tokenInput = newValue.map(SecretInput.string) }
    }

    /// Plaintext outbound token (`nil` when unset or a SecretRef).
    public var outboundToken: String? {
        get { self.outboundTokenInput?.stringValue }
        set { self.outboundTokenInput = newValue.map(SecretInput.string) }
    }

    /// Creates peer settings.
    /// - Parameters:
    ///   - token: Inbound bearer token.
    ///   - url: Outbound endpoint.
    ///   - outboundToken: Outbound bearer token.
    public init(token: String? = nil, url: String? = nil, outboundToken: String? = nil) {
        self.tokenInput = token.map(SecretInput.string)
        self.url = url
        self.outboundTokenInput = outboundToken.map(SecretInput.string)
    }

    /// Decodes peer settings leniently.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        var reader = try ChannelConfigReader(decoder: decoder)
        self.tokenInput = reader.secret("token")
        self.url = reader.value(String.self, "url")
        self.outboundTokenInput = reader.secret("outboundToken")
    }

    /// Encodes peer settings with upstream keys.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var writer = ChannelConfigWriter(encoder: encoder)
        try writer.encodeIfPresent(self.tokenInput, "token")
        try writer.encodeIfPresent(self.url, "url")
        try writer.encodeIfPresent(self.outboundTokenInput, "outboundToken")
    }
}

/// Agent2Agent (A2A 1.0) channel configuration (upstream `channels.a2a`).
///
/// Stored losslessly in ``ChannelsConfig/extensionChannels`` and read through ``ChannelsConfig/a2a``.
public struct A2AChannelConfig: Codable, Sendable, Equatable {
    /// Default blocking reply timeout.
    public static let defaultReplyTimeoutMs = 120_000
    /// Allowed reply timeout range (upstream schema bounds).
    public static let replyTimeoutRangeMs: ClosedRange<Int> = 5_000...600_000
    /// Default per-peer request budget per minute.
    public static let defaultRateLimitPerMinute = 30
    /// Peer name pattern (upstream `^[a-z0-9][a-z0-9._-]{0,63}$`).
    public static let peerNamePattern = "^[a-z0-9][a-z0-9._-]{0,63}$"

    /// Whether the channel is enabled.
    public var enabled: Bool
    /// Whether setup flows may write this config.
    public var configWrites: Bool?
    /// Public gateway origin advertised in the Agent Card (`http`/`https`).
    public var advertisedUrl: String?
    /// Blocking reply timeout in milliseconds, clamped to ``replyTimeoutRangeMs``.
    public var replyTimeoutMs: Int
    /// Requests per peer per minute (`0` disables the limit).
    public var rateLimitPerMinute: Int
    /// Agent ids listed as skills in the Agent Card (empty lists every agent).
    public var exposeAgents: [String]?
    /// Peers keyed by name.
    public var peers: [String: A2APeerConfig]
    /// Keys without a typed SDK field.
    public var additionalProperties: [String: AnyCodable]

    /// Creates A2A settings.
    /// - Parameters:
    ///   - enabled: Whether the channel is enabled.
    ///   - advertisedUrl: Public gateway origin.
    ///   - replyTimeoutMs: Blocking reply timeout.
    ///   - rateLimitPerMinute: Requests per peer per minute.
    ///   - exposeAgents: Exposed agent ids.
    ///   - peers: Peers keyed by name.
    public init(
        enabled: Bool = false,
        advertisedUrl: String? = nil,
        replyTimeoutMs: Int = A2AChannelConfig.defaultReplyTimeoutMs,
        rateLimitPerMinute: Int = A2AChannelConfig.defaultRateLimitPerMinute,
        exposeAgents: [String]? = nil,
        peers: [String: A2APeerConfig] = [:]
    ) {
        self.enabled = enabled
        self.configWrites = nil
        self.advertisedUrl = advertisedUrl
        self.replyTimeoutMs = Self.clampReplyTimeout(replyTimeoutMs)
        self.rateLimitPerMinute = max(0, rateLimitPerMinute)
        self.exposeAgents = exposeAgents
        self.peers = peers
        self.additionalProperties = [:]
    }

    /// Clamps a reply timeout into ``replyTimeoutRangeMs``.
    /// - Parameter value: Requested timeout.
    /// - Returns: Clamped timeout.
    public static func clampReplyTimeout(_ value: Int) -> Int {
        min(max(value, self.replyTimeoutRangeMs.lowerBound), self.replyTimeoutRangeMs.upperBound)
    }

    /// Whether a peer name matches the upstream pattern.
    /// - Parameter name: Peer name.
    /// - Returns: `true` when valid.
    public static func isValidPeerName(_ name: String) -> Bool {
        name.range(of: self.peerNamePattern, options: .regularExpression) != nil
    }

    /// Peers whose names satisfy the upstream pattern and that have an inbound token.
    public var validPeers: [String: A2APeerConfig] {
        self.peers.filter { Self.isValidPeerName($0.key) && $0.value.tokenInput != nil }
    }

    /// Whether at least one valid peer is configured.
    public var isConfigured: Bool {
        !self.validPeers.isEmpty
    }

    /// Decodes upstream-shaped A2A settings leniently.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        var reader = try ChannelConfigReader(decoder: decoder)
        self.enabled = reader.value(Bool.self, "enabled") ?? true
        self.configWrites = reader.value(Bool.self, "configWrites")
        self.advertisedUrl = reader.value(String.self, "advertisedUrl")
        self.replyTimeoutMs = Self.clampReplyTimeout(reader.value(Int.self, "replyTimeoutMs") ?? Self.defaultReplyTimeoutMs)
        self.rateLimitPerMinute = max(0, reader.value(Int.self, "rateLimitPerMinute") ?? Self.defaultRateLimitPerMinute)
        self.exposeAgents = reader.stringList("exposeAgents")
        self.peers = reader.value([String: A2APeerConfig].self, "peers") ?? [:]
        for name in self.peers.keys where !Self.isValidPeerName(name) {
            reader.recordIssue(
                "channels.a2a.peers.\(name) does not match \(Self.peerNamePattern) and is ignored.",
                kind: .invalidValue,
                forKey: "peers"
            )
        }
        self.additionalProperties = reader.remaining()
    }

    /// Encodes A2A settings with upstream keys.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var writer = ChannelConfigWriter(encoder: encoder)
        try writer.encode(self.enabled, "enabled")
        try writer.encodeIfPresent(self.configWrites, "configWrites")
        try writer.encodeIfPresent(self.advertisedUrl, "advertisedUrl")
        if self.replyTimeoutMs != Self.defaultReplyTimeoutMs {
            try writer.encode(self.replyTimeoutMs, "replyTimeoutMs")
        }
        if self.rateLimitPerMinute != Self.defaultRateLimitPerMinute {
            try writer.encode(self.rateLimitPerMinute, "rateLimitPerMinute")
        }
        try writer.encodeIfPresent(self.exposeAgents, "exposeAgents")
        try writer.encodeIfNotEmpty(self.peers, "peers")
        try writer.encodePassthrough(
            self.additionalProperties,
            skipping: ["enabled", "configWrites", "advertisedUrl", "replyTimeoutMs", "rateLimitPerMinute", "exposeAgents", "peers"]
        )
    }
}

public extension ChannelsConfig {
    /// Typed view of `channels.a2a` (stored in ``extensionChannels`` so it round-trips losslessly).
    var a2a: A2AChannelConfig {
        get { ChannelsConfig.typedExtensionSection(A2AChannelConfig.self, raw: self.rawSection(named: "a2a")) ?? A2AChannelConfig() }
        set { self.setExtensionSection(newValue, named: "a2a") }
    }
}
