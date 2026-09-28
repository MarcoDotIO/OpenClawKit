import Foundation
import Testing
@testable import OpenClawCore
import OpenClawProtocol

@Suite("Channels config upstream fixtures")
struct ChannelsConfigUpstreamFixtureTests {
    private func decode(_ json: String) throws -> (ChannelsConfig, [ConfigDecodeIssue]) {
        let result = try ConfigDecodeIssueCollector.decode(ChannelsConfig.self, from: Data(json.utf8))
        return (result.value, result.issues)
    }

    @Test
    func decodesUpstreamTelegramWithSecretRefAndAliases() throws {
        // Shape from upstream docs/channels/telegram.md and docs/channels/pairing.md.
        let (config, issues) = try self.decode(
            """
            {
              "telegram": {
                "botToken": {"source": "env", "provider": "default", "id": "TELEGRAM_BOT_TOKEN"},
                "apiRoot": "https://telegram-proxy.example.com",
                "requireMention": false,
                "defaultTo": 123456789,
                "dmPolicy": "pairing",
                "allowFrom": [42, "tg:77"],
                "groupPolicy": "allowlist",
                "groupAllowFrom": ["42"],
                "groups": {"*": {"requireMention": true}, "-1001": {"requireMention": false, "topics": {"7": {"enabled": true}}}},
                "timeoutSeconds": 30,
                "retry": {"attempts": 3},
                "chunkMode": "newline",
                "blockStreaming": true,
                "blockStreamingCoalesce": {"minChars": 800, "idleMs": 400},
                "richMessages": true,
                "linkPreview": false
              }
            }
            """
        )
        let telegram = config.telegram
        #expect(telegram.enabled) // present section without `enabled` is enabled upstream
        #expect(telegram.botToken == nil)
        #expect(telegram.botTokenInput == .ref(SecretRef(source: .env, id: "TELEGRAM_BOT_TOKEN")))
        #expect(telegram.baseURL == "https://telegram-proxy.example.com")
        #expect(telegram.mentionOnly == false)
        #expect(telegram.defaultChatID == "123456789")
        #expect(telegram.richMessages)
        #expect(telegram.policy.allowFrom == ["42", "tg:77"])
        #expect(telegram.policy.groupAllowFrom == ["42"])
        #expect(telegram.policy.groups?["-1001"]?.requireMention == false)
        #expect(telegram.policy.groups?["-1001"]?.additionalProperties["topics"] != nil)
        #expect(telegram.policy.streaming?.chunkMode == .newline)
        #expect(telegram.policy.streaming?.block?.enabled == true)
        #expect(telegram.policy.streaming?.block?.coalesce?.minChars == 800)
        #expect(telegram.additionalProperties["linkPreview"] == AnyCodable(false))
        #expect(telegram.effectivePolicy.requireMention == false)
        #expect(issues.contains { $0.kind == .retiredKey && $0.path.hasSuffix("timeoutSeconds") })
        #expect(issues.contains { $0.kind == .retiredKey && $0.path.hasSuffix("retry") })
        #expect(issues.contains { $0.kind == .legacyKey && $0.path.hasSuffix("chunkMode") })
        #expect(issues.contains { $0.kind == .legacyKey && $0.path.hasSuffix("apiRoot") })
    }

