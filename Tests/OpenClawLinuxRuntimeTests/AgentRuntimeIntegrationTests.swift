import Foundation
import Testing
import OpenClawCore
import OpenClawMedia
import OpenClawModels
import OpenClawProtocol
@testable import OpenClawAgents

/// Provider streaming scripted chunk lists, one list per model turn.
actor StreamingScriptProvider: ModelProvider {
    let id: String
    nonisolated let capabilities: ModelProviderCapabilities
    private var turns: [[ModelStreamChunk]]
    private(set) var requests: [ModelGenerationRequest] = []

    init(
        id: String = "streamer",
        capabilities: ModelProviderCapabilities = ModelProviderCapabilities(supportsStreaming: true, supportsTools: true, supportsTranscript: true),
        turns: [[ModelStreamChunk]]
    ) {
        self.id = id
        self.capabilities = capabilities
        self.turns = turns
    }

    func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        self.requests.append(request)
        return ModelGenerationResponse(text: "non-stream", providerID: self.id)
    }

    nonisolated func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
        let chunks = await self.nextTurn(request)
        return AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }

    private func nextTurn(_ request: ModelGenerationRequest) -> [ModelStreamChunk] {
        self.requests.append(request)
        guard !self.turns.isEmpty else { return [.completed(response: ModelGenerationResponse(text: "", providerID: self.id))] }
        return self.turns.removeFirst()
    }

    func recorded() -> [ModelGenerationRequest] {
        self.requests
    }
}

/// Records typed hook events by name.
actor HookEventLog {
    private(set) var names: [String] = []
    private(set) var events: [String: [AnyCodable]] = [:]

    func record(_ hook: HookName, _ context: HookContext) {
        self.names.append(hook.rawValue)
        if let event = context.event {
            self.events[hook.rawValue, default: []].append(event)
        }
    }

    func first(_ hook: HookName) -> [String: AnyCodable]? {
        self.events[hook.rawValue]?.first?.dictionaryValue
    }
}

/// OCR fake for media-understanding tests.
struct FakeOCR: ImageTextExtracting {
    func extractText(from _: MediaAttachment) async throws -> ImageTextExtractionResult {
        ImageTextExtractionResult(lines: ["INVOICE 42"])
    }
}

/// Music-analysis fake for the per-run `music_analyze` tool.
struct FakeMusicAnalyzer: MusicAnalyzing {
    func analyze(audioAt _: URL, analyses: Set<MusicAnalysisKind>) async throws -> MusicAnalysisSummary {
        MusicAnalysisSummary(analyses: Array(analyses).sorted { $0.rawValue < $1.rawValue }, beatsPerMinute: 120)
    }
}

@Suite("Agent runtime integration")
struct AgentRuntimeIntegrationTests {
    private func makeRuntime(
        provider: any ModelProvider,
        tools: [any AgentTool] = [EchoArgumentTool()],
        sessionStore: SessionStore? = nil,
        loop: AgentLoopConfiguration = AgentLoopConfiguration(),
        hookRegistry: HookRegistry? = nil,
        services: MediaUnderstandingServices = .none
    ) -> EmbeddedAgentRuntime {
        EmbeddedAgentRuntime(
            toolRegistry: AgentToolRegistry(tools: tools),
            modelRouter: ModelRouter(defaultProviderID: provider.id, providers: [provider]),
            sessionStore: sessionStore,
            transcriptStore: InMemorySessionTranscriptStore(),
            loopConfiguration: loop,
            hookRegistry: hookRegistry,
            mediaUnderstandingServices: services
        )
    }

    private static func userText(_ message: AgentMessage) -> String? {
        guard case .user(let user) = message else { return nil }
        return user.content.blocks.compactMap { block -> String? in
            if case .text(let text, _) = block { return text }
            return nil
        }.joined(separator: "\n")
    }

    // MARK: Request shaping

