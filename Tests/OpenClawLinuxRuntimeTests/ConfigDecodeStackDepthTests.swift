import Foundation
import OpenClawProtocol
import Testing
@testable import OpenClawCore

/// Channel config decoding must stay well inside a cooperative-thread stack (512 KB on Darwin).
///
/// `ChannelsConfig` used to store its ten channel sections inline (about 6 KB, and 8.5 KB for
/// `OpenClawConfig`), and debug builds give every temporary copy its own stack slot. Importing a
/// document with `OpenClawConfig(document:)` took about 390 KB of stack; with a test body above it,
/// this bundle crashed with SIGBUS ("Thread stack size exceeded") whenever the one-time generic
/// metadata instantiation needed a few more kilobytes. These tests run the decodes on a thread with
/// a small stack and bound the peak each one uses (debug builds: about 38 KB and 104 KB now).
@Suite("Config decode stack depth")
struct ConfigDecodeStackDepthTests {
    /// Messaging policy keys shared by every section, including nested objects, accounts and
    /// legacy keys, so each section takes its deepest decode path.
    static let policyJSON = #"""
    "dmPolicy": "allowlist", "allowFrom": [42, "+15550001111"], "groupPolicy": "open",
    "groupAllowFrom": ["ops"], "defaultTo": 7, "textChunkLimit": 4000,
    "streaming": {"mode": "partial", "chunkMode": "newline",
                  "block": {"enabled": true, "coalesce": {"minChars": 10, "maxChars": 100, "idleMs": 50}}},
    "chunkMode": "length", "blockStreaming": true, "blockStreamingCoalesce": {"minChars": 1},
    "mediaMaxMb": 5, "replyToMode": "first", "responsePrefix": "auto", "historyLimit": 20,
    "dmHistoryLimit": 10, "contextVisibility": "all", "markdown": {"tables": "code"},
    "implicitMentions": {"replyToBot": true, "quotedBot": false},
    "botLoopProtection": {"enabled": true, "maxEventsPerWindow": 5}, "allowBots": "mentions",
    "ackReaction": "eyes", "ackReactionScope": "group-mentions", "reactionNotifications": "own",
    "reactionLevel": "minimal", "joinIntro": true,
    "groups": {"*": {"requireMention": false, "groupPolicy": "open", "allowFrom": [1, 2],
                     "botLoopProtection": {"enabled": false}, "implicitMentions": {"threadParticipation": true}}},
    "mentionPatterns": ["@bot"], "heartbeatVisibility": {"showOk": true}, "typingMode": "thinking",
    "typingIntervalMs": 6000,
    "accounts": {"work": {"botToken": "${WORK_TOKEN}", "dmPolicy": "open", "streaming": {"mode": "off"}}},
    "defaultAccount": "work", "futureKey": {"nested": [1, {"deep": true}]}
    """#

    /// Every typed section plus defaults, model overrides, compatibility, legacy plugin channels
    /// and two extension channels.
    static let channelsJSON: String = {
        let sections = [
            #""discord": {"token": {"source": "env", "provider": "default", "id": "DISCORD_TOKEN"}, "presenceEnabled": false"#,
            #""telegram": {"botToken": "${TELEGRAM_BOT_TOKEN}", "webhookSecret": {"source": "file", "provider": "vault", "id": "/tg"}, "#
                + #""apiRoot": "https://t.example", "timeoutSeconds": 5"#,
            #""whatsappCloud": {"enabled": true, "accessToken": "${WA_TOKEN}", "phoneNumberId": 15550001111, "appSecret": "s""#,
            #""slack": {"botToken": "xoxb-1", "appToken": "xapp-1", "signingSecret": "${SLACK_SIGNING}", "#
                + #""relay": {"url": "https://relay.example", "authToken": "${RELAY}", "gatewayId": "g"}"#,
            #""googlechat": {"serviceAccount": {"type": "service_account"}, "audienceType": "app-url", "audience": 1234"#,
            #""signal": {"account": "+15550001111", "transport": {"kind": "container", "url": "http://signal:8080"}"#,
            #""bluebubbles": {"serverUrl": "http://bb.local", "password": "p", "actions": {"reactions": false}"#,
            #""imessage": {"cliPath": "imsg", "actions": {"reactions": false}, "catchup": {"enabled": true}"#,
            #""msteams": {"appId": "a", "appPassword": "${TEAMS}", "cloud": "usGov""#,
            #""webchat": {"enabled": true, "sharedSecret": "w""#,
            #""sms": {"authToken": "plain""#,
            #""matrix": {"homeserver": "https://matrix.example.com""#,
        ].map { "\($0), \(Self.policyJSON)}" }
        let rest = [
            #""defaults": {"groupPolicy": "open", "implicitMentions": {"replyToBot": true}}"#,
            #""modelByChannel": {"telegram": {"-100": "openai/gpt-5.4"}}"#,
            #""compatibility": {"legacySessionAccountKeys": true}"#,
            #""pluginChannels": {"legacy": {"enabled": true, "config": {"room": "lobby"}}}"#,
        ]
        return "{" + (sections + rest).joined(separator: ",\n") + "}"
    }()

    @Test
    func fixtureDecodesEverySection() throws {
        let config = try JSONDecoder().decode(ChannelsConfig.self, from: Data(Self.channelsJSON.utf8))
        let sections: [any ChannelSectionConfig] = [
            config.discord, config.telegram, config.whatsappCloud, config.slack, config.googleChat,
            config.signal, config.bluebubbles, config.imessage, config.msteams, config.webchat,
        ]
        for section in sections {
            #expect(section.enabled)
            #expect(section.policy.groups?["*"]?.requireMention == false)
            #expect(section.accounts["work"] != nil)
        }
        #expect(config.slack.relay?.url == "https://relay.example")
        #expect(config.signal.transport?.kind == .container)
        #expect(Set(config.extensionChannels.keys) == ["sms", "matrix"])
        #expect(config.pluginChannels["legacy"]?.enabled == true)
        #expect(config.compatibility.legacySessionAccountKeys)
    }

    @Test
    func channelsConfigDecodeStaysShallow() throws {
        let data = Data(Self.channelsJSON.utf8)
        let peak = try StackUsageProbe.peakBytes(stackSize: 128 * 1024) {
            let decoder = JSONDecoder()
            decoder.userInfo[.openClawConfigIssues] = ConfigDecodeIssueCollector()
            _ = try? decoder.decode(ChannelsConfig.self, from: data)
        }
        // Was about 110 KB, mostly the ten sections' temporaries in `ChannelsConfig.init(from:)`.
        #expect(peak < 64 * 1024, "Decoding a full ChannelsConfig used \(peak) bytes of stack")
    }

    @Test
    func documentImportStaysShallow() throws {
        let json = #"{"session": {"legacyChannelAccountKeys": true}, "gateway": {"port": 18789}, "channels": "#
            + Self.channelsJSON + "}"
        let document = try OpenClawConfigDocument.decode(Data(json.utf8))
        let peak = try StackUsageProbe.peakBytes(stackSize: 512 * 1024) {
            _ = OpenClawConfig(document: document, base: OpenClawConfig(), issues: ConfigDecodeIssueCollector())
        }
        // Was about 390 KB of the 512 KB a cooperative thread has.
        #expect(peak < 192 * 1024, "Importing a config document used \(peak) bytes of stack")
    }
}
