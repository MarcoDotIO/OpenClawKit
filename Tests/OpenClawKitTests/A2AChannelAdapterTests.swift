import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OpenClawChannels
import OpenClawCore
import OpenClawProtocol
import Testing

@Suite("A2A channel adapter")
struct A2AChannelAdapterTests {
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_800_000_000)

        func now() -> Date {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.value
        }

        func advance(_ seconds: TimeInterval) {
            self.lock.lock()
            self.value = self.value.addingTimeInterval(seconds)
            self.lock.unlock()
        }
    }

    static func config(_ configure: (inout A2AChannelConfig) -> Void = { _ in }) -> A2AChannelConfig {
        var config = A2AChannelConfig(
            enabled: true,
            advertisedUrl: "https://gw.example.com/",
            replyTimeoutMs: 5_000,
            peers: [
                "alice": A2APeerConfig(token: "alice-token", url: "https://alice.example.com/a2a/v1", outboundToken: "to-alice"),
                "bob": A2APeerConfig(token: "bob-token"),
            ]
        )
        configure(&config)
        return config
    }

    static func rpc(_ method: String, id: Any? = "1", params: [String: Any]? = nil) -> Data {
        var object: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let id {
            object["id"] = id
        }
        if let params {
            object["params"] = params
        }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    static func send(_ text: String, context: String? = nil, returnImmediately: Bool = false) -> [String: Any] {
        var message: [String: Any] = ["role": "ROLE_USER", "parts": [["text": text]], "messageId": "m-1"]
        if let context {
            message["contextId"] = context
        }
        return ["message": message, "configuration": ["returnImmediately": returnImmediately]]
    }

    static let alice = ["Authorization": "Bearer alice-token"]
    static let bob = ["authorization": "bearer bob-token"]

    // MARK: Protocol

    @Test
    func extractsTextAndDataPartsWithUpstreamSemantics() {
        func extract(_ json: String) -> String? {
            let parts = try! JSONDecoder().decode([AnyCodable].self, from: Data(json.utf8))
            return A2AProtocol.extractText(from: parts)
        }
        #expect(extract(#"[{"text":"hello"}]"#) == "hello")
        #expect(extract(#"[{"kind":"text","text":"hello"}]"#) == "hello")
        #expect(extract(#"[{"text":"hello"},{"data":{"count":2,"ready":true}}]"#) == "hello\n{\"count\":2,\"ready\":true}")
        #expect(extract(#"[{"data":null}]"#) == "null")
        #expect(extract(#"[{"url":"https://example.test/file"}]"#) == nil)
        #expect(extract(#"[{"raw":"aGVsbG8="}]"#) == nil)
        #expect(extract(#"[{"text":"  \n"}]"#) == nil)

        let long = A2AProtocol.extractText(from: [AnyCodable(["text": AnyCodable(String(repeating: "🦞", count: 20_000))])])
        #expect((long?.utf8.count ?? .max) <= 64 * 1_024)
        #expect(long?.hasSuffix("[message truncated at 65536 bytes]") == true)
    }

    @Test
    func routesMethodsAndValidatesContextIDs() {
        #expect(A2AProtocol.resolveMethod("SendMessage") == .sendMessage)
        #expect(A2AProtocol.resolveMethod("message/send") == .sendMessage)
        #expect(A2AProtocol.resolveMethod("tasks/get") == .getTask)
        #expect(A2AProtocol.resolveMethod("CancelTask") == .unsupported)
        #expect(A2AProtocol.resolveMethod("tasks/cancel") == .unsupported)
        #expect(A2AProtocol.resolveMethod("SendStreamingMessage") == .unsupported)
        #expect(A2AProtocol.resolveMethod("tasks/send") == nil)
        #expect(A2AProtocol.resolveMethod("constructor") == nil)
        #expect(A2AProtocol.isContextID("ctx-openclaw:peer_1.2"))
        #expect(!A2AProtocol.isContextID("../escape"))
        #expect(!A2AProtocol.isContextID(String(repeating: "a", count: 129)))
    }

    @Test
    func modelsRoundTripUpstreamWireShapes() throws {
        let json = #"{"id":"t1","contextId":"c1","status":{"state":"TASK_STATE_COMPLETED","timestamp":"2026-01-01T00:00:00.000Z"},"#
            + #""artifacts":[{"artifactId":"a1","parts":[{"text":"done"}]}],"history":[{"messageId":"m1","role":"user","parts":[{"data":{"k":1}}]}]}"#
        let task = try JSONDecoder().decode(A2ATask.self, from: Data(json.utf8))
        #expect(task.status.state == .completed)
        #expect(task.replyText == "done")
        #expect(task.history.first?.role == .user)
        #expect(task.history.first?.parts.first?.content == .data(AnyCodable(["k": AnyCodable(1)])))
        let encoded = String(decoding: try JSONEncoder().encode(task.history[0]), as: UTF8.self)
        #expect(encoded.contains(#""role":"ROLE_USER""#))
        let minimal = try JSONDecoder().decode(A2ATask.self, from: Data(#"{"id":"only"}"#.utf8))
        #expect(minimal.id == "only")
        #expect(minimal.status.state == .submitted)
    }

    // MARK: Task store

    @Test
    func taskStoreCorrelatesRepliesFIFOAndIsolatesPeers() async {
        let store = A2ATaskStore()
        let first = await store.create(contextId: "ctx", ownerPeer: "alice")
        let bobs = await store.create(contextId: "ctx", ownerPeer: "bob")
        let second = await store.create(contextId: "ctx", ownerPeer: "alice")
        #expect(await store.completeNext(contextId: "ctx", text: "one", ownerPeer: "alice")?.id == first.id)
        #expect(await store.completeNext(contextId: "ctx", text: "two", ownerPeer: "alice")?.id == second.id)
        #expect(await store.get(bobs.id, ownerPeer: "alice") == nil)
        #expect(await store.get(bobs.id, ownerPeer: "bob")?.status.state == .submitted)
        let empty = await store.completeNext(contextId: "ctx", text: " ", ownerPeer: "bob")
        #expect(empty?.artifacts.isEmpty == true)
        #expect(empty?.status.message?.text == "Agent completed without reply text")
    }

    @Test
    func taskStoreWaitReturnsWorkingOnTimeoutAndPrunesByRetention() async {
        let clock = Clock()
        let store = A2ATaskStore(now: { clock.now() })
        let task = await store.create(contextId: "ctx", ownerPeer: nil)
        await store.start(task.id)
        let waited = await store.wait(task.id, timeoutMs: 0)
        #expect(waited?.status.state == .working)
        #expect(await store.completeNext(contextId: "ctx", text: "late", ownerPeer: nil)?.status.state == .completed)

        for index in 0..<(A2ATaskStore.terminalMaxTasks + 1) {
            let extra = await store.create(contextId: "c\(index)", ownerPeer: nil)
            await store.fail(extra.id, reason: "x")
        }
        #expect(await store.get(task.id) == nil)
        let active = await store.create(contextId: "active", ownerPeer: nil)
        clock.advance(A2ATaskStore.terminalRetention + 1)
        #expect(await store.get(active.id) != nil)
        #expect(await store.count == 1)
    }

    // MARK: HTTP

    @Test
    func servesAgentCardOnBothDiscoveryPaths() async throws {
        let adapter = A2AChannelAdapter(config: Self.config { $0.exposeAgents = ["main"] }, agentIDs: ["main", "secret"], version: "9.9")
        for path in ["/.well-known/agent-card.json", "/.well-known/agent.json"] {
            let response = await adapter.handleHTTP(method: "GET", path: path, headers: [:], body: Data())
            #expect(response.status == 200)
            let card = try JSONDecoder().decode(A2AAgentCard.self, from: response.body)
            #expect(card.name == "OpenClaw")
            #expect(card.version == "9.9")
            #expect(card.supportedInterfaces == [A2AAgentCard.Interface(url: "https://gw.example.com/a2a/v1")])
            #expect(card.skills.map(\.id) == ["main"])
            #expect(card.skills.first?.description == "OpenClaw agent main.")
            #expect(card.capabilities.streaming == false)
        }
        let derived = A2AChannelAdapter(config: Self.config { $0.advertisedUrl = nil })
        #expect(await derived.agentCard(requestOrigin: "http://host:8080").supportedInterfaces.first?.url == "http://host:8080/a2a/v1")
    }

    @Test
    func rejectsUnauthenticatedAndUnknownRoutes() async throws {
        let adapter = A2AChannelAdapter(config: Self.config())
        try await adapter.start()
        let notFound = await adapter.handleHTTP(method: "GET", path: "/a2a/v1", headers: Self.alice, body: Data())
        #expect(notFound.status == 404)
        let unauthorized = await adapter.handleHTTP(method: "POST", path: "/a2a/v1", headers: ["Authorization": "Bearer nope"], body: Self.rpc("GetTask"))
        #expect(unauthorized.status == 401)
        let oversized = await adapter.handleHTTP(method: "POST", path: "/a2a/v1", headers: Self.alice, body: Data(count: 1_024 * 1_024 + 1))
        #expect(oversized.status == 413)
        let parse = await adapter.handleHTTP(method: "POST", path: "/a2a/v1", headers: Self.alice, body: Data("{".utf8))
        #expect(jsonObject(parse.bodyText)["error"].flatMap { ($0 as? [String: Any])?["code"] as? Int } == -32_700)
        let unsupported = await adapter.handleHTTP(method: "POST", path: "/a2a/v1", headers: Self.alice, body: Self.rpc("CancelTask", params: ["id": "x"]))
        #expect(jsonObject(unsupported.bodyText)["error"].flatMap { ($0 as? [String: Any])?["code"] as? Int } == -32_004)
        let unknown = await adapter.handleHTTP(method: "POST", path: "/a2a/v1", headers: Self.alice, body: Self.rpc("tasks/send"))
        #expect(jsonObject(unknown.bodyText)["error"].flatMap { ($0 as? [String: Any])?["code"] as? Int } == -32_601)
        await adapter.stop()
    }

    @Test
    func sendMessageDispatchesIsolatedSessionAndCompletesWithReply() async throws {
        let adapter = A2AChannelAdapter(config: Self.config())
        let collector = ChannelEventCollector()
        await adapter.setInboundHandler { message in
            await collector.append(message)
            try? await adapter.send(OutboundMessage(channel: .a2a, peerID: message.peerID, text: "reply to \(message.text)"))
        }
        try await adapter.start()
        let response = await adapter.handleHTTP(
            method: "POST",
            path: "/a2a/v1",
            headers: Self.alice,
            body: Self.rpc("SendMessage", id: 7, params: Self.send("do the thing", context: "ctx-1"))
        )
        await adapter.stop()

        #expect(response.status == 200)
        let object = jsonObject(response.bodyText)
        #expect(object["id"] as? Int == 7)
        let task = try #require((object["result"] as? [String: Any])?["task"] as? [String: Any])
        #expect((task["status"] as? [String: Any])?["state"] as? String == "TASK_STATE_COMPLETED")
        let artifacts = try #require(task["artifacts"] as? [[String: Any]])
        #expect((artifacts.first?["parts"] as? [[String: Any]])?.first?["text"] as? String == "reply to do the thing")
        let inbound = try #require(await collector.messages.first)
        #expect(inbound.channel == .a2a)
        #expect(inbound.peerID == "alice:ctx-1")
        #expect(inbound.senderID == "alice")
        #expect(inbound.chatType == .direct)
        #expect(inbound.messageID == "m-1")
    }

    @Test
    func slashMessagesAreRejectedAndReturnImmediatelyYieldsWorkingTask() async throws {
        let adapter = A2AChannelAdapter(config: Self.config())
        // The turn is still running while the task is polled (a returning handler fails the task).
        let gate = ChannelTestGate()
        await adapter.setInboundHandler { _ in await gate.wait() }
        defer { Task { await gate.open() } }
        try await adapter.start()
        let slash = await adapter.handleHTTP(method: "POST", path: "/a2a/v1", headers: Self.alice, body: Self.rpc("SendMessage", params: Self.send("/reset")))
        let slashTask = (jsonObject(slash.bodyText)["result"] as? [String: Any])?["task"] as? [String: Any]
        #expect((slashTask?["status"] as? [String: Any])?["state"] as? String == "TASK_STATE_REJECTED")

        let immediate = await adapter.handleHTTP(
            method: "POST",
            path: "/a2a/v1",
            headers: Self.alice,
            body: Self.rpc("message/send", params: Self.send("async", context: "ctx-2", returnImmediately: true))
        )
        let task = try #require((jsonObject(immediate.bodyText)["result"] as? [String: Any])?["task"] as? [String: Any])
        #expect((task["status"] as? [String: Any])?["state"] as? String == "TASK_STATE_WORKING")
        let taskID = try #require(task["id"] as? String)

        let polled = await adapter.handleHTTP(method: "POST", path: "/a2a/v1", headers: Self.alice, body: Self.rpc("tasks/get", params: ["id": taskID]))
        #expect((jsonObject(polled.bodyText)["result"] as? [String: Any])?["id"] as? String == taskID)
        let foreign = await adapter.handleHTTP(method: "POST", path: "/a2a/v1", headers: Self.bob, body: Self.rpc("GetTask", params: ["id": taskID]))
        #expect(jsonObject(foreign.bodyText)["error"].flatMap { ($0 as? [String: Any])?["code"] as? Int } == -32_001)
        await adapter.stop()
    }

    @Test
    func turnsThatEndWithoutAReplyFailSoLaterRepliesCompleteTheirOwnTask() async throws {
        let adapter = A2AChannelAdapter(config: Self.config())
        await adapter.setInboundHandler { message in
            // The first turn fails (for example a provider 429 swallowed by `try?`) and sends nothing.
            guard message.text != "first" else { return }
            try? await adapter.send(OutboundMessage(channel: .a2a, peerID: message.peerID, text: "reply to \(message.text)"))
        }
        try await adapter.start()
        func task(_ response: ChannelHTTPHandlerResponse) -> [String: Any]? {
            (jsonObject(response.bodyText)["result"] as? [String: Any])?["task"] as? [String: Any]
        }
        func post(_ text: String) async -> ChannelHTTPHandlerResponse {
            let body = Self.rpc("SendMessage", params: Self.send(text, context: "ctx-9"))
            return await adapter.handleHTTP(method: "POST", path: "/a2a/v1", headers: Self.alice, body: body)
        }
        let first = await post("first")
        let second = await post("second")
        await adapter.stop()

        let firstTask = try #require(task(first))
        #expect((firstTask["status"] as? [String: Any])?["state"] as? String == "TASK_STATE_FAILED")
        #expect((firstTask["artifacts"] as? [Any])?.isEmpty ?? true)
        let secondTask = try #require(task(second))
        #expect((secondTask["status"] as? [String: Any])?["state"] as? String == "TASK_STATE_COMPLETED")
        let artifacts = try #require(secondTask["artifacts"] as? [[String: Any]])
        #expect((artifacts.first?["parts"] as? [[String: Any]])?.first?["text"] as? String == "reply to second")
    }

    @Test
    func repliesHaveNoOutboundChunkingDefaults() {
        // The auto-reply engine only chunks channels with chunking defaults or a configured limit
        // (see `ChannelAutoReplyAccessTests.a2aRepliesCompleteTheirTaskWholeThroughTheEngine`).
        #expect(ChannelID.a2a.metadata.textChunking == nil)
        var channels = ChannelsConfig()
        channels.a2a = Self.config()
        #expect(channels.messagingPolicy(for: "a2a").textChunkLimit == nil)
    }

    @Test
    func rateLimitsPerPeerWithSlidingWindowAndBoundsBatches() async throws {
        let clock = Clock()
        let adapter = A2AChannelAdapter(config: Self.config { $0.rateLimitPerMinute = 2 }, now: { clock.now() })
        try await adapter.start()
        func code(_ response: ChannelHTTPHandlerResponse) -> Int? {
            jsonObject(response.bodyText)["error"].flatMap { ($0 as? [String: Any])?["code"] as? Int }
        }
        let body = Self.rpc("GetTask", params: ["id": "missing"])
        #expect(code(await adapter.handleHTTP(method: "POST", path: "/a2a/v1", headers: Self.alice, body: body)) == -32_001)
        #expect(code(await adapter.handleHTTP(method: "POST", path: "/a2a/v1", headers: Self.alice, body: body)) == -32_001)
        let limited = await adapter.handleHTTP(method: "POST", path: "/a2a/v1", headers: Self.alice, body: body)
        #expect(limited.status == 200)
        #expect(code(limited) == -32_000)
        #expect(code(await adapter.handleHTTP(method: "POST", path: "/a2a/v1", headers: Self.bob, body: body)) == -32_001)
        clock.advance(61)
        #expect(code(await adapter.handleHTTP(method: "POST", path: "/a2a/v1", headers: Self.alice, body: body)) == -32_001)

        let batch = try JSONSerialization.data(withJSONObject: (0..<31).map { ["jsonrpc": "2.0", "id": $0, "method": "GetTask"] as [String: Any] })
        let oversized = await adapter.handleHTTP(method: "POST", path: "/a2a/v1", headers: Self.bob, body: batch)
        #expect(code(oversized) == -32_000)
        await adapter.stop()
    }

    @Test
    func batchesSkipNotificationsAndNotificationOnlyRequestsReturnEmptyBody() async throws {
        let adapter = A2AChannelAdapter(config: Self.config { $0.rateLimitPerMinute = 0 })
        try await adapter.start()
        let batch = try JSONSerialization.data(withJSONObject: [
            ["jsonrpc": "2.0", "id": "a", "method": "GetTask", "params": ["id": "x"]],
            ["jsonrpc": "2.0", "method": "GetTask", "params": ["id": "x"]],
            ["jsonrpc": "1.0", "id": "b", "method": "GetTask"],
        ] as [[String: Any]])
        let response = await adapter.handleHTTP(method: "POST", path: "/a2a/v1", headers: Self.alice, body: batch)
        let entries = try #require(try JSONSerialization.jsonObject(with: response.body) as? [[String: Any]])
        #expect(entries.count == 2)
        #expect(entries[0]["id"] as? String == "a")
        #expect((entries[1]["error"] as? [String: Any])?["code"] as? Int == -32_600)

        let notificationBody = Self.rpc("GetTask", id: nil, params: ["id": "x"])
        let notification = await adapter.handleHTTP(method: "POST", path: "/a2a/v1", headers: Self.alice, body: notificationBody)
        #expect(notification.status == 200)
        #expect(notification.body.isEmpty)
        await adapter.stop()
    }

    @Test
    func accessPolicyAdmitsConfiguredPeersWithoutPairing() {
        var channels = ChannelsConfig()
        channels.a2a = Self.config()
        let policy = channels.messagingPolicy(for: "a2a")
        #expect(policy.dmPolicy == .allowlist)
        #expect(policy.allowFrom == ["alice", "bob"])
        let adapter = A2AChannelAdapter(config: A2AChannelConfig(enabled: true))
        #expect(adapter.configurationStatus.isConfigured == false)
    }

    // MARK: Outbound client

    @Test
    func clientSendsBearerSendMessageAndRetriesDottedMethodOnce() async throws {
        let http = ScriptedChannelHTTP()
        await http.on("/a2a/v1", json: #"{"jsonrpc":"2.0","id":"1","error":{"code":-32601,"message":"Method not found"}}"#)
        let accepted = #"{"jsonrpc":"2.0","id":"2","result":{"task":{"id":"remote-1","contextId":"ctx-oc-alice","#
            + #""status":{"state":"TASK_STATE_WORKING","timestamp":"t"}}}}"#
        await http.on("/a2a/v1", json: accepted)
        let adapter = A2AChannelAdapter(config: Self.config(), transport: http)
        try await adapter.start()
        let receipt = try await adapter.sendReturningReceipt(OutboundMessage(channel: .a2a, peerID: "a2a:alice", text: "hello peer"))
        await adapter.stop()

        #expect(receipt.primaryPlatformMessageID == "remote-1")
        let requests = await http.requests("/a2a/v1")
        #expect(requests.count == 2)
        #expect(requests[0].url == "https://alice.example.com/a2a/v1")
        #expect(requests[0].headers["Authorization"] == "Bearer to-alice")
        let first = jsonObject(requests[0].body)
        #expect(first["method"] as? String == "SendMessage")
        let message = try #require((first["params"] as? [String: Any])?["message"] as? [String: Any])
        #expect(message["contextId"] as? String == "ctx-oc-alice")
        #expect(message["role"] as? String == "ROLE_USER")
        #expect(((first["params"] as? [String: Any])?["configuration"] as? [String: Any])?["returnImmediately"] as? Bool == true)
        #expect(jsonObject(requests[1].body)["method"] as? String == "message/send")
    }

    @Test
    func clientRejectsMissingURLsRedirectsAndOtherErrors() async throws {
        let http = ScriptedChannelHTTP()
        await http.on("/redirect", response: HTTPResponseData(statusCode: 302, headers: ["Location": "https://evil.example.com"], body: Data()))
        await http.on("/err", json: #"{"jsonrpc":"2.0","id":"1","error":{"code":-32602,"message":"bad"}}"#)
        let client = A2AClient(
            peers: [
                "bob": A2APeerConfig(token: "t"),
                "redir": A2APeerConfig(token: "t", url: "https://r.example.com/redirect"),
                "err": A2APeerConfig(token: "t", url: "https://e.example.com/err"),
            ],
            transport: http
        )
        await #expect(throws: OpenClawCoreError.self) { _ = try await client.send(text: "x", to: "bob") }
        await #expect(throws: ChannelSendError.self) { _ = try await client.send(text: "x", to: "redir") }
        await #expect(throws: ChannelSendError.self) { _ = try await client.send(text: "x", to: "a2a:err") }
        #expect(await http.count("/err") == 1)
        #expect(await http.count("/redirect") == 1)
    }

    // Darwin only: swift-corelibs-foundation traps in `URLProtocolClient.urlProtocol(_:wasRedirectedTo:
    // redirectResponse:)`. Its URLSession does consult the session delegate's
    // `willPerformHTTPRedirection` for `data(for:)` (checked against a loopback 307 with the Swift 6.2
    // Linux image), which is what `ChannelNoRedirectHTTPTransport` relies on.
    #if canImport(Darwin)
    /// Serves `/a2a` as a 307 to `/attacker` and records every request (URLSession stub).
    final class RedirectingProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var requestedPaths: [String] = []
        static let lock = NSLock()

        override class func canInit(with _: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let url = self.request.url!
            Self.lock.withLock { Self.requestedPaths.append(url.path) }
            if url.path == "/a2a" {
                let target = URL(string: "https://attacker.example/attacker")!
                let redirect = HTTPURLResponse(url: url, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
                var next = self.request
                next.url = target
                self.client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: redirect)
                self.client?.urlProtocol(self, didReceive: redirect, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocolDidFinishLoading(self)
                return
            }
            let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            self.client?.urlProtocol(self, didReceive: ok, cacheStoragePolicy: .notAllowed)
            let payload = #"{"jsonrpc":"2.0","id":"1","result":{"task":{"id":"evil","contextId":"ctx-oc-redir","#
                + #""status":{"state":"TASK_STATE_COMPLETED"}}}}"#
            self.client?.urlProtocol(self, didLoad: Data(payload.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    @Test
    func defaultTransportRefusesRedirectsThroughARealURLSession() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectingProtocol.self]
        let client = A2AClient(
            peers: ["redir": A2APeerConfig(token: "t", url: "https://peer.example/a2a", outboundToken: "secret")],
            transport: ChannelNoRedirectHTTPTransport(configuration: configuration)
        )
        do {
            _ = try await client.send(text: "secret task text", to: "redir")
            Issue.record("expected the redirect to be refused")
        } catch let error as ChannelSendError {
            guard case .rejected(let status, _) = error else {
                Issue.record("expected rejected, got \(error)")
                return
            }
            #expect(status == 307)
        }
        let paths = RedirectingProtocol.lock.withLock { RedirectingProtocol.requestedPaths }
        #expect(paths == ["/a2a"])
        #expect(ChannelNoRedirectHTTPTransport.sameEndpoint(URL(string: "https://a.example/x")!, URL(string: "https://a.example:443/x")!))
        #expect(!ChannelNoRedirectHTTPTransport.sameEndpoint(URL(string: "https://a.example/x")!, URL(string: "https://b.example/x")!))
    }
    #endif

    @Test
    func replyWithoutPendingTaskIsRejected() async throws {
        let adapter = A2AChannelAdapter(config: Self.config())
        try await adapter.start()
        await #expect(throws: ChannelSendError.self) {
            try await adapter.send(OutboundMessage(channel: .a2a, peerID: "alice:ctx-none", text: "orphan"))
        }
        await adapter.stop()
    }
}
