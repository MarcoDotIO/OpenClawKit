import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OpenClawKit

@Suite("Discord channel adapter")
struct DiscordChannelAdapterTests {
    actor InboundCollector {
        private(set) var messages: [InboundMessage] = []

        func append(_ message: InboundMessage) {
            self.messages.append(message)
        }

        func snapshot() -> [InboundMessage] {
            self.messages
        }
    }

    actor MockDiscordTransport: DiscordHTTPTransport {
        struct RequestRecord: Sendable {
            let method: String
            let path: String
            let body: String
        }

        var requestRecords: [RequestRecord] = []
        var meStatusCode: Int
        var messagesQueue: [Data]
        var postStatusCode: Int
        let botUserID: String

        init(
            botUserID: String = "bot-id",
            meStatusCode: Int = 200,
            messagesQueue: [Data] = [],
            postStatusCode: Int = 200
        ) {
            self.botUserID = botUserID
            self.meStatusCode = meStatusCode
            self.messagesQueue = messagesQueue
            self.postStatusCode = postStatusCode
        }

        func data(for request: URLRequest) async throws -> HTTPResponseData {
            let record = RequestRecord(
                method: request.httpMethod ?? "GET",
                path: request.url?.path ?? "",
                body: String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            )
            self.requestRecords.append(record)

            if record.path.hasSuffix("/users/@me") {
                if self.meStatusCode == 200 {
                    let body = try JSONEncoder().encode(["id": self.botUserID])
                    return HTTPResponseData(statusCode: 200, headers: [:], body: body)
                }
                return HTTPResponseData(statusCode: self.meStatusCode, headers: [:], body: Data())
            }

            if record.path.contains("/messages"), record.method == "GET" {
                let body = self.messagesQueue.isEmpty ? Data("[]".utf8) : self.messagesQueue.removeFirst()
                return HTTPResponseData(statusCode: 200, headers: [:], body: body)
            }

            if record.path.contains("/messages"), record.method == "POST" {
                return HTTPResponseData(statusCode: self.postStatusCode, headers: [:], body: Data("{}".utf8))
            }

            if record.path.contains("/reactions/"), record.method == "PUT" {
                return HTTPResponseData(statusCode: 204, headers: [:], body: Data())
            }

            if record.path.hasSuffix("/typing"), record.method == "POST" {
                return HTTPResponseData(statusCode: 204, headers: [:], body: Data())
            }

            return HTTPResponseData(statusCode: 404, headers: [:], body: Data())
        }

        func records() -> [RequestRecord] {
            self.requestRecords
        }
    }

    actor MockPresenceClient: DiscordPresenceClient {
        private(set) var startCount = 0
        private(set) var stopCount = 0
        var failOnStart = false

        func setFailOnStart(_ value: Bool) {
            self.failOnStart = value
        }

        func start() async throws {
            if self.failOnStart {
                throw OpenClawCoreError.unavailable("presence start failed")
            }
            self.startCount += 1
        }

        func stop() async {
            self.stopCount += 1
        }

        func snapshot() -> (startCount: Int, stopCount: Int) {
            (self.startCount, self.stopCount)
        }
    }

    @Test
    func pollsMessagesAndDeliversInboundUserText() async throws {
        let payload = Data("""
        [
          {"id":"1","content":"<@bot-id> hello from user","author":{"id":"user-1","bot":false},"mentions":[{"id":"bot-id","bot":true}]},
          {"id":"2","content":"ignore self","author":{"id":"bot-id","bot":true}}
        ]
        """.utf8)
        let transport = MockDiscordTransport(messagesQueue: [Data("[]".utf8), payload, Data("[]".utf8)])
        let collector = InboundCollector()
        let adapter = DiscordChannelAdapter(
            config: DiscordChannelConfig(
                enabled: true,
                botToken: "secret-token",
                defaultChannelID: "channel-1",
                pollIntervalMs: 250,
                presenceEnabled: false,
                mentionOnly: true
            ),
            transport: transport,
            baseURL: URL(string: "https://discord.example/api/v10")!
        )
        await adapter.setInboundHandler { message in
            await collector.append(message)
        }

        try await adapter.start()
        try await Task.sleep(nanoseconds: 350_000_000)
        await adapter.stop()

        let received = await collector.snapshot()
        #expect(received.count >= 1)
        #expect(received.first?.channel == .discord)
        #expect(received.first?.senderID == "user-1")
        #expect(received.first?.peerID == "channel-1")
        #expect(received.first?.text == "hello from user")
    }

