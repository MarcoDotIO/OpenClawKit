import Foundation
import Testing
import OpenClawCore
import OpenClawGateway
import OpenClawModels
import OpenClawProtocol
@testable import OpenClawAgents

/// Server event emission: runtime → `agent`/`chat`/`session.*`/`sessions.changed`, per-connection
/// session subscriptions, filters, and startup gating.
@Suite("Gateway event stream", .timeLimit(.minutes(1)))
struct GatewayEventStreamTests {
    private typealias Harness = GatewayServerTestHarness

    private static func toolTurns() -> [ScriptedToolProvider.Turn] {
        [
            ScriptedToolProvider.call("echo", id: "c1", ["text": AnyCodable("hi")]),
            ScriptedToolProvider.text("all done"),
        ]
    }

    @Test
    func runEmitsOrderedAgentEventsAndV4ChatEvents() async throws {
        let stack = await Harness.runtimeStack("events-order", turns: Self.toolTurns())
        let events = await stack.server.events()
        let sent = try Harness.payload(await Harness.call(stack.server, "chat.send", [
            "sessionKey": AnyCodable("agent:main:main"),
            "message": AnyCodable("hello"),
            "idempotencyKey": AnyCodable("client-run-1"),
        ]))
        #expect(sent["runId"] == AnyCodable("client-run-1"))
        #expect(sent["status"] == AnyCodable("in_flight"))

        let frames = try await Harness.collect(events, "final chat and lifecycle end") { frames in
            frames.contains { $0.event == "chat" && ["final", "error", "aborted"].contains($0.payload?.dictionaryValue?["state"]?.stringValue ?? "") }
                && frames.contains { $0.event == "sessions.changed" && $0.payload?.dictionaryValue?["phase"] == AnyCodable("end") }
        }
        // Server-global seq is contiguous.
        let seqs = frames.compactMap(\.seq)
        #expect(seqs == Array((seqs.first ?? 1)..<((seqs.first ?? 1) + seqs.count)))

        let agent = frames.filter { $0.event == "agent" }.compactMap { $0.payload?.dictionaryValue }
        #expect(agent.allSatisfy { $0["runId"] == AnyCodable("client-run-1") })
        let runSeqs = agent.compactMap { $0["seq"]?.intValue }
        #expect(runSeqs == Array(0..<runSeqs.count))
        let order = agent.map { payload -> String in
            let stream = payload["stream"]?.stringValue ?? ""
            let phase = payload["data"]?.dictionaryValue?["phase"]?.stringValue
            return phase.map { "\(stream):\($0)" } ?? stream
        }
        let expected = ["lifecycle:start", "tool:start", "tool:result", "assistant", "lifecycle:end"]
        let filtered = order.filter { expected.contains($0) }
        #expect(filtered == expected)

        let chat = Harness.chatFrames(frames, runID: "client-run-1")
        #expect(chat.first?.state == "status")
        #expect(chat.contains { $0.state == "delta" })
        guard case .final(let final)? = chat.last else {
            Issue.record("expected a final chat event, got \(chat.map(\.state))")
            return
        }
        #expect(final.sessionkey == "agent:main:main")
        #expect(final.agentid == "main")
        #expect(final.stopreason == "stop")
        #expect(final.message?.dictionaryValue?["content"]?.arrayValue?.first?.dictionaryValue?["text"] == AnyCodable("all done"))
        #expect(final.usage?.dictionaryValue?["totalTokens"] != nil)
        if case .delta(let delta)? = chat.first(where: { $0.state == "delta" }) {
            #expect(delta.deltatext == "all done")
            #expect(delta.message?.dictionaryValue?["role"] == AnyCodable("assistant"))
        }

        // Lifecycle sessions.changed start/end.
        let lifecycle = frames.filter { $0.event == "sessions.changed" }.compactMap { $0.payload?.dictionaryValue }
            .filter { $0["reason"] == AnyCodable("lifecycle") }
        #expect(lifecycle.first?["phase"] == AnyCodable("start"))
        #expect(lifecycle.first?["hasActiveRun"] == AnyCodable(true))
        #expect(lifecycle.last?["phase"] == AnyCodable("end"))
        #expect(lifecycle.last?["status"] == AnyCodable("done"))
        #expect(lifecycle.last?["hasActiveRun"] == AnyCodable(false))
    }