    @Test
    func decodesSparseUpstreamSectionsWithoutThrowing() throws {
        let (config, _) = try self.decode(
            """
            {
              "slack": {"botToken": "${SLACK_BOT_TOKEN}", "appToken": "xapp-1", "mode": "http", "relay": {"url": "https://relay", "authToken": "t", "gatewayId": "gw"}},
              "msteams": {
                "appId": "app", "appPassword": {"source": "file", "provider": "vault", "id": "/teams/password"},
                "tenantId": "tenant", "serviceUrl": "https://smba.example", "cloud": "USGov"
              },
              "imessage": {
                "cliPath": "/opt/homebrew/bin/imsg", "service": "auto", "actions": {"edit": false},
                "catchup": {"enabled": true, "maxAgeMinutes": 10000}
              },
              "googlechat": {
                "serviceAccount": {"type": "service_account", "project_id": "p"}, "audienceType": "app-url",
                "typingIndicator": "reaction", "defaultTo": "spaces/AAA"
              },
              "whatsappCloud": {"phoneNumberId": 123}
            }
            """
        )
        #expect(config.slack.enabled)
        #expect(config.slack.botToken == nil)
        #expect(config.slack.botTokenInput == .ref(SecretRef(source: .env, id: "SLACK_BOT_TOKEN")))
        #expect(config.slack.appToken == "xapp-1")
        #expect(config.slack.mode == .http)
        #expect(config.slack.relay?.gatewayID == "gw")
        #expect(config.slack.webhookPath == "/slack/events")
        #expect(config.slack.unfurlLinks == false)
        #expect(config.msteams.botAppID == "app")
        #expect(config.msteams.botAppPasswordInput?.refValue?.provider == "vault")
        #expect(config.msteams.tenantID == "tenant")
        #expect(config.msteams.serviceURL == "https://smba.example")
        #expect(config.msteams.cloud == .usGov)
        #expect(config.imessage.cliPath == "/opt/homebrew/bin/imsg")
        #expect(config.imessage.service == .auto)
        #expect(config.imessage.actions.edit == false)
        #expect(config.imessage.actions.reactions)
        #expect(config.imessage.catchup.enabled)
        #expect(config.imessage.catchup.maxAgeMinutes == 720)
        #expect(config.imessage.sendReadReceipts)
        #expect(config.googleChat.serviceAccountSecret == nil)
        #expect(config.googleChat.audienceType == .appURL)
        #expect(config.googleChat.typingIndicator == .reaction)
        #expect(config.googleChat.defaultSpaceID == "spaces/AAA")
        #expect(config.whatsappCloud.phoneNumberID == "123")
        #expect(config.whatsappCloud.enabled == false) // SDK-only section keeps the old default
        #expect(config.discord.enabled == false) // absent section
    }

    @Test
    func decodesSignalTransportFromUpstreamDocs() throws {
        let (config, _) = try self.decode(
            """
            {"signal": {
              "enabled": true, "account": "+15551234567",
              "transport": {"kind": "external-native", "url": "http://127.0.0.1:8080"},
              "dmPolicy": "pairing", "allowFrom": ["+15557654321"]
            }}
            """
        )
        #expect(config.signal.accountID == "+15551234567")
        #expect(config.signal.transport?.kind == .externalNative)
        #expect(config.signal.serviceURL == "http://127.0.0.1:8080")
        #expect(config.signal.policy.effectiveDMPolicy == .pairing)
    }

