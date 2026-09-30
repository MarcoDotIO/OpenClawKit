import Foundation
import Testing
import OpenClawCore
import OpenClawModels
import OpenClawProtocol
@testable import OpenClawAgents

/// Provider whose turns wait until released.
actor GatedTextProvider: ModelProvider {
    let id = "gated"
    nonisolated let capabilities = ModelProviderCapabilities(supportsTools: true, supportsTranscript: true)
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private(set) var generateCount = 0
    private var replies: [String]

    init(replies: [String]) {
        self.replies = replies
    }

    func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        self.generateCount += 1
        let reply = self.replies.isEmpty ? "reply" : self.replies.removeFirst()
        if !self.released {
            await withCheckedContinuation { self.waiters.append($0) }
        }
        return ModelGenerationResponse(text: reply, providerID: self.id)
    }

    func release() {
        self.released = true
        let pending = self.waiters
        self.waiters = []
        pending.forEach { $0.resume() }
    }

    func block() {
        self.released = false
    }

    func count() -> Int {
        self.generateCount
    }
}

/// Provider routing parent and sub-agent sessions to separate scripts.
actor RoleScriptedProvider: ModelProvider {
    let id = "roles"
    nonisolated let capabilities = ModelProviderCapabilities(supportsTools: true, supportsTranscript: true)
    private var parent: [ScriptedToolProvider.Turn]
    private var child: [ScriptedToolProvider.Turn]

    init(parent: [ScriptedToolProvider.Turn], child: [ScriptedToolProvider.Turn]) {
        self.parent = parent
        self.child = child
    }

    func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        if request.sessionKey.contains(":subagent:") {
            guard !self.child.isEmpty else { return ModelGenerationResponse(text: "child idle", providerID: self.id) }
            return try await self.child.removeFirst()(request)
        }
        guard !self.parent.isEmpty else { return ModelGenerationResponse(text: "parent idle", providerID: self.id) }
        return try await self.parent.removeFirst()(request)
    }
}

/// Sub-agent policy inheritance, the yield/completion race, run identity and 32-bit-safe durations.
@Suite("Sub-agent and runtime hardening")
struct SubagentRuntimeHardeningTests {
    // MARK: Sub-agent inheritance

    @Test(.timeLimit(.minutes(1)))
    func readOnlyParentSpawnsAReadOnlyChild() async throws {
        let store = temporarySessionStore("sub-inherit")
        let parent = "agent:main:main"
        _ = await store.resolveOrCreate(sessionKey: parent, defaultAgentID: "main", route: nil)
        _ = await store.update(forKey: parent) { record in
            record.permissionMode = .readOnly
            record.toolOverrides = SessionToolOverrides(mcpServers: ["x": false])
            record.sandboxMode = "off"
        }
        let log = ToolCallLog()
        let provider = ScriptedToolProvider(turns: [
            { _ in
                ModelGenerationResponse(
                    text: "",
                    providerID: "scripted",
                    toolCalls: [
                        ModelToolCall(id: "c1", name: "exec", arguments: [:]),
                        ModelToolCall(id: "c2", name: "write", arguments: [:]),
                        ModelToolCall(id: "c3", name: "x__lookup", arguments: [:]),
                    ]
                )
            },
            ScriptedToolProvider.text("child done"),
        ])
        let runtime = EmbeddedAgentRuntime(
            toolRegistry: AgentToolRegistry(tools: [
                RecordingTool(name: "exec", log: log),
                RecordingTool(name: "write", log: log),
                RecordingTool(name: "x__lookup", log: log, source: .mcp(server: "x", toolName: "lookup")),
                RecordingTool(name: "read", log: log),
            ]),
            modelRouter: ModelRouter(defaultProviderID: provider.id, providers: [provider]),
            sessionStore: store,
            transcriptStore: InMemorySessionTranscriptStore()
        )
        let manager = SubagentManager(runtime: runtime)
        let child = try await manager.spawn(SubagentSpawnParams(task: "run rm -rf build and write X"), parentSessionKey: parent)
        #expect(try await awaitCancellable("child run finished") { await runtime.wait(runID: child.runID) }?.status == "ok")

        let childRecord = try #require(await store.recordForKey(child.childSessionKey))
        #expect(childRecord.permissionMode == .readOnly)
        #expect(childRecord.toolOverrides?.mcpServers == ["x": false])
        #expect(childRecord.sandboxMode == "off")
        #expect(await log.calls.isEmpty)
        let offered = try #require(await provider.recorded().first?.tools.map(\.name))
        #expect(offered == ["read"])
        let results = toolResults(try await runtime.history(sessionKey: child.childSessionKey))
        #expect(results.count == 3)
        #expect(results.allSatisfy { $0.isError })
    }

