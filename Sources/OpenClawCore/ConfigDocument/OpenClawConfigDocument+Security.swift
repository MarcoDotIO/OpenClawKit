import Foundation
import OpenClawProtocol

extension OpenClawConfigDocument {
    /// `security`: audit suppressions and the install policy (upstream `SecuritySchema`).
    public struct Security: ConfigDocumentObject {
        /// Audit settings.
        public var audit: Audit?
        /// Install policy (runs a server-side policy command; metadata only).
        public var installPolicy: AnyCodable?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty section.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] { [.init("audit", \.audit), .init("installPolicy", \.installPolicy)] }

        /// `security.audit`.
        public struct Audit: ConfigDocumentObject {
            /// Accepted findings omitted from the active summary and findings.
            public var suppressions: [Suppression]?
            /// Passthrough keys.
            public var additionalProperties: [String: AnyCodable] = [:]
            /// Creates an empty section.
            public init() {}
            /// Typed fields.
            public static var configFields: [ConfigField<Self>] { [.init("suppressions", \.suppressions)] }
        }

        /// One accepted audit finding.
        public struct Suppression: ConfigDocumentObject {
            /// Finding id (required; exact match).
            public var checkId: String?
            /// Case-insensitive substring of the finding title.
            public var titleIncludes: String?
            /// Case-insensitive substring of the finding detail.
            public var detailIncludes: String?
            /// Why the finding is accepted.
            public var reason: String?
            /// Passthrough keys.
            public var additionalProperties: [String: AnyCodable] = [:]
            /// Creates an empty suppression.
            public init() {}
            /// Typed fields.
            public static var configFields: [ConfigField<Self>] {
                [.init("checkId", \.checkId), .init("titleIncludes", \.titleIncludes), .init("detailIncludes", \.detailIncludes),
                 .init("reason", \.reason)]
            }

            /// The SDK audit suppression, when `checkId` is set.
            public var auditSuppression: SecurityAuditSuppression? {
                guard let checkId = ConfigValueSupport.nonEmpty(self.checkId) else { return nil }
                return SecurityAuditSuppression(
                    checkID: checkId,
                    titleIncludes: self.titleIncludes,
                    detailIncludes: self.detailIncludes,
                    reason: self.reason
                )
            }
        }

