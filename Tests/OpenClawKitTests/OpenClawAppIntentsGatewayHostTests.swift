import Foundation
import Testing
import OpenClawAppIntents
import OpenClawKit

/// Scripted gateway transport for intent-host tests.
actor FakeIntentGatewayRequester: OpenClawIntentGatewayRequesting {
    struct Request: Sendable {
        let method: String
        let params: [String: AnyCodable]
        let wasCancelled: Bool
    }

    private var responses: [String: Data] = [:]
    private var failures: [String: String] = [:]
    private(set) var requests: [Request] = []

    func respond(to method: String, json: String) {
        self.responses[method] = Data(json.utf8)
    }

    func fail(_ method: String, message: String) {
        self.failures[method] = message
    }

    func request(method: String, params: [String: AnyCodable]?, timeoutMs: Double?) async throws -> Data {
        self.requests.append(Request(method: method, params: params ?? [:], wasCancelled: Task.isCancelled))
        if let message = self.failures[method] {
            throw GatewayResponseError(method: method, code: "UNAVAILABLE", message: message, details: nil)
        }
        return self.responses[method] ?? Data("{}".utf8)
    }

    func requests(for method: String) -> [Request] {
        self.requests.filter { $0.method == method }
    }
}

@Suite("App Intents gateway host")
struct OpenClawAppIntentsGatewayHostTests {
    private func chatEvent(_ fields: [String: String], message: AnyCodable? = nil) -> EventFrame {
        var payload = fields.mapValues { AnyCodable($0) }
        if let message {
            payload["message"] = message
        }
        return EventFrame(type: "event", event: "chat", payload: AnyCodable(payload))
    }

    private func collect(_ stream: AsyncThrowingStream<OpenClawIntentRunEvent, any Error>) async throws -> [OpenClawIntentRunEvent] {
        var events: [OpenClawIntentRunEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    @Test
    func sessionsListIsParsedLeniently() async throws {
        let requester = FakeIntentGatewayRequester()
        await requester.respond(to: "sessions.list", json: """
        {"sessions":[
          {"key":"main","kind":"direct","label":"Main chat","updatedAt":1800000000000,"agentId":"main"},
          {"key":"agent:main:telegram:group:1","kind":"group","derivedTitle":"Family"},
          {"key":"agent:main:slack:c1","kind":"direct","chatType":"channel","displayName":"#ops"},
          {"key":"  ","kind":"direct"},
          {"key":"k3","kind":"unknown","futureField":{"x":1}}
        ]}
        """)
        let host = GatewayOpenClawIntentHost(requester: requester)
        let sessions = try await host.sessions(matching: " fam ", limit: 10)
        #expect(sessions.map(\.sessionKey) == ["main", "agent:main:telegram:group:1", "agent:main:slack:c1", "k3"])
        #expect(sessions.map(\.title) == ["Main chat", "Family", "#ops", "k3"])
        #expect(sessions.map(\.isGroup) == [false, true, true, false])
        #expect(sessions[0].agentId == "main")
        #expect(sessions[0].updatedAt == Date(timeIntervalSince1970: 1_800_000_000))

        let request = try #require(await requester.requests(for: "sessions.list").first)
        #expect(request.params["search"]?.stringValue == "fam")
        #expect(request.params["limit"]?.intValue == 10)
        #expect(request.params["includeDerivedTitles"]?.boolValue == true)

        let resolved = try await host.sessions(forKeys: ["k3", "missing"])
        #expect(resolved.map(\.title) == ["k3", "missing"])
        #expect(await host.cachedSummary(for: "main")?.title == "Main chat")
    }

    @Test
    func agentsListHidesSystemAgents() async throws {
        let requester = FakeIntentGatewayRequester()
        await requester.respond(to: "agents.list", json: """
        {"defaultId":"main","mainKey":"main","scope":"global","agents":[
          {"id":"main","name":"Aiden","identity":{"emoji":"🐕"}},
          {"id":"setup","kind":"system","name":"Setup"},
          {"id":"coder","identity":{"name":"Coder"}}
        ]}
        """)
        let host = GatewayOpenClawIntentHost(requester: requester)
        let agents = try await host.agents()
        #expect(agents == [
            OpenClawIntentAgentSummary(agentId: "main", displayName: "Aiden", emoji: "🐕"),
            OpenClawIntentAgentSummary(agentId: "coder", displayName: "Coder"),
        ])
    }