    @Test(.timeLimit(.minutes(1)))
    func childInheritsTheParentRunsToolPolicy() async throws {
        let log = ToolCallLog()
        let store = temporarySessionStore("sub-run-policy")
        let provider = RoleScriptedProvider(
            parent: [
                ScriptedToolProvider.call("sessions_spawn", id: "s1", ["task": AnyCodable("do it")]),
                ScriptedToolProvider.text("parent done"),
            ],
            child: [ScriptedToolProvider.call("exec", id: "c1", [:]), ScriptedToolProvider.text("child done")]
        )
        let runtime = EmbeddedAgentRuntime(
            toolRegistry: AgentToolRegistry(tools: [RecordingTool(name: "exec", log: log)]),
            modelRouter: ModelRouter(defaultProviderID: provider.id, providers: [provider]),
            sessionStore: store,
            transcriptStore: InMemorySessionTranscriptStore()
        )
        let manager = SubagentManager(runtime: runtime)
        await manager.registerTools()
        let result = try await runtime.run(
            AgentRunRequest(sessionKey: "agent:main:main", prompt: "delegate", toolPolicy: ToolPolicy(deny: ["exec"])),
            timeoutMs: 3_600_000
        )
        #expect(result.output == "parent done")
        let child = try #require(await manager.children(of: "agent:main:main").first)
        #expect(try await awaitCancellable("child run finished") { await runtime.wait(runID: child.runID) }?.status == "ok")
        #expect(await log.count("exec") == 0)
        let results = toolResults(try await runtime.history(sessionKey: child.childSessionKey))
        #expect(results.first?.text == "Tool exec is not allowed by the current tool policy")
    }

    // MARK: Yield / completion race

    @Test
    func yieldAndCompletionAlwaysScheduleExactlyOneWake() async throws {
        let runtime = EmbeddedAgentRuntime()
        // Completion first: the yield sees the queued event and wakes at once.
        #expect(await runtime.enqueueInternalEventClaimingYield("done-a", sessionKey: "a") == false)
        #expect(await runtime.markYieldedUnlessEventsPending(sessionKey: "a"))
        // Yield first: the completion claims the yield once.
        #expect(await runtime.markYieldedUnlessEventsPending(sessionKey: "b") == false)
        #expect(await runtime.enqueueInternalEventClaimingYield("done-b1", sessionKey: "b"))
        #expect(await runtime.enqueueInternalEventClaimingYield("done-b2", sessionKey: "b") == false)
        #expect(await runtime.pendingInternalEvents(sessionKey: "b") == ["done-b1", "done-b2"])
        // Racing both sides many times: exactly one of them reports a wake.
        for index in 0..<300 {
            let key = "race-\(index)"
            async let yielded = runtime.markYieldedUnlessEventsPending(sessionKey: key)
            async let claimed = runtime.enqueueInternalEventClaimingYield("done", sessionKey: key)
            let (wakeFromYield, wakeFromCompletion) = await (yielded, claimed)
            #expect(wakeFromYield != wakeFromCompletion, "exactly one wake for \(key)")
        }
    }

    // MARK: Run identity

