import Foundation

/// Stable channel identifiers supported by channel adapters and the upstream channel catalog.
///
/// Raw values match upstream OpenClaw channel ids. Use ``init(normalizing:)`` to resolve
/// user-supplied ids and upstream aliases (for example `lark`, `gchat`, `imsg`, `teams`).
///
/// - Note: 2026.3.0 added `a2a`, `buzz`, `clickclack`, `raft`, `reef`, `sms`, `wecom`,
///   `openclawWeixin`, `yuanbao` and `openclawZaloClawbot`. Exhaustive `switch` statements over
///   `ChannelID` need the new cases (documented source break). `bluebubbles` was removed upstream;
///   it stays for one more release (see ``isRemovedUpstream``) and will be deleted in the next
///   major release — migrate to ``imessage``.
public enum ChannelID: String, CaseIterable, Sendable, Codable {
    /// WhatsApp (the Swift adapter uses the Graph Cloud API; upstream uses WhatsApp Web).
    case whatsapp
    /// Telegram Bot API.
    case telegram
    /// Slack.
    case slack
    /// Google Chat.
    case googlechat
    /// Discord.
    case discord
    /// Signal through signal-cli.
    case signal
    /// BlueBubbles. Removed upstream in OpenClaw 2026.5.12; migrate to ``imessage``.
    case bluebubbles
    /// iMessage (upstream uses the `imsg` bridge).
    case imessage
    /// Microsoft Teams.
    case msteams
    /// LINE Messaging API.
    case line
    /// SDK-owned WebChat surface (upstream core webchat).
    case webchat
    /// Feishu / Lark.
    case feishu
    /// IRC.
    case irc
    /// Matrix.
    case matrix
    /// Mattermost.
    case mattermost
    /// Nextcloud Talk.
    case nextcloudTalk = "nextcloud-talk"
    /// Nostr (NIP-04 DMs).
    case nostr
    /// QQ Bot (external Tencent plugin).
    case qqbot
    /// Synology Chat.
    case synologyChat = "synology-chat"
    /// Tlon (Urbit).
    case tlon
    /// Twitch chat.
    case twitch
    /// Zalo Bot API.
    case zalo
    /// Zalo personal account.
    case zalouser
    /// Upstream synthetic QA channel (hidden).
    case qaChannel = "qa-channel"
    /// A2A (Agent-to-Agent Protocol 1.0).
    case a2a
    /// Buzz team rooms.
    case buzz
    /// ClickClack self-hosted chat.
    case clickclack
    /// Raft CLI wake bridge.
    case raft
    /// Reef guarded claw channel.
    case reef
    /// SMS through Twilio.
    case sms
    /// WeCom (external plugin).
    case wecom
    /// Weixin / WeChat (external Tencent plugin).
    case openclawWeixin = "openclaw-weixin"
    /// Yuanbao (external Tencent plugin).
    case yuanbao
    /// Zalo ClawBot (external plugin).
    case openclawZaloClawbot = "openclaw-zaloclawbot"

    /// Resolves a raw id or upstream alias (upstream `normalizeChatChannelId`).
    ///
    /// The input is trimmed and lowercased; aliases map to their canonical id. Non-ASCII aliases
    /// such as `元宝` are matched as-is.
    /// - Parameter raw: Raw channel id or alias.
    public init?(normalizing raw: String) {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else {
            return nil
        }
        if let direct = ChannelID(rawValue: key) {
            self = direct
            return
        }
        guard let resolved = OpenClawChannelMetadataCatalog.aliasIndex[key] else {
            return nil
        }
        self = resolved
    }

    /// Catalog metadata for this channel.
    public var metadata: ChannelMetadataEntry {
        OpenClawChannelMetadataCatalog.entry(for: self) ?? ChannelMetadataEntry(
            id: self,
            label: self.rawValue,
            nativeTransportAvailable: false
        )
    }

    /// Whether upstream removed this channel (currently only ``bluebubbles``).
    public var isRemovedUpstream: Bool {
        if case .removed = self.metadata.status {
            return true
        }
        return false
    }
}

/// How upstream distributes a channel implementation.
public enum ChannelDistribution: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// Built into the gateway core (WebChat).
    case core
    /// Bundled inside the upstream repository and not published separately.
    case bundled
    /// Official plugin published by OpenClaw (`@openclaw/*`).
    case official
    /// Third-party plugin maintained outside OpenClaw.
    case external
}

/// Upstream lifecycle status of a channel.
public enum ChannelUpstreamStatus: Sendable, Equatable, Hashable {
    /// Actively maintained upstream.
    case active
    /// Maintained outside OpenClaw by a third party.
    case external
    /// Removed upstream.
    /// - Parameters:
    ///   - replacement: Channel that replaces it, when one exists.
    ///   - migrationDocsPath: Upstream docs path describing the migration.
    case removed(replacement: ChannelID?, migrationDocsPath: String?)
}