    @Test
    func sendStreamsChatEventsUntilFinal() async throws {
        let requester = FakeIntentGatewayRequester()
        await requester.respond(to: "chat.send", json: #"{"runId":"r1","status":"started"}"#)
        let host = GatewayOpenClawIntentHost(
            requester: requester,
            configuration: .init(defaultSessionKey: "main", thinking: "low"))
        let stream = try await host.send(prompt: "  hello  ", sessionKey: nil, agentId: "coder")

        await host.ingest(self.chatEvent(["runId": "r1", "sessionKey": "main", "state": "status", "phase": "starting_model"]))
        await host.ingest(EventFrame(type: "event", event: "agent", payload: AnyCodable([
            "runId": AnyCodable("r1"), "stream": AnyCodable("tool"), "seq": AnyCodable(1), "ts": AnyCodable(1),
            "data": AnyCodable(["phase": AnyCodable("start"), "name": AnyCodable("exec"), "toolCallId": AnyCodable("t1")]),
        ])))
        // Events for other runs are ignored, even in the same session.
        await host.ingest(self.chatEvent(["runId": "other", "sessionKey": "main", "state": "final"]))
        await host.ingest(self.chatEvent(["runId": "r1", "sessionKey": "main", "state": "delta", "deltaText": "Hel"]))
        await host.ingest(.event(self.chatEvent(["runId": "r1", "sessionKey": "main", "state": "delta", "deltaText": "lo"])))
        await host.ingest(self.chatEvent(
            ["runId": "r1", "sessionKey": "main", "state": "final"],
            message: AnyCodable(["role": AnyCodable("assistant"), "content": AnyCodable([
                AnyCodable(["type": AnyCodable("thinking"), "thinking": AnyCodable("hmm")]),
                AnyCodable(["type": AnyCodable("text"), "text": AnyCodable("Hello!")]),
            ])])))

        let events = try await self.collect(stream)
        #expect(events.map(\.phase) == [.queued, .running, .running, .toolRunning, .streaming, .streaming, .completed])
        #expect(events.last?.text == "Hello!")
        #expect(events[5].text == "Hello")
        #expect(events.last?.fractionCompleted == 1)
        #expect(events.last?.runId == "r1")
        #expect(events.allSatisfy { $0.sessionKey == "main" })

        let send = try #require(await requester.requests(for: "chat.send").first)
        #expect(send.params["sessionKey"]?.stringValue == "main")
        #expect(send.params["message"]?.stringValue == "hello")
        #expect(send.params["agentId"]?.stringValue == "coder")
        #expect(send.params["thinking"]?.stringValue == "low")
        #expect(send.params["idempotencyKey"]?.stringValue?.isEmpty == false)
    }

    @Test
    func canonicalSessionKeysStillMatchOurRun() async throws {
        let requester = FakeIntentGatewayRequester()
        await requester.respond(to: "chat.send", json: #"{"status":"started"}"#)
        let host = GatewayOpenClawIntentHost(requester: requester)
        let stream = try await host.send(prompt: "hi", sessionKey: "main", agentId: nil)
        // Upstream runs are identified by the chat.send idempotency key, whatever key the gateway publishes.
        let runId = try #require(await requester.requests(for: "chat.send").first?.params["idempotencyKey"]?.stringValue)
        await host.ingest(self.chatEvent(["runId": runId, "sessionKey": "agent:main:main", "state": "delta", "deltaText": "A"]))
        await host.ingest(self.chatEvent(["runId": "r8", "sessionKey": "agent:main:main", "state": "final"]))
        await host.ingest(self.chatEvent(["runId": runId, "sessionKey": "agent:other:x", "state": "delta", "deltaText": "B"]))
        await host.ingest(self.chatEvent(["runId": runId, "sessionKey": "agent:main:main", "state": "final"]))
        let events = try await self.collect(stream)
        #expect(events.last?.phase == .completed)
        #expect(events.last?.text == "AB")
        #expect(events.last?.runId == runId)

        // A gateway whose ack names no run: the first post-ack event from exactly this session does.
        let second = try await host.send(prompt: "again", sessionKey: "main", agentId: nil)
        await host.ingest(self.chatEvent(["runId": "r-ops", "sessionKey": "agent:ops:main", "state": "status"]))
        await host.ingest(self.chatEvent(["runId": "r10", "sessionKey": "agent:main:main", "state": "status"]))
        await host.abort(sessionKey: "main")
        #expect(await requester.requests(for: "chat.abort").last?.params["runId"]?.stringValue == "r10")
        withExtendedLifetime(second) {}
    }

    @Test
    func errorAndAbortedEventsEndTheStream() async throws {
        let requester = FakeIntentGatewayRequester()
        await requester.respond(to: "chat.send", json: #"{"runId":"r2","status":"started"}"#)
        let host = GatewayOpenClawIntentHost(requester: requester)

        let failing = try await host.send(prompt: "fail", sessionKey: "s", agentId: nil)
        await host.ingest(self.chatEvent(["runId": "r2", "sessionKey": "s", "state": "error", "errorMessage": "boom"]))
        await #expect(throws: OpenClawIntentError.runFailed("boom")) {
            _ = try await self.collect(failing)
        }

        let aborted = try await host.send(prompt: "stop", sessionKey: "s", agentId: nil)
        await host.ingest(self.chatEvent(["runId": "r2", "sessionKey": "s", "state": "aborted"]))
        #expect(try await self.collect(aborted).last?.phase == .aborted)
    }

    @Test
    func sendFailuresAndEmptyPromptsThrow() async throws {
        let requester = FakeIntentGatewayRequester()
        await requester.fail("chat.send", message: "offline")
        let host = GatewayOpenClawIntentHost(requester: requester)
        await #expect(throws: GatewayResponseError.self) {
            _ = try await host.send(prompt: "hi", sessionKey: nil, agentId: nil)
        }
        await #expect(throws: OpenClawIntentError.emptyPrompt) {
            _ = try await host.send(prompt: "   ", sessionKey: nil, agentId: nil)
        }
    }

