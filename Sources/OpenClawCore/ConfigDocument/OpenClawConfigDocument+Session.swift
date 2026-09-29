import Foundation
import OpenClawProtocol

extension OpenClawConfigDocument {
    /// `session`: session scoping, reset, thread bindings and maintenance (upstream `SessionSchema`).
    public struct Session: ConfigDocumentObject {
        /// `per-sender` or `global`.
        public var scope: String?
        /// Direct-message session scope (default `main`).
        public var dmScope: DMScope?
        /// `main` or `per-group`.
        public var groupScope: String?
        /// Notify when a session is created.
        public var notifyOnCreate: Bool?
        /// Linked peer identities (`canonical: [aliases]`).
        public var identityLinks: [String: [String]]?
        /// Commands that reset the session.
        public var resetTriggers: [String]?
        /// Reset policy.
        public var reset: Reset?
        /// Reset policy per chat type (`direct`, `group`, `thread`; legacy `dm` is migrated).
        public var resetByType: [String: Reset]?
        /// Reset policy per channel.
        public var resetByChannel: [String: Reset]?
        /// Session store path.
        public var store: String?
        /// Main session key (default `main`).
        public var mainKey: String?
        /// Outbound send policy.
        public var sendPolicy: SendPolicyRules?
        /// Thread bindings.
        public var threadBindings: ThreadBindings?
        /// Sharing.
        public var sharing: AnyCodable?
        /// Maintenance.
        public var maintenance: Maintenance?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]

        /// Creates an empty session section.
        public init() {}

