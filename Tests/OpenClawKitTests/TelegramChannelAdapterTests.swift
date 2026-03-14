import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OpenClawKit

@Suite("Telegram channel adapter")
struct TelegramChannelAdapterTests {
    actor InboundCollector {
        private(set) var messages: [InboundMessage] = []

        func append(_ message: InboundMessage) {
            self.messages.append(message)
        }

        func snapshot() -> [InboundMessage] {
            self.messages
        }
    }

    actor MockTelegramTransport: TelegramHTTPTransport {
        enum MockFailure: Error, Sendable {
            case network
        }

        struct RequestRecord: Sendable {
            let method: String
            let path: String
            let url: String
            let body: String
        }

        var requestRecords: [RequestRecord] = []
        var meStatusCode: Int
        var updateResponses: [Data]
        var sendStatusCode: Int
        var botUsername: String
        var botID: Int64
        var pollFailureCount: Int
        var sendFailureCount: Int

        init(
            meStatusCode: Int = 200,
            updateResponses: [Data] = [],
            sendStatusCode: Int = 200,
            botUsername: String = "OpenClawBot",
            botID: Int64 = 999,
            pollFailureCount: Int = 0,
            sendFailureCount: Int = 0
        ) {
            self.meStatusCode = meStatusCode
            self.updateResponses = updateResponses
            self.sendStatusCode = sendStatusCode
            self.botUsername = botUsername
            self.botID = botID
            self.pollFailureCount = max(0, pollFailureCount)
            self.sendFailureCount = max(0, sendFailureCount)
        }

        func data(for request: URLRequest) async throws -> HTTPResponseData {
            let record = RequestRecord(
                method: request.httpMethod ?? "GET",
                path: request.url?.path ?? "",
                url: request.url?.absoluteString ?? "",
                body: String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            )
            self.requestRecords.append(record)

            if record.path.contains("/getMe") {
                guard self.meStatusCode == 200 else {
                    return HTTPResponseData(statusCode: self.meStatusCode, headers: [:], body: Data())
                }
                let payload = """
                {"ok":true,"result":{"id":\(self.botID),"is_bot":true,"username":"\(self.botUsername)"}}
                """
                return HTTPResponseData(statusCode: 200, headers: [:], body: Data(payload.utf8))
            }

            if record.path.contains("/getUpdates") {
                if self.pollFailureCount > 0 {
                    self.pollFailureCount -= 1
                    throw URLError(.networkConnectionLost)
                }
                let body = self.updateResponses.isEmpty
                    ? Data("{\"ok\":true,\"result\":[]}".utf8)
                    : self.updateResponses.removeFirst()
                return HTTPResponseData(statusCode: 200, headers: [:], body: body)
            }

            if record.path.contains("/sendChatAction") {
                return HTTPResponseData(statusCode: 200, headers: [:], body: Data("{\"ok\":true,\"result\":true}".utf8))
            }

            if record.path.contains("/sendMessage") {
                if self.sendFailureCount > 0 {
                    self.sendFailureCount -= 1
                    throw URLError(.networkConnectionLost)
                }
                guard self.sendStatusCode == 200 else {
                    return HTTPResponseData(statusCode: self.sendStatusCode, headers: [:], body: Data())
                }
                let payload = """
                {"ok":true,"result":{"message_id":1,"text":"ok","chat":{"id":123,"type":"private"}}}
                """
                return HTTPResponseData(statusCode: 200, headers: [:], body: Data(payload.utf8))
            }

            return HTTPResponseData(statusCode: 404, headers: [:], body: Data())
        }

        func records() -> [RequestRecord] {
            self.requestRecords
        }
    }

    actor MockOffsetStore: TelegramUpdateOffsetStore {
        private(set) var persistedUpdateID: Int64?
        private(set) var writes: [Int64] = []

        init(initial: Int64? = nil) {
            self.persistedUpdateID = initial
        }

        func readLastUpdateID() async -> Int64? {
            self.persistedUpdateID
        }

        func writeLastUpdateID(_ updateID: Int64) async {
            self.persistedUpdateID = updateID
            self.writes.append(updateID)
        }

        func snapshotWrites() async -> [Int64] {
            self.writes
        }
    }

