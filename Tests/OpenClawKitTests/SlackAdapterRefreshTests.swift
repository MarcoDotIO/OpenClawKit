import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OpenClawChannels
import OpenClawCore
import Testing

@Suite("Slack adapter 2026.9.6 refresh", .timeLimit(.minutes(1)))
struct SlackAdapterRefreshTests {
    static let auth = #"{"ok":true,"user_id":"UBOT","bot_id":"B1","user":"claw","team":"acme"}"#

    static func transport() async -> ScriptedChannelHTTP {
        let http = ScriptedChannelHTTP(fallback: HTTPResponseData(statusCode: 200, headers: [:], body: Data(#"{"ok":true}"#.utf8)))
        await http.on("/auth.test", json: Self.auth)
        await http.on("/apps.connections.open", json: #"{"ok":true,"url":"wss://wss.slack.example/link"}"#)
        await http.on("/chat.postMessage", json: #"{"ok":true,"ts":"1700.0001"}"#)
        return http
    }

    static func config(_ configure: (inout SlackChannelConfig) -> Void = { _ in }) -> SlackChannelConfig {
        var config = SlackChannelConfig(enabled: true, botToken: "xoxb-1", appToken: "xapp-1", signingSecret: "8f742231b10e8888abcd99yyyzzz85a5")
        configure(&config)
        return config
    }

    static func adapter(
        _ http: ScriptedChannelHTTP,
        config: SlackChannelConfig = SlackAdapterRefreshTests.config(),
        sockets: [FakeWebSocket] = [],
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> (SlackChannelAdapter, FakeWebSocketConnector) {
        let connector = FakeWebSocketConnector(sockets)
        let adapter = SlackChannelAdapter(
            config: config,
            transport: http,
            baseURL: URL(string: "https://slack.example/api")!,
            pollIntervalMs: 250,
            webSocketConnector: connector,
            now: now
        )
        return (adapter, connector)
    }

    static func envelope(_ id: String, event: String) -> String {
        #"{"envelope_id":"\#(id)","type":"events_api","payload":{"type":"event_callback","event_id":"Ev\#(id)","event":\#(event)}}"#
    }

    @Test
    func signatureMatchesSlackDocumentationVector() {
        let body = Data(
            // swiftlint:disable:next line_length
            "token=xyzz0WbapA4vBCDEFasx0q6G&team_id=T1DC2JH3J&team_domain=testteamnow&channel_id=G8PSS9T3V&channel_name=foobar&user_id=U2CERLKJA&user_name=roadrunner&command=%2Fwebhook-collect&text=&response_url=https%3A%2F%2Fhooks.slack.com%2Fcommands%2FT1DC2JH3J%2F397700885554%2F96rGlfmibIGlgcZRskXaIFfN&trigger_id=398738663015.47445629121.803a0bc887a14d10d2c447fce8b6703c".utf8
        )
        let signature = ChannelWebhookSignature.slackSignature(
            signingSecret: "8f742231b10e8888abcd99yyyzzz85a5",
            timestamp: "1531420618",
            body: body
        )
        #expect(signature == "v0=a2114d57b48eac39b9ad189dd8316235a7b4a8d21a10bd27519666489c69b503")
    }

    @Test
    func httpEventsVerifySignatureChallengeAndSkew() async throws {
        let http = await Self.transport()
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let (adapter, _) = Self.adapter(http, config: Self.config { $0.mode = .http }, now: { fixedNow })
        let collector = ChannelEventCollector()
        await adapter.setInboundHandler { await collector.append($0) }
        try await adapter.start()
        let secret = "8f742231b10e8888abcd99yyyzzz85a5"
        func signed(_ body: String, timestamp: String = "1700000000") -> [String: String] {
            [
                "X-Slack-Request-Timestamp": timestamp,
                "X-Slack-Signature": ChannelWebhookSignature.slackSignature(signingSecret: secret, timestamp: timestamp, body: Data(body.utf8)),
            ]
        }
        let challenge = #"{"type":"url_verification","challenge":"abc123"}"#
        let verified = await adapter.handleEventsWebhook(headers: signed(challenge), body: Data(challenge.utf8))
        #expect(verified.status == 200)
        #expect(verified.body == "abc123")

        var tampered = signed(challenge)
        tampered["X-Slack-Signature"] = "v0=deadbeef"
        #expect(await adapter.handleEventsWebhook(headers: tampered, body: Data(challenge.utf8)).status == 401)
        #expect(await adapter.handleEventsWebhook(headers: signed(challenge, timestamp: "1699999000"), body: Data(challenge.utf8)).status == 401)

        let event = #"{"type":"event_callback","event_id":"Ev1","event":"#
            + #"{"type":"message","channel":"D1","channel_type":"im","user":"U1","text":"hello","ts":"1.1"}}"#
        #expect(await adapter.handleEventsWebhook(headers: signed(event), body: Data(event.utf8)).status == 200)
        try await waitUntil("dm delivered") { await !collector.messages.isEmpty }
        await adapter.stop()
        #expect(await collector.messages.first?.chatType == .direct)
    }

    @Test
    func socketModeAcksEnvelopesAndMapsChannelTypes() async throws {
        let socket = FakeWebSocket(frames: [#"{"type":"hello"}"#])
        let http = await Self.transport()
        let (adapter, connector) = Self.adapter(http, sockets: [socket])
        let collector = ChannelEventCollector()
        await adapter.setInboundHandler { await collector.append($0) }
        try await adapter.start()
        await socket.feed(Self.envelope("1", event: #"{"type":"message","channel":"D1","channel_type":"im","user":"U1","text":"dm","ts":"1.0"}"#))
        await socket.feed(Self.envelope("2", event: #"{"type":"message","channel":"G1","channel_type":"mpim","user":"U1","text":"mpim","ts":"2.0"}"#))
        await socket.feed(
            Self.envelope("3", event: #"{"type":"app_mention","channel":"C1","user":"U1","text":"<@UBOT> hi","ts":"3.0","thread_ts":"2.5"}"#)
        )
        await socket.feed(
            Self.envelope("4", event: #"{"type":"message","channel":"C1","channel_type":"channel","user":"U1","text":"<@UBOT> hi","ts":"3.0"}"#)
        )
        await socket.feed(Self.envelope("5", event: #"{"type":"message","channel":"C1","channel_type":"channel","user":"U1","text":"ambient","ts":"4.0"}"#))
        try await waitUntil("acks") { await socket.sentFrames().count >= 5 }
        try await waitUntil("delivered") { await collector.messages.count == 2 }
        await adapter.stop()

        let acks = await socket.sentFrames().map { jsonObject($0)["envelope_id"] as? String }
        #expect(acks == ["1", "2", "3", "4", "5"])
        let messages = await collector.messages
        #expect(messages[0].chatType == .direct)
        // mpim needs dm.groupEnabled; the duplicate message event for the mention is deduped;
        // "ambient" lacks a mention and channels require one by default.
        #expect(messages[1].peerID == "C1")
        #expect(messages[1].threadID == "2.5")
        #expect(messages[1].chatType == .thread)
        #expect(messages[1].text == "hi")
        #expect(await connector.requests.first?.url?.host == "wss.slack.example")
        let open = try #require(await http.requests("/apps.connections.open").first)
        #expect(open.headers["Authorization"] == "Bearer xapp-1")
    }

    @Test
    func ignoreOtherMentionsAndChannelOverrides() async throws {
        let socket = FakeWebSocket(frames: [])
        let http = await Self.transport()
        let config = Self.config { config in
            config.mentionOnly = false
            config.ignoreOtherMentions = true
            config.channels = ["C-off": ChannelRoomOverrideConfig(enabled: false)]
            config.dm = ChannelDirectMessageConfig(groupEnabled: true)
        }
        let (adapter, _) = Self.adapter(http, config: config, sockets: [socket])
        let collector = ChannelEventCollector()
        await adapter.setInboundHandler { await collector.append($0) }
        try await adapter.start()
        await socket.feed(Self.envelope("1", event: #"{"type":"message","channel":"C1","user":"U1","text":"<@U999> for you","ts":"1.0"}"#))
        await socket.feed(Self.envelope("2", event: #"{"type":"message","channel":"C-off","user":"U1","text":"<@UBOT> x","ts":"2.0"}"#))
        await socket.feed(Self.envelope("3", event: #"{"type":"message","channel":"G1","channel_type":"mpim","user":"U1","text":"group","ts":"3.0"}"#))
        try await waitUntil("delivered") { await collector.messages.count == 1 }
        try await waitUntil("acked") { await socket.sentFrames().count == 3 }
        await adapter.stop()
        #expect(await collector.messages.first?.chatType == .group)
    }

    @Test
    func authErrorsBlockSocketMode() async throws {
        let http = await Self.transport()
        let blocked = ScriptedChannelHTTP()
        await blocked.on("/auth.test", json: Self.auth)
        await blocked.on("/apps.connections.open", json: #"{"ok":false,"error":"invalid_auth"}"#)
        let (adapter, _) = Self.adapter(blocked)
        await #expect(throws: OpenClawCoreError.self) {
            try await adapter.start()
        }
        _ = http
    }

    @Test
    func typingUsesAssistantStatusAndReactionNeverChatTyping() async throws {
        let socket = FakeWebSocket(frames: [])
        let http = await Self.transport()
        let (adapter, _) = Self.adapter(http, config: Self.config { $0.typingReaction = "hourglass_flowing_sand" }, sockets: [socket])
        let collector = ChannelEventCollector()
        await adapter.setInboundHandler { await collector.append($0) }
        try await adapter.start()
        await socket.feed(Self.envelope("1", event: #"{"type":"app_mention","channel":"C1","user":"U1","text":"<@UBOT> go","ts":"5.0"}"#))
        try await waitUntil("delivered") { await !collector.messages.isEmpty }
        try await adapter.sendTypingIndicator(accountID: nil, peerID: "C1")
        try await adapter.sendTypingIndicator(accountID: nil, peerID: "C1")
        try await adapter.stopTypingIndicator(accountID: nil, peerID: "C1")
        await adapter.stop()

        #expect(await http.count("/chat.typing") == 0)
        let statuses = await http.requests("/agents.sessions.setStatus").map { jsonObject($0.body) }
        #expect(statuses.map { $0["status"] as? String } == ["processing", "active"])
        #expect(statuses.first?["thread_ts"] as? String == "5.0")
        #expect(statuses.first?["channel_id"] as? String == "C1")
        #expect(await http.count("/reactions.add") == 1)
        let removed = jsonObject(try #require(await http.requests("/reactions.remove").first).body)
        #expect(removed["name"] as? String == "hourglass_flowing_sand")
        #expect(removed["timestamp"] as? String == "5.0")
    }

    @Test
    func outboundThreadingUnfurlAndReceipts() async throws {
        let http = await Self.transport()
        let config = Self.config { config in
            config.replyToModeByChatType = ChannelReplyToModeByChatType(channel: .first)
            config.unfurlMedia = false
        }
        let (adapter, _) = Self.adapter(http, config: config, sockets: [FakeWebSocket(frames: [])])
        try await adapter.start()
        let receipt = try await adapter.sendReturningReceipt(
            OutboundMessage(channel: .slack, peerID: "C1", text: "answer", replyToID: "9.0", chatType: .channel)
        )
        _ = try await adapter.sendReturningReceipt(OutboundMessage(channel: .slack, peerID: "D1", text: "dm", replyToID: "8.0", chatType: .direct))
        _ = try await adapter.sendReturningReceipt(OutboundMessage(channel: .slack, peerID: "C1", text: "in thread", threadID: "7.0"))
        await adapter.stop()

        let posts = await http.requests("/chat.postMessage").map { jsonObject($0.body) }
        #expect(posts[0]["thread_ts"] as? String == "9.0")
        #expect(posts[0]["unfurl_links"] as? Bool == false)
        #expect(posts[0]["unfurl_media"] as? Bool == false)
        #expect(posts[1]["thread_ts"] == nil)
        #expect(posts[2]["thread_ts"] as? String == "7.0")
        #expect(receipt.primaryPlatformMessageID == "1700.0001")
    }

    @Test
    func messageActionsMapToWebAPI() async throws {
        let http = await Self.transport()
        let (adapter, _) = Self.adapter(http, sockets: [FakeWebSocket(frames: [])])
        try await adapter.start()
        try await adapter.react(peerID: "C1", messageID: "1.0", emoji: "👀", remove: false)
        try await adapter.react(peerID: "C1", messageID: "1.0", emoji: ":tada:", remove: true)
        try await adapter.edit(peerID: "C1", messageID: "1.0", text: "new")
        try await adapter.unsend(peerID: "C1", messageID: "1.0")
        await adapter.stop()
        #expect(jsonObject(try #require(await http.requests("/reactions.add").first).body)["name"] as? String == "eyes")
        #expect(jsonObject(try #require(await http.requests("/reactions.remove").first).body)["name"] as? String == "tada")
        #expect(jsonObject(try #require(await http.requests("/chat.update").first).body)["ts"] as? String == "1.0")
        #expect(await http.count("/chat.delete") == 1)
    }

    @Test
    func rateLimitedPostHonorsRetryAfter() async throws {
        let http = ScriptedChannelHTTP()
        await http.on("/auth.test", json: Self.auth)
        await http.on("/apps.connections.open", json: #"{"ok":true,"url":"wss://wss.slack.example/link"}"#)
        await http.on("/chat.postMessage", status: 429, json: #"{"ok":false,"error":"ratelimited"}"#, headers: ["Retry-After": "3"])
        let (adapter, _) = Self.adapter(http, sockets: [FakeWebSocket(frames: [])])
        try await adapter.start()
        await #expect(throws: ChannelSendError.rateLimited(retryAfterMs: 3_000)) {
            try await adapter.send(OutboundMessage(channel: .slack, peerID: "C1", text: "x"))
        }
        await adapter.stop()
    }

    @Test
    func relayRequestRulesAndFrames() async throws {
        #expect(throws: OpenClawCoreError.self) {
            try SlackChannelAdapter.relayRequest(config: SlackRelayConfig(url: "ws://relay.example/slack", authToken: "t", gatewayID: "g"))
        }
        #expect(throws: OpenClawCoreError.self) {
            try SlackChannelAdapter.relayRequest(config: SlackRelayConfig(url: "https://relay.example/", authToken: "t", gatewayID: "g"))
        }
        let local = try SlackChannelAdapter.relayRequest(config: SlackRelayConfig(url: "ws://127.0.0.1:9000/slack", authToken: "t", gatewayID: "g"))
        #expect(local.url?.scheme == "ws")
        let remote = try SlackChannelAdapter.relayRequest(config: SlackRelayConfig(url: "https://relay.example/slack", authToken: "tok", gatewayID: "gw-1"))
        #expect(remote.url?.absoluteString == "wss://relay.example/slack?gateway_id=gw-1")
        #expect(remote.value(forHTTPHeaderField: "Authorization") == "Bearer tok")

        let socket = FakeWebSocket(frames: [#"{"type":"hello","slack_identity":{"username":"Claw","icon_emoji":":robot_face:"}}"#])
        let http = await Self.transport()
        let config = Self.config { config in
            config.mode = .relay
            config.relay = SlackRelayConfig(url: "https://relay.example/slack", authToken: "tok", gatewayID: "gw-1")
        }
        let (adapter, _) = Self.adapter(http, config: config, sockets: [socket])
        let collector = ChannelEventCollector()
        await adapter.setInboundHandler { await collector.append($0) }
        try await adapter.start()
        let event = #"{"type":"message","channel":"D1","channel_type":"im","user":"U1","text":"via relay","ts":"1.0"}"#
        await socket.feed(#"{"type":"slack_event","delivery_id":"d-1","route":{"kind":"channel_default","key":"D1"},"payload":{"event":\#(event)}}"#)
        await socket.feed(#"{"type":"slack_event","delivery_id":"d-1","route":{"kind":"channel_default","key":"D1"},"payload":{"event":\#(event)}}"#)
        try await waitUntil("acked twice") { await socket.sentFrames().count == 2 }
        _ = try await adapter.sendReturningReceipt(OutboundMessage(channel: .slack, peerID: "D1", text: "reply"))
        await adapter.stop()
        #expect(await collector.messages.count == 1)
        #expect(await socket.sentFrames().allSatisfy { jsonObject($0)["type"] as? String == "ack" })
        let post = jsonObject(try #require(await http.requests("/chat.postMessage").first).body)
        #expect(post["username"] as? String == "Claw")
        #expect(post["icon_emoji"] as? String == ":robot_face:")
    }

    @Test
    func botJoinEmitsJoinEventAndProbeUsesAuthTest() async throws {
        let socket = FakeWebSocket(frames: [])
        let http = await Self.transport()
        let (adapter, _) = Self.adapter(http, sockets: [socket])
        let collector = ChannelEventCollector()
        await adapter.setJoinEventHandler { await collector.appendJoin($0) }
        try await adapter.start()
        await socket.feed(Self.envelope("j", event: #"{"type":"member_joined_channel","user":"UBOT","channel":"C77"}"#))
        try await waitUntil("joined") { await !collector.joins.isEmpty }
        let probe = await adapter.probe(timeoutMs: 1_000)
        await adapter.stop()
        #expect(await collector.joins.first?.peerID == "C77")
        #expect(probe.ok)
        #expect(probe.detail == "claw @ acme")
    }

    @Test
    func socketModeWithoutAppTokenFallsBackToPolling() {
        let adapter = SlackChannelAdapter(config: SlackChannelConfig(enabled: true, botToken: "xoxb", defaultChannelID: "C1"))
        #expect(adapter.effectiveMode == .poll)
        let http = SlackChannelAdapter(config: SlackChannelConfig(enabled: true, botToken: "xoxb", mode: .http))
        #expect(http.configurationStatus.reason == "Slack HTTP mode requires signingSecret.")
    }
}