/// Channel metadata for upstream channel plugins and native Swift adapters.
public struct ChannelMetadataEntry: Sendable, Equatable {
    /// Stable channel identifier.
    public var id: ChannelID
    /// Human-facing channel label.
    public var label: String
    /// Optional upstream documentation path.
    public var docsPath: String?
    /// Additional accepted upstream identifiers.
    public var aliases: [String]
    /// Whether OpenClawKit currently provides a native Swift transport adapter.
    public var nativeTransportAvailable: Bool
    /// Label shown in channel pickers (upstream `selectionLabel`).
    public var selectionLabel: String?
    /// Secondary label (upstream `detailLabel`).
    public var detailLabel: String?
    /// SF Symbol name (upstream `systemImage`).
    public var systemImage: String?
    /// Upstream catalog order; `nil` sorts last.
    public var order: Int?
    /// How upstream distributes the channel.
    public var distribution: ChannelDistribution
    /// Upstream npm package name.
    public var packageName: String?
    /// Legacy upstream npm package names.
    public var legacyPackageNames: [String]
    /// Upstream lifecycle status.
    public var status: ChannelUpstreamStatus
    /// Kind of native Swift transport, when one exists (for example `cloud-api` for WhatsApp).
    public var nativeTransportKind: String?
    /// Why no native Swift transport exists, for plugin-only channels.
    public var nativeUnavailableReason: String?
    /// Whether upstream hides the channel from setup, docs and configured lists.
    public var hidden: Bool
    /// Typed capability flags.
    public var capabilities: ChannelCapabilities
    /// Rich-text format profile, when known.
    public var formatProfile: ChannelFormatProfile?
    /// Outbound text chunking defaults, when known.
    public var textChunking: ChannelTextChunkingDefaults?
    /// Default block-streaming coalescing thresholds, when the channel defines them.
    public var blockStreamingCoalesceDefaults: ChannelBlockStreamingCoalesceDefaults?

    /// Default outbound text chunk limit (``ChannelTextChunkingDefaults/defaultLimit``).
    public var defaultTextChunkLimit: Int? {
        self.textChunking?.defaultLimit
    }

    /// Creates a channel metadata entry.
    /// - Parameters:
    ///   - id: Channel identifier.
    ///   - label: Human-facing label.
    ///   - docsPath: Upstream documentation path.
    ///   - aliases: Accepted upstream aliases.
    ///   - nativeTransportAvailable: Whether a native Swift adapter exists.
    ///   - selectionLabel: Picker label.
    ///   - detailLabel: Secondary label.
    ///   - systemImage: SF Symbol name.
    ///   - order: Upstream catalog order.
    ///   - distribution: Upstream distribution.
    ///   - packageName: Upstream npm package name.
    ///   - legacyPackageNames: Legacy upstream npm package names.
    ///   - status: Upstream lifecycle status.
    ///   - nativeTransportKind: Kind of native transport.
    ///   - nativeUnavailableReason: Why no native transport exists.
    ///   - hidden: Whether upstream hides the channel.
    ///   - capabilities: Capability flags.
    ///   - formatProfile: Format profile.
    ///   - textChunking: Chunking defaults.
    ///   - blockStreamingCoalesceDefaults: Coalescing defaults.
    public init(
        id: ChannelID,
        label: String,
        docsPath: String? = nil,
        aliases: [String] = [],
        nativeTransportAvailable: Bool,
        selectionLabel: String? = nil,
        detailLabel: String? = nil,
        systemImage: String? = nil,
        order: Int? = nil,
        distribution: ChannelDistribution = .official,
        packageName: String? = nil,
        legacyPackageNames: [String] = [],
        status: ChannelUpstreamStatus = .active,
        nativeTransportKind: String? = nil,
        nativeUnavailableReason: String? = nil,
        hidden: Bool = false,
        capabilities: ChannelCapabilities = ChannelCapabilities(),
        formatProfile: ChannelFormatProfile? = nil,
        textChunking: ChannelTextChunkingDefaults? = nil,
        blockStreamingCoalesceDefaults: ChannelBlockStreamingCoalesceDefaults? = nil
    ) {
        self.id = id
        self.label = label
        self.docsPath = docsPath
        self.aliases = aliases
        self.nativeTransportAvailable = nativeTransportAvailable
        self.selectionLabel = selectionLabel
        self.detailLabel = detailLabel
        self.systemImage = systemImage
        self.order = order
        self.distribution = distribution
        self.packageName = packageName
        self.legacyPackageNames = legacyPackageNames
        self.status = status
        self.nativeTransportKind = nativeTransportKind
        self.nativeUnavailableReason = nativeUnavailableReason
        self.hidden = hidden
        self.capabilities = capabilities
        self.formatProfile = formatProfile
        self.textChunking = textChunking
        self.blockStreamingCoalesceDefaults = blockStreamingCoalesceDefaults
    }

