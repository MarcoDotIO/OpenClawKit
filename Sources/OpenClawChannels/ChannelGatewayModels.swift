import Foundation
import OpenClawCore
import OpenClawProtocol

/// Dynamic JSON key used by the channel gateway models.
struct ChannelGatewayKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue _: Int) {
        nil
    }
}

/// One channel account in `channels.status` (upstream `ChannelAccountSnapshot`).
///
/// Timestamps are epoch milliseconds as `Int64` (safe on 32-bit watchOS); keys this type does
/// not model are preserved in ``additionalProperties``.
public struct ChannelAccountStatusSnapshot: Codable, Sendable, Equatable {
    /// Account id (`default` for single-account channels).
    public var accountID: String
    /// Account display name.
    public var name: String?
    /// Whether the account is enabled in config.
    public var enabled: Bool?
    /// Whether the account has the configuration it needs.
    public var configured: Bool?
    /// Whether the account runtime runs.
    public var running: Bool?
    /// Whether the account is connected.
    public var connected: Bool?
    /// Last error.
    public var lastError: String?
    /// Health state understood by the macOS app (`healthy`, `not-running`, `disconnected`, `blocked`).
    public var healthState: String?
    /// Last inbound message time (epoch ms).
    public var lastInboundAt: Int64?
    /// Last outbound message time (epoch ms).
    public var lastOutboundAt: Int64?
    /// Last start time (epoch ms).
    public var lastStartAt: Int64?
    /// Last stop time (epoch ms).
    public var lastStopAt: Int64?
    /// Last probe time (epoch ms).
    public var lastProbeAt: Int64?
    /// Connection mode (for example Slack `socket`).
    public var mode: String?
    /// DM policy.
    public var dmPolicy: String?
    /// DM allowlist.
    public var allowFrom: [String]?
    /// Webhook path.
    public var webhookPath: String?
    /// API base URL.
    public var baseURL: String?
    /// Probe result.
    public var probe: AnyCodable?
    /// Unmodeled keys.
    public var additionalProperties: [String: AnyCodable]

    /// Creates an account snapshot.
    /// - Parameters:
    ///   - accountID: Account id.
    ///   - name: Display name.
    ///   - enabled: Whether enabled.
    ///   - configured: Whether configured.
    ///   - running: Whether running.
    ///   - connected: Whether connected.
    ///   - lastError: Last error.
    ///   - healthState: Health state.
    public init(
        accountID: String,
        name: String? = nil,
        enabled: Bool? = nil,
        configured: Bool? = nil,
        running: Bool? = nil,
        connected: Bool? = nil,
        lastError: String? = nil,
        healthState: String? = nil
    ) {
        self.accountID = accountID
        self.name = name
        self.enabled = enabled
        self.configured = configured
        self.running = running
        self.connected = connected
        self.lastError = lastError
        self.healthState = healthState
        self.additionalProperties = [:]
    }

    private static let modeledKeys: Set<String> = [
        "accountId", "name", "enabled", "configured", "running", "connected", "lastError", "healthState",
        "lastInboundAt", "lastOutboundAt", "lastStartAt", "lastStopAt", "lastProbeAt", "mode", "dmPolicy",
        "allowFrom", "webhookPath", "baseUrl", "probe",
    ]

