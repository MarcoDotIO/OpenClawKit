import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OpenClawChannels
import OpenClawCore
import OpenClawProtocol
import Testing

@Suite("Telegram adapter 2026.9.6 refresh")
struct TelegramAdapterRefreshTests {
    actor MemoryOffsetStore: TelegramUpdateOffsetStore {
        var value: Int64?

        func readLastUpdateID() async -> Int64? {
            self.value
        }

        func writeLastUpdateID(_ updateID: Int64) async {
            self.value = updateID
        }
    }

    static let me = #"{"ok":true,"result":{"id":999,"is_bot":true,"username":"OpenClawBot"}}"#
    static let empty = #"{"ok":true,"result":[]}"#

    static func transport() async -> ScriptedChannelHTTP {
        let http = ScriptedChannelHTTP()
        await http.on("/getMe", json: Self.me)
        await http.on("/deleteWebhook", json: #"{"ok":true,"result":true}"#)
        await http.on("/sendChatAction", json: #"{"ok":true,"result":true}"#)
        return http
    }

    static func adapter(
        _ http: ScriptedChannelHTTP,
        config: TelegramChannelConfig = TelegramChannelConfig(enabled: true, botToken: "123:abc", pollIntervalMs: 250),
        timing: TelegramPollingTiming = TelegramPollingTiming()
    ) -> TelegramChannelAdapter {
        TelegramChannelAdapter(
            config: config,
            transport: http,
            baseURL: URL(string: "https://telegram.example")!,
            offsetStore: MemoryOffsetStore(),
            diagnosticsSink: nil,
            timing: timing
        )
    }

    @Test
    func startClearsWebhookAndLongPolls() async throws {
        let http = await Self.transport()
        await http.on("/getUpdates", json: Self.empty)
        let adapter = Self.adapter(http)
        try await adapter.start()
        try await waitUntil("poll issued") { await http.count("/getUpdates") >= 1 }
        await adapter.stop()

        let webhook = await http.requests("/deleteWebhook")
        #expect(webhook.count == 1)
        #expect(jsonObject(webhook[0].body)["drop_pending_updates"] as? Bool == false)
        let poll = try #require(await http.requests("/getUpdates").first)
        #expect(poll.query?.contains("timeout=25") == true)
        #expect(poll.query?.contains("limit=100") == true)
        #expect(poll.query?.contains("allowed_updates") == true)
        #expect(poll.timeout >= 35)
        let order = await http.records.map(\.path)
        #expect(order.firstIndex { $0.hasSuffix("/getMe") }! < order.firstIndex { $0.hasSuffix("/deleteWebhook") }!)
        #expect(order.firstIndex { $0.hasSuffix("/deleteWebhook") }! < order.firstIndex { $0.hasSuffix("/getUpdates") }!)
    }

    @Test
    func conflictKeepsPollingDegradesHealthAndReclearsWebhook() async throws {
        let http = await Self.transport()
        let conflict = #"{"ok":false,"error_code":409,"description":"Conflict: terminated by other getUpdates request"}"#
        await http.on("/getUpdates", status: 409, json: conflict)
        await http.on("/getUpdates", status: 409, json: conflict)
        await http.on("/getUpdates", json: Self.empty)
        let adapter = Self.adapter(http)
        try await adapter.start()
        try await waitUntil("degraded") { await adapter.transportHealth().state == .degraded }
        let degraded = await adapter.transportHealth()
        #expect(degraded.lastError?.contains("getUpdates conflict") == true)
        #expect(degraded.lastError?.contains(TelegramChannelAdapter.conflictHint) == true)
        try await waitUntil("polling continues past conflicts") { await http.count("/getUpdates") >= 3 }
        try await waitUntil("recovered") { await adapter.transportHealth().state == .healthy }
        #expect(await http.count("/deleteWebhook") >= 2)
        await adapter.stop()
    }

    @Test
    func rateLimitHonorsRetryAfter() async throws {
        let http = await Self.transport()
        await http.on(
            "/getUpdates",
            status: 429,
            json: #"{"ok":false,"error_code":429,"description":"Too Many Requests","parameters":{"retry_after":1}}"#
        )
        await http.on("/getUpdates", json: Self.empty)
        let adapter = Self.adapter(http)
        try await adapter.start()
        try await waitUntil("rate limited") { await adapter.transportHealth().state == .degraded }
        let limitedAt = Date()
        try await waitUntil("retried") { await http.count("/getUpdates") >= 2 }
        #expect(Date().timeIntervalSince(limitedAt) >= 0.8)
        await adapter.stop()
    }

    @Test
    func unauthorizedPollBlocksTransport() async throws {
        let http = await Self.transport()
        await http.on("/getUpdates", status: 401, json: #"{"ok":false,"error_code":401,"description":"Unauthorized"}"#)
        let adapter = Self.adapter(http)
        try await adapter.start()
        try await waitUntil("blocked") { await adapter.transportHealth().state == .blocked }
        #expect(await http.count("/getUpdates") == 1)
        await adapter.stop()
    }

    @Test
    func stallWatchdogRestartsPolling() async throws {
        actor HangingTransport: TelegramHTTPTransport {
            var polls = 0

            func data(for request: URLRequest) async throws -> HTTPResponseData {
                let path = request.url?.path ?? ""
                if path.hasSuffix("/getMe") {
                    return HTTPResponseData(statusCode: 200, headers: [:], body: Data(TelegramAdapterRefreshTests.me.utf8))
                }
                if path.hasSuffix("/getUpdates") {
                    self.polls += 1
                    // Hang like a dead long poll; the watchdog must replace this task.
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                }
                return HTTPResponseData(statusCode: 200, headers: [:], body: Data(#"{"ok":true,"result":true}"#.utf8))
            }

            func pollCount() -> Int {
                self.polls
            }
        }
        let http = HangingTransport()
        var timing = TelegramPollingTiming()
        timing.stallThresholdMs = 150
        timing.watchdogIntervalMs = 50
        let adapter = TelegramChannelAdapter(
            config: TelegramChannelConfig(enabled: true, botToken: "123:abc", pollIntervalMs: 250),
            transport: http,
            baseURL: URL(string: "https://telegram.example")!,
            offsetStore: MemoryOffsetStore(),
            diagnosticsSink: nil,
            timing: timing
        )
        try await adapter.start()
        try await waitUntil("poll restarted") { await http.pollCount() >= 2 }
        await adapter.stop()
    }

    @Test
    func parsesForumTopicsRepliesAndSenderNames() async throws {
        let http = await Self.transport()
        let update = """
        {"ok":true,"result":[{"update_id":5,"message":{"message_id":77,"message_thread_id":12,"is_topic_message":true,
        "text":"what's new?","chat":{"id":-100123,"type":"supergroup","title":"Team","is_forum":true},
        "from":{"id":42,"is_bot":false,"first_name":"Ada","last_name":"Lovelace"},
        "reply_to_message":{"message_id":70,"from":{"id":999,"is_bot":true}}}}]}
        """
        await http.on("/getUpdates", json: update)
        await http.on("/getUpdates", json: Self.empty)
        let collector = ChannelEventCollector()
        let adapter = Self.adapter(http)
        await adapter.setInboundHandler { await collector.append($0) }
        try await adapter.start()
        try await waitUntil("delivered") { await !collector.messages.isEmpty }
        await adapter.stop()

        let message = try #require(await collector.messages.first)
        #expect(message.peerID == "-100123")
        #expect(message.chatType == .group)
        #expect(message.threadID == "12")
        #expect(message.messageID == "77")
        #expect(message.replyToID == "70")
        #expect(message.senderName == "Ada Lovelace")
        #expect(message.implicitMentionKinds.contains(.replyToBot))
        #expect(message.wasMentioned == false)
        #expect(message.metadata["chatTitle"] == "Team")
    }

    @Test
    func botJoinEmitsJoinEvent() async throws {
        let http = await Self.transport()
        let update = """
        {"ok":true,"result":[{"update_id":8,"my_chat_member":{"chat":{"id":-555,"type":"group","title":"New room"},"date":1700000000,
        "old_chat_member":{"status":"left","user":{"id":999,"is_bot":true}},
        "new_chat_member":{"status":"member","user":{"id":999,"is_bot":true}}}}]}
        """
        await http.on("/getUpdates", json: update)
        await http.on("/getUpdates", json: Self.empty)
        let collector = ChannelEventCollector()
        let adapter = Self.adapter(http)
        await adapter.setJoinEventHandler { await collector.appendJoin($0) }
        try await adapter.start()
        try await waitUntil("joined") { await !collector.joins.isEmpty }
        await adapter.stop()
        let join = try #require(await collector.joins.first)
        #expect(join.channel == .telegram)
        #expect(join.peerID == "-555")
        #expect(join.roomName == "New room")
        #expect(join.chatType == .group)
    }

    @Test
    func sendChunksWithReplyThreadPreviewAndSilentFlags() async throws {
        let http = await Self.transport()
        await http.on("/getUpdates", json: Self.empty)
        await http.on("/sendMessage", json: #"{"ok":true,"result":{"message_id":501,"message_thread_id":12}}"#)
        await http.on("/sendMessage", json: #"{"ok":true,"result":{"message_id":502,"message_thread_id":12}}"#)
        var config = TelegramChannelConfig(enabled: true, botToken: "123:abc", pollIntervalMs: 250)
        config.additionalProperties["linkPreview"] = AnyCodable(false)
        let adapter = Self.adapter(http, config: config)
        try await adapter.start()
        let text = String(repeating: "a", count: 3_000) + "\n\n" + String(repeating: "b", count: 3_000)
        let receipt = try await adapter.sendReturningReceipt(
            OutboundMessage(channel: .telegram, peerID: "-100123", text: text, replyToID: "77", threadID: "12", silent: true)
        )
        await adapter.stop()

        #expect(receipt.platformMessageIDs == ["501", "502"])
        let sends = await http.requests("/sendMessage")
        #expect(sends.count == 2)
        let first = jsonObject(sends[0].body)
        let second = jsonObject(sends[1].body)
        #expect((first["reply_parameters"] as? [String: Any])?["message_id"] as? Int == 77)
        #expect(second["reply_parameters"] == nil)
        #expect(first["message_thread_id"] as? Int == 12)
        #expect(second["message_thread_id"] as? Int == 12)
        #expect((first["link_preview_options"] as? [String: Any])?["is_disabled"] as? Bool == true)
        #expect(first["disable_notification"] as? Bool == true)
        #expect((first["text"] as? String)?.count ?? 0 <= TelegramChannelAdapter.textChunkLimit)
    }

    @Test
    func sendRateLimitIsClassifiedWithRetryAfter() async throws {
        let http = await Self.transport()
        await http.on("/getUpdates", json: Self.empty)
        await http.on(
            "/sendMessage",
            status: 429,
            json: #"{"ok":false,"error_code":429,"description":"Too Many Requests","parameters":{"retry_after":7}}"#
        )
        let adapter = Self.adapter(http)
        try await adapter.start()
        await #expect(throws: ChannelSendError.rateLimited(retryAfterMs: 7_000)) {
            try await adapter.send(OutboundMessage(channel: .telegram, peerID: "1", text: "hi"))
        }
        await adapter.stop()
    }

    @Test
    func messageActionsUseBotAPIMethods() async throws {
        let http = await Self.transport()
        await http.on("/getUpdates", json: Self.empty)
        await http.on("/setMessageReaction", json: #"{"ok":true,"result":true}"#)
        await http.on("/editMessageText", json: #"{"ok":true,"result":{"message_id":9}}"#)
        await http.on("/deleteMessage", json: #"{"ok":true,"result":true}"#)
        await http.on("/sendPoll", json: #"{"ok":true,"result":{"message_id":33}}"#)
        let adapter = Self.adapter(http)
        let registry = ChannelRegistry()
        await registry.register(adapter)
        try await adapter.start()

        try await adapter.react(peerID: "10", messageID: "9", emoji: "👍", remove: false)
        try await adapter.react(peerID: "10", messageID: "9", emoji: "👍", remove: true)
        try await adapter.edit(peerID: "10", messageID: "9", text: "edited")
        let poll = try await adapter.sendPoll(peerID: "10", question: "Lunch?", options: ["Yes", "No"], allowMultiple: true)
        _ = try await registry.performAction(
            MessageActionParams(
                channel: "telegram",
                action: "delete",
                params: ["to": AnyCodable("10"), "messageId": AnyCodable("9")],
                idempotencykey: "k1"
            )
        )
        await adapter.stop()

        let reactions = await http.requests("/setMessageReaction")
        #expect((jsonObject(reactions[0].body)["reaction"] as? [[String: Any]])?.first?["emoji"] as? String == "👍")
        #expect((jsonObject(reactions[1].body)["reaction"] as? [Any])?.isEmpty == true)
        #expect(jsonObject(try #require(await http.requests("/editMessageText").first).body)["text"] as? String == "edited")
        #expect(await http.count("/deleteMessage") == 1)
        let pollBody = jsonObject(try #require(await http.requests("/sendPoll").first).body)
        #expect(pollBody["allows_multiple_answers"] as? Bool == true)
        #expect((pollBody["options"] as? [[String: Any]])?.map { $0["text"] as? String } == ["Yes", "No"])
        #expect(poll?.primaryPlatformMessageID == "33")
    }

    @Test
    func probeAndConfigurationStatus() async throws {
        let http = await Self.transport()
        let adapter = Self.adapter(http)
        let probe = await adapter.probe(timeoutMs: 2_000)
        #expect(probe.ok)
        #expect(probe.detail == "@OpenClawBot")
        #expect(adapter.configurationStatus == .configured)

        let unconfigured = Self.adapter(http, config: TelegramChannelConfig(enabled: true))
        #expect(unconfigured.configurationStatus.isConfigured == false)
        let registry = ChannelRegistry()
        await registry.register(unconfigured)
        try await registry.start(id: .telegram)
        let state = await registry.runtimeState(for: .telegram)
        #expect(state.running == false)
        #expect(state.unconfiguredReason?.contains("botToken") == true)
    }

    @Test
    func apiRootNormalizationDropsBotEndpointSegment() {
        #expect(TelegramChannelAdapter.normalizeAPIRoot("https://tg.example/") == "https://tg.example")
        #expect(TelegramChannelAdapter.normalizeAPIRoot("https://tg.example/proxy/bot123:ABC") == "https://tg.example/proxy")
        #expect(TelegramChannelAdapter.normalizeAPIRoot("") == "https://api.telegram.org")
    }
}