        /// SDK audit suppressions derived from `audit.suppressions`.
        public var auditSuppressions: [SecurityAuditSuppression] {
            self.audit?.suppressions?.compactMap(\.auditSuppression) ?? []
        }
    }

    /// One `accessGroups.<name>` entry: `discord.channelAudience`, `message.senders`, or an unknown type.
    public struct AccessGroup: ConfigDocumentObject {
        /// `discord.channelAudience` or `message.senders`.
        public var type: String?
        /// Discord guild id (`discord.channelAudience`).
        public var guildId: String?
        /// Discord channel id (`discord.channelAudience`).
        public var channelId: String?
        /// `canViewChannel` (`discord.channelAudience`).
        public var membership: String?
        /// Sender ids per channel (`message.senders`).
        public var members: [String: [String]]?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty group.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [.init("type", \.type), .init("guildId", \.guildId), .init("channelId", \.channelId),
             .init("membership", \.membership), .init("members", \.members)]
        }
    }

    /// `proxy`: operator-managed SSRF forward proxy for the gateway host (decoded only).
    public struct Proxy: ConfigDocumentObject {
        /// Enables the proxy.
        public var enabled: Bool?
        /// Proxy URL (`http`/`https`; sensitive).
        public var proxyUrl: String?
        /// TLS (`caFile`).
        public var tls: AnyCodable?
        /// `gateway-only`, `proxy` or `block`.
        public var loopbackMode: String?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty section.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [.init("enabled", \.enabled), .init("proxyUrl", \.proxyUrl), .init("tls", \.tls), .init("loopbackMode", \.loopbackMode)]
        }
    }

    /// `hooks`: webhook ingress and internal hooks (unrelated to the in-process ``HookRegistry``).
    public struct Hooks: ConfigDocumentObject {
        /// Enables webhook ingress.
        public var enabled: Bool?
        /// Ingress path.
        public var path: String?
        /// Ingress bearer token (sensitive plain string).
        public var token: String?
        /// Default session key.
        public var defaultSessionKey: String?
        /// Allow requests to pick a session key.
        public var allowRequestSessionKey: Bool?
        /// Allowed session-key prefixes.
        public var allowedSessionKeyPrefixes: [String]?
        /// Allowed agent ids.
        public var allowedAgentIds: [String]?
        /// Presets.
        public var presets: [String]?
        /// Transforms directory.
        public var transformsDir: String?
        /// Mappings.
        public var mappings: [HookMapping]?
        /// Gmail ingestion (passthrough).
        public var gmail: AnyCodable?
        /// Internal hooks (`enabled`, `entries`, `load`).
        public var `internal`: AnyCodable?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty section.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [
                .init("enabled", \.enabled), .init("path", \.path), .init("token", \.token),
                .init("defaultSessionKey", \.defaultSessionKey), .init("allowRequestSessionKey", \.allowRequestSessionKey),
                .init("allowedSessionKeyPrefixes", \.allowedSessionKeyPrefixes), .init("allowedAgentIds", \.allowedAgentIds),
                .init("presets", \.presets), .init("transformsDir", \.transformsDir), .init("mappings", \.mappings),
                .init("gmail", \.gmail), .init("internal", \.internal),
            ]
        }

        /// Upstream check: a persistent agent mapping needs `sessionKey`, `hooks.defaultSessionKey` or a transform.
        /// - Returns: Issues (empty when valid).
        public func validationIssues() -> [ConfigDecodeIssue] {
            let hasDefault = ConfigValueSupport.nonEmpty(self.defaultSessionKey) != nil
            return (self.mappings ?? []).enumerated().compactMap { index, mapping in
                guard (mapping.action ?? "agent") == "agent", mapping.sessionMode == "persistent",
                      ConfigValueSupport.nonEmpty(mapping.sessionKey) == nil, !hasDefault, mapping.transform == nil
                else { return nil }
                return ConfigDecodeIssue(
                    path: "hooks.mappings[\(index)].sessionKey",
                    message: "persistent hook mappings require sessionKey, hooks.defaultSessionKey, or a transform",
                    kind: .invalidValue
                )
            }
        }

        /// One `hooks.mappings[]` entry (typed subset).
        public struct HookMapping: ConfigDocumentObject {
            /// Mapping id.
            public var id: String?
            /// `wake` or `agent`.
            public var action: String?
            /// Target agent.
            public var agentId: String?
            /// Session key.
            public var sessionKey: String?
            /// `isolated` or `persistent`.
            public var sessionMode: String?
            /// Transform module.
            public var transform: AnyCodable?
            /// Passthrough keys.
            public var additionalProperties: [String: AnyCodable] = [:]
            /// Creates an empty mapping.
            public init() {}
            /// Typed fields.
            public static var configFields: [ConfigField<Self>] {
                [.init("id", \.id), .init("action", \.action), .init("agentId", \.agentId), .init("sessionKey", \.sessionKey),
                 .init("sessionMode", \.sessionMode), .init("transform", \.transform)]
            }
        }
    }

    /// `cron`: scheduled jobs.
    public struct Cron: ConfigDocumentObject {
        /// Enables cron.
        public var enabled: Bool?
        /// Skip missed recurring slots at startup (default `false`).
        public var skipMissedJobs: Bool?
        /// Triggers (`enabled`).
        public var triggers: AnyCodable?
        /// Webhook bearer token (secret).
        public var webhookToken: ConfigSecretValue?
        /// Webhook SSRF policy.
        public var webhookSsrfPolicy: AnyCodable?
        /// Completed-run retention (duration, `false` disables; default `24h`).
        public var sessionRetention: ConfigStringOrFalse?
        /// Failure alerts.
        public var failureAlert: AnyCodable?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty section.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [.init("enabled", \.enabled), .init("skipMissedJobs", \.skipMissedJobs), .init("triggers", \.triggers),
             .init("webhookToken", \.webhookToken), .init("webhookSsrfPolicy", \.webhookSsrfPolicy),
             .init("sessionRetention", \.sessionRetention), .init("failureAlert", \.failureAlert)]
        }

        /// Session retention in milliseconds (bare numbers are hours); `nil` when disabled or invalid.
        public var sessionRetentionMilliseconds: Int64? {
            guard case .string(let value)? = self.sessionRetention ?? .string("24h") else { return nil }
            return ConfigDuration.parseMilliseconds(value, defaultUnit: .hours)
        }
    }

    /// `approvals`: exec and plugin approval forwarding (gateway routing; metadata only).
    public struct Approvals: ConfigDocumentObject {
        /// Exec approval forwarding.
        public var exec: AnyCodable?
        /// Plugin approval forwarding.
        public var plugin: AnyCodable?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty section.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] { [.init("exec", \.exec), .init("plugin", \.plugin)] }
    }

    /// `transcripts` (metadata only).
    public struct Transcripts: ConfigDocumentObject {
        /// Enables transcript capture.
        public var enabled: Bool?
        /// Auto-start rules.
        public var autoStart: [AnyCodable]?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty section.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] { [.init("enabled", \.enabled), .init("autoStart", \.autoStart)] }
    }

    /// `cloudWorkers` (metadata only; secret-bearing profile settings must be SecretRefs).
    public struct CloudWorkers: ConfigDocumentObject {
        /// Desktop workers.
        public var desktop: Bool?
        /// Prepared pool (`maxTotal`, default 4).
        public var preparedPool: AnyCodable?
        /// `host/owner/repo` → profile id.
        public var projectProfiles: [String: String]?
        /// Profiles by id.
        public var profiles: [String: AnyCodable]?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty section.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [.init("desktop", \.desktop), .init("preparedPool", \.preparedPool), .init("projectProfiles", \.projectProfiles),
             .init("profiles", \.profiles)]
        }
    }

    /// `desktop` (metadata only).
    public struct Desktop: ConfigDocumentObject {
        /// Desktop host (`enabled` required, `managed`, `port` default 5900, `passwordFile`).
        public var host: AnyCodable?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty section.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] { [.init("host", \.host)] }
    }

    /// `nodeHost`: CLI node-host settings (Apple node apps may read `skills.enabled`).
    public struct NodeHost: ConfigDocumentObject {
        /// Auto update.
        public var autoUpdate: AnyCodable?
        /// Agent runs.
        public var agentRuns: AnyCodable?
        /// Worker runs.
        public var workerRuns: AnyCodable?
        /// Browser proxy.
        public var browserProxy: AnyCodable?
        /// Node-host MCP servers.
        public var mcp: AnyCodable?
        /// Skills (`enabled`).
        public var skills: AnyCodable?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty section.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [.init("autoUpdate", \.autoUpdate), .init("agentRuns", \.agentRuns), .init("workerRuns", \.workerRuns),
             .init("browserProxy", \.browserProxy), .init("mcp", \.mcp), .init("skills", \.skills)]
        }

        /// `nodeHost.skills.enabled`.
        public var skillsEnabled: Bool? {
            self.skills?.dictionaryValue?["enabled"]?.boolValue
        }
    }
}
