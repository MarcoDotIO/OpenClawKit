import Foundation
import OpenClawProtocol

extension OpenClawConfigDocument {
    /// `messages`: reply presentation, queueing and acknowledgements (gateway behavior; typed for UIs).
    public struct Messages: ConfigDocumentObject {
        /// `automatic` or `message_tool` (booleans are accepted: `true` → automatic, `false` → message_tool).
        public var visibleReplies: AnyCodable?
        /// Reply prefix.
        public var responsePrefix: String?
        /// Usage footer template (string or object).
        public var usageTemplate: AnyCodable?
        /// `on`, `off`, `tokens`, `full`, or a per-channel map.
        public var responseUsage: AnyCodable?
        /// Group-chat behavior (`mentionPatterns`, `historyLimit`, `unmentionedInbound`, `visibleReplies`).
        public var groupChat: GroupChat?
        /// Inbound queue.
        public var queue: AnyCodable?
        /// Inbound debounce.
        public var inbound: AnyCodable?
        /// Acknowledgement reaction.
        public var ackReaction: String?
        /// `group-mentions`, `group-all`, `direct`, `all`, `off` or `none`.
        public var ackReactionScope: String?
        /// Status reactions.
        public var statusReactions: AnyCodable?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]

        /// Creates an empty section.
        public init() {}

        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [
                .init("visibleReplies", \.visibleReplies), .init("responsePrefix", \.responsePrefix),
                .init("usageTemplate", \.usageTemplate), .init("responseUsage", \.responseUsage), .init("groupChat", \.groupChat),
                .init("queue", \.queue), .init("inbound", \.inbound), .init("ackReaction", \.ackReaction),
                .init("ackReactionScope", \.ackReactionScope), .init("statusReactions", \.statusReactions),
            ]
        }

        /// `visibleReplies` normalized to `automatic` / `message_tool`.
        public var visibleRepliesMode: String? {
            switch self.visibleReplies?.value {
            case .bool(let flag)?:
                return flag ? "automatic" : "message_tool"
            case .string(let value)?:
                return value
            default:
                return nil
            }
        }

        /// The string form of `responseUsage` as the SDK ``UsageDisplayLevel`` (`on` → tokens).
        public var responseUsageLevel: UsageDisplayLevel? {
            guard let raw = self.responseUsage?.stringValue else { return nil }
            return UsageDisplayLevel.normalize(raw)
        }

        /// Reply visibility for group chats: `groupChat.visibleReplies`, else the root `visibleReplies`
        /// (upstream `messages.groupChat?.visibleReplies ?? messages.visibleReplies`).
        public var groupVisibleRepliesMode: String? {
            self.groupChat?.visibleRepliesMode ?? self.visibleRepliesMode
        }

        /// `messages.groupChat` (upstream `GroupChatSchema`, strict upstream; unknown keys pass through here).
        public struct GroupChat: ConfigDocumentObject {
            /// Extra mention regex patterns.
            public var mentionPatterns: [String]?
            /// Group history limit (≥ 0).
            public var historyLimit: Int?
            /// `user_request` (default) or `room_event` for unmentioned messages in rooms without a mention requirement.
            public var unmentionedInbound: String?
            /// `automatic` or `message_tool` (booleans are accepted: `true` → automatic, `false` → message_tool).
            public var visibleReplies: AnyCodable?
            /// Passthrough keys.
            public var additionalProperties: [String: AnyCodable] = [:]

            /// Creates an empty group-chat section.
            public init() {}

            /// Typed fields.
            public static var configFields: [ConfigField<Self>] {
                [
                    .init("mentionPatterns", \.mentionPatterns), .init("historyLimit", \.historyLimit),
                    .init("unmentionedInbound", \.unmentionedInbound), .init("visibleReplies", \.visibleReplies),
                ]
            }

            /// `visibleReplies` normalized to `automatic` / `message_tool`.
            public var visibleRepliesMode: String? {
                switch self.visibleReplies?.value {
                case .bool(let flag)?:
                    return flag ? "automatic" : "message_tool"
                case .string(let value)?:
                    return value
                default:
                    return nil
                }
            }

            /// `unmentionedInbound` with the upstream default (`user_request`).
            public var effectiveUnmentionedInbound: String {
                ConfigValueSupport.nonEmpty(self.unmentionedInbound) ?? "user_request"
            }
        }
    }

    /// `commands`: slash-command settings (defaults: native `auto`, nativeSkills `auto`, restart `true`).
    public struct Commands: ConfigDocumentObject {
        /// Native commands: `true`, `false` or `"auto"`.
        public var native: ConfigBoolOrAuto?
        /// Native skill commands: `true`, `false` or `"auto"`.
        public var nativeSkills: ConfigBoolOrAuto?
        /// Text commands.
        public var text: Bool?
        /// `/bash`.
        public var bash: Bool?
        /// Foreground bash window in milliseconds (0...30000).
        public var bashForegroundMs: Int?
        /// `/config`.
        public var config: Bool?
        /// `/mcp`.
        public var mcp: Bool?
        /// `/plugins`.
        public var plugins: Bool?
        /// `/debug`.
        public var debug: Bool?
        /// `/restart`.
        public var restart: Bool?
        /// Owner senders.
        public var ownerAllowFrom: [ConfigStringOrNumber]?
        /// Allowed senders per channel.
        public var allowFrom: [String: [ConfigStringOrNumber]]?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]

        /// Creates an empty section.
        public init() {}

        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [
                .init("native", \.native), .init("nativeSkills", \.nativeSkills), .init("text", \.text), .init("bash", \.bash),
                .init("bashForegroundMs", \.bashForegroundMs), .init("config", \.config), .init("mcp", \.mcp),
                .init("plugins", \.plugins), .init("debug", \.debug), .init("restart", \.restart),
                .init("ownerAllowFrom", \.ownerAllowFrom), .init("allowFrom", \.allowFrom),
            ]
        }
    }

    /// `broadcast`: `strategy` (`parallel` | `sequential`) plus `<channel>:<peerId>` groups
    /// (each an agent-id list or `{agents, mentionGating, maxRounds, maxTurns}`), all passed through.
    public struct Broadcast: ConfigDocumentObject {
        /// `parallel` or `sequential`.
        public var strategy: String?
        /// Broadcast groups keyed by `<channel>:<peerId>`.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty section.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] { [.init("strategy", \.strategy)] }

        /// Agent ids of one group (list form or `agents` of the object form).
        /// - Parameter key: `<channel>:<peerId>` group key.
        /// - Returns: Agent ids, or `nil` when the group is absent.
        public func agents(forGroup key: String) -> [String]? {
            guard let value = self.additionalProperties[key] else { return nil }
            if let list = value.arrayValue {
                return list.compactMap(\.stringValue)
            }
            return value.dictionaryValue?["agents"]?.arrayValue?.compactMap(\.stringValue)
        }
    }
}
