import Foundation
import Testing
@testable import OpenClawCore
import OpenClawProtocol

@Suite("Upstream channels container document")
struct ChannelsConfigDocumentTests {
    private let upstreamJSON = """
    {
      "defaults": {"groupPolicy": "open", "contextVisibility": "allowlist"},
      "modelByChannel": {"discord": {"123": "anthropic/claude-sonnet-5"}},
      "telegram": {"botToken": "${TELEGRAM_BOT_TOKEN}", "dmPolicy": "allowlist", "allowFrom": [1], "linkPreview": false,
                   "threadBindings": {"enabled": true, "idleHours": 4}},
      "matrix": {"homeserver": "https://matrix.example", "execApprovals": {"enabled": "auto"}, "healthMonitor": {"enabled": false},
                 "accounts": {"a": {"enabled": false}, "b": {}}, "defaultAccount": "a"},
      "whatsapp": {"enabled": false}
    }
    """

    @Test
    func roundTripsLosslessly() throws {
        let document = try JSONDecoder().decode(ChannelsConfigDocument.self, from: Data(self.upstreamJSON.utf8))
        #expect(document.defaults?.groupPolicy == .open)
        #expect(document.modelByChannel?["discord"]?["123"] == "anthropic/claude-sonnet-5")
        #expect(document.channels.keys.sorted() == ["matrix", "telegram", "whatsapp"])
        let matrix = try #require(document.channels["matrix"])
        #expect(matrix.enabled)
        #expect(matrix.healthMonitorEnabled == false)
        #expect(matrix.execApprovals?["enabled"] == AnyCodable("auto"))
        #expect(matrix.accounts.keys.sorted() == ["a", "b"])
        #expect(matrix.defaultAccount == "a")
        #expect(document.channels["telegram"]?.threadBindings?["idleHours"] == AnyCodable(4))
        #expect(document.channels["telegram"]?.policy.allowFrom == ["1"])
        #expect(document.channels["whatsapp"]?.enabled == false)

        let encoded = try JSONEncoder().encode(document)
        let original = try JSONDecoder().decode([String: AnyCodable].self, from: Data(self.upstreamJSON.utf8))
        let reencoded = try JSONDecoder().decode([String: AnyCodable].self, from: encoded)
        #expect(reencoded == original)
    }

    @Test
    func importsIntoTheRuntimeModelAndExportsUpstreamKeysOnly() throws {
        let document = try JSONDecoder().decode(ChannelsConfigDocument.self, from: Data(self.upstreamJSON.utf8))
        var config = document.channelsConfig
        #expect(config.telegram.enabled)
        #expect(config.telegram.policy.dmPolicy == .allowlist)
        #expect(config.extensionChannels["matrix"] != nil)
        #expect(config.defaults.contextVisibility == .allowlist)

        config.telegram.mentionOnly = false
        config.telegram.pollIntervalMs = 5_000
        config.telegram.policy.typingMode = .never
        config.webchat.enabled = true
        config.whatsappCloud.enabled = true
        config.discord = DiscordChannelConfig(enabled: true, botToken: "discord-token", defaultChannelID: "42")
        config.msteams = MicrosoftTeamsChannelConfig(enabled: true, botAppID: "app", tenantID: "t")

        let exported = ChannelsConfigDocument(exporting: config, preserving: document)
        let telegram = try #require(exported.channels["telegram"]?.raw)
        #expect(telegram["linkPreview"] == AnyCodable(false))
        #expect(telegram["threadBindings"] != nil)
        #expect(telegram["pollIntervalMs"] == nil)
        #expect(telegram["typingMode"] == nil)
        #expect(telegram["requireMention"] == nil)
        #expect(telegram["mentionOnly"] == nil)
        #expect(telegram["groups"]?.dictionaryValue?["*"]?.dictionaryValue?["requireMention"] == AnyCodable(false))
        #expect(telegram["botToken"]?.dictionaryValue?["id"] == AnyCodable("TELEGRAM_BOT_TOKEN"))
        #expect(exported.channels["webchat"] == nil)
        #expect(exported.channels["whatsappCloud"] == nil)
        #expect(exported.channels["pluginChannels"] == nil)
        #expect(exported.channels["whatsapp"]?.enabled == false)
        #expect(exported.channels["matrix"]?.raw["homeserver"] == AnyCodable("https://matrix.example"))
        let discord = try #require(exported.channels["discord"]?.raw)
        #expect(discord["token"] == AnyCodable("discord-token"))
        #expect(discord["defaultTo"] == AnyCodable("42"))
        #expect(discord["botToken"] == nil)
        #expect(discord["presenceEnabled"] == nil)
        let teams = try #require(exported.channels["msteams"]?.raw)
        #expect(teams["appId"] == AnyCodable("app"))
        #expect(teams["tenantId"] == AnyCodable("t"))
        #expect(teams["serviceUrl"] == nil)
        #expect(exported.modelByChannel?["discord"]?["123"] == "anthropic/claude-sonnet-5")

        // The exported document imports back to the same effective settings.
        let reimported = exported.channelsConfig
        #expect(reimported.discord.botToken == "discord-token")
        #expect(reimported.discord.defaultChannelID == "42")
        #expect(reimported.telegram.policy.groupConfig(for: "-1")?.requireMention == false)
    }

    @Test
    func documentValidationReportsUpstreamIssues() throws {
        let document = try JSONDecoder().decode(
            ChannelsConfigDocument.self,
            from: Data(#"{"irc": {"dmPolicy": "open", "allowFrom": ["alice"]}}"#.utf8)
        )
        #expect(document.validationIssues().contains { $0.path == "channels.irc.allowFrom" })
    }
}