        /// SDK-only `session.legacyChannelAccountKeys` switch (read from the passthrough keys).
        ///
        /// Imports map it to ``ChannelsCompatibilityConfig/legacySessionAccountKeys``. Upstream's
        /// strict session schema rejects the key, so stores strip it before writing
        /// (see ``OpenClawConfigDocument/sdkOnlyKeyPaths``).
        public var legacyChannelAccountKeys: Bool? {
            self.additionalProperties["legacyChannelAccountKeys"]?.boolValue
        }

        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [
                .init("scope", \.scope), .init("dmScope", \.dmScope), .init("groupScope", \.groupScope),
                .init("notifyOnCreate", \.notifyOnCreate), .init("identityLinks", \.identityLinks),
                .init("resetTriggers", \.resetTriggers), .init("reset", \.reset), .init("resetByType", \.resetByType),
                .init("resetByChannel", \.resetByChannel), .init("store", \.store), .init("mainKey", \.mainKey),
                .init("sendPolicy", \.sendPolicy), .init("threadBindings", \.threadBindings), .init("sharing", \.sharing),
                .init("maintenance", \.maintenance),
            ]
        }

        /// `session.dmScope` vocabulary.
        public struct DMScope: ConfigOpenEnum {
            /// Raw config string.
            public let rawValue: String
            /// Creates a value from its raw string.
            public init(rawValue: String) { self.rawValue = rawValue }
            /// One shared direct-message session.
            public static let main = Self(rawValue: "main")
            /// One session per peer.
            public static let perPeer = Self(rawValue: "per-peer")
            /// One session per channel and peer.
            public static let perChannelPeer = Self(rawValue: "per-channel-peer")
            /// One session per account, channel and peer.
            public static let perAccountChannelPeer = Self(rawValue: "per-account-channel-peer")
            /// Known values.
            public static let known: [Self] = [.main, .perPeer, .perChannelPeer, .perAccountChannelPeer]
        }

        /// Reset policy.
        public struct Reset: ConfigDocumentObject {
            /// `none`, `daily` or `idle`.
            public var mode: String?
            /// Hour of the daily reset (0...23).
            public var atHour: Int?
            /// Idle minutes before reset.
            public var idleMinutes: Int?
            /// Passthrough keys.
            public var additionalProperties: [String: AnyCodable] = [:]
            /// Creates an empty policy.
            public init() {}
            /// Typed fields.
            public static var configFields: [ConfigField<Self>] {
                [.init("mode", \.mode), .init("atHour", \.atHour), .init("idleMinutes", \.idleMinutes)]
            }
        }

        /// `session.sendPolicy` (the default action maps to the SDK ``SendPolicy``).
        public struct SendPolicyRules: ConfigDocumentObject {
            /// `allow` or `deny`.
            public var `default`: String?
            /// Ordered rules (typed shallowly).
            public var rules: [AnyCodable]?
            /// Passthrough keys.
            public var additionalProperties: [String: AnyCodable] = [:]
            /// Creates an empty policy.
            public init() {}
            /// Typed fields.
            public static var configFields: [ConfigField<Self>] { [.init("default", \.default), .init("rules", \.rules)] }
        }

        /// Thread bindings.
        public struct ThreadBindings: ConfigDocumentObject {
            /// Enables thread bindings.
            public var enabled: Bool?
            /// Idle hours before unbinding (legacy `ttlHours` is migrated).
            public var idleHours: Double?
            /// Maximum age in hours.
            public var maxAgeHours: Double?
            /// Spawn sessions for new threads.
            public var spawnSessions: Bool?
            /// `isolated` or `fork`.
            public var defaultSpawnContext: String?
            /// Passthrough keys.
            public var additionalProperties: [String: AnyCodable] = [:]
            /// Creates an empty section.
            public init() {}
            /// Typed fields.
            public static var configFields: [ConfigField<Self>] {
                [.init("enabled", \.enabled), .init("idleHours", \.idleHours), .init("maxAgeHours", \.maxAgeHours),
                 .init("spawnSessions", \.spawnSessions), .init("defaultSpawnContext", \.defaultSpawnContext)]
            }
        }

        /// `session.maintenance`.
        public struct Maintenance: ConfigDocumentObject {
            /// `enforce` or `warn`.
            public var mode: String?
            /// Cold storage.
            public var coldStorage: AnyCodable?
            /// Prune age (duration; bare numbers are days; must be > 0).
            public var pruneAfter: ConfigDurationValue?
            /// Dashboard archive age (duration, `false` or `0`).
            public var archiveDashboardAfter: AnyCodable?
            /// Maximum entries.
            public var maxEntries: Int?
            /// Recent entries preserved (duration or `false`).
            public var preserveRecent: AnyCodable?
            /// Reset archive retention (duration or `false`).
            public var resetArchiveRetention: AnyCodable?
            /// Disk budget (`2mb`-style size or `false`).
            public var maxDiskBytes: AnyCodable?
            /// High-water mark.
            public var highWaterBytes: ConfigByteSize?
            /// Passthrough keys.
            public var additionalProperties: [String: AnyCodable] = [:]
            /// Creates an empty section.
            public init() {}
            /// Typed fields.
            public static var configFields: [ConfigField<Self>] {
                [
                    .init("mode", \.mode), .init("coldStorage", \.coldStorage), .init("pruneAfter", \.pruneAfter),
                    .init("archiveDashboardAfter", \.archiveDashboardAfter), .init("maxEntries", \.maxEntries),
                    .init("preserveRecent", \.preserveRecent), .init("resetArchiveRetention", \.resetArchiveRetention),
                    .init("maxDiskBytes", \.maxDiskBytes), .init("highWaterBytes", \.highWaterBytes),
                ]
            }

            /// Prune age in milliseconds (bare numbers are days).
            public var pruneAfterMilliseconds: Int64? {
                self.pruneAfter?.milliseconds(defaultUnit: .days)
            }
        }

        /// Approximates this section as the SDK-native ``RoutingConfig``.
        ///
        /// Upstream builds keys as `agent:<agentId>:<channel>:<accountId>:direct:<peer>` and collapses
        /// linked peers through `identityLinks`; the SDK key format belongs to the sessions slice, so this
        /// projection only maps which discriminators are included.
        public var routingConfig: RoutingConfig {
            let mainKey = ConfigValueSupport.nonEmpty(self.mainKey) ?? "main"
            switch self.dmScope ?? .main {
            case .perPeer:
                return RoutingConfig(defaultSessionKey: mainKey, includeChannelID: false, includeAccountID: false, includePeerID: true)
            case .perChannelPeer:
                return RoutingConfig(defaultSessionKey: mainKey, includeChannelID: true, includeAccountID: false, includePeerID: true)
            case .perAccountChannelPeer:
                return RoutingConfig(defaultSessionKey: mainKey, includeChannelID: true, includeAccountID: true, includePeerID: true)
            default:
                return RoutingConfig(defaultSessionKey: mainKey, includeChannelID: false, includeAccountID: false, includePeerID: false)
            }
        }

        /// The SDK send policy for the default action.
        public var defaultSendPolicy: SendPolicy? {
            self.sendPolicy?.default.flatMap { SendPolicy(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
        }
    }
}
