import Foundation
import OpenClawProtocol

/// One note produced by a channel config migration.
public struct ChannelConfigMigrationNote: Codable, Sendable, Equatable {
    /// Note classification.
    public enum Kind: String, Codable, Sendable, Equatable, CaseIterable {
        /// A value moved to its new location.
        case moved
        /// A value was dropped because the target has no equivalent.
        case dropped
        /// The migrated config needs manual attention.
        case warning
        /// An operator action is required outside the config.
        case action
    }

    /// Note classification.
    public var kind: Kind
    /// Upstream config path the note refers to.
    public var path: String
    /// Human-readable description.
    public var message: String

    /// Creates a migration note.
    /// - Parameters:
    ///   - kind: Note classification.
    ///   - path: Config path.
    ///   - message: Human-readable description.
    public init(kind: Kind, path: String, message: String) {
        self.kind = kind
        self.path = path
        self.message = message
    }
}

/// Channel config migrations (upstream doctor migrations for channel sections).
public enum ChannelConfigMigration {
    /// BlueBubbles' media size default; iMessage defaults to 16 MB.
    public static let blueBubblesDefaultMediaMaxMb = 8.0

    /// Builds iMessage settings from a BlueBubbles section (upstream `imessage-from-bluebubbles`).
    ///
    /// Copies `dmPolicy`, `allowFrom`, `groupPolicy`, `groupAllowFrom`, `groups` (per-group keys
    /// must be re-keyed by numeric iMessage `chat_id`), `sendReadReceipts`, `includeAttachments`,
    /// `attachmentRoots`, `mediaMaxMb` (an unset value becomes an explicit 8, BlueBubbles'
    /// default), `textChunkLimit`, `actions.*` and `accounts.*`. Server URL, password and webhook
    /// paths are dropped, as are `coalesceSameSenderDms` and `enrichGroupParticipantsFromContacts`.
    /// - Parameter config: Channels config holding the BlueBubbles section.
    /// - Returns: The iMessage settings and human-readable warnings.
    public static func blueBubblesToIMessage(_ config: ChannelsConfig) -> (IMessageChannelConfig, warnings: [String]) {
        let result = self.migrate(blueBubbles: config.bluebubbles, into: config.imessage)
        return (result.config, result.notes.filter { $0.kind != .moved }.map(\.message))
    }

