import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OpenClawChannels
import OpenClawCore
import Testing

@Suite("Google Chat adapter refresh (2026.3.0)")
struct GoogleChatAdapterRefreshTests {
    static func adapter(
        http: ScriptedChannelHTTP,
        _ configure: (inout GoogleChatChannelConfig) -> Void = { _ in }
    ) -> GoogleChatChannelAdapter {
        var config = GoogleChatChannelConfig(enabled: true, bearerToken: "gc-token", defaultSpaceID: "spaces/AAA")
        configure(&config)
        return GoogleChatChannelAdapter(config: config, transport: http, baseURL: URL(string: "https://chat.example/v1")!)
    }

    @Test
    func chunksAt32KilobytesOfUTF8AndReturnsMessageNames() async throws {
        let http = ScriptedChannelHTTP()
        await http.on("/spaces/AAA/messages", json: #"{"name":"spaces/AAA/messages/M1"}"#)
        await http.on("/spaces/AAA/messages", json: #"{"name":"spaces/AAA/messages/M2"}"#)
        let adapter = Self.adapter(http: http)
        try await adapter.start()
        // 12,000 three-byte characters = 36,000 bytes: two chunks even though it is only 12,000 chars.
        let longText = String(repeating: "€", count: 12_000)
        let receipt = try await adapter.sendReturningReceipt(OutboundMessage(channel: .googlechat, peerID: "spaces/AAA", text: longText))
        await adapter.stop()

        let requests = await http.requests("/spaces/AAA/messages")
        #expect(requests.count == 2)
        for request in requests {
            let text = jsonObject(request.body)["text"] as? String ?? ""
            #expect(text.utf8.count <= 32_000)
        }
        #expect(receipt.platformMessageIDs == ["spaces/AAA/messages/M1", "spaces/AAA/messages/M2"])
    }

    @Test
    func typingPlaceholderIsReplacedByFirstReplyChunk() async throws {
        let http = ScriptedChannelHTTP()
        await http.on("/spaces/AAA/messages", method: "POST", json: #"{"name":"spaces/AAA/messages/TYPING"}"#)
        await http.on("/spaces/AAA/messages/TYPING", method: "PATCH", json: #"{"name":"spaces/AAA/messages/TYPING"}"#)
        let adapter = Self.adapter(http: http) {
            $0.typingIndicator = .reaction
            $0.policy.name = "Molty"
        }
        #expect(adapter.supportsTypingIndicator)
        try await adapter.start()
        try await adapter.sendTypingIndicator(accountID: nil, peerID: "spaces/AAA")
        try await adapter.sendTypingIndicator(accountID: nil, peerID: "spaces/AAA")
        let receipt = try await adapter.sendReturningReceipt(OutboundMessage(channel: .googlechat, peerID: "spaces/AAA", text: "the answer"))
        try await adapter.stopTypingIndicator(accountID: nil, peerID: "spaces/AAA")
        await adapter.stop()

        let posts = await http.requests("/spaces/AAA/messages", method: "POST")
        #expect(posts.count == 1)
        #expect(jsonObject(posts[0].body)["text"] as? String == "_Molty is typing..._")
        let patch = try #require(await http.requests("/spaces/AAA/messages/TYPING", method: "PATCH").first)
        #expect(patch.query == "updateMask=text")
        #expect(jsonObject(patch.body)["text"] as? String == "the answer")
        #expect(receipt.primaryPlatformMessageID == "spaces/AAA/messages/TYPING")
        #expect(await http.count("/TYPING", method: "DELETE") == 0)
    }

    @Test
    func unusedPlaceholderIsDeletedAndNoneModeDisablesTyping() async throws {
        let http = ScriptedChannelHTTP()
        await http.on("/spaces/AAA/messages", method: "POST", json: #"{"name":"spaces/AAA/messages/T2"}"#)
        await http.on("/spaces/AAA/messages/T2", method: "DELETE", json: "{}")
        let adapter = Self.adapter(http: http)
        try await adapter.start()
        try await adapter.sendTypingIndicator(accountID: nil, peerID: "spaces/AAA")
        try await adapter.stopTypingIndicator(accountID: nil, peerID: "spaces/AAA")
        await adapter.stop()
        #expect(await http.count("/spaces/AAA/messages/T2", method: "DELETE") == 1)

        let silent = Self.adapter(http: ScriptedChannelHTTP()) { $0.typingIndicator = GoogleChatTypingIndicator.none }
        #expect(silent.supportsTypingIndicator == false)
    }

    @Test
    func botSendersNeedAllowBotsAndJoinEventsAreEmitted() async throws {
        let payload = Data((#"{"type":"MESSAGE","space":{"name":"spaces/AAA","spaceType":"SPACE"},"#
            + #""message":{"name":"spaces/AAA/messages/B1","text":"beep","sender":{"name":"users/bot","type":"BOT"}}}"#).utf8)
        let joined = Data(#"{"type":"ADDED_TO_SPACE","space":{"name":"spaces/NEW","spaceType":"SPACE","displayName":"Team"}}"#.utf8)

        let strict = Self.adapter(http: ScriptedChannelHTTP())
        let strictCollector = ChannelEventCollector()
        await strict.setInboundHandler { await strictCollector.append($0) }
        await strict.setJoinEventHandler { await strictCollector.appendJoin($0) }
        try await strict.start()
        try await strict.handleWebhookEvent(payload)
        try await strict.handleWebhookEvent(joined)
        #expect(await strictCollector.messages.isEmpty)
        let join = try #require(await strictCollector.joins.first)
        #expect(join.peerID == "spaces/NEW")
        #expect(join.roomName == "Team")

        let permissive = Self.adapter(http: ScriptedChannelHTTP()) { $0.policy.allowBots = .enabled }
        let collector = ChannelEventCollector()
        await permissive.setInboundHandler { await collector.append($0) }
        try await permissive.start()
        try await permissive.handleWebhookEvent(payload)
        let message = try #require(await collector.messages.first)
        #expect(message.isFromBot)
        #expect(message.chatType == .group)
    }

    @Test
    func missingBearerTokenReportsUnconfigured() {
        let adapter = Self.adapter(http: ScriptedChannelHTTP()) { $0.bearerToken = nil }
        #expect(adapter.configurationStatus.isConfigured == false)
    }
}
