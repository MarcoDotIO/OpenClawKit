import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OpenClawChannels
import OpenClawCore
import OpenClawProtocol
import Testing

/// 2026.3.0 FX6 regressions: partial multi-part delivery, ambiguous 5xx, remote numeric input,
/// iMessage post-write failures and media budgets.
@Suite("Channel delivery hardening", .timeLimit(.minutes(1)))
struct ChannelDeliveryHardeningTests {
    actor OffsetStore: TelegramUpdateOffsetStore {
        func readLastUpdateID() async -> Int64? { nil }
        func writeLastUpdateID(_: Int64) async {}
    }

    actor Collector {
        private(set) var names: [String] = []
        func append(_ name: String) { self.names.append(name) }
    }

    static func registry(_ collector: Collector? = nil, maxAttempts: Int = 3) -> ChannelRegistry {
        var sink: RuntimeDiagnosticSink?
        if let collector {
            sink = { event in await collector.append(event.name) }
        }
        return ChannelRegistry(
            sendRetryPolicy: ChannelSendRetryPolicy(maxAttempts: maxAttempts, initialBackoffMs: 1, maxBackoffMs: 2, backoffMultiplier: 1),
            sendThrottlePolicy: ChannelSendThrottlePolicy(),
            diagnosticsSink: sink
        )
    }