    /// Decodes an upstream account snapshot.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ChannelGatewayKey.self)
        func value<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
            try? container.decodeIfPresent(type, forKey: ChannelGatewayKey(key))
        }
        self.accountID = value(String.self, "accountId") ?? "default"
        self.name = value(String.self, "name")
        self.enabled = value(Bool.self, "enabled")
        self.configured = value(Bool.self, "configured")
        self.running = value(Bool.self, "running")
        self.connected = value(Bool.self, "connected")
        self.lastError = value(String.self, "lastError")
        self.healthState = value(String.self, "healthState")
        self.lastInboundAt = value(Int64.self, "lastInboundAt")
        self.lastOutboundAt = value(Int64.self, "lastOutboundAt")
        self.lastStartAt = value(Int64.self, "lastStartAt")
        self.lastStopAt = value(Int64.self, "lastStopAt")
        self.lastProbeAt = value(Int64.self, "lastProbeAt")
        self.mode = value(String.self, "mode")
        self.dmPolicy = value(String.self, "dmPolicy")
        self.allowFrom = value([String].self, "allowFrom")
        self.webhookPath = value(String.self, "webhookPath")
        self.baseURL = value(String.self, "baseUrl")
        self.probe = value(AnyCodable.self, "probe")
        var extra: [String: AnyCodable] = [:]
        for key in container.allKeys where !Self.modeledKeys.contains(key.stringValue) {
            extra[key.stringValue] = try? container.decode(AnyCodable.self, forKey: key)
        }
        self.additionalProperties = extra
    }

    /// Encodes the snapshot with upstream keys.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ChannelGatewayKey.self)
        func put<T: Encodable>(_ value: T?, _ key: String) throws {
            try container.encodeIfPresent(value, forKey: ChannelGatewayKey(key))
        }
        for (key, value) in self.additionalProperties where !Self.modeledKeys.contains(key) {
            try container.encode(value, forKey: ChannelGatewayKey(key))
        }
        try put(self.accountID, "accountId")
        try put(self.name, "name")
        try put(self.enabled, "enabled")
        try put(self.configured, "configured")
        try put(self.running, "running")
        try put(self.connected, "connected")
        try put(self.lastError, "lastError")
        try put(self.healthState, "healthState")
        try put(self.lastInboundAt, "lastInboundAt")
        try put(self.lastOutboundAt, "lastOutboundAt")
        try put(self.lastStartAt, "lastStartAt")
        try put(self.lastStopAt, "lastStopAt")
        try put(self.lastProbeAt, "lastProbeAt")
        try put(self.mode, "mode")
        try put(self.dmPolicy, "dmPolicy")
        try put(self.allowFrom, "allowFrom")
        try put(self.webhookPath, "webhookPath")
        try put(self.baseURL, "baseUrl")
        try put(self.probe, "probe")
    }
}

/// One `channels.status` status issue (upstream `statusIssues[]`).
public struct ChannelStatusIssue: Codable, Sendable, Equatable {
    /// Issue kind.
    public enum Kind: String, Codable, Sendable, Equatable, CaseIterable {
        /// Missing platform intent/permission grant.
        case intent
        /// Missing permission.
        case permissions
        /// Configuration problem.
        case config
        /// Authentication problem.
        case auth
        /// Runtime problem.
        case runtime
    }

    /// Channel id.
    public var channel: String
    /// Account id.
    public var accountID: String
    /// Issue kind.
    public var kind: Kind
    /// Human-readable message.
    public var message: String
    /// Suggested fix.
    public var fix: String?

    /// Creates a status issue.
    /// - Parameters:
    ///   - channel: Channel id.
    ///   - accountID: Account id.
    ///   - kind: Issue kind.
    ///   - message: Message.
    ///   - fix: Suggested fix.
    public init(channel: String, accountID: String = "default", kind: Kind, message: String, fix: String? = nil) {
        self.channel = channel
        self.accountID = accountID
        self.kind = kind
        self.message = message
        self.fix = fix
    }

    private enum CodingKeys: String, CodingKey {
        case channel
        case accountID = "accountId"
        case kind
        case message
        case fix
    }
}

/// UI metadata for one channel (upstream `ChannelUiMeta`).
public struct ChannelUIMeta: Codable, Sendable, Equatable {
    /// Channel id.
    public var id: String
    /// Label.
    public var label: String
    /// Detail label (falls back to the label).
    public var detailLabel: String
    /// SF Symbol name.
    public var systemImage: String?

    /// Creates UI metadata.
    /// - Parameters:
    ///   - id: Channel id.
    ///   - label: Label.
    ///   - detailLabel: Detail label.
    ///   - systemImage: SF Symbol name.
    public init(id: String, label: String, detailLabel: String, systemImage: String? = nil) {
        self.id = id
        self.label = label
        self.detailLabel = detailLabel
        self.systemImage = systemImage
    }
}

/// Per-channel summary in `channels.status` (`channels[<id>]`).
public struct ChannelStatusSummary: Codable, Sendable, Equatable {
    /// Whether the channel is configured.
    public var configured: Bool
    /// Whether any account runs.
    public var running: Bool
    /// Whether any account is connected.
    public var connected: Bool
    /// Last error.
    public var lastError: String?

    /// Creates a summary.
    /// - Parameters:
    ///   - configured: Whether configured.
    ///   - running: Whether running.
    ///   - connected: Whether connected.
    ///   - lastError: Last error.
    public init(configured: Bool, running: Bool, connected: Bool, lastError: String? = nil) {
        self.configured = configured
        self.running = running
        self.connected = connected
        self.lastError = lastError
    }
}