    @Test
    func sessionMessagesReachOnlySubscribedConnections() async throws {
        let stack = await Harness.runtimeStack("events-subscribe", turns: Self.toolTurns())
        let subscribedConnection = GatewayConnectionContext(connectionID: "conn-subscribed", scopes: [GatewayConnectionContext.operatorAdminScope])
        let otherConnection = GatewayConnectionContext(connectionID: "conn-other", scopes: [GatewayConnectionContext.operatorAdminScope])
        let subscribedRecorder = Harness.Recorder()
        let otherRecorder = Harness.Recorder()
        let subscribed = GatewayClient(
            socketFactory: { LoopbackGatewaySocket(server: stack.server, connection: subscribedConnection) },
            onEvent: { await subscribedRecorder.record($0) }
        )
        let other = GatewayClient(
            socketFactory: { LoopbackGatewaySocket(server: stack.server, connection: otherConnection) },
            onEvent: { await otherRecorder.record($0) }
        )
        try await subscribed.connect(to: GatewayEndpoint(url: URL(string: "ws://127.0.0.1:18789")!))
        try await other.connect(to: GatewayEndpoint(url: URL(string: "ws://127.0.0.1:18789")!))

        let ack = try await subscribed.send(method: "sessions.messages.subscribe", params: ["key": AnyCodable("agent:main:main")])
        #expect(ack.payload?.dictionaryValue?["subscribed"] == AnyCodable(true))
        #expect(await stack.server.sessionMessageSubscriptions(connectionID: "conn-subscribed") == ["agent:main:main"])

        let sent = try await subscribed.send(method: "sessions.send", params: ["key": AnyCodable("agent:main:main"), "message": AnyCodable("hello")])
        let runID = try #require(sent.payload?.dictionaryValue?["runId"]?.stringValue)

        let received = try await subscribedRecorder.waitFor("subscribed final chat and four session messages") { frames in
            frames.contains { $0.event == "chat" && $0.payload?.dictionaryValue?["state"] == AnyCodable("final") }
                && frames.filter { $0.event == "session.message" }.count >= 4
        }
        let messages = received.filter { $0.event == "session.message" }.compactMap { $0.payload?.dictionaryValue }
        #expect(messages.compactMap { $0["message"]?.dictionaryValue?["role"]?.stringValue } == ["user", "assistant", "toolResult", "assistant"])
        #expect(messages.compactMap { $0["messageSeq"]?.intValue } == [1, 2, 3, 4])
        #expect(messages.allSatisfy { $0["messageId"]?.stringValue != nil })
        #expect(received.contains { $0.event == "session.tool" && $0.payload?.dictionaryValue?["runId"] == AnyCodable(runID) })

        let otherFrames = try await otherRecorder.waitFor("other connection final chat") { frames in
            frames.contains { $0.event == "chat" && $0.payload?.dictionaryValue?["state"] == AnyCodable("final") }
        }
        #expect(otherFrames.contains { $0.event == "chat" })
        #expect(otherFrames.contains { $0.event == "session.message" } == false)
        #expect(otherFrames.contains { $0.event == "session.tool" } == false)

        let unsubscribed = try await subscribed.send(method: "sessions.messages.unsubscribe", params: ["key": AnyCodable("agent:main:main")])
        #expect(unsubscribed.payload?.dictionaryValue?["subscribed"] == AnyCodable(false))
        #expect(await stack.server.wantsSessionEvents(sessionKey: "agent:main:main") == false)
        await subscribed.disconnect()
        await other.disconnect()
    }

    @Test
    func lateSubscriberReceivesTheNextRunsPromptAndReply() async throws {
        let stack = await Harness.runtimeStack("events-late-subscribe", turns: [
            ScriptedToolProvider.text("first reply"),
            ScriptedToolProvider.text("second reply"),
        ])
        let chat = await stack.server.events(filter: .only(.chat))
        _ = try Harness.payload(await Harness.call(stack.server, "sessions.send", [
            "key": AnyCodable("agent:main:main"), "message": AnyCodable("one"),
        ]))
        _ = try await Harness.collect(chat, "first run final") { frames in frames.contains { $0.payload?.dictionaryValue?["state"] == AnyCodable("final") } }
        // Keep the second run's start strictly after the first run's rows (millisecond timestamps).
        try await Task.sleep(nanoseconds: 20_000_000)

        let connection = GatewayConnectionContext(connectionID: "conn-late", scopes: [GatewayConnectionContext.operatorAdminScope])
        // Connection-bound subscriptions follow the registered connection's role and scopes.
        await stack.server.connectionOpened(connection)
        let bound = await stack.server.events(filter: .connection("conn-late"))
        _ = try Harness.payload(await Harness.call(
            stack.server, "sessions.messages.subscribe", ["key": AnyCodable("agent:main:main")], connection: connection
        ))
        _ = try Harness.payload(await Harness.call(
            stack.server, "sessions.send", ["key": AnyCodable("agent:main:main"), "message": AnyCodable("two")], connection: connection
        ))
        let frames = try await Harness.collect(bound, "second run messages and final") { frames in
            frames.filter { $0.event == "session.message" }.count >= 2
                && frames.contains { $0.event == "chat" && $0.payload?.dictionaryValue?["state"] == AnyCodable("final") }
        }
        // The first sync anchors on the run start, so the second run's prompt is not skipped even when
        // it is persisted before the bridge handles the lifecycle start frame.
        let messages = frames.filter { $0.event == "session.message" }.compactMap { $0.payload?.dictionaryValue }
        #expect(messages.compactMap { $0["message"]?.dictionaryValue?["role"]?.stringValue } == ["user", "assistant"])
        #expect(messages.compactMap { $0["messageSeq"]?.intValue } == [3, 4])
        let prompt = messages.first?["message"]?.dictionaryValue?["content"]?.arrayValue?.first?.dictionaryValue?["text"]?.stringValue
        #expect(prompt?.contains("two") == true)
    }