    @Test
    func sendPostsOutboundMessageToDiscordChannel() async throws {
        let transport = MockDiscordTransport(messagesQueue: [Data("[]".utf8)])
        let adapter = DiscordChannelAdapter(
            config: DiscordChannelConfig(
                enabled: true,
                botToken: "secret-token",
                defaultChannelID: "channel-1",
                pollIntervalMs: 250,
                presenceEnabled: false,
                mentionOnly: true
            ),
            transport: transport,
            baseURL: URL(string: "https://discord.example/api/v10")!
        )

        try await adapter.start()
        try await adapter.send(
            OutboundMessage(channel: .discord, peerID: "channel-1", text: "hello outbound")
        )
        await adapter.stop()

        let records = await transport.records()
        #expect(records.contains(where: { $0.method == "POST" && $0.path.hasSuffix("/channels/channel-1/messages") }))
        #expect(records.contains(where: { $0.body.contains("hello outbound") }))
    }

    @Test
    func startFailsWithAuthenticationErrorWhenTokenRejected() async throws {
        let transport = MockDiscordTransport(meStatusCode: 401)
        let adapter = DiscordChannelAdapter(
            config: DiscordChannelConfig(
                enabled: true,
                botToken: "bad-token",
                defaultChannelID: "channel-1",
                pollIntervalMs: 250,
                presenceEnabled: false,
                mentionOnly: true
            ),
            transport: transport,
            baseURL: URL(string: "https://discord.example/api/v10")!
        )

        do {
            try await adapter.start()
            Issue.record("Expected auth failure")
        } catch {
            #expect(String(describing: error).lowercased().contains("authentication"))
        }
    }

    @Test
    func startsAndStopsPresenceClientWhenEnabled() async throws {
        let transport = MockDiscordTransport(messagesQueue: [Data("[]".utf8)])
        let presence = MockPresenceClient()
        let adapter = DiscordChannelAdapter(
            config: DiscordChannelConfig(
                enabled: true,
                botToken: "secret-token",
                defaultChannelID: "channel-1",
                pollIntervalMs: 250,
                presenceEnabled: true,
                mentionOnly: true
            ),
            transport: transport,
            baseURL: URL(string: "https://discord.example/api/v10")!,
            presenceFactory: { _ in presence }
        )

        try await adapter.start()
        await adapter.stop()

        let snapshot = await presence.snapshot()
        #expect(snapshot.startCount == 1)
        #expect(snapshot.stopCount == 1)
    }

    @Test
    func startFailsWhenPresenceClientStartThrows() async throws {
        let transport = MockDiscordTransport(messagesQueue: [Data("[]".utf8)])
        let presence = MockPresenceClient()
        await presence.setFailOnStart(true)

        let adapter = DiscordChannelAdapter(
            config: DiscordChannelConfig(
                enabled: true,
                botToken: "secret-token",
                defaultChannelID: "channel-1",
                pollIntervalMs: 250,
                presenceEnabled: true,
                mentionOnly: true
            ),
            transport: transport,
            baseURL: URL(string: "https://discord.example/api/v10")!,
            presenceFactory: { _ in presence }
        )

        do {
            try await adapter.start()
            Issue.record("Expected presence start failure")
        } catch {
            #expect(String(describing: error).lowercased().contains("presence"))
        }
    }