    @Test
    func pollsUpdatesAndDeliversInboundPrivateMessages() async throws {
        let updates = Data("""
        {
          "ok": true,
          "result": [{
            "update_id": 1,
            "message": {
              "message_id": 10,
              "text": "hello from tg",
              "chat": {"id": 111, "type": "private"},
              "from": {"id": 42, "is_bot": false}
            }
          }]
        }
        """.utf8)
        let transport = MockTelegramTransport(updateResponses: [updates, Data("{\"ok\":true,\"result\":[]}".utf8)])
        let collector = InboundCollector()
        let adapter = TelegramChannelAdapter(
            config: TelegramChannelConfig(
                enabled: true,
                botToken: "token",
                pollIntervalMs: 250
            ),
            transport: transport,
            baseURL: URL(string: "https://telegram.example")!,
            offsetStore: MockOffsetStore()
        )
        await adapter.setInboundHandler { message in
            await collector.append(message)
        }

        try await adapter.start()
        try await Task.sleep(nanoseconds: 350_000_000)
        await adapter.stop()

        let messages = await collector.snapshot()
        #expect(messages.count >= 1)
        #expect(messages.first?.channel == .telegram)
        #expect(messages.first?.accountID == "42")
        #expect(messages.first?.peerID == "111")
        #expect(messages.first?.text == "hello from tg")
    }

    @Test
    func mentionOnlyModeFiltersGroupMessagesWithoutMentions() async throws {
        let updates = Data("""
        {"ok":true,"result":[
          {"update_id":5,"message":{"message_id":1,"text":"hello all","chat":{"id":-1001,"type":"group"},"from":{"id":10,"is_bot":false}}},
          {"update_id":6,"message":{"message_id":2,"text":"@OpenClawBot status please","chat":{"id":-1001,"type":"group"},"from":{"id":11,"is_bot":false}}}
        ]}
        """.utf8)
        let transport = MockTelegramTransport(updateResponses: [updates, Data("{\"ok\":true,\"result\":[]}".utf8)])
        let collector = InboundCollector()
        let adapter = TelegramChannelAdapter(
            config: TelegramChannelConfig(
                enabled: true,
                botToken: "token",
                pollIntervalMs: 250,
                mentionOnly: true
            ),
            transport: transport,
            baseURL: URL(string: "https://telegram.example")!,
            offsetStore: MockOffsetStore()
        )
        await adapter.setInboundHandler { message in
            await collector.append(message)
        }

        try await adapter.start()
        try await Task.sleep(nanoseconds: 350_000_000)
        await adapter.stop()

        let messages = await collector.snapshot()
        #expect(messages.count == 1)
        #expect(messages.first?.accountID == "11")
        #expect(messages.first?.text.contains("status please") == true)
    }

    @Test
    func sendPostsOutboundMessage() async throws {
        let transport = MockTelegramTransport(updateResponses: [Data("{\"ok\":true,\"result\":[]}".utf8)])
        let adapter = TelegramChannelAdapter(
            config: TelegramChannelConfig(
                enabled: true,
                botToken: "token",
                defaultChatID: "222",
                pollIntervalMs: 250
            ),
            transport: transport,
            baseURL: URL(string: "https://telegram.example")!,
            offsetStore: MockOffsetStore()
        )

        try await adapter.start()
        try await adapter.send(OutboundMessage(channel: .telegram, peerID: "222", text: "hello outbound"))
        await adapter.stop()

        let records = await transport.records()
        #expect(records.contains(where: { $0.method == "POST" && $0.path.contains("/sendMessage") }))
        #expect(records.contains(where: { $0.body.contains("hello outbound") }))
    }

    @Test
    func startFailsWhenGetMeIsUnauthorized() async throws {
        let transport = MockTelegramTransport(meStatusCode: 401)
        let adapter = TelegramChannelAdapter(
            config: TelegramChannelConfig(
                enabled: true,
                botToken: "bad-token",
                pollIntervalMs: 250
            ),
            transport: transport,
            baseURL: URL(string: "https://telegram.example")!,
            offsetStore: MockOffsetStore()
        )

        do {
            try await adapter.start()
            Issue.record("Expected auth failure")
        } catch {
            #expect(String(describing: error).lowercased().contains("status"))
        }
    }

