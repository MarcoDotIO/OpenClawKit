import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OpenClawKit

@Suite("Channel adapters E2E")
struct ChannelAdaptersE2ETests {
    actor TelegramInboundCollector {
        private(set) var messages: [InboundMessage] = []

        func append(_ message: InboundMessage) {
            self.messages.append(message)
        }

        func snapshot() -> [InboundMessage] {
            self.messages
        }
    }

    actor TelegramOffsetStore: TelegramUpdateOffsetStore {
        private var value: Int64?

        func readLastUpdateID() async -> Int64? {
            self.value
        }

        func writeLastUpdateID(_ updateID: Int64) async {
            self.value = updateID
        }
    }

    actor TelegramTransport: TelegramHTTPTransport {
        var updateResponses: [Data]

        init(updateResponses: [Data]) {
            self.updateResponses = updateResponses
        }

        func data(for request: URLRequest) async throws -> HTTPResponseData {
            let path = request.url?.path ?? ""
            if path.contains("/getMe") {
                return HTTPResponseData(
                    statusCode: 200,
                    headers: [:],
                    body: Data("{\"ok\":true,\"result\":{\"id\":999,\"is_bot\":true,\"username\":\"OpenClawBot\"}}".utf8)
                )
            }
            if path.contains("/getUpdates") {
                let payload = self.updateResponses.isEmpty
                    ? Data("{\"ok\":true,\"result\":[]}".utf8)
                    : self.updateResponses.removeFirst()
                return HTTPResponseData(statusCode: 200, headers: [:], body: payload)
            }
            if path.contains("/sendChatAction") {
                return HTTPResponseData(statusCode: 200, headers: [:], body: Data("{\"ok\":true,\"result\":true}".utf8))
            }
            return HTTPResponseData(statusCode: 404, headers: [:], body: Data())
        }
    }

    @Test
    func supportsCoreChannelIDs() async throws {
        let registry = ChannelRegistry()
        for channelID in ChannelID.allCases {
            await registry.register(InMemoryChannelAdapter(id: channelID))
        }

        let ids = await registry.adapterIDs().map(\.rawValue)
        #expect(ids.contains("whatsapp"))
        #expect(ids.contains("telegram"))
        #expect(ids.contains("slack"))
        #expect(ids.contains("discord"))
        #expect(ids.contains("signal"))
        #expect(ids.contains("imessage"))
        #expect(ids.contains("line"))
    }

    @Test
    func registryDispatchesOutboundToTelegramAdapter() async throws {
        let registry = ChannelRegistry()
        let telegram = InMemoryChannelAdapter(id: .telegram)
        await registry.register(telegram)
        try await telegram.start()

        try await registry.send(
            OutboundMessage(channel: .telegram, accountID: "default", peerID: "123", text: "ping")
        )

        let sent = await telegram.sentMessages()
        #expect(sent.count == 1)
        #expect(sent.first?.channel == .telegram)
        #expect(sent.first?.text == "ping")
    }

    @Test
    func registryDispatchesOutboundToWhatsAppAdapter() async throws {
        let registry = ChannelRegistry()
        let whatsapp = InMemoryChannelAdapter(id: .whatsapp)
        await registry.register(whatsapp)
        try await whatsapp.start()

        try await registry.send(
            OutboundMessage(channel: .whatsapp, accountID: "acct", peerID: "15550001111", text: "pong")
        )

        let sent = await whatsapp.sentMessages()
        #expect(sent.count == 1)
        #expect(sent.first?.channel == .whatsapp)
        #expect(sent.first?.text == "pong")
    }

    @Test
    func telegramAdapterResumesFromPersistedOffsetAcrossRestart() async throws {
        let firstUpdates = Data("""
        {"ok":true,"result":[{"update_id":20,"message":{"message_id":1,"text":"first","chat":{"id":111,"type":"private"},"from":{"id":42,"is_bot":false}}}]}
        """.utf8)
        let secondUpdates = Data("""
        {"ok":true,"result":[
          {"update_id":20,"message":{"message_id":1,"text":"stale","chat":{"id":111,"type":"private"},"from":{"id":42,"is_bot":false}}},
          {"update_id":21,"message":{"message_id":2,"text":"second","chat":{"id":111,"type":"private"},"from":{"id":42,"is_bot":false}}}
        ]}
        """.utf8)

        let offsetStore = TelegramOffsetStore()

        let collector1 = TelegramInboundCollector()
        let adapter1 = TelegramChannelAdapter(
            config: TelegramChannelConfig(enabled: true, botToken: "token", pollIntervalMs: 500),
            transport: TelegramTransport(updateResponses: [firstUpdates]),
            baseURL: URL(string: "https://telegram.example")!,
            offsetStore: offsetStore
        )
        await adapter1.setInboundHandler { inbound in
            await collector1.append(inbound)
        }
        try await adapter1.start()
        try await Task.sleep(nanoseconds: 250_000_000)
        await adapter1.stop()

        let collector2 = TelegramInboundCollector()
        let adapter2 = TelegramChannelAdapter(
            config: TelegramChannelConfig(enabled: true, botToken: "token", pollIntervalMs: 500),
            transport: TelegramTransport(updateResponses: [secondUpdates]),
            baseURL: URL(string: "https://telegram.example")!,
            offsetStore: offsetStore
        )
        await adapter2.setInboundHandler { inbound in
            await collector2.append(inbound)
        }
        try await adapter2.start()
        try await Task.sleep(nanoseconds: 250_000_000)
        await adapter2.stop()

        let firstRun = await collector1.snapshot()
        let secondRun = await collector2.snapshot()
        #expect(firstRun.map(\.text) == ["first"])
        #expect(secondRun.map(\.text) == ["second"])
    }
}