    static func migrate(
        blueBubbles source: LegacyBlueBubblesChannelConfig,
        into existing: IMessageChannelConfig
    ) -> (config: IMessageChannelConfig, notes: [ChannelConfigMigrationNote]) {
        var notes: [ChannelConfigMigrationNote] = []
        var target = existing
        target.enabled = existing.enabled || source.enabled

        var policy = existing.policy
        let sourcePolicy = source.policy
        func move<T>(_ keyPath: WritableKeyPath<ChannelMessagingPolicyConfig, T?>, _ name: String) {
            guard let value = sourcePolicy[keyPath: keyPath], policy[keyPath: keyPath] == nil else { return }
            policy[keyPath: keyPath] = value
            notes.append(ChannelConfigMigrationNote(kind: .moved, path: "channels.bluebubbles.\(name)", message: "Moved \(name) to channels.imessage.\(name)."))
        }
        move(\.dmPolicy, "dmPolicy")
        move(\.allowFrom, "allowFrom")
        move(\.groupPolicy, "groupPolicy")
        move(\.groupAllowFrom, "groupAllowFrom")
        move(\.textChunkLimit, "textChunkLimit")
        move(\.ackReaction, "ackReaction")
        move(\.ackReactionScope, "ackReactionScope")
        move(\.requireMention, "requireMention")
        if let groups = sourcePolicy.groups, policy.groups == nil {
            policy.groups = groups
            notes.append(ChannelConfigMigrationNote(kind: .moved, path: "channels.bluebubbles.groups", message: "Moved groups to channels.imessage.groups."))
            if groups.keys.contains(where: { $0 != "*" }) {
                notes.append(
                    ChannelConfigMigrationNote(
                        kind: .warning,
                        path: "channels.imessage.groups",
                        message: "Per-group entries are keyed by BlueBubbles chat GUIDs; re-key them by numeric iMessage chat_id "
                            + "(the \"*\" wildcard entry carries over as-is)."
                    )
                )
            }
        }
        if policy.mediaMaxMb == nil {
            policy.mediaMaxMb = sourcePolicy.mediaMaxMb ?? Self.blueBubblesDefaultMediaMaxMb
            notes.append(
                ChannelConfigMigrationNote(
                    kind: .moved,
                    path: "channels.bluebubbles.mediaMaxMb",
                    message: "Set channels.imessage.mediaMaxMb to \(policy.mediaMaxMb ?? Self.blueBubblesDefaultMediaMaxMb) "
                        + "(BlueBubbles defaulted to 8; iMessage defaults to 16)."
                )
            )
        }
        target.policy = policy

        if let sendReadReceipts = source.sendReadReceipts {
            target.sendReadReceipts = sendReadReceipts
        }
        if let includeAttachments = source.includeAttachments {
            target.includeAttachments = includeAttachments
        }
        if let roots = source.attachmentRoots, target.attachmentRoots == nil {
            target.attachmentRoots = roots
        }
        if let actions = source.actions, let migrated = Self.iMessageActions(from: actions, base: target.actions) {
            target.actions = migrated
        }

        let droppedAccountKeys: Set<String> = ["serverUrl", "serverURL", "password", "webhookPath", "webhookPaths"]
        for (accountID, account) in source.accounts where target.accounts[accountID] == nil {
            var values = account.values
            for key in droppedAccountKeys {
                values.removeValue(forKey: key)
            }
            target.accounts[accountID] = ChannelAccountOverride(values: values)
            notes.append(
                ChannelConfigMigrationNote(
                    kind: .moved,
                    path: "channels.bluebubbles.accounts.\(accountID)",
                    message: "Moved account \(accountID) to channels.imessage.accounts.\(accountID) without server URL/password."
                )
            )
        }
        if target.defaultAccount == nil {
            target.defaultAccount = source.defaultAccount
        }

        notes.append(
            ChannelConfigMigrationNote(
                kind: .dropped,
                path: "channels.bluebubbles.serverUrl",
                message: "Dropped the BlueBubbles server URL, password and webhook path; iMessage talks to imsg directly."
            )
        )
        for key in ["coalesceSameSenderDms", "enrichGroupParticipantsFromContacts"] where source.additionalProperties[key] != nil {
            notes.append(
                ChannelConfigMigrationNote(
                    kind: .dropped,
                    path: "channels.bluebubbles.\(key)",
                    message: "Dropped \(key); iMessage has no equivalent setting."
                )
            )
        }
        notes.append(
            ChannelConfigMigrationNote(
                kind: .action,
                path: "channels.imessage",
                message: "Install imsg on a signed-in Mac (or configure channels.imessage.remoteHost for an SSH wrapper) and "
                    + "implement IMessageTransport on top of `imsg rpc`; reply attachments and native actions depend on "
                    + "`imsg status --json` capabilities."
            )
        )
        return (target, notes)
    }

    private static func iMessageActions(from actions: [String: Bool], base: IMessageActionConfig) -> IMessageActionConfig? {
        var merged = base.asDictionary
        for (key, value) in actions where merged[key] != nil {
            merged[key] = value
        }
        let object = merged.mapValues { AnyCodable($0) }
        return ChannelConfigJSON.decode(IMessageActionConfig.self, from: object)
    }
}

public extension ChannelsConfig {
    /// Moves `channels.bluebubbles` into `channels.imessage` and disables BlueBubbles.
    ///
    /// Existing iMessage values win over BlueBubbles values. See
    /// ``ChannelConfigMigration/blueBubblesToIMessage(_:)`` for the key mapping.
    /// - Returns: Migration notes (moved, dropped, warnings and required operator actions).
    @discardableResult
    mutating func migrateBlueBubblesToIMessage() -> [ChannelConfigMigrationNote] {
        let result = ChannelConfigMigration.migrate(blueBubbles: self.bluebubbles, into: self.imessage)
        self.imessage = result.config
        var notes = result.notes
        if self.bluebubbles.enabled {
            notes.append(
                ChannelConfigMigrationNote(
                    kind: .moved,
                    path: "channels.bluebubbles.enabled",
                    message: "Disabled channels.bluebubbles; channels.imessage is now enabled."
                )
            )
        }
        self.bluebubbles = LegacyBlueBubblesChannelConfig()
        return notes
    }
}
