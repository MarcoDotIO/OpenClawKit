import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OpenClawChannels
import OpenClawCore
import OpenClawProtocol
import Testing

@Suite("Signal adapter 2026.9.6 refresh", .timeLimit(.minutes(1)))
struct SignalAdapterRefreshTests {
    struct ScriptedLines: ChannelLineStreaming {
        let lines: [String]

        func lines(for _: URLRequest) async throws -> AsyncThrowingStream<String, Error> {
            let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
            for line in self.lines {
                continuation.yield(line)
            }
            // Keep the stream open like a live SSE connection.
            return stream
        }
    }

    static func config(_ configure: (inout SignalChannelConfig) -> Void = { _ in }) -> SignalChannelConfig {
        var config = SignalChannelConfig(enabled: true, serviceURL: "http://signal.example:8080", accountID: "+15550000001")
        configure(&config)
        return config
    }

    static func transport() async -> ScriptedChannelHTTP {
        let http = ScriptedChannelHTTP(fallback: HTTPResponseData(statusCode: 204, headers: [:], body: Data()))
        await http.on("/v2/send", status: 201, json: #"{"timestamp":1700000000123}"#)
        await http.on("/v1/about", json: #"{"versions":["v1","v2"]}"#)
        return http
    }

    static func groupFrame(text: String, timestamp: Int, source: String = "+15550000002", mentionUUID: String? = nil) -> String {
        let mentions = mentionUUID.map { #","mentions":[{"uuid":"\#($0)","start":0,"length":1}]"# } ?? ""
        return """
        {"envelope":{"source":"\(source)","sourceNumber":"\(source)","sourceUuid":"uuid-\(source)","sourceName":"Ada","timestamp":\(timestamp),
        "dataMessage":{"timestamp":\(timestamp),"message":"\(text)","groupInfo":{"groupId":"R0lE","groupName":"Team"}\(mentions)}},
        "account":"+15550000001"}
        """
    }

    @Test
    func containerReceivesOverWebSocketWithGroupPeers() async throws {
        let socket = FakeWebSocket(frames: [])
        let connector = FakeWebSocketConnector([socket])
        let http = await Self.transport()
        let adapter = SignalChannelAdapter(
            config: Self.config { $0.accountUUID = "uuid-self" },
            transport: http,
            webSocketConnector: connector
        )
        let collector = ChannelEventCollector()
        await adapter.setInboundHandler { await collector.append($0) }
        try await adapter.start()
        await socket.feed(Self.groupFrame(text: "hello team", timestamp: 10, mentionUUID: "uuid-self"))
        await socket.feed(Self.groupFrame(text: "echo", timestamp: 11, source: "+15550000001"))
        try await waitUntil("delivered") { await !collector.messages.isEmpty }
        let url = await connector.requests.first?.url?.absoluteString
        await adapter.stop()

        #expect(url == "ws://signal.example:8080/v1/receive/%2B15550000001")
        let messages = await collector.messages
        #expect(messages.count == 1)
        #expect(messages[0].peerID == "group:R0lE")
        #expect(messages[0].chatType == .group)
        #expect(messages[0].senderID == "+15550000002")
        #expect(messages[0].senderName == "Ada")
        #expect(messages[0].wasMentioned == true)
        #expect(messages[0].messageID == "10")
        #expect(await adapter.isUsingPollingFallback() == false)
    }

    @Test
    func typingUsesPutAndDeleteAndGroupRecipientFormat() async throws {
        let http = await Self.transport()
        let adapter = SignalChannelAdapter(config: Self.config(), transport: http, webSocketConnector: FakeWebSocketConnector([FakeWebSocket(frames: [])]))
        try await adapter.start()
        try await adapter.sendTypingIndicator(accountID: nil, peerID: "+15550000002")
        try await adapter.stopTypingIndicator(accountID: nil, peerID: "group:R0lE")
        await adapter.stop()

        let put = try #require(await http.requests("/v1/typing-indicator/+15550000001", method: "PUT").first)
        #expect(jsonObject(put.body)["recipient"] as? String == "+15550000002")
        let delete = try #require(await http.requests("/v1/typing-indicator/+15550000001", method: "DELETE").first)
        #expect(jsonObject(delete.body)["recipient"] as? String == "group." + Data("R0lE".utf8).base64EncodedString())
    }

    @Test
    func sendIncludesAttachmentsQuoteAndReturnsTimestampReceipt() async throws {
        let socket = FakeWebSocket(frames: [])
        let http = await Self.transport()
        let adapter = SignalChannelAdapter(
            config: Self.config { $0.sendReadReceipts = true },
            transport: http,
            webSocketConnector: FakeWebSocketConnector([socket])
        )
        let collector = ChannelEventCollector()
        await adapter.setInboundHandler { await collector.append($0) }
        try await adapter.start()
        await socket.feed(#"{"envelope":{"sourceNumber":"+15550000002","timestamp":42,"dataMessage":{"timestamp":42,"message":"question?"}}}"#)
        try await waitUntil("delivered") { await !collector.messages.isEmpty }
        let attachment = MediaAttachment(mimeType: "image/png", data: Data([1, 2, 3]), fileName: "a,b;c#.png")
        let receipt = try await adapter.sendReturningReceipt(
            OutboundMessage(channel: .signal, peerID: "+15550000002", text: "answer", attachments: [attachment], replyToID: "42")
        )
        await adapter.stop()

        #expect(receipt.primaryPlatformMessageID == "1700000000123")
        let body = jsonObject(try #require(await http.requests("/v2/send").first).body)
        #expect(body["number"] as? String == "+15550000001")
        #expect(body["quote_timestamp"] as? Int == 42)
        #expect(body["quote_author"] as? String == "+15550000002")
        let encoded = try #require((body["base64_attachments"] as? [String])?.first)
        #expect(encoded == "data:image/png;filename=a_b_c_.png;base64,AQID")
        let receiptBody = jsonObject(try #require(await http.requests("/v1/receipts/+15550000001").first).body)
        #expect(receiptBody["timestamp"] as? Int == 42)
        #expect(receiptBody["receipt_type"] as? String == "read")
    }

    @Test
    func attachmentBudgetIsEnforced() async throws {
        let http = await Self.transport()
        var policy = ChannelMessagingPolicyConfig()
        policy.mediaMaxMb = 0.000_001
        let adapter = SignalChannelAdapter(
            config: Self.config { $0.policy = policy },
            transport: http,
            webSocketConnector: FakeWebSocketConnector([FakeWebSocket(frames: [])])
        )
        try await adapter.start()
        let big = MediaAttachment(mimeType: "application/octet-stream", data: Data(repeating: 0, count: 64))
        await #expect(throws: ChannelSendError.self) {
            try await adapter.send(OutboundMessage(channel: .signal, peerID: "+15550000002", text: "", attachments: [big]))
        }
        await adapter.stop()
    }

    @Test
    func reactionsPostToReactionsEndpoint() async throws {
        let http = await Self.transport()
        let adapter = SignalChannelAdapter(config: Self.config(), transport: http, webSocketConnector: FakeWebSocketConnector([FakeWebSocket(frames: [])]))
        try await adapter.start()
        try await adapter.react(peerID: "+15550000002", messageID: "99", emoji: "👍", remove: false)
        try await adapter.react(peerID: "+15550000002", messageID: "99", emoji: "👍", remove: true)
        await adapter.stop()
        let add = jsonObject(try #require(await http.requests("/v1/reactions/+15550000001", method: "POST").first).body)
        #expect(add["reaction"] as? String == "👍")
        #expect(add["target_author"] as? String == "+15550000002")
        #expect(add["timestamp"] as? Int == 99)
        #expect(await http.count("/v1/reactions/+15550000001", method: "DELETE") == 1)
    }

    @Test
    func externalNativeUsesJSONRPCAndSSE() async throws {
        let http = ScriptedChannelHTTP()
        await http.on("/api/v1/rpc", json: #"{"jsonrpc":"2.0","result":{"timestamp":555},"id":"1"}"#)
        await http.on("/api/v1/check", json: "{}")
        let event = #"{"envelope":{"sourceNumber":"+15550000003","timestamp":77,"dataMessage":{"timestamp":77,"message":"via sse"}},"account":"+15550000001"}"#
        let adapter = SignalChannelAdapter(
            config: Self.config { $0.transport = SignalTransportConfig(kind: .externalNative, url: "http://127.0.0.1:8080") },
            transport: http,
            serviceURL: URL(string: "http://127.0.0.1:8080")!,
            lineStreamer: ScriptedLines(lines: [": keepalive", "event: receive", "data: \(event)", ""])
        )
        let collector = ChannelEventCollector()
        await adapter.setInboundHandler { await collector.append($0) }
        try await adapter.start()
        try await waitUntil("sse delivered") { await !collector.messages.isEmpty }
        let receipt = try await adapter.sendReturningReceipt(OutboundMessage(channel: .signal, peerID: "group:R0lE", text: "hi group"))
        try await adapter.sendTypingIndicator(accountID: nil, peerID: "+15550000003")
        let probe = await adapter.probe(timeoutMs: 1_000)
        await adapter.stop()

        #expect(await collector.messages.first?.text == "via sse")
        #expect(receipt.primaryPlatformMessageID == "555")
        let calls = await http.requests("/api/v1/rpc").map { jsonObject($0.body) }
        #expect(calls.map { $0["method"] as? String } == ["send", "sendTyping"])
        #expect((calls[0]["params"] as? [String: Any])?["groupId"] as? String == "R0lE")
        #expect(((calls[1]["params"] as? [String: Any])?["recipient"] as? [String]) == ["+15550000003"])
        #expect(probe.ok)
    }

    @Test
    func managedNativeIsUnsupportedWithHint() async throws {
        let adapter = SignalChannelAdapter(config: Self.config { $0.transport = SignalTransportConfig(kind: .managedNative) })
        #expect(adapter.configurationStatus.reason?.contains("external-native") == true)
        await #expect(throws: OpenClawCoreError.self) {
            try await adapter.start()
        }
    }

    @Test
    func decodesUpstreamSignalTransportAndAccountKeys() throws {
        let json = """
        {"account":"+15551234567","accountUuid":"abc","transport":{"kind":"container","url":"http://c:8080"},
         "sendReadReceipts":true,"groups":{"*":{"requireMention":true}},"replyToModeByChatType":{"group":"first"}}
        """
        let config = try JSONDecoder().decode(SignalChannelConfig.self, from: Data(json.utf8))
        #expect(config.accountID == "+15551234567")
        #expect(config.accountUUID == "abc")
        #expect(config.serviceURL == "http://c:8080")
        #expect(config.resolvedTransportKind == .container)
        #expect(config.sendReadReceipts)
        #expect(config.policy.groups?["*"]?.requireMention == true)
        #expect(config.replyToModeByChatType.group == .first)
    }
}