    static func telegram(_ http: ScriptedChannelHTTP, token: String = "123:abc") async throws -> TelegramChannelAdapter {
        await http.on("/getMe", json: #"{"ok":true,"result":{"id":999,"is_bot":true,"username":"OpenClawBot"}}"#)
        await http.on("/deleteWebhook", json: #"{"ok":true,"result":true}"#)
        await http.on("/getUpdates", json: #"{"ok":true,"result":[]}"#)
        let adapter = TelegramChannelAdapter(
            config: TelegramChannelConfig(enabled: true, botToken: token, pollIntervalMs: 250),
            transport: http,
            baseURL: URL(string: "https://telegram.example")!,
            offsetStore: OffsetStore(),
            diagnosticsSink: nil
        )
        try await adapter.start()
        return adapter
    }

    /// Three paragraphs that chunk into three Telegram messages.
    static let threeChunkText = (0..<3).map { String(repeating: "\($0)", count: 3_500) }.joined(separator: "\n\n")

    static func sent(_ id: Int) -> String {
        #"{"ok":true,"result":{"message_id":\#(id),"chat":{"id":1}}}"#
    }

    // MARK: F1 partial delivery

    @Test
    func telegramRateLimitOnALaterChunkIsRetriedPerChunkWithoutResendingEarlierChunks() async throws {
        let http = ScriptedChannelHTTP()
        await http.on("/sendMessage", json: Self.sent(1))
        await http.on("/sendMessage", status: 429, json: #"{"ok":false,"error_code":429,"parameters":{"retry_after":0}}"#)
        await http.on("/sendMessage", json: Self.sent(2))
        await http.on("/sendMessage", json: Self.sent(3))
        let adapter = try await Self.telegram(http)
        let registry = Self.registry()
        await registry.register(adapter)

        let outcome = try await registry.send(OutboundMessage(channel: .telegram, peerID: "1", text: Self.threeChunkText))
        await adapter.stop()

        #expect(outcome.attempts == 1)
        #expect(outcome.receipt?.platformMessageIDs == ["1", "2", "3"])
        let texts = await http.requests("/sendMessage").map { jsonObject($0.body)["text"] as? String ?? "" }
        #expect(texts.count == 4)
        #expect(texts.filter { $0.hasPrefix("0") }.count == 1)
        #expect(texts.filter { $0.hasPrefix("1") }.count == 2)
    }

    @Test
    func telegramServerErrorAfterTheFirstChunkIsAPartialDeliveryThatIsNeverRetried() async throws {
        let http = ScriptedChannelHTTP()
        await http.on("/sendMessage", json: Self.sent(1))
        await http.on("/sendMessage", status: 502, json: "bad gateway")
        let adapter = try await Self.telegram(http)
        let collector = Collector()
        let registry = Self.registry(collector)
        await registry.register(adapter)

        do {
            try await registry.send(OutboundMessage(channel: .telegram, peerID: "1", text: Self.threeChunkText))
            Issue.record("expected a partial delivery failure")
        } catch let failure as ChannelDeliveryFailure {
            #expect(failure.attempts == 1)
            #expect(failure.deliveredReceipt?.platformMessageIDs == ["1"])
            guard case .partiallyDelivered(_, let underlying) = failure.classification else {
                Issue.record("expected partiallyDelivered, got \(String(describing: failure.classification))")
                return
            }
            if case .unknownOutcome = underlying {} else {
                Issue.record("expected the 502 to be an unknown outcome, got \(underlying)")
            }
        }
        await adapter.stop()
        #expect(await http.count("/sendMessage") == 2)
        #expect(await collector.names.contains("channel.delivery.partial"))
    }

    @Test
    func serverErrorsAreAmbiguousAndNotRetried() async throws {
        #expect(ChannelSendError.classify(statusCode: 500)?.isRetryable == false)
        if case .unknownOutcome = ChannelSendError.classify(statusCode: 503) {} else {
            Issue.record("HTTP 503 must be an unknown outcome")
        }
        let http = ScriptedChannelHTTP()
        await http.on("/sendMessage", status: 503, json: "unavailable")
        let adapter = try await Self.telegram(http)
        let registry = Self.registry()
        await registry.register(adapter)
        await #expect(throws: ChannelDeliveryFailure.self) {
            try await registry.send(OutboundMessage(channel: .telegram, peerID: "1", text: "hi"))
        }
        await adapter.stop()
        #expect(await http.count("/sendMessage") == 1)
    }

    @Test
    func registryNeverRetriesPartialDeliveries() async throws {
        actor PartialAdapter: ReceiptingChannelAdapter {
            let id: ChannelID = .discord
            private(set) var attempts = 0
            func start() async throws {}
            func stop() async {}
            func send(_ message: OutboundMessage) async throws {
                _ = try await self.sendReturningReceipt(message)
            }

            func sendReturningReceipt(_: OutboundMessage) async throws -> ChannelSendReceipt {
                self.attempts += 1
                throw ChannelSendError.partiallyDelivered(
                    receipt: ChannelSendReceipt(platformMessageID: "d-1"),
                    failure: .rateLimited(retryAfterMs: 1)
                )
            }
        }
        let adapter = PartialAdapter()
        let registry = Self.registry()
        await registry.register(adapter)
        await #expect(throws: ChannelDeliveryFailure.self) {
            try await registry.send(OutboundMessage(channel: .discord, peerID: "c", text: "hi"))
        }
        #expect(await adapter.attempts == 1)
        let partial = ChannelSendError.partiallyDelivered(receipt: ChannelSendReceipt(platformMessageID: "x"), failure: .rateLimited(retryAfterMs: 1))
        #expect(partial.isRetryable == false)
        #expect(partial.retryAfterMs == nil)
        #expect(partial.deliveredReceipt?.platformMessageIDs == ["x"])
    }

    @Test
    func multipartDeliveryPropagatesFirstPartFailuresUnchanged() async throws {
        actor Runner {
            var calls: [Int] = []
            func run() async throws -> [ChannelSendReceipt.Part] {
                try await ChannelMultipartDelivery(backoffMs: 1).run(count: 3) { index in
                    self.calls.append(index)
                    if index == 0 { throw URLError(.cannotConnectToHost) }
                    return [ChannelSendReceipt.Part(platformMessageID: "\(index)", index: index)]
                }
            }
        }
        let runner = Runner()
        await #expect(throws: URLError.self) {
            _ = try await runner.run()
        }
        #expect(await runner.calls == [0])
    }

    @Test
    func linePushRetriesUnderOneRetryKeyAndAcceptsTheConflictAnswer() async throws {
        var config = LineChannelConfig(enabled: true)
        config.channelAccessToken = "line-token"
        config.channelSecret = "line-secret"
        let http = ScriptedChannelHTTP()
        await http.on("/message/push", status: 500, json: #"{"message":"Internal server error"}"#)
        await http.on("/message/push", status: 409, json: #"{"message":"The retry key is already accepted","sentMessages":[{"id":"accepted-earlier"}]}"#)
        await http.on("/message/push", json: #"{"sentMessages":[{"id":"second"}]}"#)
        let adapter = LineChannelAdapter(config: config, transport: http)
        try await adapter.start()
        let registry = Self.registry()
        await registry.register(adapter)

        let first = try await registry.send(OutboundMessage(channel: .line, peerID: "U1", text: "first"))
        #expect(first.receipt?.primaryPlatformMessageID == "accepted-earlier")
        #expect(first.attempts == 1)
        let pushes = await http.requests("/message/push")
        #expect(pushes.count == 2)
        let key = try #require(pushes.first?.headers["X-Line-Retry-Key"])
        #expect(pushes.last?.headers["X-Line-Retry-Key"] == key)

        _ = try await registry.send(OutboundMessage(channel: .line, peerID: "U1", text: "second"))
        let third = try #require(await http.requests("/message/push").last)
        #expect(third.headers["X-Line-Retry-Key"] != key)
        await adapter.stop()
    }

    @Test
    func linePushFailingOnEveryKeyedAttemptIsNotReplayedWithAFreshKey() async throws {
        var config = LineChannelConfig(enabled: true)
        config.channelAccessToken = "line-token"
        config.channelSecret = "line-secret"
        let http = ScriptedChannelHTTP()
        await http.on("/message/push", status: 500, json: #"{"message":"Internal server error"}"#)
        let adapter = LineChannelAdapter(config: config, transport: http)
        try await adapter.start()
        let registry = Self.registry()
        await registry.register(adapter)
        await #expect(throws: ChannelDeliveryFailure.self) {
            try await registry.send(OutboundMessage(channel: .line, peerID: "U1", text: "hello"))
        }
        let pushes = await http.requests("/message/push")
        #expect(pushes.count == LineChannelAdapter.maxPushAttempts)
        #expect(Set(pushes.compactMap { $0.headers["X-Line-Retry-Key"] }).count == 1)
        await adapter.stop()
    }

    // MARK: F6 iMessage post-write failures

    @Test
    func imsgSendTimeoutsAndExitsAfterTheWriteAreUnknownOutcomes() async throws {
        let silent = FakeIMsgPipe { _, _ in nil }
        let client = IMsgRPCClient(pipe: silent)
        try await client.start()
        do {
            _ = try await client.request("send", params: ["text": AnyCodable("hi")], timeoutMs: 50)
            Issue.record("expected timeout")
        } catch {
            #expect(ChannelSendError.classify(error).isRetryable == false)
            if case .unknownOutcome = ChannelSendError.classify(error) {} else {
                Issue.record("expected unknownOutcome, got \(error)")
            }
        }
        do {
            _ = try await client.request("chats.list", timeoutMs: 50)
            Issue.record("expected timeout")
        } catch {
            #expect(error is OpenClawCoreError)
        }

        let pending = Task { try await client.request("send", params: ["text": AnyCodable("again")], timeoutMs: 0) }
        try await waitUntil("send written") { await silent.requests("send").count == 2 }
        await silent.push(.exited(status: 1))
        do {
            _ = try await pending.value
            Issue.record("expected process exit failure")
        } catch {
            if case .unknownOutcome = ChannelSendError.classify(error) {} else {
                Issue.record("expected unknownOutcome after exit, got \(error)")
            }
        }
        await client.stop()
    }

    @Test
    func imsgSendErrorsAreRetryableOnlyWhenImsgSaysNotStarted() {
        let data = AnyCodable(["disposition": AnyCodable("not_started"), "retry_safe": AnyCodable(true)])
        let notStarted = IMsgRPCError(code: 1, message: "not started", data: data)
        #expect(ChannelSendError.classify(IMsgRPCTransport.normalizeSendError(notStarted)).isRetryable)
        let stalled = IMsgRPCError(code: 2, message: "Timed out waiting for response")
        #expect(ChannelSendError.classify(IMsgRPCTransport.normalizeSendError(stalled)).isRetryable == false)
        #expect(ChannelSendError.classify(IMsgRPCError(message: "raw")).isRetryable)
    }

    @Test
    func unreadableSuccessBodiesAreUnknownOutcomes() {
        let decodingError = DecodingError.dataCorrupted(DecodingError.Context(codingPath: [], debugDescription: "bad"))
        #expect(ChannelSendError.classify(decodingError).isRetryable == false)
    }

    // MARK: F7 remote numeric input

    @Test
    func hugeRetryAfterValuesAreCappedInsteadOfTrapping() {
        #expect(ChannelSendError.classify(statusCode: 429, headers: ["Retry-After": "1e16"]) == .rateLimited(retryAfterMs: 60_000))
        #expect(ChannelSendError.parseRetryAfterHeader("1e300") == 60_000)
        let telegram = Data(#"{"ok":false,"error_code":429,"parameters":{"retry_after":1e16}}"#.utf8)
        #expect(ChannelSendError.telegramRetryAfterMs(body: telegram) == 60_000)
        let discord = Data(#"{"retry_after":1e16,"global":false}"#.utf8)
        #expect(ChannelSendError.discordRetryAfterMs(body: discord) == 60_000)
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(ChannelSendError.parseRetryAfterHeader("Fri, 01 Jan 9999 00:00:00 GMT", now: now) == 60_000)
        #expect(ChannelSendError.parseRetryAfterHeader("Thu, 01 Jan 1970 00:00:00 GMT", now: now) == 0)
        #expect(ChannelSendError.cappedRetryAfterMs(seconds: 0.0001) == 1)
    }

    @Test
    func millisecondConversionsSaturateAndProbeTimeoutsAreClamped() async {
        #expect(ChannelAsync.nanoseconds(milliseconds: Int.max) == UInt64(Int64.max))
        #expect(ChannelAsync.nanoseconds(milliseconds: -5) == 0)
        #expect(ChannelAsync.nanoseconds(milliseconds: 2) == 2_000_000)

        let registry = Self.registry()
        await registry.register(InMemoryChannelAdapter(id: .telegram))
        let handlers = ChannelGatewayHandlers(context: ChannelGatewayContext(
            registry: registry,
            pairingStore: ChannelPairingStore(),
            config: ChannelsConfig(telegram: TelegramChannelConfig(enabled: true, botToken: "t"))
        ))
        let report = await handlers.statusReport(probe: true, timeoutMs: 20_000_000_000_000)
        #expect(report.channelOrder.contains("telegram"))
    }

    // MARK: F13 media budgets

    @Test
    func mediaBudgetsNeverTrapOnLargeOrNonFiniteValues() {
        #expect(ChannelMediaLimits.maxBytes(megabytes: 1e20, defaultMegabytes: 10) == Int.max)
        #expect(ChannelMediaLimits.maxBytes(megabytes: .infinity, defaultMegabytes: 10) == 10 * 1_048_576)
        #expect(ChannelMediaLimits.maxBytes(megabytes: .nan, defaultMegabytes: 16) == 16 * 1_048_576)
        #expect(ChannelMediaLimits.maxBytes(megabytes: 4_096, defaultMegabytes: 10) == Int(min(4_096 * 1_048_576.0, Double(Int.max))))
        #expect(ChannelMediaLimits.maxBytes(megabytes: -1, defaultMegabytes: 10) == 0)
        #expect(ChannelMediaLimits.maxBytes(megabytes: nil, defaultMegabytes: 8) == 8 * 1_048_576)
    }

    @Test
    func lineMediaDownloadWithAnUnboundedBudgetDoesNotTrap() async throws {
        var config = LineChannelConfig(enabled: true)
        config.channelAccessToken = "line-token"
        config.channelSecret = "line-secret"
        config.policy.mediaMaxMb = 1e20
        config.policy.dmPolicy = .open
        let http = ScriptedChannelHTTP()
        await http.on("/content", response: HTTPResponseData(statusCode: 200, headers: ["Content-Type": "image/png"], body: Data([1, 2, 3])))
        let adapter = LineChannelAdapter(config: config, transport: http)
        let collector = ChannelEventCollector()
        await adapter.setInboundHandler { await collector.append($0) }
        try await adapter.start()
        let json = #"{"events":[{"type":"message","webhookEventId":"e1","replyToken":"r1","source":{"type":"user","userId":"U1"},"#
            + #""message":{"id":"m1","type":"image"}}]}"#
        let body = Data(json.utf8)
        let headers = ["X-Line-Signature": ChannelWebhookSignature.lineSignature(channelSecret: "line-secret", body: body)]
        #expect(await adapter.handleWebhook(headers: headers, body: body).status == 200)
        try await waitUntil("image delivered") { await !collector.messages.isEmpty }
        #expect(await collector.messages.first?.attachments.first?.data == Data([1, 2, 3]))
        await adapter.stop()
    }
}