    @Test
    func requestCarriesThinkingFastModeRunStartAndPromptCache() async throws {
        let provider = ScriptedToolProvider(turns: [ScriptedToolProvider.text("ok")])
        let store = SessionStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("shape-\(UUID().uuidString).json"))
        _ = await store.resolveOrCreate(sessionKey: "shape", defaultAgentID: "main", route: nil)
        _ = await store.update(forKey: "shape") { record in
            record.fastModeSetting = .auto
            record.thinkingLevel = .high
        }
        let runtime = self.makeRuntime(
            provider: provider,
            sessionStore: store,
            loop: AgentLoopConfiguration(fastModeDefault: .on, promptCache: ModelPromptCachePolicy(longRetention: true))
        )
        let before = Date()
        _ = try await runtime.run(AgentRunRequest(sessionKey: "shape", prompt: "hi"))
        let request = try #require(await provider.recorded().first)
        #expect(request.policy.thinkingLevel == .high)
        #expect(request.policy.reasoningEffort == nil)
        #expect(request.policy.fastModeSetting == .auto)
        #expect(request.policy.promptCache == ModelPromptCachePolicy(longRetention: true))
        let started = try #require(request.policy.runStartedAt)
        #expect(abs(started.timeIntervalSince(before)) < 5)

        // An explicit request flag wins over the session; the agent default fills in when neither is set.
        _ = try await runtime.run(AgentRunRequest(sessionKey: "shape", prompt: "again", fastMode: false))
        #expect(await provider.recorded().last?.policy.fastModeSetting == .off)
        let fresh = self.makeRuntime(provider: provider, loop: AgentLoopConfiguration(fastModeDefault: .on))
        _ = try await fresh.run(AgentRunRequest(sessionKey: "other", prompt: "x"))
        #expect(await provider.recorded().last?.policy.fastModeSetting == .on)
    }

    @Test
    func thinkingIsClampedForCatalogModelsAndUltraBecomesMax() {
        #expect(AgentLoop.resolveThinkingLevel(.ultra, providerID: "custom", modelID: "m", agentRuntime: nil) == .max)
        #expect(AgentLoop.resolveThinkingLevel(nil, providerID: "openai", modelID: "gpt-6-astra", agentRuntime: nil) == nil)
        // apple-fm/system does not reason: every level clamps to off.
        #expect(AgentLoop.resolveThinkingLevel(.high, providerID: "apple-fm", modelID: "system", agentRuntime: nil) == .off)
        let profile = OpenClawReferenceProviderCatalog.thinkingProfile(providerID: "openai", modelID: "gpt-6-astra")
        #expect(AgentLoop.resolveThinkingLevel(.medium, providerID: "openai", modelID: "gpt-6-astra", agentRuntime: nil)
            == profile.resolveSupported(.medium).providerTransportLevel)
    }

    @Test
    func toolsAreOnlySentToProvidersThatSupportTools() async throws {
        let provider = StreamingScriptProvider(
            capabilities: ModelProviderCapabilities(supportsTranscript: true),
            turns: []
        )
        let runtime = self.makeRuntime(provider: provider)
        _ = try await runtime.run(AgentRunRequest(sessionKey: "no-tools", prompt: "hi"))
        let request = try #require(await provider.recorded().first)
        #expect(request.tools.isEmpty)
        #expect(request.messages.map(\.role) == [.user])
    }

    @Test
    func streamedTextAccumulatesAndReasoningSignatureReplays() async throws {
        let signature = "sig-abc"
        let provider = StreamingScriptProvider(turns: [
            [
                .reasoningDelta("think "),
                .reasoningDelta("more"),
                ModelStreamChunk(kind: .text, text: "Calling "),
                .toolCallUpdate(ModelToolCallDelta(index: 0, id: "t1", name: "echo", argumentsDelta: "{\"text\":")),
                .toolCallUpdate(ModelToolCallDelta(index: 0, argumentsDelta: "\"hi\"}")),
                ModelStreamChunk(kind: .final, stopReason: .toolUse, reasoningSignature: signature),
            ],
            [
                ModelStreamChunk(kind: .text, text: "all "),
                ModelStreamChunk(kind: .text, text: "done"),
                ModelStreamChunk(kind: .final, stopReason: .stop),
            ],
        ])
        let runtime = self.makeRuntime(provider: provider)
        var deltas: [String: String] = [:]
        for try await frame in runtime.runEvents(AgentRunRequest(runID: "stream-run", sessionKey: "stream", prompt: "go"), timeoutMs: 5_000) {
            if frame.stream == .assistant, let delta = frame.data["delta"]?.stringValue, let item = frame.data["itemId"]?.stringValue {
                deltas[item, default: ""] += delta
            }
        }
        // Text deltas accumulate per turn even though the final chunks carry no text.
        #expect(deltas["stream-run:assistant:2"] == "all done")
        #expect(deltas["stream-run:assistant:1"] == "Calling")
        let history = try await runtime.history(sessionKey: "stream")
        guard case .assistant(let first) = history[1] else {
            Issue.record("expected an assistant turn")
            return
        }
        #expect(first.content.first == .thinking(AgentThinkingBlock(thinking: "think more", thinkingSignature: signature)))
        #expect(first.provider == "streamer")
        let second = try #require(await provider.recorded().last)
        guard case .assistant(let parts) = second.messages[1] else {
            Issue.record("expected the replayed assistant message")
            return
        }
        #expect(parts.first == .thinking("think more", signature: signature))
        #expect(second.messages.map(\.role) == [.user, .assistant, .tool])
        guard case .assistant(let last) = history.last else {
            Issue.record("expected a final assistant turn")
            return
        }
        #expect(last.content == [.text("all done")])
    }

    // MARK: Hooks

    @Test
    func beforeAgentRunBlockPersistsRedactedTurnAndFails() async throws {
        let hooks = HookRegistry()
        await hooks.register(.beforeAgentRun, event: BeforeAgentRunEvent.self) { _, _ in
            InputGateDecision.block(reason: "policy", message: "Contains secrets")
        }
        let provider = ScriptedToolProvider(turns: [ScriptedToolProvider.text("never")])
        let runtime = self.makeRuntime(provider: provider, hookRegistry: hooks)
        await #expect(throws: AgentRuntimeError.self) {
            _ = try await runtime.run(AgentRunRequest(sessionKey: "gate", prompt: "my password is hunter2"))
        }
        #expect(await provider.recorded().isEmpty)
        let history = try await runtime.history(sessionKey: "gate")
        #expect(history.count == 1)
        #expect(history.first.flatMap(Self.userText) == "Your message could not be sent: Contains secrets (blocked by before_agent_run)")
    }

    @Test
    func modelResolveAndPromptBuildHooksShapeTheRequest() async throws {
        let hooks = HookRegistry()
        await hooks.register(.beforeModelResolve, event: BeforeModelResolveEvent.self) { _, _ in
            BeforeModelResolveResult(modelOverride: "override-model", providerOverride: "alt")
        }
        await hooks.register(.beforePromptBuild, event: BeforePromptBuildEvent.self) { event, _ -> BeforePromptBuildResult? in
            #expect(event.prompt == "question")
            return BeforePromptBuildResult(
                prependContext: "CTX-BEFORE",
                appendContext: "CTX-AFTER",
                appendSystemContext: "PLUGIN-SYSTEM",
                toolsAllow: ["finish"]
            )
        }
        let primary = ScriptedToolProvider(id: "primary", turns: [ScriptedToolProvider.text("wrong")])
        let alternate = ScriptedToolProvider(id: "alt", turns: [ScriptedToolProvider.text("right")])
        let runtime = EmbeddedAgentRuntime(
            toolRegistry: AgentToolRegistry(tools: [EchoArgumentTool(), TerminatingTool()]),
            modelRouter: ModelRouter(defaultProviderID: "primary", providers: [primary, alternate]),
            transcriptStore: InMemorySessionTranscriptStore(),
            loopConfiguration: AgentLoopConfiguration(baseSystemPrompt: "BASE"),
            hookRegistry: hooks,
            mediaUnderstandingServices: .none
        )
        let result = try await runtime.run(AgentRunRequest(sessionKey: "shape-hooks", prompt: "question"))
        #expect(result.output == "right")
        #expect(await primary.recorded().isEmpty)
        let request = try #require(await alternate.recorded().first)
        #expect(request.providerID == "alt")
        #expect(request.modelID == "override-model")
        #expect(request.tools.map(\.name) == ["finish"])
        let system = try #require(request.systemPrompt)
        #expect(system.hasPrefix("BASE"))
        #expect(system.contains(AgentHookSystemContext.header))
        #expect(system.contains("PLUGIN-SYSTEM"))
        let userText = request.messages.first?.text ?? ""
        #expect(userText.hasPrefix("CTX-BEFORE\n\nquestion"))
        #expect(userText.hasSuffix("CTX-AFTER"))
        // The transcript keeps the user's own prompt.
        #expect(try await runtime.history(sessionKey: "shape-hooks").first.flatMap(Self.userText) == "question")
    }

    @Test
    func typedToolHooksBlockRewriteAndObserve() async throws {
        let hooks = HookRegistry()
        let log = HookEventLog()
        await hooks.register(.beforeToolCall, event: BeforeToolCallEvent.self) { event, _ -> BeforeToolCallDecision? in
            if event.toolCallId == "blocked" {
                return BeforeToolCallDecision(block: true, blockReason: "nope")
            }
            return BeforeToolCallDecision(params: ["text": AnyCodable("rewritten")])
        }
        await hooks.register(.afterToolCall) { context in
            await log.record(.afterToolCall, context)
            return nil
        }
        await hooks.register(.toolResultPersist, event: ToolResultPersistEvent.self) { event, _ -> ToolResultPersistResult? in
            guard var message = event.message.dictionaryValue, event.toolCallId == "ok" else { return nil }
            message["details"] = AnyCodable(["persisted": AnyCodable(true)])
            return ToolResultPersistResult(message: AnyCodable(message))
        }
        let provider = ScriptedToolProvider(turns: [
            { _ in
                ModelGenerationResponse(
                    text: "",
                    providerID: "scripted",
                    toolCalls: [
                        ModelToolCall(id: "blocked", name: "echo", arguments: ["text": AnyCodable("a")]),
                        ModelToolCall(id: "ok", name: "echo", arguments: ["text": AnyCodable("b")]),
                    ]
                )
            },
            ScriptedToolProvider.text("done"),
        ])
        let runtime = self.makeRuntime(provider: provider, hookRegistry: hooks)
        let result = try await runtime.run(AgentRunRequest(sessionKey: "tool-hooks", prompt: "go"))
        #expect(result.toolResults.map(\.output.text) == ["Tool call blocked: nope", "echo:rewritten"])
        let observed = try #require(await log.first(.afterToolCall))
        #expect(observed["toolName"]?.stringValue == "echo")
        #expect(observed["error"]?.stringValue == "Tool call blocked: nope")
        let history = try await runtime.history(sessionKey: "tool-hooks")
        let persisted = history.compactMap { message -> AgentToolResultMessage? in
            if case .toolResult(let result) = message, result.toolCallId == "ok" { return result }
            return nil
        }
        #expect(persisted.first?.details?.dictionaryValue?["persisted"]?.boolValue == true)
    }

    @Test
    func typedApprovalRequestWaitsForTheBrokerAndUsesTimeoutReason() async throws {
        let hooks = HookRegistry()
        await hooks.register(.beforeToolCall, event: BeforeToolCallEvent.self) { _, _ in
            BeforeToolCallDecision(
                requireApproval: HookApprovalRequest(title: "Echo", description: "Allow?", timeoutMs: 50, timeoutReason: "Owner did not answer")
            )
        }
        let provider = ScriptedToolProvider(turns: [
            ScriptedToolProvider.call("echo", id: "c1", ["text": AnyCodable("x")]),
            ScriptedToolProvider.text("ok"),
        ])
        let runtime = self.makeRuntime(provider: provider, hookRegistry: hooks)
        let result = try await runtime.run(AgentRunRequest(sessionKey: "typed-approval", prompt: "go"), timeoutMs: 5_000)
        #expect(result.toolResults.first?.isError == true)
        #expect(result.toolResults.first?.output.text == "Owner did not answer")
    }

    @Test
    func lifecycleHooksFireInOrderAndReplyCanBeRewritten() async throws {
        let hooks = HookRegistry()
        let log = HookEventLog()
        for hook in [HookName.sessionStart, .llmInput, .llmOutput, .modelCallStarted, .modelCallEnded, .messageSent, .agentEnd] {
            await hooks.register(hook) { context in
                await log.record(hook, context)
                return nil
            }
        }
        await hooks.register(.messageSending, event: MessageSendingEvent.self) { event, _ in
            MessageSendingResult(content: event.content.uppercased())
        }
        let provider = ScriptedToolProvider(turns: [ScriptedToolProvider.text("hello there")])
        let runtime = self.makeRuntime(provider: provider, hookRegistry: hooks)
        let result = try await runtime.run(AgentRunRequest(runID: "life", sessionKey: "life", prompt: "hi"))
        #expect(result.output == "HELLO THERE")
        let names = await log.names
        #expect(names == ["session_start", "llm_input", "model_call_started", "model_call_ended", "llm_output", "message_sent", "agent_end"])
        let input = try #require(await log.first(.llmInput))
        #expect(input["provider"]?.stringValue == "scripted")
        #expect(input["prompt"]?.stringValue == "hi")
        let end = try #require(await log.first(.agentEnd))
        #expect(end["success"]?.boolValue == true)
        #expect((end["messages"]?.arrayValue?.count ?? 0) == 2)
        // The transcript keeps the model's own text.
        guard case .assistant(let assistant) = try await runtime.history(sessionKey: "life").last else {
            Issue.record("expected an assistant message")
            return
        }
        #expect(assistant.content == [.text("hello there")])
    }

    @Test
    func beforeMessageWriteCanBlockTranscriptWrites() async throws {
        let hooks = HookRegistry()
        await hooks.register(.beforeMessageWrite, event: BeforeMessageWriteEvent.self) { event, _ -> BeforeMessageWriteResult? in
            event.message.dictionaryValue?["role"]?.stringValue == "assistant" ? BeforeMessageWriteResult(block: true) : nil
        }
        let provider = ScriptedToolProvider(turns: [ScriptedToolProvider.text("secret answer")])
        let runtime = self.makeRuntime(provider: provider, hookRegistry: hooks)
        let result = try await runtime.run(AgentRunRequest(sessionKey: "write", prompt: "hi"))
        #expect(result.output == "secret answer")
        #expect(try await runtime.history(sessionKey: "write").map(\.role) == ["user"])
    }

    @Test
    func agentEndReportsFailures() async throws {
        struct Boom: Error {}
        let hooks = HookRegistry()
        let log = HookEventLog()
        await hooks.register(.agentEnd) { context in
            await log.record(.agentEnd, context)
            return nil
        }
        let provider = ScriptedToolProvider(turns: [{ _ in throw Boom() }])
        let runtime = self.makeRuntime(provider: provider, hookRegistry: hooks)
        _ = try? await runtime.run(AgentRunRequest(sessionKey: "fail", prompt: "hi"))
        let end = try #require(await log.first(.agentEnd))
        #expect(end["success"]?.boolValue == false)
        #expect(end["error"]?.stringValue?.isEmpty == false)
    }

    @Test
    func resetEmitsBeforeResetSessionEndAndSessionStart() async throws {
        let hooks = HookRegistry()
        let log = HookEventLog()
        for hook in [HookName.beforeReset, .sessionEnd, .sessionStart] {
            await hooks.register(hook) { context in
                await log.record(hook, context)
                return nil
            }
        }
        let store = SessionStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("reset-\(UUID().uuidString).json"))
        let provider = ScriptedToolProvider(turns: [], fallback: ScriptedToolProvider.text("ok"))
        let runtime = self.makeRuntime(provider: provider, sessionStore: store, hookRegistry: hooks)
        _ = try await runtime.run(AgentRunRequest(sessionKey: "agent:main:reset", prompt: "hi"))
        _ = try await runtime.resetSession(sessionKey: "agent:main:reset")
        #expect(await log.names == ["session_start", "before_reset", "session_end", "session_start"])
        let ended = try #require(await log.first(.sessionEnd))
        #expect(ended["reason"]?.stringValue == "reset")
        #expect(ended["messageCount"]?.intValue == 2)
    }

    @Test
    func loopHooksBridgeForwardsTypedDecisions() async throws {
        let hooks = HookRegistry()
        await hooks.register(.beforeToolCall, event: BeforeToolCallEvent.self) { _, _ in
            BeforeToolCallDecision(params: ["text": AnyCodable("bridged")])
        }
        let provider = ScriptedToolProvider(turns: [
            ScriptedToolProvider.call("echo", id: "c1", ["text": AnyCodable("x")]),
            ScriptedToolProvider.text("ok"),
        ])
        let runtime = EmbeddedAgentRuntime(
            toolRegistry: AgentToolRegistry(tools: [EchoArgumentTool()]),
            modelRouter: ModelRouter(defaultProviderID: provider.id, providers: [provider]),
            transcriptStore: InMemorySessionTranscriptStore(),
            hooks: .bridging(hooks),
            mediaUnderstandingServices: .none
        )
        let result = try await runtime.run(AgentRunRequest(sessionKey: "bridge", prompt: "go"))
        #expect(result.toolResults.first?.output.text == "echo:bridged")
        #expect(AgentLoopHooks.decision(from: BeforeToolCallDecision(block: true)) == .block(reason: AgentLoop.defaultHookBlockReason))
    }

    // MARK: Provider-executed tools, overflow and Tool Search

    @Test
    func providerExecutedToolCallsAreRecordedNotRerun() async throws {
        let executed = ModelExecutedToolCall(
            call: ModelToolCall(id: "fm-1", name: "echo", arguments: ["text": AnyCodable("in-process")]),
            result: ModelToolResult(toolCallID: "fm-1", toolName: "echo", content: [.text("echo:in-process")])
        )
        let provider = ScriptedToolProvider(turns: [
            { _ in ModelGenerationResponse(text: "final", providerID: "scripted", executedToolCalls: [executed]) },
        ])
        let runtime = self.makeRuntime(provider: provider)
        let result = try await runtime.run(AgentRunRequest(sessionKey: "fm", prompt: "go"))
        #expect(result.output == "final")
        #expect(result.iterations == 1)
        #expect(result.toolResults.map(\.output.text) == ["echo:in-process"])
        #expect(try await runtime.history(sessionKey: "fm").map(\.role) == ["user", "assistant", "toolResult", "assistant"])
    }

    @Test
    func typedContextOverflowTriggersOverflowCompaction() async throws {
        struct Overflow: ModelContextOverflowReporting, LocalizedError {
            var isContextOverflow: Bool { true }
            var overflowContextSize: Int? { 8_192 }
            var overflowTokenCount: Int? { 9_000 }
            var errorDescription: String? { "the session overflowed" }
        }
        let provider = ScriptedToolProvider(turns: [
            ScriptedToolProvider.text("first"),
            { _ in throw Overflow() },
            ScriptedToolProvider.text("after compaction"),
        ])
        let runtime = self.makeRuntime(provider: provider)
        _ = try await runtime.run(AgentRunRequest(sessionKey: "overflow", prompt: "one"))
        var compactionTriggers: [String] = []
        for try await frame in runtime.runEvents(AgentRunRequest(sessionKey: "overflow", prompt: "two"), timeoutMs: 5_000)
            where frame.stream == .compaction
        {
            compactionTriggers.append(frame.data["trigger"]?.stringValue ?? "")
        }
        #expect(compactionTriggers.first == "overflow")
        #expect(CompactionPlanner.isContextOverflowError(FoundationModelsError(code: .contextOverflow, message: "too long")))
        #expect(!CompactionPlanner.isContextOverflowError(FoundationModelsError(code: .guardrail, message: "blocked")))
    }

    @Test
    func smallContextModelsGetToolSearchAboveEightTools() async throws {
        let tools: [any AgentTool] = (1...9).map { SleepyParallelTool(name: "tool_\($0)", delayNs: 0) }
        let provider = ScriptedToolProvider(id: "apple-fm", turns: [ScriptedToolProvider.text("ok")])
        let runtime = self.makeRuntime(provider: provider, tools: tools)
        _ = try await runtime.run(AgentRunRequest(sessionKey: "small", prompt: "hi", modelProviderID: "apple-fm", modelID: "system"))
        let names = try #require(await provider.recorded().first).tools.map(\.name)
        #expect(names.contains(ToolSearchCatalog.searchToolName))
        #expect(!names.contains("tool_1"))

        let large = ScriptedToolProvider(id: "big", turns: [ScriptedToolProvider.text("ok")])
        let roomy = self.makeRuntime(provider: large, tools: tools)
        _ = try await roomy.run(AgentRunRequest(sessionKey: "large", prompt: "hi"))
        #expect(try #require(await large.recorded().first).tools.count == 9)
    }

    // MARK: Media and skills

    @Test
    func textOnlyModelsGetOCRTextInsteadOfImages() async throws {
        let provider = ScriptedToolProvider(id: "texty", turns: [ScriptedToolProvider.text("ok")])
        let config = ModelProviderConfig(models: [ModelDefinitionConfig(id: "reader", input: [.text])])
        let diagnostics = DiagnosticNames()
        let runtime = EmbeddedAgentRuntime(
            toolRegistry: AgentToolRegistry(tools: []),
            modelRouter: ModelRouter(defaultProviderID: "texty", providers: [provider]),
            diagnosticsSink: { event in await diagnostics.record(event.name) },
            transcriptStore: InMemorySessionTranscriptStore(),
            loopConfiguration: AgentLoopConfiguration(providerConfigs: ["texty": config]),
            mediaUnderstandingServices: MediaUnderstandingServices(imageText: FakeOCR())
        )
        let image = MediaAttachment(mimeType: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47]), fileName: "scan.png")
        _ = try await runtime.run(AgentRunRequest(sessionKey: "ocr", prompt: "what is this?", modelID: "reader", attachments: [image]))
        let request = try #require(await provider.recorded().first)
        guard case .user(let content) = request.messages.first else {
            Issue.record("expected a user message")
            return
        }
        #expect(content.contains { $0.text?.contains("INVOICE 42") == true })
        #expect(!content.contains { part in
            if case .image = part { return true }
            return false
        })
        #expect(await diagnostics.names.contains("media.understanding.converted"))
    }

    @Test
    func audioAttachmentsGetARunScopedMusicTool() async throws {
        let provider = ScriptedToolProvider(turns: [ScriptedToolProvider.text("ok")])
        let runtime = self.makeRuntime(provider: provider, tools: [], services: MediaUnderstandingServices(music: FakeMusicAnalyzer()))
        let audio = MediaAttachment(mimeType: "audio/mpeg", data: Data([0x49, 0x44, 0x33]), fileName: "song.mp3")
        _ = try await runtime.run(AgentRunRequest(sessionKey: "music", prompt: "tempo?", attachments: [audio]))
        #expect(try #require(await provider.recorded().first).tools.map(\.name) == [MusicAnalyzeTool.toolName])
        // Run-scoped tools never leak into the shared registry or later runs.
        #expect(await runtime.toolRegistry.tool(named: MusicAnalyzeTool.toolName) == nil)
        _ = try await runtime.run(AgentRunRequest(sessionKey: "music", prompt: "again"))
        #expect(await provider.recorded().last?.tools.isEmpty == true)
    }

    @Test
    func skillCatalogUsesAJailedReadToolWhenToolsAreAvailable() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("skills-\(UUID().uuidString)", isDirectory: true)
        let skillDir = workspace.appendingPathComponent("skills/greeter", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try """
        ---
        name: greeter
        description: Greets people warmly.
        ---
        # Greeter
        Say hello with enthusiasm.
        """.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let skillPath = skillDir.appendingPathComponent("SKILL.md").path
        let provider = ScriptedToolProvider(turns: [
            ScriptedToolProvider.call("read", id: "r1", ["path": AnyCodable(skillPath)]),
            ScriptedToolProvider.call("read", id: "r2", ["path": AnyCodable("/etc/hosts")]),
            ScriptedToolProvider.text("done"),
        ])
        let runtime = self.makeRuntime(provider: provider, tools: [])
        let result = try await runtime.run(AgentRunRequest(sessionKey: "skills", prompt: "greet", workspaceRootPath: workspace.path))
        let first = try #require(await provider.recorded().first)
        #expect(first.tools.map(\.name) == ["read"])
        #expect(first.systemPrompt?.contains("<available_skills>") == true)
        #expect(result.toolResults[0].output.text.contains("Say hello with enthusiasm."))
        #expect(result.toolResults[1].isError)

        // Providers without tools get inline skill bodies and no read tool.
        let legacy = StreamingScriptProvider(capabilities: ModelProviderCapabilities(supportsTranscript: true), turns: [])
        let plain = self.makeRuntime(provider: legacy, tools: [])
        _ = try await plain.run(AgentRunRequest(sessionKey: "inline", prompt: "greet", workspaceRootPath: workspace.path))
        let inline = try #require(await legacy.recorded().first)
        #expect(inline.tools.isEmpty)
        #expect(inline.systemPrompt?.contains("Say hello with enthusiasm.") == true)
    }

    @Test
    func readToolPagesTextWithContinuationNotices() throws {
        let text = (1...5).map { "line \($0)" }.joined(separator: "\n")
        let page = SkillReadTool.page(text: text, offset: 2, limit: 2)
        #expect(page.text == "line 2\nline 3\n\n[2 more lines in file. Use offset=4 to continue.]")
        let tail = SkillReadTool.page(text: text, offset: 4, limit: nil)
        #expect(tail.text == "line 4\nline 5")
        #expect(SkillReadTool.page(text: text, offset: 9, limit: nil).isError)
    }

    @Test
    func promptContributorsSeeOfferedTools() async throws {
        let provider = ScriptedToolProvider(turns: [ScriptedToolProvider.text("ok")])
        let runtime = self.makeRuntime(provider: provider)
        await runtime.addPromptContributor { context in
            context.availableToolNames.contains("echo") ? "ECHO-AVAILABLE via \(context.providerID ?? "")" : nil
        }
        _ = try await runtime.run(AgentRunRequest(sessionKey: "contrib", prompt: "hi"))
        #expect(await provider.recorded().first?.systemPrompt?.contains("ECHO-AVAILABLE via scripted") == true)
    }
}

/// Collects diagnostic event names.
actor DiagnosticNames {
    private(set) var names: [String] = []

    func record(_ name: String) {
        self.names.append(name)
    }
}
