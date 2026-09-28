import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OpenClawChannels
import OpenClawCore

@Suite("Channel send receipts and retry classification")
struct ChannelSendRetryTests {
    actor ScriptedAdapter: ReceiptingChannelAdapter {
        let id: ChannelID
        private var failures: [Error]
        private(set) var attempts = 0

        init(id: ChannelID = .telegram, failures: [Error]) {
            self.id = id
            self.failures = failures
        }

        func start() async throws {}
        func stop() async {}

        func send(_ message: OutboundMessage) async throws {
            _ = try await self.sendReturningReceipt(message)
        }

        func sendReturningReceipt(_ message: OutboundMessage) async throws -> ChannelSendReceipt {
            self.attempts += 1
            if !self.failures.isEmpty {
                throw self.failures.removeFirst()
            }
            return ChannelSendReceipt(platformMessageID: "msg-\(self.attempts)", replyToID: message.replyToID)
        }
    }

    actor ReconcilingAdapter: UnknownSendReconciling {
        let id: ChannelID = .slack
        let result: ChannelUnknownSendReconciliation
        private(set) var attempts = 0

        init(result: ChannelUnknownSendReconciliation) {
            self.result = result
        }

        func start() async throws {}
        func stop() async {}

        func send(_: OutboundMessage) async throws {
            self.attempts += 1
            if self.attempts == 1 {
                throw ChannelSendError.unknownOutcome(underlying: "timeout after body written")
            }
        }

        func reconcile(_: OutboundMessage, attemptStartedAt _: Date) async -> ChannelUnknownSendReconciliation {
            self.result
        }
    }

    actor Collector {
        private(set) var names: [String] = []
        func append(_ name: String) { self.names.append(name) }
    }

    private func registry(_ collector: Collector? = nil) -> ChannelRegistry {
        var sink: RuntimeDiagnosticSink?
        if let collector {
            sink = { event in
                await collector.append(event.name)
            }
        }
        return ChannelRegistry(
            sendRetryPolicy: ChannelSendRetryPolicy(maxAttempts: 3, initialBackoffMs: 1, maxBackoffMs: 2, backoffMultiplier: 1),
            sendThrottlePolicy: ChannelSendThrottlePolicy(),
            diagnosticsSink: sink
        )
    }

    @Test
    func returnsReceiptsFromReceiptingAdapters() async throws {
        let registry = self.registry()
        let adapter = ScriptedAdapter(failures: [])
        await registry.register(adapter)
        let outcome = try await registry.send(OutboundMessage(channel: .telegram, peerID: "1", text: "hi", replyToID: "9"))
        #expect(outcome.receipt?.primaryPlatformMessageID == "msg-1")
        #expect(outcome.receipt?.replyToID == "9")
        #expect(outcome.attempts == 1)
    }

    @Test
    func neverRetriesUnknownOutcomes() async throws {
        let collector = Collector()
        let registry = self.registry(collector)
        let adapter = ScriptedAdapter(failures: [URLError(.timedOut)])
        await registry.register(adapter)
        do {
            try await registry.send(OutboundMessage(channel: .telegram, peerID: "1", text: "hi"))
            Issue.record("expected failure")
        } catch let failure as ChannelDeliveryFailure {
            #expect(failure.attempts == 1)
            if case .unknownOutcome = failure.classification {} else {
                Issue.record("expected unknownOutcome, got \(String(describing: failure.classification))")
            }
        }
        #expect(await adapter.attempts == 1)
        #expect(await collector.names.contains("channel.delivery.unknown_outcome"))
    }

    @Test
    func retriesNotSentAndHonorsRetryAfter() async throws {
        let collector = Collector()
        let registry = self.registry(collector)
        let adapter = ScriptedAdapter(failures: [
            URLError(.cannotConnectToHost),
            ChannelSendError.rateLimited(retryAfterMs: 5),
        ])
        await registry.register(adapter)
        let started = Date()
        let outcome = try await registry.send(OutboundMessage(channel: .telegram, peerID: "1", text: "hi"))
        #expect(outcome.attempts == 3)
        #expect(Date().timeIntervalSince(started) >= 0.004)
        #expect(await collector.names.contains("channel.delivery.rate_limited"))
        #expect(await collector.names.filter { $0 == "channel.delivery.retry" }.count == 2)
    }

