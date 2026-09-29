import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OpenClawChannels
import OpenClawCore
import Testing

@Suite("LINE channel adapter")
struct LineChannelAdapterTests {
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_800_000_000)

        func now() -> Date {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.value
        }

        func advance(_ seconds: TimeInterval) {
            self.lock.lock()
            self.value = self.value.addingTimeInterval(seconds)
            self.lock.unlock()
        }
    }

    static let secret = "line-secret"

    static func config() -> LineChannelConfig {
        var config = LineChannelConfig(enabled: true)
        config.channelAccessToken = "line-token"
        config.channelSecret = Self.secret
        return config
    }

    static func signed(_ json: String) -> (headers: [String: String], body: Data) {
        let body = Data(json.utf8)
        return (["X-Line-Signature": ChannelWebhookSignature.lineSignature(channelSecret: Self.secret, body: body)], body)
    }

    @Test
    func signatureMatchesKnownVector() {
        // base64(HMAC-SHA256(secret, body)) computed independently with Python's hmac module.
        #expect(ChannelWebhookSignature.lineSignature(channelSecret: "line-secret", body: Data("{}".utf8)) == "hBcw8zWjhUK8A2tp/CjHF/+hHTMcYtYsx1Hz7OrIrBI=")
        let body = Data(#"{"destination":"U123","events":[]}"#.utf8)
        #expect(ChannelWebhookSignature.lineSignature(channelSecret: "8f4c1b1e", body: body) == "4tEGhJKkMtswN7AKDxpMlKU81Mcqr5990+ZOqUSsQoo=")
    }

    @Test
    func webhookVerifiesSignatureAndMapsUserGroupAndJoinEvents() async throws {
        let adapter = LineChannelAdapter(config: Self.config(), transport: ScriptedChannelHTTP())
        let collector = ChannelEventCollector()
        await adapter.setInboundHandler { await collector.append($0) }
        await adapter.setJoinEventHandler { await collector.appendJoin($0) }
        try await adapter.start()

        let bad = await adapter.handleWebhook(headers: ["X-Line-Signature": "bogus"], body: Data(#"{"events":[]}"#.utf8))
        #expect(bad.status == 401)

        let json = #"{"events":["#
            + #"{"type":"message","webhookEventId":"e1","replyToken":"r1","source":{"type":"user","userId":"U1"},"#
            + #""message":{"type":"text","id":"m1","text":"hello"}},"#
            + #"{"type":"message","webhookEventId":"e2","replyToken":"r2","source":{"type":"group","groupId":"C9","userId":"U2"},"#
            + #""message":{"type":"text","id":"m2","text":"@bot hi","mention":{"mentionees":[{"index":0,"length":4,"isSelf":true}]}}},"#
            + #"{"type":"join","webhookEventId":"e3","replyToken":"r3","source":{"type":"group","groupId":"C10"}},"#
            + #"{"type":"message","webhookEventId":"e1","source":{"type":"user","userId":"U1"},"message":{"type":"text","id":"m1","text":"hello"}}"#
            + #"]}"#
        let request = Self.signed(json)
        let response = await adapter.handleWebhook(headers: request.headers, body: request.body)
        await adapter.stop()

        #expect(response.status == 200)
        let messages = await collector.messages
        #expect(messages.count == 2)
        #expect(messages[0].peerID == "U1")
        #expect(messages[0].chatType == .direct)
        #expect(messages[0].senderID == "U1")
        #expect(messages[1].peerID == "C9")
        #expect(messages[1].chatType == .group)
        #expect(messages[1].senderID == "U2")
        #expect(messages[1].wasMentioned == true)
        #expect(await collector.joins.first?.peerID == "C10")
    }

    @Test
    func repliesWithFreshTokenThenFallsBackToPushWithRetryKey() async throws {
        let http = ScriptedChannelHTTP()
        await http.on("/message/reply", json: #"{"sentMessages":[{"id":"s1"}]}"#)
        await http.on("/message/push", json: #"{"sentMessages":[{"id":"p1"}]}"#)
        let clock = Clock()
        let adapter = LineChannelAdapter(config: Self.config(), transport: http, now: { clock.now() })
        try await adapter.start()
        let event = Self.signed(
            #"{"events":[{"type":"message","replyToken":"tok","source":{"type":"user","userId":"U1"},"message":{"type":"text","id":"m","text":"q"}}]}"#
        )
        _ = await adapter.handleWebhook(headers: event.headers, body: event.body)

        let replied = try await adapter.sendReturningReceipt(OutboundMessage(channel: .line, peerID: "U1", text: "first"))
        #expect(replied.primaryPlatformMessageID == "s1")
        let reply = try #require(await http.requests("/message/reply").first)
        #expect(jsonObject(reply.body)["replyToken"] as? String == "tok")
        #expect(reply.headers["Authorization"] == "Bearer line-token")

        let pushed = try await adapter.sendReturningReceipt(OutboundMessage(channel: .line, peerID: "U1", text: "second"))
        #expect(pushed.primaryPlatformMessageID == "p1")
        let push = try #require(await http.requests("/message/push").first)
        #expect(jsonObject(push.body)["to"] as? String == "U1")
        #expect(push.headers["X-Line-Retry-Key"]?.isEmpty == false)

        _ = await adapter.handleWebhook(headers: event.headers, body: event.body)
        clock.advance(LineChannelAdapter.replyTokenTTL + 1)
        _ = try await adapter.sendReturningReceipt(OutboundMessage(channel: .line, peerID: "U1", text: "stale"))
        #expect(await http.count("/message/reply") == 1)
        #expect(await http.count("/message/push") == 2)
        await adapter.stop()
    }

    @Test
    func chunksAt5000AndBatchesFiveMessagesPerRequest() async throws {
        let http = ScriptedChannelHTTP()
        await http.on("/message/push", json: #"{"sentMessages":[{"id":"a"},{"id":"b"},{"id":"c"},{"id":"d"},{"id":"e"}]}"#)
        let adapter = LineChannelAdapter(config: Self.config(), transport: http)
        try await adapter.start()
        let text = (0..<6).map { _ in String(repeating: "x", count: 4_999) }.joined(separator: "\n\n")
        _ = try await adapter.send(OutboundMessage(channel: .line, peerID: "C1", text: text))
        await adapter.stop()
        let pushes = await http.requests("/message/push")
        #expect(pushes.count == 2)
        let first = jsonObject(pushes[0].body)["messages"] as? [[String: Any]] ?? []
        #expect(first.count == 5)
        #expect(first.allSatisfy { ($0["text"] as? String ?? "").count <= 5_000 })
    }

    @Test
    func retriedPushConflictCountsAsDeliveredAndTypingOnlyForUsers() async throws {
        let http = ScriptedChannelHTTP()
        await http.on("/message/push", status: 409, json: #"{"message":"The retry key is already accepted","sentMessages":[{"id":"dup"}]}"#)
        await http.on("/chat/loading/start", json: "{}")
        let adapter = LineChannelAdapter(config: Self.config(), transport: http)
        try await adapter.start()
        let receipt = try await adapter.sendReturningReceipt(OutboundMessage(channel: .line, peerID: "U1", text: "hi"))
        #expect(receipt.primaryPlatformMessageID == "dup")
        try await adapter.sendTypingIndicator(accountID: nil, peerID: "U1")
        try await adapter.sendTypingIndicator(accountID: nil, peerID: "C1")
        await adapter.stop()
        let loading = await http.requests("/chat/loading/start")
        #expect(loading.count == 1)
        #expect(jsonObject(loading[0].body)["chatId"] as? String == "U1")
    }

    @Test
    func unconfiguredWithoutCredentialsAndPolicyDefaults() {
        let adapter = LineChannelAdapter(config: LineChannelConfig(enabled: true))
        #expect(adapter.configurationStatus.reason == LineChannelConfig.unconfiguredReason)
        var channels = ChannelsConfig()
        channels.line = Self.config()
        let policy = channels.messagingPolicy(for: "line")
        #expect(policy.dmPolicy == .pairing)
        #expect(policy.groupPolicy == .allowlist)
        #expect(adapter.webhookPath == "/line/webhook")
    }
}
