import Foundation
import Testing
import OpenClawCore
import OpenClawGateway
import OpenClawModels
import OpenClawProtocol
@testable import OpenClawAgents

/// Provider that answers sub-agent sessions and parent sessions differently.
actor SessionRoutingProvider: ModelProvider {
    let id = "routing"
    nonisolated let capabilities = ModelProviderCapabilities(supportsTools: true, supportsTranscript: true)
    private var parentTurns = 0
    private(set) var parentPrompts: [String] = []

    func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        if request.sessionKey.contains(":subagent:") {
            return ModelGenerationResponse(text: "child result", providerID: self.id)
        }
        self.parentTurns += 1
        self.parentPrompts.append(request.messages.map(\.text).joined(separator: "\n"))
        switch self.parentTurns {
        case 1:
            return ModelGenerationResponse(
                text: "",
                providerID: self.id,
                toolCalls: [ModelToolCall(id: "spawn", name: "sessions_spawn", arguments: ["task": AnyCodable("research"), "taskName": AnyCodable("research")])]
            )
        case 2:
            return ModelGenerationResponse(text: "", providerID: self.id, toolCalls: [ModelToolCall(id: "yield", name: "sessions_yield", arguments: [:])])
        default:
            return ModelGenerationResponse(text: "parent resumed", providerID: self.id)
        }
    }

    func prompts() -> [String] {
        self.parentPrompts
    }
}

@Suite("Agent runtime extensions")
struct AgentRuntimeExtensionsTests {
    // MARK: - Exec gate