    @Test
    func keepsUpstreamWhatsAppAndPluginSectionsAsExtensionChannels() throws {
        let json = """
        {
          "whatsapp": {"enabled": true, "dmPolicy": "allowlist", "allowFrom": ["+15551234567"]},
          "sms": {"accountSid": "AC1", "authToken": "plain-secret", "fromNumber": "+15550001111"},
          "matrix": {"homeserver": "https://matrix.example", "accessToken": {"source": "env", "provider": "default", "id": "MATRIX_TOKEN"}},
          "a2a": {"peers": {"alpha": {"url": "https://a", "token": "peer-secret"}}},
          "defaults": {"groupPolicy": "open", "botLoopProtection": {"maxEventsPerWindow": 5}, "heartbeat": {"showOk": true}},
          "modelByChannel": {"telegram": {"123": "openai/gpt-5.5"}}
        }
        """
        let (config, issues) = try self.decode(json)
        #expect(config.whatsappCloud.enabled == false)
        #expect(config.extensionChannels["whatsapp"]?.dictionaryValue?["dmPolicy"] == AnyCodable("allowlist"))
        #expect(config.rawSection(named: "sms")?["accountSid"] == AnyCodable("AC1"))
        #expect(config.isChannelEnabled("sms"))
        #expect(config.defaults.groupPolicy == .open)
        #expect(config.defaults.heartbeatVisibility?.showOk == true)
        #expect(issues.contains { $0.kind == .legacyKey && $0.path.contains("heartbeat") })
        #expect(config.modelByChannel["telegram"]?["123"] == "openai/gpt-5.5")

        let whatsappPolicy = config.messagingPolicy(for: "sms")
        #expect(whatsappPolicy.groupPolicy == .open) // inherited from channels.defaults
        #expect(whatsappPolicy.botLoopProtection?.maxEventsPerWindow == 5)

        let plaintext = config.plaintextSecretPaths()
        #expect(plaintext.contains("channels.sms.authToken"))
        #expect(plaintext.contains("channels.a2a.peers.alpha.token"))
        #expect(!plaintext.contains { $0.hasPrefix("channels.matrix") })

        // Round trip keeps unknown sections verbatim.
        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ChannelsConfig.self, from: encoded)
        #expect(decoded == config)
        let object = try JSONDecoder().decode([String: AnyCodable].self, from: encoded)
        #expect(object["sms"] != nil)
        #expect(object["whatsapp"] != nil)
        #expect(object["pluginChannels"] != nil)
    }

    @Test
    func resolvesAccountsWithAccountValuesWinning() throws {
        let (config, issues) = try self.decode(
            """
            {"telegram": {
              "botToken": "root-token", "dmPolicy": "allowlist", "allowFrom": ["1"], "requireMention": true,
              "accounts": {"work": {"botToken": "work-token", "requireMention": false, "allowFrom": ["2"]}, "home": {"enabled": false}},
              "defaultAccount": "work"
            }}
            """
        )
        #expect(config.telegram.accountIDs == ["home", "work"])
        let work = config.telegram.resolvedAccount("WORK")
        #expect(work.botToken == "work-token")
        #expect(work.mentionOnly == false)
        #expect(work.policy.allowFrom == ["2"])
        #expect(work.policy.dmPolicy == .allowlist) // inherited from root
        #expect(work.accounts.isEmpty)
        let defaultAccount = config.telegram.resolvedAccount(nil)
        #expect(defaultAccount.botToken == "work-token") // defaultAccount = work
        #expect(config.telegram.resolvedAccount("missing").botToken == "root-token")
        #expect(config.telegram.accounts["home"]?.isEnabled == false)
        #expect(config.messagingPolicy(for: "telegram", accountID: "work").allowFrom == ["2"])
        #expect(issues.isEmpty || issues.allSatisfy { $0.kind != .typeMismatch })
    }

    @Test
    func sdkShapedConfigRoundTripsUnchanged() throws {
        var original = ChannelsConfig(
            discord: DiscordChannelConfig(enabled: true, botToken: "d", defaultChannelID: "c", mentionOnly: false),
            telegram: TelegramChannelConfig(enabled: true, botToken: "t", richMessages: true),
            slack: SlackChannelConfig(enabled: true, botToken: "s"),
            compatibility: ChannelsCompatibilityConfig(legacySessionAccountKeys: true)
        )
        original.telegram.policy.dmPolicy = .open
        original.telegram.policy.allowFrom = ["*"]
        original.telegram.accounts = ["alt": ChannelAccountOverride(values: ["botToken": AnyCodable("alt")])]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChannelsConfig.self, from: data)
        #expect(decoded == original)
        #expect(decoded.compatibility.legacySessionAccountKeys)
    }

    @Test
    func validationIssuesMirrorUpstreamRefinements() throws {
        let (config, _) = try self.decode(
            """
            {
              "discord": {"dmPolicy": "open", "allowFrom": ["123"]},
              "slack": {"dmPolicy": "allowlist"},
              "signal": {"accounts": {"a": {}, "b": {}}},
              "telegram": {"defaultAccount": "ghost"},
              "matrix": {"bindings": {"acp": {"agent": "x"}}}
            }
            """
        )
        let issues = config.validationIssues()
        #expect(issues.contains { $0.path == "channels.discord.allowFrom" && $0.message.contains("\"*\"") })
        #expect(issues.contains { $0.path == "channels.slack.allowFrom" })
        #expect(issues.contains { $0.path == "channels.signal.defaultAccount" })
        #expect(issues.contains { $0.path == "channels.telegram.defaultAccount" && $0.message.contains("ghost") })
        #expect(issues.contains { $0.path == "channels.matrix.bindings.acp" })
    }

    @Test
    func resolvesSecretsThroughInjectedResolver() async throws {
        let (config, _) = try self.decode(
            """
            {"discord": {"token": "${DISCORD_BOT_TOKEN}"}, "slack": {"botToken": {"source": "exec", "provider": "op", "id": "slack/bot"}}}
            """
        )
        #expect(config.discord.botTokenInput == .ref(SecretRef(source: .env, id: "DISCORD_BOT_TOKEN")))
        let resolver = ChannelSecretResolver.standard(environment: ["DISCORD_BOT_TOKEN": "resolved-discord"])
        await #expect(throws: OpenClawCoreError.self) {
            _ = try await config.resolvingSecrets(using: resolver)
        }
        let custom = ChannelSecretResolver { input in
            switch input {
            case .string(let value): value
            case .ref(let ref): "resolved:\(ref.id)"
            }
        }
        let resolved = try await config.resolvingSecrets(using: custom)
        #expect(resolved.discord.botToken == "resolved:DISCORD_BOT_TOKEN")
        #expect(resolved.slack.botToken == "resolved:slack/bot")

        var envOnly = config
        envOnly.slack.botTokenInput = .string("plain")
        let envResolved = try await envOnly.resolvingSecrets(using: resolver)
        #expect(envResolved.discord.botToken == "resolved-discord")
    }

    @Test
    func pluginSettingsExposeReadOnlyViews() throws {
        let (config, _) = try self.decode(
            """
            {
              "buzz": {"relayUrl": "wss://relay.buzz", "privateKey": "${BUZZ_PRIVATE_KEY}", "groups": {"b": {}, "a": {}}, "historyLimit": 50},
              "clickclack": {"baseUrl": "https://cc", "token": "tok", "reconnectMs": 10, "allowBots": "mentions"},
              "raft": {"profile": "work"},
              "reef": {"handle": "me", "guard": {
                "provider": "openai", "authMode": "api-key", "apiKeyEnv": "OPENAI_API_KEY",
                "pinnedModel": "gpt", "policyVersion": "1", "timeoutMs": 1000
              }}
            }
            """
        )
        let buzz = try #require(config.pluginSettings(BuzzChannelSettings.self))
        #expect(buzz.isConfigured)
        #expect(buzz.groupIDs == ["a", "b"])
        #expect(buzz.historyLimit == 20)
        #expect(buzz.groupPolicy == .allowlist)
        let clickclack = try #require(config.pluginSettings(ClickClackChannelSettings.self))
        #expect(clickclack.reconnectMs == 100)
        #expect(clickclack.allowBots == .mentions)
        #expect(config.pluginSettings(RaftChannelSettings.self)?.profile == "work")
        let reef = try #require(config.pluginSettings(ReefChannelSettings.self))
        #expect(reef.relayURL == "https://reefwire.ai")
        #expect(reef.requestPolicy == .codeOnly)
        #expect(reef.guardSettings?.apiKeyEnv == "OPENAI_API_KEY")
        #expect(reef.isConfigured)
        #expect(config.plaintextSecretPaths().contains("channels.clickclack.token"))
        #expect(!config.plaintextSecretPaths().contains("channels.buzz.privateKey"))
    }
}
