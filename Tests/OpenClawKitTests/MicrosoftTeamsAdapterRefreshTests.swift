import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OpenClawChannels
import OpenClawCore
import Testing

@Suite("Microsoft Teams adapter 2026.9.6 refresh")
struct MicrosoftTeamsAdapterRefreshTests {
    static func transport(expiresIn: Int = 3_600) async -> ScriptedChannelHTTP {
        let http = ScriptedChannelHTTP()
        await http.on("/oauth2/v2.0/token", json: #"{"token_type":"Bearer","expires_in":\#(expiresIn),"access_token":"tok-1"}"#)
        await http.on("/activities", json: #"{"id":"act-1"}"#)
        await http.on("/activities/act-0", json: #"{"id":"act-2"}"#)
        return http
    }

    static func config(_ configure: (inout MicrosoftTeamsChannelConfig) -> Void = { _ in }) -> MicrosoftTeamsChannelConfig {
        var config = MicrosoftTeamsChannelConfig(
            enabled: true,
            botAppID: "app-1",
            botAppPassword: "secret-1",
            tenantID: "tenant-9",
            defaultConversationID: "conv-default"
        )
        configure(&config)
        return config
    }

    @Test
    func serviceURLAllowlistRejectsForeignHosts() throws {
        #expect(BotFrameworkServiceURL.isAllowed("https://smba.trafficmanager.net/amer/"))
        #expect(BotFrameworkServiceURL.isAllowed("https://smba.infra.gov.teams.microsoft.us"))
        #expect(BotFrameworkServiceURL.isAllowed("https://x.botframework.azure.cn/"))
        #expect(!BotFrameworkServiceURL.isAllowed("http://smba.trafficmanager.net/amer"))
        #expect(!BotFrameworkServiceURL.isAllowed("https://evil.example.com"))
        #expect(!BotFrameworkServiceURL.isAllowed("https://smba.trafficmanager.net.evil.example.com"))
        #expect(!BotFrameworkServiceURL.isAllowed("https://notsmba.trafficmanager.net"))
        #expect(try BotFrameworkServiceURL.normalize("https://smba.trafficmanager.net/amer///") == "https://smba.trafficmanager.net/amer")
        do {
            _ = try BotFrameworkServiceURL.normalize("https://evil.example.com/teams")
            Issue.record("expected a blocked host")
        } catch {
            #expect(error.localizedDescription.contains("Blocked Microsoft Teams serviceUrl host: evil.example.com"))
        }
    }

    @Test
    func tokenIsAcquiredWithClientCredentialsAndCached() async throws {
        let http = await Self.transport()
        let adapter = MicrosoftTeamsChannelAdapter(config: Self.config(), transport: http)
        try await adapter.start()
        try await adapter.send(OutboundMessage(channel: .msteams, peerID: "conv-1", text: "one"))
        try await adapter.send(OutboundMessage(channel: .msteams, peerID: "conv-1", text: "two"))
        await adapter.stop()

        let tokens = await http.requests("/oauth2/v2.0/token")
        #expect(tokens.count == 1)
        #expect(tokens[0].url == "https://login.microsoftonline.com/tenant-9/oauth2/v2.0/token")
        let form = ChannelHTTP.parseForm(Data(tokens[0].body.utf8))
        #expect(form["grant_type"] == "client_credentials")
        #expect(form["client_id"] == "app-1")
        #expect(form["client_secret"] == "secret-1")
        #expect(form["scope"] == "https://api.botframework.com/.default")
        let posts = await http.requests("/activities")
        #expect(posts.count == 2)
        #expect(posts.allSatisfy { $0.headers["Authorization"] == "Bearer tok-1" })
        #expect(posts.allSatisfy { !$0.body.contains("secret-1") && $0.headers["Authorization"]?.contains("secret-1") == false })
    }

    @Test
    func perConversationServiceURLFromInboundWinsAndEvilHostsAreIgnored() async throws {
        let http = await Self.transport()
        let adapter = MicrosoftTeamsChannelAdapter(config: Self.config(), transport: http)
        try await adapter.start()
        let good = #"{"type":"message","id":"a1","text":"hi","serviceUrl":"https://smba.trafficmanager.net/emea/","from":{"id":"u1"},"conversation":{"id":"conv-emea"}}"#
        let evil = #"{"type":"message","id":"a2","text":"hi","serviceUrl":"https://evil.example.com/","from":{"id":"u1"},"conversation":{"id":"conv-evil"}}"#
        try await adapter.handleWebhookEvent(Data(good.utf8))
        try await adapter.handleWebhookEvent(Data(evil.utf8))
        try await adapter.send(OutboundMessage(channel: .msteams, peerID: "conv-emea", text: "reply"))
        try await adapter.send(OutboundMessage(channel: .msteams, peerID: "conv-evil", text: "reply"))
        await adapter.stop()

        let posts = await http.requests("/activities")
        #expect(posts.map(\.url).contains("https://smba.trafficmanager.net/emea/v3/conversations/conv-emea/activities"))
        #expect(posts.map(\.url).contains("https://smba.trafficmanager.net/teams/v3/conversations/conv-evil/activities"))
        #expect(!posts.contains { $0.url.contains("evil.example.com") })
    }

    @Test
    func blockedConfiguredServiceURLFailsStartBeforeAnyToken() async throws {
        let http = await Self.transport()
        let adapter = MicrosoftTeamsChannelAdapter(
            config: Self.config(),
            transport: http,
            serviceURL: URL(string: "https://evil.example.com/teams")!
        )
        await #expect(throws: OpenClawCoreError.self) {
            try await adapter.start()
        }
        #expect(await http.count("/oauth2/v2.0/token") == 0)
    }

    @Test
    func repliesPostToActivityAndChunkAndTyping() async throws {
        let http = await Self.transport()
        let adapter = MicrosoftTeamsChannelAdapter(config: Self.config(), transport: http)
        try await adapter.start()
        let long = String(repeating: "x", count: 4_500)
        let receipt = try await adapter.sendReturningReceipt(OutboundMessage(channel: .msteams, peerID: "conv-1", text: long, replyToID: "act-0"))
        try await adapter.sendTypingIndicator(accountID: nil, peerID: "conv-1")
        await adapter.stop()

        #expect(receipt.platformMessageIDs == ["act-2", "act-1"])
        #expect(await http.count("/activities/act-0") == 1)
        let typing = await http.requests("/activities").map { jsonObject($0.body) }.filter { $0["type"] as? String == "typing" }
        #expect(typing.count == 1)
        #expect(adapter.supportsTypingIndicator)
    }

    @Test
    func typingDisabledAndBotInstallJoinEvent() async throws {
        let http = await Self.transport()
        let adapter = MicrosoftTeamsChannelAdapter(config: Self.config { $0.typingIndicator = false }, transport: http)
        #expect(adapter.supportsTypingIndicator == false)
        let collector = ChannelEventCollector()
        await adapter.setJoinEventHandler { await collector.appendJoin($0) }
        try await adapter.start()
        let update = #"{"type":"conversationUpdate","recipient":{"id":"28:app-1"},"membersAdded":[{"id":"28:app-1"}],"#
            + #""conversation":{"id":"19:room","name":"Ops","conversationType":"channel"}}"#
        try await adapter.handleWebhookEvent(Data(update.utf8))
        await adapter.stop()
        let join = try #require(await collector.joins.first)
        #expect(join.peerID == "19:room")
        #expect(join.roomName == "Ops")
        #expect(join.chatType == .channel)
    }

    @Test
    func nationalCloudAuthoritiesAndUpstreamKeys() async throws {
        let provider = BotFrameworkTokenProvider(appID: "a", appPassword: "b", cloud: .usGov)
        #expect(provider.tokenEndpoint.absoluteString == "https://login.microsoftonline.us/botframework.com/oauth2/v2.0/token")
        #expect(provider.scope == "https://api.botframework.us/.default")
        let json = #"{"appId":"x","appPassword":"y","tenantId":"t","serviceUrl":"https://smba.infra.gov.teams.microsoft.us","cloud":"USGov","typingIndicator":false}"#
        let config = try JSONDecoder().decode(MicrosoftTeamsChannelConfig.self, from: Data(json.utf8))
        #expect(config.botAppID == "x")
        #expect(config.botAppPassword == "y")
        #expect(config.tenantID == "t")
        #expect(config.cloud == .usGov)
        #expect(config.typingIndicator == false)
    }

    @Test
    func unconfiguredWithoutCredentials() async throws {
        let adapter = MicrosoftTeamsChannelAdapter(config: MicrosoftTeamsChannelConfig(enabled: true, botAppID: "a"))
        #expect(adapter.configurationStatus.reason == "Microsoft Teams requires appId and appPassword.")
        let probe = await adapter.probe(timeoutMs: 100)
        #expect(probe.ok == false)
    }
}