/// Typed `channels.status` result (upstream `ChannelsStatusResult`, Int64-safe timestamps).
public struct ChannelsStatusReport: Codable, Sendable, Equatable {
    /// Report time (epoch ms).
    public var ts: Int64
    /// Channel ids in upstream catalog order.
    public var channelOrder: [String]
    /// Labels by channel id.
    public var channelLabels: [String: String]
    /// Detail labels by channel id.
    public var channelDetailLabels: [String: String]?
    /// SF Symbols by channel id.
    public var channelSystemImages: [String: String]?
    /// UI metadata.
    public var channelMeta: [ChannelUIMeta]?
    /// Per-channel summaries.
    public var channels: [String: ChannelStatusSummary]
    /// Account snapshots by channel id.
    public var channelAccounts: [String: [ChannelAccountStatusSnapshot]]
    /// Default account id by channel id.
    public var channelDefaultAccountID: [String: String]
    /// Whether the report is partial.
    public var partial: Bool?
    /// Warnings.
    public var warnings: [String]?
    /// Status issues (at most 50).
    public var statusIssues: [ChannelStatusIssue]?

    /// Creates a report.
    /// - Parameters:
    ///   - ts: Report time (epoch ms).
    ///   - channelOrder: Channel order.
    ///   - channelLabels: Labels.
    ///   - channelDetailLabels: Detail labels.
    ///   - channelSystemImages: SF Symbols.
    ///   - channelMeta: UI metadata.
    ///   - channels: Summaries.
    ///   - channelAccounts: Account snapshots.
    ///   - channelDefaultAccountID: Default account ids.
    ///   - partial: Whether partial.
    ///   - warnings: Warnings.
    ///   - statusIssues: Status issues.
    public init(
        ts: Int64,
        channelOrder: [String],
        channelLabels: [String: String],
        channelDetailLabels: [String: String]? = nil,
        channelSystemImages: [String: String]? = nil,
        channelMeta: [ChannelUIMeta]? = nil,
        channels: [String: ChannelStatusSummary],
        channelAccounts: [String: [ChannelAccountStatusSnapshot]],
        channelDefaultAccountID: [String: String],
        partial: Bool? = nil,
        warnings: [String]? = nil,
        statusIssues: [ChannelStatusIssue]? = nil
    ) {
        self.ts = ts
        self.channelOrder = channelOrder
        self.channelLabels = channelLabels
        self.channelDetailLabels = channelDetailLabels
        self.channelSystemImages = channelSystemImages
        self.channelMeta = channelMeta
        self.channels = channels
        self.channelAccounts = channelAccounts
        self.channelDefaultAccountID = channelDefaultAccountID
        self.partial = partial
        self.warnings = warnings
        self.statusIssues = statusIssues
    }

    private enum CodingKeys: String, CodingKey {
        case ts
        case channelOrder
        case channelLabels
        case channelDetailLabels
        case channelSystemImages
        case channelMeta
        case channels
        case channelAccounts
        case channelDefaultAccountID = "channelDefaultAccountId"
        case partial
        case warnings
        case statusIssues
    }
}

/// One pairing-policy account in `channels.pairing.list`.
public struct ChannelPairingAccountInfo: Codable, Sendable, Equatable {
    /// Channel id.
    public var channel: String
    /// Channel label.
    public var channelLabel: String
    /// Account id.
    public var accountID: String
    /// Account label.
    public var accountLabel: String?
    /// Whether approval notifications can be sent.
    public var notifySupported: Bool

    /// Creates account info.
    /// - Parameters:
    ///   - channel: Channel id.
    ///   - channelLabel: Channel label.
    ///   - accountID: Account id.
    ///   - accountLabel: Account label.
    ///   - notifySupported: Whether notifications are supported.
    public init(channel: String, channelLabel: String, accountID: String, accountLabel: String? = nil, notifySupported: Bool) {
        self.channel = channel
        self.channelLabel = channelLabel
        self.accountID = accountID
        self.accountLabel = accountLabel
        self.notifySupported = notifySupported
    }

    private enum CodingKeys: String, CodingKey {
        case channel
        case channelLabel
        case accountID = "accountId"
        case accountLabel
        case notifySupported
    }
}

/// One pending request in `channels.pairing.list`.
public struct ChannelPairingRequestInfo: Codable, Sendable, Equatable {
    /// Opaque request id.
    public var requestID: String
    /// Channel id.
    public var channel: String
    /// Channel label.
    public var channelLabel: String
    /// Account id.
    public var accountID: String
    /// Account label.
    public var accountLabel: String?
    /// Sender id.
    public var senderID: String
    /// Label of the sender id kind (for example `userId`).
    public var senderLabel: String
    /// Request metadata.
    public var metadata: [String: String]?
    /// Creation time (ISO-8601).
    public var createdAt: String
    /// Last-seen time (ISO-8601).
    public var lastSeenAt: String
    /// Expiry time (ISO-8601).
    public var expiresAt: String
    /// Whether approval notifications can be sent.
    public var notifySupported: Bool

