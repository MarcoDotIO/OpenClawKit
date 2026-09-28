import Foundation
import Testing
@testable import OpenClawCore
import OpenClawProtocol

@Suite("Channel config migration and audit")
struct ChannelConfigMigrationTests {
    @Test
    func blueBubblesMigratesToIMessage() throws {
        let json = """
        {"bluebubbles": {
          "enabled": true, "serverUrl": "http://mac.local:1234", "password": "bb-pass", "webhookPath": "/bb",
          "dmPolicy": "allowlist", "allowFrom": ["+15550001111"], "groupPolicy": "open",
          "groups": {"*": {"requireMention": true}, "iMessage;+;chat123": {"requireMention": false}},
          "sendReadReceipts": false, "includeAttachments": true, "attachmentRoots": ["~/Pictures"],
          "actions": {"edit": false, "polls": false},
          "accounts": {"work": {"serverUrl": "http://work:1234", "password": "p", "allowFrom": ["+15552223333"]}},
          "coalesceSameSenderDms": true, "enrichGroupParticipantsFromContacts": true
        }}
        """
        var config = try JSONDecoder().decode(ChannelsConfig.self, from: Data(json.utf8))
        let (preview, warnings) = ChannelConfigMigration.blueBubblesToIMessage(config)
        #expect(preview.enabled)
        #expect(!warnings.isEmpty)

        let notes = config.migrateBlueBubblesToIMessage()
        let imessage = config.imessage
        #expect(imessage.enabled)
        #expect(imessage.policy.dmPolicy == .allowlist)
        #expect(imessage.policy.allowFrom == ["+15550001111"])
        #expect(imessage.policy.groupPolicy == .open)
        #expect(imessage.policy.groups?["*"]?.requireMention == true)
        #expect(imessage.policy.mediaMaxMb == 8)
        #expect(imessage.sendReadReceipts == false)
        #expect(imessage.includeAttachments)
        #expect(imessage.attachmentRoots == ["~/Pictures"])
        #expect(imessage.actions.edit == false)
        #expect(imessage.actions.polls == false)
        #expect(imessage.actions.reactions)
        #expect(imessage.accounts["work"]?.values["serverUrl"] == nil)
        #expect(imessage.accounts["work"]?.values["password"] == nil)
        #expect(imessage.accounts["work"]?.values["allowFrom"] != nil)
        #expect(config.bluebubbles.enabled == false)
        #expect(notes.contains { $0.kind == .warning && $0.message.contains("chat_id") })
        #expect(notes.contains { $0.kind == .dropped && $0.path.hasSuffix("coalesceSameSenderDms") })
        #expect(notes.contains { $0.kind == .dropped && $0.path.hasSuffix("enrichGroupParticipantsFromContacts") })
        #expect(notes.contains { $0.kind == .action && $0.message.contains("imsg") })
    }

    @Test
    func existingIMessageValuesWinDuringMigration() {
        var config = ChannelsConfig()
        config.bluebubbles.enabled = true
        config.bluebubbles.policy.dmPolicy = .open
        config.bluebubbles.policy.mediaMaxMb = 20
        config.imessage.policy.dmPolicy = .pairing
        config.migrateBlueBubblesToIMessage()
        #expect(config.imessage.policy.dmPolicy == .pairing)
        #expect(config.imessage.policy.mediaMaxMb == 20)
    }

    @Test
    func auditFindingsFlagPlaintextSecretsAndRemovedChannels() {
        var config = ChannelsConfig(
            telegram: TelegramChannelConfig(enabled: true, botToken: "123:abc", webhookSecret: "hook"),
            slack: SlackChannelConfig(enabled: true, botToken: "xoxb")
        )
        config.slack.relay = SlackRelayConfig(url: "https://relay", authToken: "relay-token")
        config.msteams = MicrosoftTeamsChannelConfig(enabled: true, botAppPassword: "pw", cloud: .usGovDoD)
        config.bluebubbles.enabled = true
        config.googleChat.serviceAccount = AnyCodable("{\"type\":\"service_account\"}")
        config.discord.botTokenInput = .ref(SecretRef(source: .env, id: "DISCORD_TOKEN"))
        config.telegram.accounts["alt"] = ChannelAccountOverride(values: ["botToken": AnyCodable("456:def")])

        let paths = config.plaintextSecretPaths()
        #expect(paths.contains("channels.telegram.botToken"))
        #expect(paths.contains("channels.telegram.webhookSecret"))
        #expect(paths.contains("channels.telegram.accounts.alt.botToken"))
        #expect(paths.contains("channels.slack.relay.authToken"))
        #expect(paths.contains("channels.msteams.appPassword"))
        #expect(paths.contains("channels.googlechat.serviceAccount"))
        #expect(!paths.contains("channels.discord.token"))

        let findings = config.securityAuditFindings()
        #expect(findings.contains { $0.id == "channels.secrets.plaintext" && $0.severity == .warning })
        #expect(findings.contains { $0.id == "channels.bluebubbles.removed-upstream" && $0.severity == .info })
        #expect(findings.contains { $0.id == "channels.msteams.cloud-service-url" })
    }

    @Test
    func pluginChannelConfigDecodesWithoutRawKey() throws {
        let json = #"{"pluginChannels": {"matrix": {"enabled": true, "config": {"homeserver": "https://m"}}}}"#
        let config = try JSONDecoder().decode(ChannelsConfig.self, from: Data(json.utf8))
        #expect(config.pluginChannels["matrix"]?.enabled == true)
        #expect(config.pluginChannels["matrix"]?.raw.isEmpty == true)
        #expect(config.isChannelEnabled("matrix"))
    }
}
