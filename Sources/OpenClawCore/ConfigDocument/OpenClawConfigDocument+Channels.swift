import Foundation
import OpenClawProtocol

extension OpenClawConfigDocument {
    /// `channels`: channel defaults, per-channel model overrides, and plugin-owned channel blocks.
    ///
    /// Upstream `channels` is a passthrough object: every key other than `defaults` and
    /// `modelByChannel` is a channel id holding that channel's plugin-owned config. ``entries`` types
    /// the generic fields shared by channels; channel-specific keys pass through inside each block.
    /// Per-channel field sync belongs to the channels slice.
    public struct Channels: Codable, Sendable, Equatable {
        /// Built-in channel ids with typed upstream schemas.
        public static let builtInChannelIDs: Set<String> = [
            "discord", "googlechat", "imessage", "irc", "msteams", "signal", "slack", "telegram", "whatsapp",
        ]

        /// `channels.defaults`.
        public var defaults: Defaults?
        /// `channels.modelByChannel`: `channel → peerOrAccountKey → provider/model`.
        public var modelByChannel: [String: [String: String]]?
        /// Channel blocks keyed by channel id.
        public var entries: [String: ChannelBlock]
        /// Keys that are not objects (kept verbatim).
        public var additionalProperties: [String: AnyCodable]

        /// Creates an empty channels section.
        public init(
            defaults: Defaults? = nil,
            modelByChannel: [String: [String: String]]? = nil,
            entries: [String: ChannelBlock] = [:],
            additionalProperties: [String: AnyCodable] = [:]
        ) {
            self.defaults = defaults
            self.modelByChannel = modelByChannel
            self.entries = entries
            self.additionalProperties = additionalProperties
        }

        /// Decodes defaults, the model map and every channel block leniently.
        /// - Parameter decoder: Source decoder.
        public init(from decoder: Decoder) throws {
            var reader = try ConfigObjectReader(decoder: decoder)
            self.defaults = reader.decode(Defaults.self, forKey: "defaults")
            self.modelByChannel = reader.decode([String: [String: String]].self, forKey: "modelByChannel")
            var entries: [String: ChannelBlock] = [:]
            var additional: [String: AnyCodable] = [:]
            for (key, value) in reader.remainingProperties() {
                if key == "defaults" || key == "modelByChannel" {
                    additional[key] = value
                } else if value.dictionaryValue != nil,
                          let block = reader.decode(ChannelBlock.self, forKey: key)
                {
                    entries[key] = block
                } else {
                    additional[key] = value
                }
            }
            self.entries = entries
            self.additionalProperties = additional
        }

        /// Encodes defaults, the model map, channel blocks and passthrough keys.
        /// - Parameter encoder: Target encoder.
        public func encode(to encoder: Encoder) throws {
            var writer = ConfigObjectWriter(encoder: encoder)
            try writer.encode(self.defaults, forKey: "defaults")
            try writer.encode(self.modelByChannel, forKey: "modelByChannel")
            for key in self.entries.keys.sorted() {
                try writer.encode(self.entries[key], forKey: key)
            }
            try writer.finish(additional: self.additionalProperties)
        }

        /// Channel ids that are not built-in upstream channels (plugin channels).
        public var pluginChannelIDs: [String] {
            self.entries.keys.filter { !Self.builtInChannelIDs.contains($0) }.sorted()
        }

        /// `channels.defaults`.
        public struct Defaults: ConfigDocumentObject {
            /// `open`, `disabled` or `allowlist`.
            public var groupPolicy: String?
            /// `all`, `allowlist` or `allowlist_quote`.
            public var contextVisibility: String?
            /// Heartbeat visibility (`showOk`, `showAlerts`, `useIndicator`).
            public var heartbeatVisibility: AnyCodable?
            /// Bot-loop protection.
            public var botLoopProtection: AnyCodable?
            /// Implicit mentions.
            public var implicitMentions: AnyCodable?
            /// Passthrough keys (for example the migrated `heartbeat` block).
            public var additionalProperties: [String: AnyCodable] = [:]
            /// Creates empty defaults.
            public init() {}
            /// Typed fields.
            public static var configFields: [ConfigField<Self>] {
                [.init("groupPolicy", \.groupPolicy), .init("contextVisibility", \.contextVisibility),
                 .init("heartbeatVisibility", \.heartbeatVisibility), .init("botLoopProtection", \.botLoopProtection),
                 .init("implicitMentions", \.implicitMentions)]
            }
        }
    }

    /// Generic fields shared by channel blocks (and their `accounts.<id>` entries).
    public struct ChannelBlock: ConfigDocumentObject {
        /// Enables the channel.
        public var enabled: Bool?
        /// Display name.
        public var name: String?
        /// `pairing`, `allowlist`, `open` or `disabled` (root default `pairing`).
        public var dmPolicy: String?
        /// `open`, `disabled` or `allowlist` (root default `allowlist`).
        public var groupPolicy: String?
        /// Allowed direct-message senders.
        public var allowFrom: [ConfigStringOrNumber]?
        /// Allowed group senders.
        public var groupAllowFrom: [ConfigStringOrNumber]?
        /// Default delivery target.
        public var defaultTo: String?
        /// Default account id.
        public var defaultAccount: String?
        /// Reply prefix.
        public var responsePrefix: String?
        /// History limit.
        public var historyLimit: Int?
        /// Text chunk limit.
        public var textChunkLimit: Int?
        /// Media size cap in MB.
        public var mediaMaxMb: Double?
        /// `off`, `first`, `all` or `batched`.
        public var replyToMode: String?
        /// Thread bindings.
        public var threadBindings: Session.ThreadBindings?
        /// Exec approvals routed through the channel.
        public var execApprovals: AnyCodable?
        /// Streaming behavior.
        public var streaming: AnyCodable?
        /// Accounts keyed by account id.
        public var accounts: [String: ChannelBlock]?
        /// Passthrough keys (channel-specific settings).
        public var additionalProperties: [String: AnyCodable] = [:]

        /// Creates an empty block.
        public init() {}

        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [
                .init("enabled", \.enabled), .init("name", \.name), .init("dmPolicy", \.dmPolicy),
                .init("groupPolicy", \.groupPolicy), .init("allowFrom", \.allowFrom), .init("groupAllowFrom", \.groupAllowFrom),
                .init("defaultTo", \.defaultTo), .init("defaultAccount", \.defaultAccount),
                .init("responsePrefix", \.responsePrefix), .init("historyLimit", \.historyLimit),
                .init("textChunkLimit", \.textChunkLimit), .init("mediaMaxMb", \.mediaMaxMb), .init("replyToMode", \.replyToMode),
                .init("threadBindings", \.threadBindings), .init("execApprovals", \.execApprovals), .init("streaming", \.streaming),
                .init("accounts", \.accounts),
            ]
        }
    }
}
