import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OpenClawChannels
import OpenClawCore
import OpenClawProtocol
import Testing

@Suite("Discord gateway adapter")
struct DiscordGatewayAdapterTests {
    static let hello = #"{"op":10,"d":{"heartbeat_interval":45000}}"#
    static let ready = #"{"op":0,"s":1,"t":"READY","d":{"session_id":"sess-1","resume_gateway_url":"wss://resume.example","user":{"id":"bot-id"}}}"#

    static func transport() async -> ScriptedChannelHTTP {
        let http = ScriptedChannelHTTP()
        await http.on("/users/@me", json: #"{"id":"bot-id","username":"clawbot"}"#)
        await http.on("/messages", method: "POST", json: #"{"id":"m-1"}"#)
        return http
    }

    static func adapter(
        _ http: ScriptedChannelHTTP,
        sockets: [FakeWebSocket],
        configure: (inout DiscordChannelConfig) -> Void = { _ in }
    ) -> (DiscordChannelAdapter, FakeWebSocketConnector) {
        var config = DiscordChannelConfig(enabled: true, botToken: "secret-token", presenceEnabled: true, mentionOnly: true)
        configure(&config)
        let connector = FakeWebSocketConnector(sockets)
        let adapter = DiscordChannelAdapter(
            config: config,
            transport: http,
            baseURL: URL(string: "https://discord.example/api/v10")!,
            presenceFactory: nil,
            gatewayConnector: connector
        )
        return (adapter, connector)
    }

    static func messageCreate(
        id: String,
        content: String,
        channel: String = "c-1",
        guild: String? = "g-1",
        mentionsBot: Bool = false,
        authorBot: Bool = false
    ) -> String {
        let guildField = guild.map { #","guild_id":"\#($0)""# } ?? ""
        let mentions = mentionsBot ? #"[{"id":"bot-id"}]"# : "[]"
        return """
        {"op":0,"s":2,"t":"MESSAGE_CREATE","d":{"id":"\(id)","channel_id":"\(channel)"\(guildField),"content":"\(content)",
        "author":{"id":"user-1","username":"ada","global_name":"Ada","bot":\(authorBot)},"mentions":\(mentions)}}
        """
    }

    @Test
    func identifiesWithUpstreamIntentsAndPresence() async throws {
        let socket = FakeWebSocket(frames: [Self.hello, Self.ready])
        let http = await Self.transport()
        let (adapter, _) = Self.adapter(http, sockets: [socket]) { config in
            config.activity = "Helping"
            config.status = .dnd
        }
        try await adapter.start()
        let identify = jsonObject(try #require(await socket.sentFrames().first))
        await adapter.stop()

        #expect(identify["op"] as? Int == 2)
        let data = try #require(identify["d"] as? [String: Any])
        let intents = try #require(data["intents"] as? Int)
        // Guilds, guild emojis, guild messages, reactions, DMs, DM reactions, message content.
        let expected: Int = [0, 3, 9, 10, 12, 13, 15].reduce(0) { $0 | (1 << $1) }
        #expect(intents == expected)
        let presence = try #require(data["presence"] as? [String: Any])
        #expect(presence["status"] as? String == "dnd")
        let activity = try #require((presence["activities"] as? [[String: Any]])?.first)
        #expect(activity["type"] as? Int == 4)
        #expect(activity["state"] as? String == "Helping")
    }

    @Test
    func intentsOmitMessageContentAndAddPrivilegedWhenConfigured() {
        let base = DiscordGatewayIntent.resolve(DiscordIntentsConfig(messageContent: false))
        #expect(base & DiscordGatewayIntent.messageContent == 0)
        let privileged = DiscordGatewayIntent.resolve(DiscordIntentsConfig(presence: true, guildMembers: true))
        #expect(privileged & DiscordGatewayIntent.guildPresences != 0)
        #expect(privileged & DiscordGatewayIntent.guildMembers != 0)
    }

    @Test
    func dispatchesDirectGuildAndThreadMessages() async throws {
        let socket = FakeWebSocket(frames: [Self.hello, Self.ready])
        let http = await Self.transport()
        let (adapter, _) = Self.adapter(http, sockets: [socket])
        let collector = ChannelEventCollector()
        await adapter.setInboundHandler { await collector.append($0) }
        try await adapter.start()

        await socket.feed(Self.messageCreate(id: "1", content: "hi in dm", channel: "dm-1", guild: nil))
        await socket.feed(Self.messageCreate(id: "2", content: "no mention here"))
        await socket.feed(Self.messageCreate(id: "3", content: "<@bot-id> in guild", mentionsBot: true))
        await socket.feed(#"{"op":0,"s":3,"t":"THREAD_CREATE","d":{"id":"t-1","type":11,"parent_id":"c-1"}}"#)
        await socket.feed(Self.messageCreate(id: "4", content: "<@bot-id> in thread", channel: "t-1", mentionsBot: true))
        try await waitUntil("three messages") { await collector.messages.count == 3 }
        await adapter.stop()

        // Channels are delivered independently (per-channel queues), so order by message id.
        let messages = await collector.messages.sorted { ($0.messageID ?? "") < ($1.messageID ?? "") }
        #expect(messages[0].chatType == .direct)
        #expect(messages[0].wasMentioned == nil)
        #expect(messages[0].senderName == "Ada")
        #expect(messages[1].chatType == .channel)
        #expect(messages[1].wasMentioned == true)
        #expect(messages[1].text == "in guild")
        #expect(messages[2].chatType == .thread)
        #expect(messages[2].threadID == "t-1")
        #expect(messages[2].peerID == "t-1")
    }

    @Test
    func dmDisabledAndChannelOverridesGateIngestion() async throws {
        let socket = FakeWebSocket(frames: [Self.hello, Self.ready])
        let http = await Self.transport()
        let (adapter, _) = Self.adapter(http, sockets: [socket]) { config in
            config.dm = ChannelDirectMessageConfig(enabled: false)
            var guild = ChannelRoomOverrideConfig(requireMention: true)
            guild.channels = ["open": ChannelRoomOverrideConfig(requireMention: false), "off": ChannelRoomOverrideConfig(enabled: false)]
            config.guilds = ["g-1": guild]
        }
        let collector = ChannelEventCollector()
        await adapter.setInboundHandler { await collector.append($0) }
        try await adapter.start()
        await socket.feed(Self.messageCreate(id: "1", content: "dm", channel: "dm", guild: nil))
        await socket.feed(Self.messageCreate(id: "2", content: "<@bot-id> disabled", channel: "off", mentionsBot: true))
        await socket.feed(Self.messageCreate(id: "3", content: "no mention needed", channel: "open"))
        try await waitUntil("one message") { await collector.messages.count == 1 }
        await adapter.stop()
        #expect(await collector.messages.first?.peerID == "open")
    }

    @Test
    func slowInboundHandlerDoesNotStallHeartbeatsOrOtherChannels() async throws {
        let socket = FakeWebSocket(frames: [#"{"op":10,"d":{"heartbeat_interval":1000}}"#, Self.ready])
        let http = await Self.transport()
        let (adapter, connector) = Self.adapter(http, sockets: [socket]) { config in
            config.mentionOnly = false
        }
        let gate = ChannelTestGate()
        let collector = ChannelEventCollector()
        await adapter.setInboundHandler { message in
            await collector.append(message)
            if message.peerID == "slow" {
                // A long agent turn: blocks well past two heartbeat intervals.
                await gate.wait()
            }
        }
        try await adapter.start()
        // Answer every heartbeat like the gateway does.
        let acker = Task {
            var acked = 0
            while !Task.isCancelled {
                let beats = await socket.sentFrames().filter { (jsonObject($0)["op"] as? Int) == 1 }.count
                while acked < beats {
                    await socket.feed(#"{"op":11}"#)
                    acked += 1
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        defer { acker.cancel() }

        await socket.feed(Self.messageCreate(id: "1", content: "slow turn", channel: "slow"))
        try await waitUntil("slow turn started") { await gate.waitCount == 1 }
        await socket.feed(Self.messageCreate(id: "2", content: "other channel", channel: "fast"))
        try await waitUntil("other channel delivered while the slow turn runs") {
            await collector.messages.contains { $0.peerID == "fast" }
        }
        try await waitUntil("at least two heartbeats acknowledged", timeoutSeconds: 10) {
            await socket.sentFrames().filter { (jsonObject($0)["op"] as? Int) == 1 }.count >= 2
        }
        // Give a missed ACK time to trip the zombie check (next beat after the first).
        try await Task.sleep(nanoseconds: 1_100_000_000)
        #expect(await socket.isClosed() == false)
        #expect(await connector.connectCount() == 1)
        #expect(await adapter.transportHealth().state == .healthy)

        await gate.open()
        await adapter.stop()
    }

    @Test
    func reconnectsWithResumeAfterOp7() async throws {
        let first = FakeWebSocket(frames: [Self.hello, Self.ready, #"{"op":7,"d":null}"#])
        let second = FakeWebSocket(frames: [Self.hello])
        let http = await Self.transport()
        let (adapter, connector) = Self.adapter(http, sockets: [first, second])
        try await adapter.start()
        try await waitUntil("resumed") { await !second.sentFrames().isEmpty }
        let resume = jsonObject(try #require(await second.sentFrames().first))
        let urls = await connector.requests.compactMap { $0.url?.host }
        await adapter.stop()
        #expect(resume["op"] as? Int == 6)
        #expect((resume["d"] as? [String: Any])?["session_id"] as? String == "sess-1")
        #expect(urls.last == "resume.example")
    }

    @Test
    func sendChunksSuppressesEmbedsRepliesAndRewritesMentions() async throws {
        let socket = FakeWebSocket(frames: [Self.hello, Self.ready])
        let http = await Self.transport()
        let (adapter, _) = Self.adapter(http, sockets: [socket]) { config in
            config.mentionAliases = ["ada": "111"]
        }
        try await adapter.start()
        let lines = (1...20).map { "line \($0)" }.joined(separator: "\n")
        let receipt = try await adapter.sendReturningReceipt(
            OutboundMessage(channel: .discord, peerID: "c-1", text: "hey @ada\n" + lines, replyToID: "m-0")
        )
        await adapter.stop()

        let posts = await http.requests("/channels/c-1/messages", method: "POST")
        #expect(posts.count == 2)
        #expect(receipt.parts.count == 2)
        let first = jsonObject(posts[0].body)
        #expect(first["flags"] as? Int == 4)
        #expect((first["message_reference"] as? [String: Any])?["message_id"] as? String == "m-0")
        #expect((first["content"] as? String)?.contains("<@111>") == true)
        #expect(jsonObject(posts[1].body)["message_reference"] == nil)
        #expect(((first["content"] as? String) ?? "").split(separator: "\n").count <= 17)
    }

    @Test
    func editDeleteAndPollUseRESTEndpoints() async throws {
        let socket = FakeWebSocket(frames: [Self.hello, Self.ready])
        let http = await Self.transport()
        await http.on("/channels/c-1/messages/m-9", method: "PATCH", json: #"{"id":"m-9"}"#)
        await http.on("/channels/c-1/messages/m-9", method: "DELETE", status: 204, json: "")
        let (adapter, _) = Self.adapter(http, sockets: [socket])
        try await adapter.start()
        try await adapter.edit(peerID: "c-1", messageID: "m-9", text: "fixed")
        try await adapter.unsend(peerID: "c-1", messageID: "m-9")
        let poll = try await adapter.sendPoll(peerID: "c-1", question: "Ship?", options: ["yes", "no"], allowMultiple: false)
        await adapter.stop()
        #expect(await http.count("/channels/c-1/messages/m-9", method: "PATCH") == 1)
        #expect(await http.count("/channels/c-1/messages/m-9", method: "DELETE") == 1)
        let body = jsonObject(try #require(await http.requests("/channels/c-1/messages", method: "POST").last).body)
        #expect(((body["poll"] as? [String: Any])?["question"] as? [String: Any])?["text"] as? String == "Ship?")
        #expect(poll?.primaryPlatformMessageID == "m-1")
    }

    @Test
    func rateLimitedSendCarriesRetryAfter() async throws {
        let socket = FakeWebSocket(frames: [Self.hello, Self.ready])
        let http = ScriptedChannelHTTP()
        await http.on("/users/@me", json: #"{"id":"bot-id"}"#)
        await http.on("/messages", method: "POST", status: 429, json: #"{"message":"You are being rate limited.","retry_after":1.5}"#)
        let (adapter, _) = Self.adapter(http, sockets: [socket])
        try await adapter.start()
        await #expect(throws: ChannelSendError.rateLimited(retryAfterMs: 1_500)) {
            try await adapter.send(OutboundMessage(channel: .discord, peerID: "c-1", text: "hi"))
        }
        await adapter.stop()
    }

    @Test
    func recentGuildCreateEmitsJoinEvent() async throws {
        let socket = FakeWebSocket(frames: [Self.hello, Self.ready])
        let http = await Self.transport()
        let (adapter, _) = Self.adapter(http, sockets: [socket])
        let collector = ChannelEventCollector()
        await adapter.setJoinEventHandler { await collector.appendJoin($0) }
        try await adapter.start()
        let now = ISO8601DateFormatter().string(from: Date())
        await socket.feed(#"{"op":0,"s":4,"t":"GUILD_CREATE","d":{"id":"g-9","name":"Guild","joined_at":"\#(now)","system_channel_id":"c-sys"}}"#)
        await socket.feed(#"{"op":0,"s":5,"t":"GUILD_CREATE","d":{"id":"g-old","joined_at":"2020-01-01T00:00:00Z","system_channel_id":"c-x"}}"#)
        try await waitUntil("join") { await !collector.joins.isEmpty }
        await adapter.stop()
        let joins = await collector.joins
        #expect(joins.count == 1)
        #expect(joins.first?.peerID == "c-sys")
        #expect(joins.first?.roomName == "Guild")
    }

    @Test
    func mentionAliasRewriteIsWordBounded() {
        let rewritten = DiscordChannelAdapter.applyMentionAliases("@Ada and @adam and email@ada", aliases: ["ada": "1"])
        #expect(rewritten == "<@1> and @adam and email@ada")
    }

    @Test
    func configDecodesUpstreamDiscordKeys() throws {
        let json = """
        {"token":"t","intents":{"messageContent":false},"suppressEmbeds":false,"maxLinesPerMessage":10,
         "mentionAliases":{"bob":"42"},"dm":{"enabled":false},"guilds":{"g":{"requireMention":false,"channels":{"c":{"users":[123]}}}},
         "status":"idle","activity":"Reading","activityType":3,"transport":"rest-polling"}
        """
        let config = try JSONDecoder().decode(DiscordChannelConfig.self, from: Data(json.utf8))
        #expect(config.botToken == "t")
        #expect(config.intents.messageContent == false)
        #expect(config.suppressEmbeds == false)
        #expect(config.maxLinesPerMessage == 10)
        #expect(config.mentionAliases == ["bob": "42"])
        #expect(config.dm.enabled == false)
        #expect(config.guilds["g"]?.requireMention == false)
        #expect(config.guilds["g"]?.channels?["c"]?.users == ["123"])
        #expect(config.status == .idle)
        #expect(config.activityType == 3)
        #expect(config.transport == .restPolling)
        let exported = ChannelsConfigDocument(exporting: ChannelsConfig(discord: config)).channels["discord"]?.raw
        #expect(exported?["transport"] == nil)
        #expect(exported?["suppressEmbeds"]?.boolValue == false)
    }
}