    @Test
    func restartUsesPersistedOffsetAndSkipsStaleUpdates() async throws {
        let updates = Data("""
        {"ok":true,"result":[
          {"update_id":10,"message":{"message_id":1,"text":"stale","chat":{"id":111,"type":"private"},"from":{"id":42,"is_bot":false}}},
          {"update_id":11,"message":{"message_id":2,"text":"fresh","chat":{"id":111,"type":"private"},"from":{"id":42,"is_bot":false}}}
        ]}
        """.utf8)
        let transport = MockTelegramTransport(updateResponses: [updates, Data("{\"ok\":true,\"result\":[]}".utf8)])
        let offsetStore = MockOffsetStore(initial: 10)
        let collector = InboundCollector()
        let adapter = TelegramChannelAdapter(
            config: TelegramChannelConfig(
                enabled: true,
                botToken: "token",
                pollIntervalMs: 250
            ),
            transport: transport,
            baseURL: URL(string: "https://telegram.example")!,
            offsetStore: offsetStore
        )
        await adapter.setInboundHandler { inbound in
            await collector.append(inbound)
        }

        try await adapter.start()
        try await Task.sleep(nanoseconds: 350_000_000)
        await adapter.stop()

        let messages = await collector.snapshot()
        let writes = await offsetStore.snapshotWrites()
        let requests = await transport.records()

        #expect(messages.count == 1)
        #expect(messages.first?.text == "fresh")
        #expect(writes.contains(11))
        #expect(requests.contains(where: { $0.path.contains("/getUpdates") && $0.url.contains("offset=11") }))
    }

    @Test
    func duplicateUpdateIDsAreProcessedOnce() async throws {
        let updates = Data("""
        {"ok":true,"result":[
          {"update_id":70,"message":{"message_id":1,"text":"hello once","chat":{"id":111,"type":"private"},"from":{"id":42,"is_bot":false}}},
          {"update_id":70,"message":{"message_id":1,"text":"hello once","chat":{"id":111,"type":"private"},"from":{"id":42,"is_bot":false}}}
        ]}
        """.utf8)
        let transport = MockTelegramTransport(updateResponses: [updates, Data("{\"ok\":true,\"result\":[]}".utf8)])
        let offsetStore = MockOffsetStore()
        let collector = InboundCollector()
        let adapter = TelegramChannelAdapter(
            config: TelegramChannelConfig(
                enabled: true,
                botToken: "token",
                pollIntervalMs: 250
            ),
            transport: transport,
            baseURL: URL(string: "https://telegram.example")!,
            offsetStore: offsetStore
        )
        await adapter.setInboundHandler { inbound in
            await collector.append(inbound)
        }

        try await adapter.start()
        try await Task.sleep(nanoseconds: 350_000_000)
        await adapter.stop()

        let messages = await collector.snapshot()
        let writes = await offsetStore.snapshotWrites()
        #expect(messages.count == 1)
        #expect(messages.first?.text == "hello once")
        #expect(writes == [70])
    }

    @Test
    func pollLoopRecoversFromNetworkFailureAndProcessesLaterUpdates() async throws {
        let updates = Data("""
        {
          "ok": true,
          "result": [{
            "update_id": 90,
            "message": {
              "message_id": 10,
              "text": "after retry",
              "chat": {"id": 111, "type": "private"},
              "from": {"id": 42, "is_bot": false}
            }
          }]
        }
        """.utf8)
        let transport = MockTelegramTransport(
            updateResponses: [updates, Data("{\"ok\":true,\"result\":[]}".utf8)],
            pollFailureCount: 1
        )
        let collector = InboundCollector()
        let adapter = TelegramChannelAdapter(
            config: TelegramChannelConfig(enabled: true, botToken: "token", pollIntervalMs: 250),
            transport: transport,
            baseURL: URL(string: "https://telegram.example")!,
            offsetStore: MockOffsetStore()
        )
        await adapter.setInboundHandler { inbound in
            await collector.append(inbound)
        }

        try await adapter.start()
        try await Task.sleep(nanoseconds: 650_000_000)
        await adapter.stop()

        let messages = await collector.snapshot()
        let records = await transport.records()
        let pollRequests = records.filter { $0.path.contains("/getUpdates") }
        #expect(messages.count == 1)
        #expect(messages.first?.text == "after retry")
        #expect(pollRequests.count >= 2)
    }

    @Test
    func sendDoesNotRetryOnNetworkFailure() async throws {
        let transport = MockTelegramTransport(
            updateResponses: [Data("{\"ok\":true,\"result\":[]}".utf8)],
            sendFailureCount: 1
        )
        let adapter = TelegramChannelAdapter(
            config: TelegramChannelConfig(
                enabled: true,
                botToken: "token",
                defaultChatID: "222",
                pollIntervalMs: 250
            ),
            transport: transport,
            baseURL: URL(string: "https://telegram.example")!,
            offsetStore: MockOffsetStore()
        )

        try await adapter.start()
        do {
            try await adapter.send(OutboundMessage(channel: .telegram, peerID: "222", text: "hello outbound"))
            Issue.record("Expected send failure")
        } catch {}
        await adapter.stop()

        let records = await transport.records()
        let sendRequests = records.filter { $0.path.contains("/sendMessage") }
        #expect(sendRequests.count == 1)
    }
}