    @Test
    func runsTimeOut() async throws {
        let requester = FakeIntentGatewayRequester()
        await requester.respond(to: "chat.send", json: #"{"runId":"r3"}"#)
        let host = GatewayOpenClawIntentHost(requester: requester, configuration: .init(runTimeout: 0.05))
        let stream = try await host.send(prompt: "slow", sessionKey: nil, agentId: nil)
        await #expect(throws: OpenClawIntentError.timedOut) {
            _ = try await self.collect(stream)
        }
    }

    @Test
    func attachmentsAreSentAsBase64Payloads() async throws {
        let requester = FakeIntentGatewayRequester()
        await requester.respond(to: "chat.send", json: #"{"runId":"r4"}"#)
        let host = GatewayOpenClawIntentHost(requester: requester)
        _ = try await host.send(
            prompt: "describe",
            sessionKey: "s",
            agentId: nil,
            attachments: [
                OpenClawIntentAttachment(data: Data([0xFF, 0xD8]), mimeType: "image/jpeg", fileName: "a.jpg"),
                OpenClawIntentAttachment(data: Data("hi".utf8), mimeType: "", fileName: "b.bin"),
            ])
        let send = try #require(await requester.requests(for: "chat.send").first)
        let attachments = try #require(send.params["attachments"]?.arrayValue)
        #expect(attachments.count == 2)
        #expect(attachments[0].dictionaryValue?["type"]?.stringValue == "image")
        #expect(attachments[0].dictionaryValue?["content"]?.stringValue == Data([0xFF, 0xD8]).base64EncodedString())
        #expect(attachments[1].dictionaryValue?["type"]?.stringValue == "file")
        #expect(attachments[1].dictionaryValue?["mimeType"]?.stringValue == "application/octet-stream")
    }

    @Test
    func abortTargetsTheActiveRunEvenFromACancelledTask() async throws {
        let requester = FakeIntentGatewayRequester()
        await requester.respond(to: "chat.send", json: #"{"runId":"r5"}"#)
        let host = GatewayOpenClawIntentHost(requester: requester)
        _ = try await host.send(prompt: "long", sessionKey: "s", agentId: nil)

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await host.abort(sessionKey: "s")
        }
        await task.value

        let abort = try #require(await requester.requests(for: "chat.abort").first)
        #expect(abort.params["sessionKey"]?.stringValue == "s")
        #expect(abort.params["runId"]?.stringValue == "r5")
        #expect(!abort.wasCancelled)
    }

    @Test
    func consumeFeedsEventStreams() async throws {
        let requester = FakeIntentGatewayRequester()
        await requester.respond(to: "chat.send", json: #"{"runId":"r6"}"#)
        let host = GatewayOpenClawIntentHost(requester: requester)
        let stream = try await host.send(prompt: "hi", sessionKey: "s", agentId: nil)
        let (events, continuation) = AsyncStream<EventFrame>.makeStream()
        let consumer = host.consume(events)
        continuation.yield(self.chatEvent(["runId": "r6", "sessionKey": "s", "state": "final"], message: AnyCodable("done")))
        continuation.finish()
        #expect(try await self.collect(stream).last?.text == "done")
        await consumer.value
    }

    @Test
    func startTalkUsesTheConfiguredHandler() async throws {
        let requester = FakeIntentGatewayRequester()
        await #expect(throws: OpenClawIntentError.self) {
            try await GatewayOpenClawIntentHost(requester: requester).startTalk(sessionKey: nil)
        }
        let started = FakeIntentGatewayRequester()
        let host = GatewayOpenClawIntentHost(requester: requester) { key in
            _ = try await started.request(method: "talk.start", params: ["sessionKey": AnyCodable(key ?? "")], timeoutMs: nil)
        }
        try await host.startTalk(sessionKey: "s")
        #expect(await started.requests(for: "talk.start").first?.params["sessionKey"]?.stringValue == "s")
    }

    @Test
    func messageTextExtractionHandlesGatewayShapes() {
        #expect(OpenClawIntentMessageText.extract(from: nil) == nil)
        #expect(OpenClawIntentMessageText.extract(from: AnyCodable("plain")) == "plain")
        #expect(OpenClawIntentMessageText.extract(from: AnyCodable(["content": AnyCodable("c")])) == "c")
        #expect(OpenClawIntentMessageText.extract(from: AnyCodable(["text": AnyCodable("t")])) == "t")
        #expect(OpenClawIntentMessageText.extract(from: AnyCodable([
            AnyCodable(["type": AnyCodable("text"), "text": AnyCodable("a")]),
            AnyCodable(["type": AnyCodable("image"), "url": AnyCodable("x")]),
            AnyCodable(["type": AnyCodable("output_text"), "text": AnyCodable("b")]),
        ])) == "ab")
        #expect(OpenClawIntentMessageText.extract(from: AnyCodable(["content": AnyCodable([
            AnyCodable(["type": AnyCodable("image")]),
        ])])) == nil)
    }
}