    @Test
    func startupSkipsBacklogAndProcessesOnlyNewMentions() async throws {
        let firstPoll = Data("""
        [
          {"id":"10","content":"<@bot-id> old mention","author":{"id":"user-1","bot":false},"mentions":[{"id":"bot-id","bot":true}]}
        ]
        """.utf8)
        let secondPoll = Data("""
        [
          {"id":"10","content":"<@bot-id> old mention","author":{"id":"user-1","bot":false},"mentions":[{"id":"bot-id","bot":true}]},
          {"id":"11","content":"<@bot-id> new mention","author":{"id":"user-2","bot":false},"mentions":[{"id":"bot-id","bot":true}]}
        ]
        """.utf8)

        let transport = MockDiscordTransport(messagesQueue: [firstPoll, secondPoll, Data("[]".utf8)])
        let collector = InboundCollector()
        let adapter = DiscordChannelAdapter(
            config: DiscordChannelConfig(
                enabled: true,
                botToken: "secret-token",
                defaultChannelID: "channel-1",
                pollIntervalMs: 250,
                presenceEnabled: false,
                mentionOnly: true
            ),
            transport: transport,
            baseURL: URL(string: "https://discord.example/api/v10")!
        )
        await adapter.setInboundHandler { message in
            await collector.append(message)
        }

        try await adapter.start()
        try await Task.sleep(nanoseconds: 650_000_000)
        await adapter.stop()

        let received = await collector.snapshot()
        #expect(received.count == 1)
        #expect(received.first?.text.contains("new mention") == true)
    }

    @Test
    func mentionOnlyModeIgnoresNonMentionMessages() async throws {
        let secondPoll = Data("""
        [
          {"id":"21","content":"hello everyone","author":{"id":"user-1","bot":false},"mentions":[]},
          {"id":"22","content":"<@bot-id> please respond","author":{"id":"user-2","bot":false},"mentions":[{"id":"bot-id","bot":true}]}
        ]
        """.utf8)
        let transport = MockDiscordTransport(messagesQueue: [Data("[]".utf8), secondPoll, Data("[]".utf8)])
        let collector = InboundCollector()
        let adapter = DiscordChannelAdapter(
            config: DiscordChannelConfig(
                enabled: true,
                botToken: "secret-token",
                defaultChannelID: "channel-1",
                pollIntervalMs: 250,
                presenceEnabled: false,
                mentionOnly: true
            ),
            transport: transport,
            baseURL: URL(string: "https://discord.example/api/v10")!
        )
        await adapter.setInboundHandler { message in
            await collector.append(message)
        }

        try await adapter.start()
        try await Task.sleep(nanoseconds: 650_000_000)
        await adapter.stop()

        let received = await collector.snapshot()
        #expect(received.count == 1)
        #expect(received.first?.senderID == "user-2")
    }

    @Test
    func mentionTriggerAddsEyesReaction() async throws {
        let payload = Data("""
        [
          {"id":"31","content":"<@bot-id> wake up","author":{"id":"user-1","bot":false},"mentions":[{"id":"bot-id","bot":true}]}
        ]
        """.utf8)
        let transport = MockDiscordTransport(messagesQueue: [Data("[]".utf8), payload, Data("[]".utf8)])
        let adapter = DiscordChannelAdapter(
            config: DiscordChannelConfig(
                enabled: true,
                botToken: "secret-token",
                defaultChannelID: "channel-1",
                pollIntervalMs: 250,
                presenceEnabled: false,
                mentionOnly: true
            ),
            transport: transport,
            baseURL: URL(string: "https://discord.example/api/v10")!
        )

        try await adapter.start()
        try await Task.sleep(nanoseconds: 650_000_000)
        // 2026.3.0: the poll loop no longer reacts unconditionally; AutoReplyEngine sends the
        // ack reaction through ReactingChannelAdapter according to ackReactionScope.
        try await adapter.addReaction(peerID: "channel-1", messageID: "31", emoji: "👀")
        await adapter.stop()

        let records = await transport.records()
        #expect(records.contains(where: { $0.method == "PUT" && $0.path.contains("/reactions/") && $0.path.hasSuffix("/@me") }))
        #expect(records.contains(where: { $0.method == "POST" && $0.path.hasSuffix("/typing") }))
    }
}