    @Test(.timeLimit(.minutes(1)))
    func duplicateRunIDsJoinTheActiveRun() async throws {
        let provider = GatedTextProvider(replies: ["first"])
        let runtime = EmbeddedAgentRuntime(
            toolRegistry: AgentToolRegistry(),
            modelRouter: ModelRouter(defaultProviderID: provider.id, providers: [provider])
        )
        await runtime.start(AgentRunRequest(runID: "dup", sessionKey: "one", prompt: "a"), streaming: false)
        try await waitUntil("first run reached the provider") { await provider.count() == 1 }
        await runtime.start(AgentRunRequest(runID: "dup", sessionKey: "two", prompt: "b"), streaming: false)
        #expect(await runtime.activeRunIDs() == ["dup"])
        await provider.release()
        #expect(try await awaitCancellable("joined run finished") { await runtime.wait(runID: "dup") }?.output == "first")
        #expect(await provider.count() == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func aStaleTimerNeverCancelsANewRunWithTheSameID() async throws {
        // The first run has to finish before its 200 ms timer so the timer is stale during the second
        // run. A stalled pool can let the timer win, so start over until the first run finishes first.
        var provider: GatedTextProvider
        var runtime: EmbeddedAgentRuntime
        var first: AgentRunWaitResult?
        repeat {
            provider = GatedTextProvider(replies: ["old", "new"])
            await provider.release()
            runtime = EmbeddedAgentRuntime(
                toolRegistry: AgentToolRegistry(),
                modelRouter: ModelRouter(defaultProviderID: provider.id, providers: [provider])
            )
            await runtime.start(AgentRunRequest(runID: "reuse", sessionKey: "s", prompt: "a"), timeoutMs: 200, streaming: false)
            first = try await awaitCancellable("first run finished") { [runtime] in await runtime.wait(runID: "reuse") }
        } while first?.status == "timeout"
        #expect(first?.output == "old")

        await provider.block()
        await runtime.start(AgentRunRequest(runID: "reuse", sessionKey: "s", prompt: "b"), streaming: false)
        let approval = await runtime.approvals.request(presentation: .exec(commandText: "make"), runID: "reuse")
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(await runtime.approvals.get(id: approval.id)?.state == .pending)
        #expect(await runtime.activeRunIDs() == ["reuse"])
        await provider.release()
        // The waiter sees the new run, not the previous run's retained result.
        let second = try await awaitCancellable("second run finished") { [runtime] in await runtime.wait(runID: "reuse") }
        #expect(second?.output == "new")
        _ = await runtime.approvals.cancel(id: approval.id)
    }

    // MARK: Session age on 32-bit Int

    @Test
    func hugeRunAndWaitTimeoutsDoNotTrap() async throws {
        let provider = ScriptedToolProvider(turns: [], fallback: ScriptedToolProvider.text("ok"))
        let runtime = EmbeddedAgentRuntime(
            toolRegistry: AgentToolRegistry(),
            modelRouter: ModelRouter(defaultProviderID: provider.id, providers: [provider])
        )
        let runID = await runtime.start(AgentRunRequest(sessionKey: "huge", prompt: "hi"), timeoutMs: Int.max)
        let waited = await runtime.wait(runID: runID, timeoutMs: Int.max)
        #expect(waited?.status == "ok")
        let result = try await runtime.run(AgentRunRequest(sessionKey: "huge", prompt: "again"), timeoutMs: Int.max)
        #expect(result.output == "ok")
    }

    @Test
    func sessionEndReportsTheAgeOfABackdatedTranscript() async throws {
        let directory = try RuntimeExtTestSupport.temporaryDirectory("backdated")
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = JSONLSessionTranscriptStore(directory: directory)
        let key = "agent:main:old"
        let sessionID = SessionTranscriptIdentity.sessionID(forKey: key)
        _ = try await transcript.createSession(id: sessionID, cwd: "", parentSession: nil)
        try await transcript.appendMessage(.userText("hello", timestamp: 1), sessionID: sessionID)
        let file = directory.appendingPathComponent("\(sessionID).jsonl")
        let text = try String(contentsOf: file, encoding: .utf8)
        let backdated = text.replacingOccurrences(
            of: #""timestamp":"[^"]*""#,
            with: #""timestamp":"1970-01-02T00:00:00.000Z""#,
            options: .regularExpression,
            range: text.startIndex..<(text.firstIndex(of: "\n") ?? text.endIndex)
        )
        try backdated.write(to: file, atomically: true, encoding: .utf8)
        await transcript.invalidateCache()

        let hooks = HookRegistry()
        let log = HookEventLog()
        await hooks.register(.sessionEnd) { context in
            await log.record(.sessionEnd, context)
            return nil
        }
        let runtime = EmbeddedAgentRuntime(transcriptStore: transcript, hookRegistry: hooks)
        #expect(try await runtime.deleteSession(sessionKey: key))
        let ended = try #require(await log.first(.sessionEnd))
        let duration = try #require(ended["durationMs"]?.int64Value)
        #expect(duration > Int64(Int32.max))
    }
}