    /// Label with the upstream fallback (`detailLabel ?? label`).
    public var resolvedDetailLabel: String {
        self.detailLabel ?? self.label
    }
}

/// One generated upstream channel row (see `ChannelMetadataCatalog+Generated.swift`).
struct ChannelUpstreamRow: Sendable {
    let id: String
    let label: String
    let selectionLabel: String?
    let detailLabel: String?
    let docsPath: String?
    let aliases: [String]
    let order: Int?
    let systemImage: String?
    let distribution: ChannelDistribution
    let packageName: String?
    let legacyPackageNames: [String]
    let removedUpstream: Bool
    let hidden: Bool
}

/// Channel metadata catalog aligned with the pinned OpenClaw upstream plugin set.
///
/// Display metadata (labels, aliases, SF Symbols, docs paths, order, distribution) is generated
/// from the upstream manifests by `Scripts/channel-catalog-gen.mjs`; capabilities, format profiles
/// and chunk limits are hand-maintained because upstream defines them in plugin code.
public enum OpenClawChannelMetadataCatalog {
    /// Known channel metadata entries in ``ChannelID`` declaration order, including plugin-only
    /// channels without Swift transports.
    public static let entries: [ChannelMetadataEntry] = ChannelID.allCases.map(Self.makeEntry(for:))

    /// Entries sorted like the upstream catalog: by ``ChannelMetadataEntry/order`` (missing last),
    /// then by id.
    public static let orderedEntries: [ChannelMetadataEntry] = Self.entries.sorted { lhs, rhs in
        let lhsOrder = lhs.order ?? Int.max
        let rhsOrder = rhs.order ?? Int.max
        if lhsOrder != rhsOrder {
            return lhsOrder < rhsOrder
        }
        return lhs.id.rawValue < rhs.id.rawValue
    }

    /// Ordered entries without upstream-hidden channels (``ChannelMetadataEntry/hidden``).
    public static var visibleEntries: [ChannelMetadataEntry] {
        self.orderedEntries.filter { !$0.hidden }
    }

    /// Lowercased alias → channel index used by ``ChannelID/init(normalizing:)``.
    static let aliasIndex: [String: ChannelID] = {
        var index: [String: ChannelID] = [:]
        for entry in Self.entries {
            for alias in entry.aliases {
                let key = alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !key.isEmpty, index[key] == nil {
                    index[key] = entry.id
                }
            }
        }
        return index
    }()

    private static let entriesByID: [ChannelID: ChannelMetadataEntry] = Dictionary(
        uniqueKeysWithValues: Self.entries.map { ($0.id, $0) }
    )

    /// Returns channel metadata for one identifier.
    /// - Parameter id: Channel identifier.
    /// - Returns: The catalog entry.
    public static func entry(for id: ChannelID) -> ChannelMetadataEntry? {
        self.entriesByID[id]
    }

    /// Resolves a channel id or upstream alias, case-insensitively.
    /// - Parameter alias: Raw id or alias.
    /// - Returns: The catalog entry, or `nil` for unknown ids.
    public static func entry(forAlias alias: String) -> ChannelMetadataEntry? {
        ChannelID(normalizing: alias).flatMap { self.entry(for: $0) }
    }

    private static func makeEntry(for id: ChannelID) -> ChannelMetadataEntry {
        let row = self.generatedRows.first { $0.id == id.rawValue }
        let traits = ChannelCatalogTraitsTable.rows[id.rawValue]
        let status: ChannelUpstreamStatus
        if row?.removedUpstream == true {
            status = .removed(replacement: .imessage, migrationDocsPath: "/channels/imessage-from-bluebubbles")
        } else if row?.distribution == .external {
            status = .external
        } else {
            status = .active
        }
        return ChannelMetadataEntry(
            id: id,
            label: row?.label ?? id.rawValue,
            docsPath: row?.docsPath ?? "/channels/\(id.rawValue)",
            aliases: row?.aliases ?? [],
            nativeTransportAvailable: traits?.nativeTransportAvailable ?? false,
            selectionLabel: row?.selectionLabel,
            detailLabel: row?.detailLabel,
            systemImage: row?.systemImage,
            order: row?.order,
            distribution: row?.distribution ?? .official,
            packageName: row?.packageName,
            legacyPackageNames: row?.legacyPackageNames ?? [],
            status: status,
            nativeTransportKind: traits?.nativeTransportKind,
            nativeUnavailableReason: traits?.nativeTransportAvailable == true ? nil : traits?.nativeUnavailableReason,
            hidden: row?.hidden ?? false,
            capabilities: traits?.capabilities ?? ChannelCapabilities(chatTypes: [.direct]),
            formatProfile: traits?.formatProfile,
            textChunking: traits?.chunking,
            blockStreamingCoalesceDefaults: traits?.coalesce
        )
    }
}