    /// Creates request info.
    /// - Parameters:
    ///   - requestID: Request id.
    ///   - channel: Channel id.
    ///   - channelLabel: Channel label.
    ///   - accountID: Account id.
    ///   - accountLabel: Account label.
    ///   - senderID: Sender id.
    ///   - senderLabel: Sender id label.
    ///   - metadata: Metadata.
    ///   - createdAt: Creation time.
    ///   - lastSeenAt: Last-seen time.
    ///   - expiresAt: Expiry time.
    ///   - notifySupported: Whether notifications are supported.
    public init(
        requestID: String,
        channel: String,
        channelLabel: String,
        accountID: String,
        accountLabel: String? = nil,
        senderID: String,
        senderLabel: String,
        metadata: [String: String]? = nil,
        createdAt: String,
        lastSeenAt: String,
        expiresAt: String,
        notifySupported: Bool
    ) {
        self.requestID = requestID
        self.channel = channel
        self.channelLabel = channelLabel
        self.accountID = accountID
        self.accountLabel = accountLabel
        self.senderID = senderID
        self.senderLabel = senderLabel
        self.metadata = metadata
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.expiresAt = expiresAt
        self.notifySupported = notifySupported
    }

    private enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case channel
        case channelLabel
        case accountID = "accountId"
        case accountLabel
        case senderID = "senderId"
        case senderLabel
        case metadata
        case createdAt
        case lastSeenAt
        case expiresAt
        case notifySupported
    }
}

/// Typed `channels.pairing.list` result.
public struct ChannelsPairingListReport: Codable, Sendable, Equatable {
    /// Pairing limits.
    public struct Limits: Codable, Sendable, Equatable {
        /// Pending requests per account.
        public var pendingPerAccount: Int
        /// Pending TTL in milliseconds.
        public var ttlMs: Int64

        /// Creates limits.
        /// - Parameters:
        ///   - pendingPerAccount: Pending requests per account.
        ///   - ttlMs: Pending TTL in milliseconds.
        public init(pendingPerAccount: Int, ttlMs: Int64) {
            self.pendingPerAccount = pendingPerAccount
            self.ttlMs = ttlMs
        }
    }

    /// Pairing-policy accounts.
    public var accounts: [ChannelPairingAccountInfo]
    /// Pending requests.
    public var requests: [ChannelPairingRequestInfo]
    /// Whether a command owner is configured.
    public var commandOwnerConfigured: Bool
    /// Limits.
    public var limits: Limits

    /// Creates a list report.
    /// - Parameters:
    ///   - accounts: Accounts.
    ///   - requests: Requests.
    ///   - commandOwnerConfigured: Whether a command owner is configured.
    ///   - limits: Limits.
    public init(accounts: [ChannelPairingAccountInfo], requests: [ChannelPairingRequestInfo], commandOwnerConfigured: Bool, limits: Limits) {
        self.accounts = accounts
        self.requests = requests
        self.commandOwnerConfigured = commandOwnerConfigured
        self.limits = limits
    }
}

/// Typed `channels.pairing.approve` result.
public struct ChannelsPairingApproveReport: Codable, Sendable, Equatable {
    /// Approval notification outcome.
    public enum Notification: String, Codable, Sendable, Equatable, CaseIterable {
        /// Not requested.
        case notRequested = "not-requested"
        /// Sent.
        case sent
        /// The channel cannot notify.
        case unsupported
        /// Sending failed.
        case failed
    }

    /// Command-owner bootstrap outcome.
    public enum CommandOwnerBootstrap: String, Codable, Sendable, Equatable, CaseIterable {
        /// Not requested.
        case notRequested = "not-requested"
        /// The sender became the command owner.
        case configured
        /// A command owner already exists.
        case alreadyConfigured = "already-configured"
        /// Bootstrap is unavailable on this host.
        case unavailable
    }

    /// Request id.
    public var requestID: String
    /// Approved sender id.
    public var senderID: String
    /// Notification outcome.
    public var notification: Notification
    /// Command-owner bootstrap outcome.
    public var commandOwnerBootstrap: CommandOwnerBootstrap