    @Test
    func doesNotRetryPermanentRejections() async throws {
        let registry = self.registry()
        let adapter = ScriptedAdapter(failures: [ChannelSendError.rejected(status: 400, detail: "chat not found")])
        await registry.register(adapter)
        await #expect(throws: ChannelDeliveryFailure.self) {
            try await registry.send(OutboundMessage(channel: .telegram, peerID: "1", text: "hi"))
        }
        #expect(await adapter.attempts == 1)
    }

    @Test
    func reconcilesUnknownOutcomes() async throws {
        let sentAdapter = ReconcilingAdapter(result: .sent(ChannelSendReceipt(platformMessageID: "1700000000.0001")))
        let registry = self.registry()
        await registry.register(sentAdapter)
        let outcome = try await registry.send(OutboundMessage(channel: .slack, peerID: "C1", text: "hi"))
        #expect(outcome.receipt?.primaryPlatformMessageID == "1700000000.0001")
        #expect(await sentAdapter.attempts == 1)

        let notSentAdapter = ReconcilingAdapter(result: .notSent)
        let retrying = self.registry()
        await retrying.register(notSentAdapter)
        let retried = try await retrying.send(OutboundMessage(channel: .slack, peerID: "C1", text: "hi"))
        #expect(retried.attempts == 2)
        #expect(await notSentAdapter.attempts == 2)
    }

    @Test
    func classifiesHTTPResponsesAndRetryAfterHeaders() {
        #expect(ChannelSendError.classify(statusCode: 200) == nil)
        #expect(ChannelSendError.classify(statusCode: 503)?.isRetryable == true)
        #expect(ChannelSendError.classify(statusCode: 403)?.isRetryable == false)
        let telegramBody = Data(#"{"ok":false,"error_code":429,"parameters":{"retry_after":3}}"#.utf8)
        #expect(ChannelSendError.classify(statusCode: 429, body: telegramBody) == .rateLimited(retryAfterMs: 3_000))
        let discordBody = Data(#"{"message":"You are being rate limited.","retry_after":0.25,"global":false}"#.utf8)
        #expect(ChannelSendError.classify(statusCode: 429, body: discordBody) == .rateLimited(retryAfterMs: 250))
        #expect(ChannelSendError.classify(statusCode: 429, headers: ["Retry-After": "120"]) == .rateLimited(retryAfterMs: 60_000))
        #expect(ChannelSendError.parseRetryAfterHeader("2") == 2_000)
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(ChannelSendError.parseRetryAfterHeader("Mon, 12 Jan 1970 13:46:50 GMT", now: now) == 10_000)
        #expect(ChannelSendError.classify(OpenClawCoreError.invalidConfiguration("x")).isRetryable == false)
        #expect(ChannelSendError.classify(OpenClawCoreError.unavailable("x")).isRetryable)
        #expect(ChannelSendError.classify(URLError(.networkConnectionLost)).isRetryable == false)
        #expect(ChannelSendError.classify(URLError(.notConnectedToInternet)).isRetryable)
    }

    @Test
    func combinesChunkReceipts() {
        let combined = ChannelSendReceipt.combined([
            ChannelSendReceipt(platformMessageID: "a"),
            ChannelSendReceipt(parts: [
                ChannelSendReceipt.Part(platformMessageID: "b", kind: .media),
                ChannelSendReceipt.Part(platformMessageID: "c"),
            ]),
        ])
        #expect(combined?.platformMessageIDs == ["a", "b", "c"])
        #expect(combined?.parts.map(\.index) == [0, 1, 2])
        #expect(combined?.primaryPlatformMessageID == "a")
    }

    @Test
    func registryTracksLifecycleState() async throws {
        let registry = self.registry()
        let adapter = InMemoryChannelAdapter(id: .webchat)
        await registry.register(adapter)
        #expect(await registry.runtimeState(for: .webchat).running == false)
        try await registry.start(id: .webchat)
        #expect(await registry.runtimeState(for: .webchat).running)
        await registry.recordInbound(channel: .webchat)
        #expect(await registry.runtimeState(for: .webchat).lastInboundAt != nil)
        try await registry.stop(id: .webchat)
        let stopped = await registry.runtimeState(for: .webchat)
        #expect(stopped.running == false)
        #expect(stopped.lastStopAt != nil)
        #expect(await registry.probe(id: .webchat).supported == false)
        await #expect(throws: OpenClawCoreError.self) {
            try await registry.start(id: .sms)
        }
    }
}
