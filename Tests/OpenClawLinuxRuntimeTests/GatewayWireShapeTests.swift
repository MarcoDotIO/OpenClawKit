import Foundation
import Testing
import OpenClawCore
import OpenClawGateway
import OpenClawProtocol
@testable import OpenClawAgents

/// Legacy + upstream wire shapes of the in-process gateway (agent/agent.wait, session rows,
/// session mutations, chat events) and the built-in session lifecycle handlers.
@Suite("Gateway wire shapes", .timeLimit(.minutes(1)))
struct GatewayWireShapeTests {
    private typealias Harness = GatewayServerTestHarness

    actor RunRecorder {
        private(set) var requests: [GatewayAgentRequest] = []
        func record(_ request: GatewayAgentRequest) { self.requests.append(request) }
    }

    // MARK: - agent / agent.wait models

    @Test
    func agentRunIdKeysEncodeUpstreamAndDecodeBothSpellings() throws {
        let accepted = GatewayAgentAccepted(runID: "run-1", sessionKey: "main", agentID: "main", acceptedAt: 4_102_444_800_000)
        let encoded = try Harness.object(accepted)
        #expect(encoded["runId"] == AnyCodable("run-1"))
        #expect(encoded["runID"] == nil)
        #expect(encoded["agentId"] == AnyCodable("main"))
        #expect(encoded["acceptedAt"]?.int64Value == Int64(4_102_444_800_000))

        let legacy = try JSONDecoder().decode(GatewayAgentAccepted.self, from: Data(#"{"runID":"legacy","status":"accepted"}"#.utf8))
        #expect(legacy.runID == "legacy")
        #expect(legacy.acceptedAt == nil)

        let waitParams = try JSONDecoder().decode(GatewayAgentWaitParams.self, from: Data(#"{"runId":"r","timeoutMs":250}"#.utf8))
        #expect(waitParams.runID == "r")
        #expect(waitParams.timeoutMs == 250)
        let legacyWait = try JSONDecoder().decode(GatewayAgentWaitParams.self, from: Data(#"{"runID":"r2"}"#.utf8))
        #expect(legacyWait.runID == "r2")
        let encodedWait = try GatewayPayloadCodec.encode(GatewayAgentWaitParams(runID: "r3", timeoutMs: 5))
        let upstream = try GatewayPayloadCodec.decode(AgentWaitParams.self, from: encodedWait)
        #expect(upstream.runid == "r3")

        let result = GatewayAgentWaitResult(runID: "r", status: "ok", startedAt: 3_000_000_000_000, endedAt: 3_000_000_000_500)
        let resultObject = try Harness.object(result)
        #expect(resultObject["startedAt"]?.int64Value == Int64(3_000_000_000_000))
        let decoded = try JSONDecoder().decode(GatewayAgentWaitResult.self, from: Data(#"{"runID":"x","status":"timeout","startedAt":1.5e12}"#.utf8))
        #expect(decoded.runID == "x")
        #expect(decoded.startedAt == Int64(1_500_000_000_000))
        #expect(decoded.stamped(startedAt: 1, endedAt: 9).endedAt == Int64(9))
    }

    // MARK: - Session rows

    @Test
    func sessionInfoEncodesLegacyAndUpstreamKeys() throws {
        let info = GatewaySessionInfo(
            key: "agent:main:telegram:group:42",
            agentID: "main",
            updatedAtMs: 4_102_444_800_123,
            accountID: "acct",
            label: "Team",
            modelOverride: "openai/gpt-5.4",
            thinkingLevel: "high",
            sessionID: "sess-1",
            kind: "group",
            permissionMode: "guarded",
            traceLevel: "on",
            fastMode: "auto",
            archived: true,
            pinned: true,
            unread: true,
            archivedAtMs: 4_102_444_800_000,
            pinnedAtMs: 4_102_444_700_000,
            color: "blue",
            category: "Work",
            agentRuntime: "codex",
            totalTokens: 12,
            toolOverrides: AnyCodable(["webSearch": AnyCodable(false)])
        )
        let object = try Harness.object(info)
        #expect(object["agentID"] == AnyCodable("main"))
        #expect(object["agentId"] == AnyCodable("main"))
        #expect(object["updatedAtMs"]?.int64Value == Int64(4_102_444_800_123))
        #expect(object["updatedAt"]?.int64Value == Int64(4_102_444_800_123))
        #expect(object["accountID"] == AnyCodable("acct"))
        #expect(object["accountId"] == AnyCodable("acct"))
        #expect(object["kind"] == AnyCodable("group"))
        #expect(object["modelOverride"] == AnyCodable("openai/gpt-5.4"))
        #expect(object["model"] == AnyCodable("gpt-5.4"))
        #expect(object["modelProvider"] == AnyCodable("openai"))
        #expect(object["fastMode"] == AnyCodable("auto"))
        #expect(object["pinned"] == AnyCodable(true))
        #expect(object["archivedAt"]?.int64Value == Int64(4_102_444_800_000))
        #expect(object["agentRuntime"]?.dictionaryValue?["id"] == AnyCodable("codex"))
        #expect(object["permissionMode"] == AnyCodable("guarded"))

        // Round trip, and the upstream generated SessionRow decodes the same row.
        let roundTrip = try GatewayPayloadCodec.decode(GatewaySessionInfo.self, from: AnyCodable(object))
        #expect(roundTrip == info)
        let row = try GatewayPayloadCodec.decode(SessionRow.self, from: AnyCodable(object))
        #expect(row.key == info.key)
        #expect(row.pinned == true)
        #expect(row.permissionmode == .guarded)
        #expect(row.kind == AnyCodable("group"))
    }

    @Test
    func sessionInfoDecodesLegacyRowsAndUpstreamRows() throws {
        let legacy = try JSONDecoder().decode(
            GatewaySessionInfo.self,
            from: Data(#"{"key":"main","agentID":"assistant","updatedAtMs":42,"label":"Primary","execSecurity":"allowlist"}"#.utf8)
        )
        #expect(legacy.agentID == "assistant")
        #expect(legacy.updatedAtMs == Int64(42))
        #expect(legacy.execSecurity == "allowlist")
        #expect(legacy.archived == false)
        #expect(legacy.resolvedKind == "direct")

        let upstream = try JSONDecoder().decode(
            GatewaySessionInfo.self,
            from: Data(#"""
            {"key":"agent:ops:main","kind":"direct","agentId":"ops","updatedAt":1.7e12,"sessionId":"s","model":"claude","modelProvider":"anthropic",
             "fastMode":true,"archivedAt":1700000000000,"unread":true,"agentRuntime":{"id":"pi"},"previousSessionId":"old","spawnDepth":2}
            """#.utf8)
        )
        #expect(upstream.agentID == "ops")
        #expect(upstream.updatedAtMs == Int64(1_700_000_000_000))
        #expect(upstream.modelOverride == "anthropic/claude")
        #expect(upstream.fastMode == "on")
        #expect(upstream.archived == true)
        #expect(upstream.unread == true)
        #expect(upstream.agentRuntime == "pi")
        #expect(upstream.parentSessionID == "old")
        #expect(upstream.spawnDepth == 2)
    }

    @Test
    func mutationResultCarriesEntryAndArchived() throws {
        let result = GatewaySessionMutationResult(key: "k", deleted: true, entry: AnyCodable(["key": AnyCodable("k")]), archived: [])
        let object = try Harness.object(result)
        #expect(object["archived"] == AnyCodable([AnyCodable]()))
        #expect(object["entry"]?.dictionaryValue?["key"] == AnyCodable("k"))
        let upstream = try GatewayPayloadCodec.decode(SessionsDeleteResult.self, from: AnyCodable(object))
        #expect(upstream.deleted == true)
        #expect(upstream.archived.isEmpty)
    }

    // MARK: - ChatEventFrame

    @Test
    func chatEventFrameDecodesTheV4Union() throws {
        let delta = try ChatEventFrame(payload: try JSONDecoder().decode(
            AnyCodable.self,
            from: Data(#"{"runId":"r","sessionKey":"s","seq":3,"state":"delta","deltaText":"lo","replace":true,"message":{"role":"assistant"}}"#.utf8)
        ))
        guard case .delta(let event) = delta else {
            Issue.record("expected delta, got \(delta.state)")
            return
        }
        #expect(event.deltatext == "lo")
        #expect(event.replace == true)
        #expect(delta.runID == "r")
        #expect(delta.seq == 3)
        #expect(delta.isTerminal == false)

        let final = try ChatEventFrame(payload: AnyCodable([
            "runId": AnyCodable("r"), "sessionKey": AnyCodable("s"), "seq": AnyCodable(4), "state": AnyCodable("final"),
            "stopReason": AnyCodable("stop"), "yielded": AnyCodable(true),
        ]))
        guard case .final(let finalEvent) = final else {
            Issue.record("expected final")
            return
        }
        #expect(finalEvent.stopreason == "stop")
        #expect(final.isTerminal)

        let error = try ChatEventFrame(payload: AnyCodable([
            "runId": AnyCodable("r"), "sessionKey": AnyCodable("s"), "seq": AnyCodable(5), "state": AnyCodable("error"),
            "errorMessage": AnyCodable("boom"), "errorKind": AnyCodable("timeout"),
            "errorDetail": AnyCodable(["provider": AnyCodable("openai"), "httpStatus": AnyCodable(429)]),
        ]))
        guard case .error(let errorEvent) = error else {
            Issue.record("expected error")
            return
        }
        #expect(errorEvent.errordetail?["httpStatus"] == AnyCodable(429))

        let future = try ChatEventFrame(payload: AnyCodable(["runId": AnyCodable("r"), "state": AnyCodable("queued"), "seq": AnyCodable(1)]))
        #expect(future.state == "queued")
        #expect(future.runID == "r")
        let reencoded = try future.payload().dictionaryValue
        #expect(reencoded?["state"] == AnyCodable("queued"))

        let status = try ChatEventFrame(payload: AnyCodable([
            "runId": AnyCodable("r"), "sessionKey": AnyCodable("s"), "seq": AnyCodable(0), "state": AnyCodable("status"), "phase": AnyCodable("starting_model"),
        ]))
        guard case .status(let statusEvent) = status else {
            Issue.record("expected status")
            return
        }
        #expect(statusEvent.phase == .startingModel)
    }

    @Test
    func broadcastDeltaAppendsOrReplaces() {
        #expect(ChatEventFrame.broadcastDelta(text: "hello", previous: "") ?? ("", true) == ("hello", false))
        #expect(ChatEventFrame.broadcastDelta(text: "hello world", previous: "hello") ?? ("", true) == (" world", false))
        #expect(ChatEventFrame.broadcastDelta(text: "bye", previous: "hello") ?? ("", false) == ("bye", true))
        #expect(ChatEventFrame.broadcastDelta(text: "same", previous: "same") == nil)
        let message = ChatEventFrame.assistantMessage(text: "hi", timestampMs: 4_102_444_800_000)
        #expect(message.dictionaryValue?["timestamp"]?.int64Value == Int64(4_102_444_800_000))
    }

    // MARK: - Built-in agent

    @Test
    func agentAcceptsUpstreamParamsAndDedupesRetries() async throws {
        let recorder = RunRecorder()
        let (server, _) = Harness.bareServer("wire-agent", handlers: GatewayServerHandlers(runAgent: { params in
            await recorder.record(params)
            let runID = UUID().uuidString
            return GatewayAgentExecution(runID: runID, task: Task {
                GatewayAgentWaitResult(runID: runID, status: "ok", sessionKey: params.sessionKey, output: params.text)
            })
        }))
        let json = #"""
        {"message":"hello","idempotencyKey":"idem-1","sessionKey":"agent:ops:main","agentId":"ops","provider":"openai",
         "model":"gpt-5.4","timeout":2,"thinking":"high","extraSystemPrompt":"be brief","label":"Ops","promptMode":"minimal",
         "cwd":"/tmp","deliver":true,"channel":"telegram","to":"123"}
        """#
        let first = try await Harness.rawCall(server, "agent", json: json)
        let accepted = try Harness.payload(first)
        #expect(accepted["status"] == AnyCodable("accepted"))
        #expect(accepted["sessionKey"] == AnyCodable("agent:ops:main"))
        #expect(accepted["agentId"] == AnyCodable("ops"))
        #expect(accepted["acceptedAt"]?.int64Value != nil)
        let runID = try #require(accepted["runId"]?.stringValue)

        let retry = try await Harness.rawCall(server, "agent", json: json)
        #expect(try Harness.payload(retry)["runId"] == AnyCodable(runID))
        let recorded = await recorder.requests
        #expect(recorded.count == 1)
        let params = try #require(recorded.first)
        #expect(params.message == "hello")
        #expect(params.agentID == "ops")
        #expect(params.modelProviderID == "openai")
        #expect(params.modelID == "gpt-5.4")
        #expect(params.timeoutMs == 2_000)
        #expect(params.thinking == "high")
        #expect(params.extraSystemPrompt == "be brief")
        #expect(params.promptMode == "minimal")
        #expect(params.cwd == "/tmp")
        #expect(params.idempotencyKey == "idem-1")

        let waited = try Harness.payload(await Harness.call(server, "agent.wait", ["runId": AnyCodable(runID), "timeoutMs": AnyCodable(2_000)]))
        #expect(waited["status"] == AnyCodable("ok"))
        #expect(waited["output"] == AnyCodable("hello"))
        #expect(waited["startedAt"]?.int64Value != nil)
        #expect(waited["endedAt"]?.int64Value != nil)
        _ = try GatewayPayloadCodec.decode(GatewayAgentWaitResult.self, from: AnyCodable(waited))

        let missingMessage = await Harness.call(server, "agent", ["sessionKey": AnyCodable("main")])
        #expect(missingMessage.error?.errorCode == .invalidRequest)
    }

    @Test
    func agentWaitTimeoutKeepsTrackingAndLegacyKeyWorks() async throws {
        let (server, _) = Harness.bareServer("wire-wait", handlers: GatewayServerHandlers(runAgent: { params in
            let runID = "slow-run"
            return GatewayAgentExecution(runID: runID, task: Task {
                try await Task.sleep(nanoseconds: 150_000_000)
                return GatewayAgentWaitResult(runID: runID, status: "ok", sessionKey: params.sessionKey, output: "late")
            })
        }))
        _ = await Harness.call(server, "agent", ["message": AnyCodable("go"), "idempotencyKey": AnyCodable("k")])
        let timedOut = try Harness.payload(await Harness.call(server, "agent.wait", ["runId": AnyCodable("slow-run"), "timeoutMs": AnyCodable(1)]))
        #expect(timedOut["status"] == AnyCodable("timeout"))
        #expect(timedOut["startedAt"]?.int64Value != nil)
        #expect(timedOut["endedAt"] == nil)
        let done = try Harness.payload(await Harness.call(server, "agent.wait", ["runID": AnyCodable("slow-run"), "timeoutMs": AnyCodable(2_000)]))
        #expect(done["status"] == AnyCodable("ok"))
        #expect(done["output"] == AnyCodable("late"))
    }

    // MARK: - Built-in sessions

    @Test
    func sessionMutationsAcceptUpstreamKeysAndEmitSessionsChanged() async throws {
        let (server, store) = Harness.bareServer("wire-sessions")
        let events = await server.events(filter: .only(.sessionsChanged))
        let patched = try Harness.payload(await Harness.call(server, "sessions.patch", [
            "key": AnyCodable("agent:main:work"),
            "agentId": AnyCodable("main"),
            "model": AnyCodable("openai/gpt-5.4"),
            "pinned": AnyCodable(true),
            "category": AnyCodable("Work"),
            "permissionMode": AnyCodable("guarded"),
        ]))
        #expect(patched["ok"] == AnyCodable(true))
        #expect(patched["key"] == AnyCodable("agent:main:work"))
        #expect(patched["entry"]?.dictionaryValue?["permissionMode"] == AnyCodable("guarded"))
        let session = try #require(patched["session"]?.dictionaryValue)
        #expect(session["pinned"] == AnyCodable(true))
        #expect(session["modelOverride"] == AnyCodable("openai/gpt-5.4"))
        #expect(session["category"] == AnyCodable("Work"))
        #expect(await server.sessionGroups.contains("Work"))

        let reset = try Harness.payload(await Harness.call(server, "sessions.reset", [
            "key": AnyCodable("agent:main:work"), "agentId": AnyCodable("main"), "reason": AnyCodable("new"),
        ]))
        #expect(reset["session"]?.dictionaryValue?["sessionId"] != nil)

        let listed = try Harness.payload(await Harness.call(server, "sessions.list", ["agentId": AnyCodable("main")]))
        #expect(listed["count"] == AnyCodable(1))
        #expect(listed["ts"]?.int64Value != nil)
        #expect(listed["sessions"]?.arrayValue?.first?.dictionaryValue?["kind"] == AnyCodable("direct"))

        let deleted = try Harness.payload(await Harness.call(server, "sessions.delete", ["key": AnyCodable("agent:main:work")]))
        #expect(deleted["deleted"] == AnyCodable(true))
        #expect(deleted["archived"] == AnyCodable([AnyCodable]()))
        #expect(await store.recordForKey("agent:main:work") == nil)

        let frames = try await Harness.collect(events, "three sessions.changed frames") { $0.count >= 3 }
        let reasons = frames.compactMap { $0.payload?.dictionaryValue?["reason"]?.stringValue }
        #expect(reasons == ["create", "reset", "delete"])
        #expect(frames.first?.payload?.dictionaryValue?["session"]?.dictionaryValue?["pinned"] == AnyCodable(true))
    }

    @Test
    func builtinCreateSendAndAbortUseRunAgent() async throws {
        let recorder = RunRecorder()
        let (server, store) = Harness.bareServer("wire-create", handlers: GatewayServerHandlers(runAgent: { params in
            await recorder.record(params)
            let runID = UUID().uuidString
            return GatewayAgentExecution(runID: runID, task: Task {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return GatewayAgentWaitResult(runID: runID, status: "ok")
            })
        }))
        let created = try Harness.payload(await Harness.call(server, "sessions.create", [
            "agentId": AnyCodable("main"), "label": AnyCodable("New"), "message": AnyCodable("start"),
        ]))
        let key = try #require(created["key"]?.stringValue)
        #expect(key.hasPrefix("agent:main:dashboard:"))
        #expect(created["runStarted"] == AnyCodable(true))
        #expect(created["sessionId"]?.stringValue != nil)
        #expect(await store.recordForKey(key)?.label == "New")

        let sent = try Harness.payload(await Harness.call(server, "sessions.send", ["key": AnyCodable(key), "message": AnyCodable("more")]))
        #expect(sent["status"] == AnyCodable("started"))
        #expect(sent["runStarted"] == AnyCodable(true))
        let secondRun = try #require(sent["runId"]?.stringValue)
        #expect(await recorder.requests.map(\.message) == ["start", "more"])

        let aborted = try Harness.payload(await Harness.call(server, "sessions.abort", ["key": AnyCodable(key)]))
        #expect(aborted["status"] == AnyCodable("aborted"))
        #expect(aborted["abortedRunId"] == AnyCodable(secondRun))
        let none = try Harness.payload(await Harness.call(server, "sessions.abort", ["runId": AnyCodable("unknown")]))
        #expect(none["status"] == AnyCodable("no-active-run"))
    }

    @Test
    func cronStatusRejectsParamsOutsideTheClosedSchema() async throws {
        let (server, _) = Harness.bareServer("wire-cron")
        let scheduler = CronScheduler(storeURL: nil)
        await registerCronGatewayMethods(on: server, scheduler: scheduler)
        #expect(await Harness.call(server, "cron.status").ok)
        let extra = await Harness.call(server, "cron.status", ["agentId": AnyCodable("main")])
        #expect(extra.error?.errorCode == .invalidRequest)
        #expect(extra.error?.message.contains("agentId") == true)
    }
}
