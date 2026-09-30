import Foundation
@testable import OpenClawChannels
import OpenClawCore
import OpenClawProtocol
import Testing

/// Scripted `imsg rpc --json` pipe: answers requests by method and can push notifications.
actor FakeIMsgPipe: IMsgRPCPipe {
    typealias Responder = @Sendable (_ method: String, _ params: [String: Any]) -> String?

    private var continuation: AsyncStream<IMsgRPCPipeEvent>.Continuation?
    private(set) var lines: [String] = []
    private let responder: Responder
    private var failWrites = false

    init(responder: @escaping Responder) {
        self.responder = responder
    }

    func open() async throws -> AsyncStream<IMsgRPCPipeEvent> {
        let (stream, continuation) = AsyncStream<IMsgRPCPipeEvent>.makeStream()
        self.continuation = continuation
        return stream
    }

    func write(line: String) async throws {
        if self.failWrites {
            throw POSIXError(.EPIPE)
        }
        self.lines.append(line)
        let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
        guard let id = object["id"] as? Int, let method = object["method"] as? String else { return }
        if let body = self.responder(method, object["params"] as? [String: Any] ?? [:]) {
            self.continuation?.yield(.stdout(#"{"jsonrpc":"2.0","id":\#(id),\#(body)}"#))
        }
    }

    func close() async {
        self.continuation?.yield(.exited(status: 0))
        self.continuation?.finish()
    }

    func push(_ event: IMsgRPCPipeEvent) {
        self.continuation?.yield(event)
    }

    func setFailWrites(_ value: Bool) {
        self.failWrites = value
    }

    func requests(_ method: String) -> [RPCParams] {
        self.lines.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
            .filter { $0["method"] as? String == method }
            .compactMap { ($0["params"] as? [String: Any]).map(RPCParams.init) }
    }
}

/// Immutable JSON params snapshot handed across actor boundaries in tests.
struct RPCParams: @unchecked Sendable {
    let values: [String: Any]

    subscript(_ key: String) -> Any? {
        self.values[key]
    }
}

@Suite("imsg JSON-RPC transport", .timeLimit(.minutes(1)))
struct IMsgRPCTransportTests {
    static func standardResponder(_ method: String, _: [String: Any]) -> String? {
        switch method {
        case "watch.subscribe": return #""result":{"subscription":7}"#
        case "send": return #""result":{"guid":"GUID-1","message_id":"42"}"#
        case "send.attachment": return #""result":{"ok":true}"#
        case "ping": return #""result":{"ok":true}"#
        case "watch.unsubscribe": return #""result":{}"#
        default: return #""error":{"code":-32601,"message":"Method not found"}"#
        }
    }

    @Test
    func parsesTargetsLikeUpstream() throws {
        #expect(try IMessageTarget.parse("chat_id:12") == .chatID(12))
        #expect(try IMessageTarget.parse("chat:12") == .chatID(12))
        #expect(try IMessageTarget.parse("chat_guid:iMessage;+;chat123") == .chatGUID("iMessage;+;chat123"))
        #expect(try IMessageTarget.parse("chat_identifier:chat123") == .chatIdentifier("chat123"))
        let bare = "0123456789ABCDEF0123456789abcdef"
        #expect(try IMessageTarget.parse(bare) == .chatIdentifier(bare.lowercased()))
        #expect(try IMessageTarget.parse("sms:+15550001111") == .handle("+15550001111", service: .sms))
        #expect(try IMessageTarget.parse("friend@icloud.com") == .handle("friend@icloud.com", service: nil))
        #expect(throws: OpenClawCoreError.self) { try IMessageTarget.parse("chat_id:abc") }
    }

    @Test
    func clientMatchesResponsesAndFormatsErrors() async throws {
        let pipe = FakeIMsgPipe { method, _ in
            method == "boom" ? #""error":{"code":-32603,"message":"Internal error","data":"detail"}"# : #""result":{"pong":true}"#
        }
        let client = IMsgRPCClient(pipe: pipe)
        try await client.start()
        let result = try await client.request("ping")
        #expect(result.dictionaryValue?["pong"]?.boolValue == true)
        do {
            _ = try await client.request("boom")
            Issue.record("expected error")
        } catch let error as IMsgRPCError {
            #expect(error.code == -32_603)
            #expect(error.message == "Internal error: code=-32603 detail")
        }
        await client.stop()
    }

    @Test
    func timeoutsBridgeStallsAndClosedProcessesFailPendingRequests() async throws {
        let stalls = LockedCounter()
        let pipe = FakeIMsgPipe { method, _ in
            switch method {
            case "silent": return nil
            case "stall": return #""error":{"code":-32603,"message":"Timed out waiting for response to 'send-message'"}"#
            default: return #""result":{}"#
            }
        }
        let client = IMsgRPCClient(pipe: pipe)
        await client.setBridgeStallHandler { stalls.increment() }
        try await client.start()
        await #expect(throws: OpenClawCoreError.self) { _ = try await client.request("silent", timeoutMs: 20) }
        do {
            _ = try await client.request("stall")
            Issue.record("expected stall error")
        } catch {
            #expect(error.localizedDescription.contains("imsg launch"))
        }
        #expect(stalls.value == 1)

        let pending = Task { try await client.request("silent", timeoutMs: 0) }
        try await waitUntil("request written") { await pipe.requests("silent").count == 2 }
        await pipe.push(.stderr("Error: permission denied reading chat.db — grant Full Disk Access"))
        await pipe.push(.exited(status: 1))
        do {
            _ = try await pending.value
            Issue.record("expected close error")
        } catch {
            #expect(error.localizedDescription.contains("Grant Full Disk Access"))
        }
        #expect(await client.isRunning == false)
    }

    @Test
    func writeFailureFailsRequestImmediately() async throws {
        let pipe = FakeIMsgPipe { _, _ in nil }
        await pipe.setFailWrites(true)
        let client = IMsgRPCClient(pipe: pipe)
        try await client.start()
        await #expect(throws: (any Error).self) { _ = try await client.request("ping", timeoutMs: 60_000) }
        #expect(await client.isRunning == false)
    }

    @Test
    func transportSendsTextAttachmentsAndTargets() async throws {
        let pipe = FakeIMsgPipe(responder: Self.standardResponder)
        var config = IMessageChannelConfig(enabled: true)
        config.service = .imessage
        config.region = "US"
        config.sendTransport = .bridge
        let transport = IMsgRPCTransport(config: config) { pipe }
        let id = try await transport.sendReturningID(IMessageTransportMessage(
            accountID: nil,
            peerID: "chat_id:5",
            text: "hello",
            attachments: [MediaAttachment(mimeType: "image/png", data: Data([1]), fileName: "a.png"), MediaAttachment(mimeType: "image/png", data: Data([2]))]
        ))
        #expect(id == "GUID-1")
        let send = try #require(await pipe.requests("send").first)
        #expect(send["text"] as? String == "hello")
        #expect(send["chat_id"] as? Int == 5)
        #expect(send["service"] as? String == "imessage")
        #expect(send["region"] as? String == "US")
        #expect(send["transport"] as? String == "bridge")
        #expect((send["file"] as? String)?.hasSuffix("a.png") == true)
        #expect(send["to"] == nil)
        let attachment = try #require(await pipe.requests("send.attachment").first)
        #expect(attachment["chat_id"] as? Int == 5)

        _ = try await transport.sendReturningID(IMessageTransportMessage(accountID: nil, peerID: "sms:+15550001111", text: "hi"))
        let handleSend = try #require(await pipe.requests("send").last)
        #expect(handleSend["to"] as? String == "+15550001111")
        #expect(handleSend["service"] as? String == "sms")
        await transport.stopWatching()
    }

    @Test
    func adapterWatchesInboundDropsOwnMessagesAndRoutesGroups() async throws {
        let pipe = FakeIMsgPipe(responder: Self.standardResponder)
        let config = IMessageChannelConfig(enabled: true, allowUnsupportedPlatformSimulation: false)
        let adapter = IMessageChannelAdapter(config: config, transport: IMsgRPCTransport(config: config) { pipe })
        let collector = ChannelEventCollector()
        await adapter.setInboundHandler { await collector.append($0) }
        try await adapter.start()
        let subscribe = try #require(await pipe.requests("watch.subscribe").first)
        #expect(subscribe["include_reactions"] as? Bool == true)
        #expect(subscribe["attachments"] as? Bool == false)

        func notify(_ message: String) async {
            await pipe.push(.stdout(#"{"jsonrpc":"2.0","method":"message","params":{"message":\#(message)}}"#))
        }
        await notify(#"{"id":1,"guid":"g1","sender":"+15550002222","sender_name":"Ann","text":"hi there","is_from_me":false,"is_group":false}"#)
        await notify(#"{"id":2,"guid":"g2","sender":"+15550003333","text":"mine","is_from_me":true}"#)
        await notify(#"{"id":3,"guid":"g3","chat_id":9,"sender":"bob@icloud.com","text":"group hello","is_group":true,"reply_to_guid":"g1"}"#)
        await notify(#"{"id":4,"guid":"g4","sender":"+15550002222","text":"","is_reaction":true,"reaction_type":"love"}"#)
        await notify(#"{"id":1,"guid":"g1","sender":"+15550002222","text":"hi there"}"#)
        try await waitUntil("two inbound") { await collector.messages.count == 2 }

        let receipt = try await adapter.sendReturningReceipt(OutboundMessage(channel: .imessage, peerID: "+15550002222", text: "echo me"))
        #expect(receipt.primaryPlatformMessageID == "GUID-1")
        await notify(#"{"id":5,"guid":"g5","sender":"+15550002222","text":"echo me"}"#)
        await notify(#"{"id":6,"guid":"g6","sender":"+15550002222","text":"after"}"#)
        try await waitUntil("third inbound") { await collector.messages.count == 3 }
        #expect(await adapter.probe(timeoutMs: 1_000).ok)
        await adapter.stop()

        let messages = await collector.messages
        #expect(messages[0].peerID == "+15550002222")
        #expect(messages[0].senderName == "Ann")
        #expect(messages[0].chatType == .direct)
        #expect(messages[0].messageID == "g1")
        #expect(messages[1].peerID == "chat_id:9")
        #expect(messages[1].chatType == .group)
        #expect(messages[1].senderID == "bob@icloud.com")
        #expect(messages[1].replyToID == "g1")
        #expect(messages[2].text == "after")
        #expect(await pipe.requests("watch.unsubscribe").first?["subscription"] as? Int == 7)
    }
}

@Suite("iMessage private-API actions and catch-up", .timeLimit(.minutes(1)))
struct IMessagePrivateActionsTests {
    @Test
    func actionsUseChatGUIDFromInboundAndTypingDisablesAfterFailure() async throws {
        let pipe = FakeIMsgPipe { method, _ in
            switch method {
            case "watch.subscribe": return #""result":{"subscription":1}"#
            case "typing": return #""error":{"code":-32601,"message":"Method not found"}"#
            case "read", "tapback", "message.edit", "message.unsend": return #""result":{"ok":true}"#
            case "poll.send": return #""result":{"guid":"POLL-1"}"#
            default: return #""result":{}"#
            }
        }
        let config = IMessageChannelConfig(enabled: true)
        let adapter = IMessageChannelAdapter(config: config, transport: IMsgRPCTransport(config: config) { pipe })
        let collector = ChannelEventCollector()
        await adapter.setInboundHandler { await collector.append($0) }
        try await adapter.start()
        let message = #"{"id":7,"guid":"g7","sender":"+15550002222","text":"hi","chat_guid":"iMessage;-;+15550002222"}"#
        await pipe.push(.stdout(#"{"jsonrpc":"2.0","method":"message","params":{"message":\#(message)}}"#))
        try await waitUntil("inbound") { await collector.messages.count == 1 }
        #expect(await pipe.requests("read").first?["to"] as? String == "+15550002222")

        try await adapter.sendTypingIndicator(accountID: nil, peerID: "+15550002222")
        try await adapter.sendTypingIndicator(accountID: nil, peerID: "+15550002222")
        #expect(await pipe.requests("typing").count == 1)

        try await adapter.react(peerID: "+15550002222", messageID: "g7", emoji: "👍", remove: false)
        let tapback = try #require(await pipe.requests("tapback").first)
        #expect(tapback["chat_guid"] as? String == "iMessage;-;+15550002222")
        #expect(tapback["reaction"] as? String == "like")
        try await adapter.edit(peerID: "chat_guid:iMessage;+;chat9", messageID: "g8", text: "fixed")
        #expect(await pipe.requests("message.edit").first?["chat_guid"] as? String == "iMessage;+;chat9")
        let poll = try await adapter.sendPoll(peerID: "+15550002222", question: "Lunch?", options: ["Tacos", "Sushi"], allowMultiple: false)
        #expect(poll?.primaryPlatformMessageID == "POLL-1")
        await #expect(throws: ChannelMessageActionError.self) {
            try await adapter.unsend(peerID: "+15550009999", messageID: "x")
        }
        await adapter.stop()
    }

    @Test
    func catchupReplaysFromPersistedCursorWithinAgeAndLimit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("imsg-cursor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cursor = directory.appendingPathComponent("cursor")
        try Data("40".utf8).write(to: cursor)
        let pipe = FakeIMsgPipe { method, _ in method == "watch.subscribe" ? #""result":{"subscription":2}"# : #""result":{}"# }
        var config = IMessageChannelConfig(enabled: true)
        config.sendReadReceipts = false
        config.catchup = IMessageCatchupConfig(enabled: true, maxAgeMinutes: 60, perRunLimit: 1)
        let adapter = IMessageChannelAdapter(config: config, transport: IMsgRPCTransport(config: config) { pipe }, cursorFileURL: cursor)
        let collector = ChannelEventCollector()
        await adapter.setInboundHandler { await collector.append($0) }
        try await adapter.start()
        #expect(await pipe.requests("watch.subscribe").first?["since_rowid"] as? Int == 40)

        let formatter = ISO8601DateFormatter()
        let stale = formatter.string(from: Date().addingTimeInterval(-3 * 3_600))
        let recent = formatter.string(from: Date().addingTimeInterval(-5 * 60))
        for (id, created) in [(41, stale), (42, recent), (43, recent)] {
            let payload = #"{"id":\#(id),"guid":"c\#(id)","sender":"+15550002222","text":"m\#(id)","created_at":"\#(created)"}"#
            await pipe.push(.stdout(#"{"jsonrpc":"2.0","method":"message","params":{"message":\#(payload)}}"#))
        }
        let live = formatter.string(from: Date().addingTimeInterval(60))
        let livePayload = #"{"id":44,"guid":"c44","sender":"+15550002222","text":"live","created_at":"\#(live)"}"#
        await pipe.push(.stdout(#"{"jsonrpc":"2.0","method":"message","params":{"message":\#(livePayload)}}"#))
        try await waitUntil("two delivered") { await collector.messages.count == 2 }
        try await waitUntil("cursor persisted") { (try? String(contentsOf: cursor, encoding: .utf8)) == "44" }
        await adapter.stop()
        #expect(await collector.messages.map(\.text) == ["m42", "live"])
    }
}

/// Thread-safe counter for callbacks.
final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.count
    }

    func increment() {
        self.lock.lock()
        self.count += 1
        self.lock.unlock()
    }
}

#if os(macOS) || os(Linux)
@Suite("imsg process pipe")
struct IMsgProcessPipeTests {
    @Test
    func spawnsScriptAndExchangesNewlineDelimitedJSON() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("imsg-pipe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("imsg")
        let body = """
        #!/bin/sh
        [ "$1" = "rpc" ] && [ "$2" = "--json" ] || exit 64
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed 's/.*"id":\\([0-9]*\\).*/\\1/')
          printf '{"jsonrpc":"2.0","method":"message","params":{"message":{"id":%s}}}\\n' "$id"
          printf '{"jsonrpc":"2.0","id":%s,"result":{"echo":%s}}\\n' "$id" "$id"
        done
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let client = IMsgRPCClient(pipe: IMsgProcessPipe(cliPath: script.path))
        try await client.start()
        let first = try await client.request("ping", timeoutMs: 10_000)
        let second = try await client.request("ping", timeoutMs: 10_000)
        #expect(first.dictionaryValue?["echo"]?.intValue == 1)
        #expect(second.dictionaryValue?["echo"]?.intValue == 2)
        var iterator = client.notifications.makeAsyncIterator()
        #expect(await iterator.next()?.method == "message")
        await client.stop()
        #expect(await client.isRunning == false)
    }
}
#endif