    @Test
    func abortEmitsAbortedChatEventAndFiltersSelectEvents() async throws {
        let stack = await Harness.runtimeStack("events-abort", turns: [
            { _ in
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return ModelGenerationResponse(text: "late", providerID: "scripted")
            },
        ])
        let chatOnly = await stack.server.events(filter: .only(.chat))
        let accepted = try Harness.payload(await Harness.call(stack.server, "agent", [
            "message": AnyCodable("slow"), "idempotencyKey": AnyCodable("abort-me"), "sessionKey": AnyCodable("agent:main:slow"),
        ]))
        #expect(accepted["runId"] == AnyCodable("abort-me"))
        try await Task.sleep(nanoseconds: 50_000_000)
        let aborted = try Harness.payload(await Harness.call(stack.server, "chat.abort", ["sessionKey": AnyCodable("agent:main:slow")]))
        #expect(aborted["aborted"] == AnyCodable(true))
        #expect(aborted["runIds"] == AnyCodable([AnyCodable("abort-me")]))

        let frames = try await Harness.collect(chatOnly, "aborted chat event") { frames in
            frames.contains { $0.payload?.dictionaryValue?["state"] == AnyCodable("aborted") }
        }
        #expect(frames.allSatisfy { $0.event == "chat" })
        guard case .aborted(let event)? = Harness.chatFrames(frames, runID: "abort-me").last else {
            Issue.record("expected an aborted chat event")
            return
        }
        #expect(event.stopreason == "aborted")
        let waited = try Harness.payload(try await awaitCancellable("aborted run reported") {
            await Harness.call(stack.server, "agent.wait", ["runId": AnyCodable("abort-me")])
        })
        #expect(waited["status"] == AnyCodable("error"))
        #expect(waited["endedAt"]?.int64Value != nil)
    }

    @Test
    func typedEmitAndInProcessObserversOptIntoSessionMessages() async throws {
        let (server, _) = Harness.bareServer("events-emit")
        struct Note: Encodable { let kind: String }
        let all = await server.events()
        let frame = try await server.emit(event: "sdk.note", encoding: Note(kind: "hello"))
        #expect(frame.payload?.dictionaryValue?["kind"] == AnyCodable("hello"))
        #expect(await server.wantsSessionEvents(sessionKey: "s") == false)
        let observer = await server.events(filter: .only(.sessionMessage))
        #expect(await server.wantsSessionEvents(sessionKey: "s") == true)
        await server.broadcast(event: "session.message", payload: AnyCodable(["sessionKey": AnyCodable("s")]))
        let observed = try await Harness.collect(observer, "observed session.message") { !$0.isEmpty }
        #expect(observed.first?.event == "session.message")
        let seen = try await Harness.collect(all, "note and session.message") { $0.count >= 2 }
        #expect(seen.map(\.event) == ["sdk.note", "session.message"])
    }

    @Test
    func startupGatingAnswersRetryableUnavailableUntilReady() async throws {
        let (server, _) = Harness.bareServer("events-startup", startupPending: true)
        #expect(await server.isStartupPending())
        let gated = await Harness.call(server, "sessions.list")
        let error = try #require(gated.error)
        #expect(error.errorCode == .unavailable)
        #expect(error.isStartupUnavailable)
        #expect(error.retryafterms == GATEWAY_STARTUP_RETRY_AFTER_MS)
        #expect(error.message == "sessions.list unavailable during gateway startup")
        #expect(error.details?.dictionaryValue?["method"] == AnyCodable("sessions.list"))
        // Not startup-gated upstream: dispatches normally.
        #expect(await Harness.call(server, "sessions.patch", ["key": AnyCodable("main")]).ok)
        // Authorization still runs first.
        let reader = GatewayConnectionContext(role: "node")
        #expect(await Harness.call(server, "sessions.list", connection: reader).error?.errorCode == .invalidRequest)

        // A client retrying the startup error succeeds once startup completes.
        let client = GatewayClient(socketFactory: { LoopbackGatewaySocket(server: server) }, startupUnavailableRetryLimit: 10)
        try await client.connect(to: GatewayEndpoint(url: URL(string: "ws://127.0.0.1:18789")!))
        Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            await server.completeStartup()
        }
        let response = try await client.send(method: "sessions.list")
        #expect(response.ok)
        await client.disconnect()

        await server.beginStartup(gating: ["sessions.patch"])
        #expect(await Harness.call(server, "sessions.patch", ["key": AnyCodable("main")]).error?.isStartupUnavailable == true)
        #expect(await Harness.call(server, "sessions.list").ok)
        try await server.runStartup {}
        #expect(await server.isStartupPending() == false)
    }
}