    @Test
    func execGateFollowsPermissionModes() async throws {
        let broker = ApprovalBroker()
        let gate = ExecApprovalGate(broker: broker, allowlist: { $0.hasPrefix("ls") })
        #expect(await gate.evaluate(command: "rm -rf /", permissionMode: .readOnly, sessionKey: "s") == .deny(
            reason: "Exec is denied in this session (permission mode read-only).",
            source: .policy
        ))
        #expect(await gate.evaluate(command: "rm x", permissionMode: .full, sessionKey: "s") == .allow(source: .fullAccess))
        #expect(await gate.evaluate(command: "ls -la", permissionMode: .guarded, sessionKey: "s") == .allow(source: .allowlist))
        #expect(await gate.evaluate(command: "make", permissionMode: nil, configuredMode: .allowlist, sessionKey: "s").isAllowed == false)

        // guarded: a human decides.
        let updates = await broker.updates()
        let resolver = Task {
            for await approval in updates where approval.state == .pending {
                _ = try? await broker.resolve(id: approval.id, decision: .deny)
                break
            }
        }
        let denied = await gate.evaluate(command: "git push", permissionMode: .guarded, sessionKey: "s")
        resolver.cancel()
        #expect(denied.isAllowed == false)
        // A denied command is closed and never re-presented.
        #expect(await gate.evaluate(command: "git  push", permissionMode: .guarded, sessionKey: "s") == .deny(
            reason: "This command was already denied in this session; choose a different approach.",
            source: .closed
        ))
        #expect(await broker.pending().isEmpty)
    }

    @Test
    func autoReviewDenialsReturnToAgentAndEscalateAfterThree() async throws {
        let broker = ApprovalBroker()
        let gate = ExecApprovalGate(broker: broker, reviewer: { request in
            request.command.contains("safe") ? .allow : .deny(reason: "too risky")
        })
        #expect(await gate.evaluate(command: "safe thing", permissionMode: .workspace, sessionKey: "w") == .allow(source: .reviewer))
        for index in 0..<3 {
            let decision = await gate.evaluate(command: "danger \(index)", permissionMode: .workspace, sessionKey: "w")
            guard case .deny(let reason, let source) = decision else {
                Issue.record("expected reviewer denial")
                return
            }
            #expect(source == .reviewer)
            #expect(reason.contains("too risky"))
        }
        #expect(await broker.pending().isEmpty)
        // The fourth command escalates to a human.
        let escalated = Task { await gate.evaluate(command: "danger 4", permissionMode: .workspace, sessionKey: "w") }
        var pending: [AgentApproval] = []
        for _ in 0..<100 {
            pending = await broker.pending()
            if !pending.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let approval = try #require(pending.first)
        #expect(approval.presentation.warningText?.contains("Escalated") == true)
        _ = try await broker.resolve(id: approval.id, decision: .allowOnce)
        #expect(await escalated.value == .allow(source: .human))

        let failing = ExecApprovalGate(broker: broker, reviewer: { _ in
            struct ReviewDown: Error {}
            throw ReviewDown()
        })
        let asking = Task { await failing.evaluate(command: "anything", permissionMode: .workspace, sessionKey: "f") }
        for _ in 0..<100 where await broker.pending().isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let failed = try #require(await broker.pending().first)
        #expect(failed.presentation.warningText?.contains("Automatic review failed") == true)
        await broker.cancel(runID: "none")
        _ = await broker.cancel(id: failed.id)
        #expect(await asking.value.isAllowed == false)
    }

    @Test
    func backfillReconcilerNeitherLosesNorResurrects() {
        var reconciler = ApprovalBackfillReconciler()
        reconciler.applyRequested(id: "b", payload: ["id": AnyCodable("b")])
        reconciler.applyResolved(id: "a")
        reconciler.applyList([["id": AnyCodable("a")], ["id": AnyCodable("c")]])
        #expect(reconciler.pendingIDs == ["b", "c"])
        reconciler.applyResolved(id: "c")
        reconciler.applyRequested(id: "c", payload: [:])
        #expect(reconciler.pendingIDs == ["b"])
    }

    // MARK: - Sub-agents and ledger

    @Test
    func spawnAnnouncesCompletionAndWakesTheYieldedParent() async throws {
        let provider = SessionRoutingProvider()
        let store = SessionStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("sub-\(UUID().uuidString)/sessions.json"))
        let runtime = EmbeddedAgentRuntime(
            toolRegistry: AgentToolRegistry(),
            modelRouter: ModelRouter(defaultProviderID: provider.id, providers: [provider]),
            sessionStore: store,
            transcriptStore: InMemorySessionTranscriptStore()
        )
        let ledger = TaskLedger()
        await ledger.attach(to: runtime)
        let manager = SubagentManager(runtime: runtime, ledger: ledger)
        await manager.registerTools()

        let result = try await runtime.run(AgentRunRequest(sessionKey: "agent:main:main", prompt: "delegate"), timeoutMs: 10_000)
        #expect(result.toolResults.map(\.name) == ["sessions_spawn", "sessions_yield"])
        let spawnDetails = try #require(result.toolResults.first?.output.details?.dictionaryValue)
        #expect(spawnDetails["status"] == AnyCodable("accepted"))
        let childKey = try #require(spawnDetails["childSessionKey"]?.stringValue)
        #expect(SessionKey.isSubagentKey(childKey))
        #expect(await store.recordForKey(childKey)?.spawnedBy == "agent:main:main")
        #expect(await store.recordForKey(childKey)?.spawnDepth == 1)

        var prompts: [String] = []
        for _ in 0..<300 {
            prompts = await provider.prompts()
            if prompts.contains(where: { $0.contains("child result") }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(prompts.contains { $0.contains("[Subagent completion]") && $0.contains("child result") })

        let tasks = await ledger.list().tasks
        #expect(tasks.count == 1)
        #expect(tasks.first?.kind == .subagent)
        for _ in 0..<100 where await ledger.list().tasks.first?.status.isTerminal != true {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await ledger.list().tasks.first?.status == .completed)
        #expect(await ledger.list(statuses: [.running]).tasks.isEmpty)
        let children = await manager.children(of: "agent:main:main")
        #expect(children.first?.status == "ok")

        // Nested spawns beyond the depth limit are rejected.
        do {
            try await manager.spawn(SubagentSpawnParams(task: "deeper"), parentSessionKey: childKey)
            Issue.record("expected depth limit")
        } catch let error as SubagentError {
            #expect(error.errorDescription?.contains("depth") == true)
        }
    }

    @Test
    func spawnParamsRejectUnsupportedOptionsAndKillWorks() async throws {
        #expect(throws: SubagentError.self) { try SubagentSpawnParams.parse(["task": AnyCodable("x"), "runtime": AnyCodable("acp")]) }
        #expect(throws: SubagentError.self) { try SubagentSpawnParams.parse(["task": AnyCodable("x"), "visible": AnyCodable(true)]) }
        #expect(throws: SubagentError.self) { try SubagentSpawnParams.parse(["task": AnyCodable("x"), "taskName": AnyCodable("Bad Name")]) }
        #expect(throws: SubagentError.self) { try SubagentSpawnParams.parse(["task": AnyCodable(" ")]) }
        let parsed = try SubagentSpawnParams.parse(["task": AnyCodable("x"), "context": AnyCodable("fork"), "cleanup": AnyCodable("delete")])
        #expect(parsed.context == .fork)
        #expect(parsed.deleteOnCompletion)

        let slow = ScriptedToolProvider(turns: [], fallback: { _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return ModelGenerationResponse(text: "late", providerID: "scripted")
        })
        let transcript = InMemorySessionTranscriptStore()
        let runtime = EmbeddedAgentRuntime(modelRouter: ModelRouter(defaultProviderID: slow.id, providers: [slow]), transcriptStore: transcript)
        // Parent history large enough to exceed a tiny fork cap.
        let parentID = SessionTranscriptIdentity.sessionID(forKey: "p")
        try await transcript.ensureSession(id: parentID)
        _ = try await transcript.appendMessage(.userText(String(repeating: "context ", count: 400), timestamp: 1), sessionID: parentID)
        let manager = SubagentManager(runtime: runtime, configuration: SubagentConfiguration(forkMaxTokens: 10))
        let record = try await manager.spawn(SubagentSpawnParams(task: "work", taskName: "worker", context: .fork), parentSessionKey: "p")
        #expect(record.context == .isolated)
        #expect(await manager.resolve(target: "work", parentSessionKey: "p").map(\.taskName) == ["worker"])
        #expect(await manager.resolve(target: "1", parentSessionKey: "p").count == 1)
        let killed = try await manager.kill(target: "last", parentSessionKey: "p")
        #expect(killed.map(\.status) == ["killed"])
        #expect(await runtime.wait(runID: record.runID, timeoutMs: 2_000)?.status == "error")
    }

    @Test
    func ledgerTracksEventsAndServesRPCs() async throws {
        let ledger = TaskLedger()
        let task = await ledger.create(kind: .tool, title: "Export", sessionKey: "s", runID: "run-1")
        let now = SessionTranscriptClock.nowMs()
        await ledger.observe(AgentEventFrame(runID: "run-1", seq: 0, stream: .lifecycle, ts: now, data: ["phase": AnyCodable("start")]))
        await ledger.observe(
            AgentEventFrame(runID: "run-1", seq: 1, stream: .tool, ts: now, data: ["phase": AnyCodable("start"), "name": AnyCodable("read")])
        )
        var record = try #require(await ledger.get(id: task.id))
        #expect(record.status == .running)
        #expect(record.toolUseCount == 1)
        #expect(record.execution?.currentTool?.name == "read")
        await ledger.observe(
            AgentEventFrame(runID: "run-1", seq: 2, stream: .lifecycle, ts: now, data: ["phase": AnyCodable("error"), "timedOut": AnyCodable(true)])
        )
        record = try #require(await ledger.get(id: task.id))
        #expect(record.status == .timedOut)
        let wire = try JSONEncoder().encode(AnyCodable(record.payload(includeDetails: true)))
        _ = try JSONDecoder().decode(TaskSummary.self, from: wire)

        let ledgerStore = SessionStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString).json"))
        let server = GatewayServer(sessionStore: ledgerStore, secretVault: GatewaySecretVault(credentialStore: InMemoryTestCredentialStore()))
        await ledger.attach(to: server, runtime: EmbeddedAgentRuntime())
        let listed = await server.handle(RequestFrame(type: "req", id: "1", method: "tasks.list", params: AnyCodable(["status": AnyCodable("timed_out")])))
        #expect(listed.payload?.dictionaryValue?["tasks"]?.arrayValue?.count == 1)
        let fetched = await server.handle(RequestFrame(type: "req", id: "2", method: "tasks.get", params: AnyCodable(["taskId": AnyCodable(task.id)])))
        #expect(fetched.payload?.dictionaryValue?["task"]?.dictionaryValue?["title"] == AnyCodable("Export"))
        let cancelled = await server.handle(RequestFrame(type: "req", id: "3", method: "tasks.cancel", params: AnyCodable(["taskId": AnyCodable(task.id)])))
        #expect(cancelled.payload?.dictionaryValue?["found"] == AnyCodable(true))
        #expect(cancelled.payload?.dictionaryValue?["cancelled"] == AnyCodable(false))
    }

    // MARK: - Goals

    @Test
    func goalToolsAndRPCIdempotency() async throws {
        let store = SessionStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("goals-\(UUID().uuidString)/sessions.json"))
        _ = await store.resolveOrCreate(sessionKey: "g", defaultAgentID: "main", route: nil)
        let manager = SessionGoalManager(store: store)
        let tools = SessionGoalTools.tools(manager: manager)
        let context = AgentToolInvocationContext(sessionKey: "g")
        let create = try #require(tools.first { $0.name == "create_goal" })
        let createArguments: [String: AnyCodable] = ["objective": AnyCodable("Ship it"), "tokenBudget": AnyCodable(10)]
        let created = try await create.invoke(AgentToolInvocation(arguments: createArguments, context: context), update: nil)
        #expect(created.isError == false)
        let again = try await create.invoke(AgentToolInvocation(arguments: ["objective": AnyCodable("Other")], context: context), update: nil)
        #expect(again.isError)

        let goal = try #require(await manager.goal(sessionKey: "g"))
        #expect(goal.promptLine == "Current session goal: Ship it (active)")
        await store.recordUsage(tokens: 25, forKey: "g")
        #expect(await manager.goal(sessionKey: "g")?.status == .budgetLimited)

        let server = GatewayServer(sessionStore: store, secretVault: GatewaySecretVault(credentialStore: InMemoryTestCredentialStore()))
        await manager.registerGatewayMethods(on: server)
        let params: [String: AnyCodable] = [
            "sessionKey": AnyCodable("g"),
            "goalId": AnyCodable(goal.id),
            "operationId": AnyCodable("op-1"),
            "issuedAtMs": AnyCodable(1),
            "action": AnyCodable("complete"),
            "note": AnyCodable("done"),
        ]
        let first = await server.handle(RequestFrame(type: "req", id: "1", method: "sessions.goal.update", params: AnyCodable(params)))
        #expect(first.payload?.dictionaryValue?["status"] == AnyCodable("updated"))
        #expect(first.payload?.dictionaryValue?["goal"]?.dictionaryValue?["status"] == AnyCodable("complete"))
        let replay = await server.handle(RequestFrame(type: "req", id: "2", method: "sessions.goal.update", params: AnyCodable(params)))
        #expect(replay.payload?.dictionaryValue?["replayed"] == AnyCodable(true))
        var clear = params
        clear["operationId"] = AnyCodable("op-2")
        clear["action"] = nil
        let cleared = await server.handle(RequestFrame(type: "req", id: "3", method: "sessions.goal.clear", params: AnyCodable(clear)))
        #expect(cleared.payload?.dictionaryValue?["status"] == AnyCodable("cleared"))
        #expect(await manager.goal(sessionKey: "g") == nil)
    }

    // MARK: - Progress cards

    @Test
    func progressCardsValidateRevisionsAndRefreshHidden() async throws {
        let store = ProgressCardStore()
        let tool = store.tool
        let output = try await tool.invoke(
            AgentToolInvocation(
                arguments: [
                    "markdown": AnyCodable("Working"),
                    "plan": AnyCodable([AnyCodable(["step": AnyCodable("a"), "status": AnyCodable("in_progress")])]),
                ],
                context: AgentToolInvocationContext(sessionKey: "pc")
            ),
            update: nil
        )
        #expect(output.isError == false)
        #expect(await store.card(sessionKey: "pc")?.revision == 1)
        do {
            try await store.put(sessionKey: "pc", markdown: "x", steps: nil, expectedRevision: 5)
            Issue.record("expected revision conflict")
        } catch let error as ProgressCardError {
            #expect(error == .revisionConflict(expected: 5, actual: 1))
        }
        let badStep = try await tool.invoke(
            AgentToolInvocation(
                arguments: ["plan": AnyCodable([AnyCodable(["step": AnyCodable("a"), "status": AnyCodable("done")])])],
                context: AgentToolInvocationContext(sessionKey: "pc")
            ),
            update: nil
        )
        #expect(badStep.isError)

        let provider = ScriptedToolProvider(turns: [ScriptedToolProvider.text("refreshed")])
        let transcript = InMemorySessionTranscriptStore()
        let runtime = EmbeddedAgentRuntime(modelRouter: ModelRouter(defaultProviderID: provider.id, providers: [provider]), transcriptStore: transcript)
        let server = GatewayServer(
            sessionStore: SessionStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("pc-\(UUID().uuidString).json")),
            secretVault: GatewaySecretVault(credentialStore: InMemoryTestCredentialStore())
        )
        await store.attach(to: server, runtime: runtime)
        let fetched = await server.handle(RequestFrame(type: "req", id: "1", method: "progressCard.get", params: AnyCodable(["sessionKey": AnyCodable("pc")])))
        #expect(fetched.payload?.dictionaryValue?["card"]?.dictionaryValue?["revision"] == AnyCodable(1))
        let refresh = await server.handle(
            RequestFrame(
                type: "req",
                id: "2",
                method: "progressCard.refresh",
                params: AnyCodable(["sessionKey": AnyCodable("pc"), "idempotencyKey": AnyCodable("k1")])
            )
        )
        let runID = try #require(refresh.payload?.dictionaryValue?["runId"]?.stringValue)
        #expect(await runtime.wait(runID: runID, timeoutMs: 5_000)?.status == "ok")
        // The refresh instruction is hidden from chat history.
        #expect(try await runtime.history(sessionKey: "pc").map(\.role) == ["assistant"])
    }

    // MARK: - Tool search

    @Test
    func toolSearchRanksAndCapsDirectory() {
        let descriptors = (0..<20).map { index in
            AgentToolDescriptor(name: "tool_\(index)", description: index == 7 ? "Convert currency amounts between codes" : "Generic helper \(index)")
        } + [
            AgentToolDescriptor(name: "read", description: "Read file contents"),
            AgentToolDescriptor(name: "docs__search", description: "Search docs", source: .mcp(server: "docs", toolName: "search")),
        ]
        let catalog = ToolSearchCatalog(descriptors: descriptors, configuration: .embeddedDefault)
        #expect(catalog.isActive)
        let visible = catalog.modelVisibleDescriptors.map(\.name)
        #expect(visible.contains("read"))
        #expect(visible.contains("tool_search"))
        #expect(visible.contains("tool_7") == false)
        #expect(catalog.search("currency conversion", limit: 3).first?.id == "tool_7")
        #expect(catalog.search("docs", limit: 5).first?.searchDescription.hasPrefix("[untrusted mcp tool metadata]") == true)
        let directory = catalog.directoryPrompt() ?? ""
        #expect(directory.contains("docs__search") == false)
        #expect(directory.count <= ToolSearchConfiguration.maxDirectoryChars)

        let batch = catalog.runSearch(["queries": AnyCodable((0..<17).map { _ in AnyCodable(["query": AnyCodable("x")]) })])
        #expect(batch.isError)
        let tooMany = catalog.runSearch(["queries": AnyCodable([AnyCodable(["query": AnyCodable("a"), "limit": AnyCodable(20)]),
                                                                  AnyCodable(["query": AnyCodable("b"), "limit": AnyCodable(20)]),
                                                                  AnyCodable(["query": AnyCodable("c"), "limit": AnyCodable(20)])])])
        #expect(tooMany.isError)
        let ok = catalog.runSearch(["queries": AnyCodable([AnyCodable(["query": AnyCodable("currency")])])])
        #expect(ok.isError == false)
        #expect(catalog.runDescribe(["id": AnyCodable("tool_7")]).details?.dictionaryValue?["parameters"] != nil)
    }

    @Test
    func toolCallRoutesThroughTheNormalExecutionPath() async throws {
        var tools: [any AgentTool] = (0..<12).map { SleepyParallelTool(name: "filler_\($0)", delayNs: 0) }
        tools.append(EchoArgumentTool())
        let provider = ScriptedToolProvider(turns: [
            { request in
                #expect(request.tools.map(\.name).contains("echo") == false)
                #expect(request.tools.map(\.name).contains("tool_call"))
                return ModelGenerationResponse(
                    text: "",
                    providerID: "scripted",
                    toolCalls: [
                        ModelToolCall(id: "s1", name: "tool_search", arguments: ["query": AnyCodable("echo text")]),
                        ModelToolCall(
                            id: "c1",
                            name: "tool_call",
                            arguments: ["id": AnyCodable("echo"), "args": AnyCodable(["text": AnyCodable("via search")])]
                        ),
                        ModelToolCall(id: "c2", name: "tool_call", arguments: ["id": AnyCodable("echo"), "args": AnyCodable(["nope": AnyCodable(1)])]),
                    ]
                )
            },
            ScriptedToolProvider.text("done"),
        ])
        let runtime = EmbeddedAgentRuntime(
            toolRegistry: AgentToolRegistry(tools: tools),
            modelRouter: ModelRouter(defaultProviderID: provider.id, providers: [provider])
        )
        let result = try await runtime.run(AgentRunRequest(sessionKey: "ts", prompt: "go"))
        #expect(result.toolResults.count == 3)
        let search = try #require(result.toolResults.first { $0.toolCallID == "s1" })
        #expect(search.output.text.contains("\"echo\""))
        let call = try #require(result.toolResults.first { $0.toolCallID == "c1" })
        #expect(call.name == "tool_call")
        #expect(call.output.text == "echo:via search")
        let invalid = try #require(result.toolResults.first { $0.toolCallID == "c2" })
        #expect(invalid.isError)
        #expect(invalid.output.text.contains("Expected echo({text: string})"))
    }
}