    /// Creates an approve report.
    /// - Parameters:
    ///   - requestID: Request id.
    ///   - senderID: Sender id.
    ///   - notification: Notification outcome.
    ///   - commandOwnerBootstrap: Bootstrap outcome.
    public init(requestID: String, senderID: String, notification: Notification, commandOwnerBootstrap: CommandOwnerBootstrap) {
        self.requestID = requestID
        self.senderID = senderID
        self.notification = notification
        self.commandOwnerBootstrap = commandOwnerBootstrap
    }

    private enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case senderID = "senderId"
        case notification
        case commandOwnerBootstrap
    }
}

/// Typed `channels.pairing.dismiss` result.
public struct ChannelsPairingDismissReport: Codable, Sendable, Equatable {
    /// Request id.
    public var requestID: String
    /// Sender id.
    public var senderID: String

    /// Creates a dismiss report.
    /// - Parameters:
    ///   - requestID: Request id.
    ///   - senderID: Sender id.
    public init(requestID: String, senderID: String) {
        self.requestID = requestID
        self.senderID = senderID
    }

    private enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case senderID = "senderId"
    }
}

/// Typed client for the channel control RPCs over any gateway request function.
///
/// ```swift
/// let client = ChannelsGatewayClient { method, params in
///     try await channel.request(method: method, params: params, timeoutMs: 15_000)
/// }
/// let status = try await client.status(probe: true)
/// ```
public struct ChannelsGatewayClient: Sendable {
    /// Sends one request and returns the raw response payload JSON.
    public typealias Request = @Sendable (_ method: String, _ params: [String: AnyCodable]?) async throws -> Data

    private let request: Request

    /// Creates a client.
    /// - Parameter request: Request function (for example wrapping `GatewayChannelActor.request`).
    public init(request: @escaping Request) {
        self.request = request
    }

    /// Calls `channels.status`.
    /// - Parameters:
    ///   - probe: Whether to probe adapters.
    ///   - timeoutMs: Probe timeout.
    ///   - channel: Channel filter.
    /// - Returns: Typed status report.
    public func status(probe: Bool = false, timeoutMs: Int? = nil, channel: String? = nil) async throws -> ChannelsStatusReport {
        var params: [String: AnyCodable] = [:]
        if probe { params["probe"] = AnyCodable(true) }
        if let timeoutMs { params["timeoutMs"] = AnyCodable(timeoutMs) }
        if let channel { params["channel"] = AnyCodable(channel) }
        return try await self.call("channels.status", params: params)
    }

    /// Calls `channels.pairing.list`.
    /// - Parameters:
    ///   - channel: Channel filter.
    ///   - accountID: Account filter.
    /// - Returns: Typed list report.
    public func pairingList(channel: String? = nil, accountID: String? = nil) async throws -> ChannelsPairingListReport {
        var params: [String: AnyCodable] = [:]
        if let channel { params["channel"] = AnyCodable(channel) }
        if let accountID { params["accountId"] = AnyCodable(accountID) }
        return try await self.call("channels.pairing.list", params: params)
    }

    /// Calls `channels.pairing.approve`.
    /// - Parameters:
    ///   - channel: Channel id.
    ///   - accountID: Account id.
    ///   - requestID: Request id.
    ///   - notify: Whether to notify the sender.
    ///   - bootstrapCommandOwner: Whether to make the sender the command owner.
    /// - Returns: Typed approve report.
    public func pairingApprove(
        channel: String,
        accountID: String,
        requestID: String,
        notify: Bool? = nil,
        bootstrapCommandOwner: Bool? = nil
    ) async throws -> ChannelsPairingApproveReport {
        var params: [String: AnyCodable] = [
            "channel": AnyCodable(channel),
            "accountId": AnyCodable(accountID),
            "requestId": AnyCodable(requestID),
        ]
        if let notify { params["notify"] = AnyCodable(notify) }
        if let bootstrapCommandOwner { params["bootstrapCommandOwner"] = AnyCodable(bootstrapCommandOwner) }
        return try await self.call("channels.pairing.approve", params: params)
    }

    /// Calls `channels.pairing.dismiss`.
    /// - Parameters:
    ///   - channel: Channel id.
    ///   - accountID: Account id.
    ///   - requestID: Request id.
    /// - Returns: Typed dismiss report.
    public func pairingDismiss(channel: String, accountID: String, requestID: String) async throws -> ChannelsPairingDismissReport {
        try await self.call(
            "channels.pairing.dismiss",
            params: ["channel": AnyCodable(channel), "accountId": AnyCodable(accountID), "requestId": AnyCodable(requestID)]
        )
    }

    private func call<T: Decodable>(_ method: String, params: [String: AnyCodable]) async throws -> T {
        let data = try await self.request(method, params)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
