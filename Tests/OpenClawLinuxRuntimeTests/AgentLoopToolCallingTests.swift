import Foundation
import Testing
import OpenClawCore
import OpenClawModels
import OpenClawProtocol
@testable import OpenClawAgents

/// Contract-v2 provider answering from a script of turns.
actor ScriptedToolProvider: ModelProvider {
    typealias Turn = @Sendable (ModelGenerationRequest) async throws -> ModelGenerationResponse

    let id: String
    nonisolated let capabilities = ModelProviderCapabilities(supportsTools: true, supportsParallelToolCalls: true, supportsTranscript: true)
    private var turns: [Turn]
    private let fallback: Turn?
    private(set) var requests: [ModelGenerationRequest] = []

    init(id: String = "scripted", turns: [Turn], fallback: Turn? = nil) {
        self.id = id
        self.turns = turns
        self.fallback = fallback
    }

    func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        self.requests.append(request)
        if !self.turns.isEmpty {
            let turn = self.turns.removeFirst()
            return try await turn(request)
        }
        if let fallback {
            return try await fallback(request)
        }
        return ModelGenerationResponse(text: "fallback", providerID: self.id, modelID: "scripted-1")
    }

    func recorded() -> [ModelGenerationRequest] {
        self.requests
    }

    static func call(_ name: String, id: String, _ arguments: [String: AnyCodable] = [:]) -> Turn {
        { _ in
            ModelGenerationResponse(
                text: "",
                providerID: "scripted",
                modelID: "scripted-1",
                toolCalls: [ModelToolCall(id: id, name: name, arguments: arguments)],
                usage: ModelUsage(inputTokens: 10, outputTokens: 2)
            )
        }
    }

    static func text(_ text: String) -> Turn {
        { _ in ModelGenerationResponse(text: text, providerID: "scripted", modelID: "scripted-1", usage: ModelUsage(inputTokens: 5, outputTokens: 3)) }
    }
}

struct EchoArgumentTool: AgentTool {
    let name = "echo"

    var descriptor: AgentToolDescriptor {
        AgentToolDescriptor(
            name: self.name,
            description: "Echo text.",
            parameters: [
                "type": AnyCodable("object"),
                "properties": AnyCodable(["text": AnyCodable(["type": AnyCodable("string")])]),
                "required": AnyCodable(["text"]),
                "additionalProperties": AnyCodable(false),
            ]
        )
    }

    func invoke(_ invocation: AgentToolInvocation, update _: AgentToolUpdateHandler?) async throws -> AgentToolOutput {
        .text("echo:\(invocation.arguments["text"]?.stringValue ?? "")")
    }
}

actor IntervalLog {
    private(set) var intervals: [String: (start: Date, end: Date)] = [:]

    func record(_ name: String, start: Date, end: Date) {
        self.intervals[name] = (start, end)
    }
}

struct SleepyParallelTool: AgentTool {
    let name: String
    let delayNs: UInt64
    var log: IntervalLog?

    var descriptor: AgentToolDescriptor {
        AgentToolDescriptor(name: self.name, executionMode: .parallel)
    }

    func invoke(_ invocation: AgentToolInvocation, update _: AgentToolUpdateHandler?) async throws -> AgentToolOutput {
        let start = Date()
        try await Task.sleep(nanoseconds: self.delayNs)
        await self.log?.record(self.name, start: start, end: Date())
        return .text("\(self.name)-done")
    }
}

struct TerminatingTool: AgentTool {
    let name = "finish"

    func invoke(_ invocation: AgentToolInvocation, update _: AgentToolUpdateHandler?) async throws -> AgentToolOutput {
        AgentToolOutput(content: [.text("finished")], terminate: true)
    }
}

@Suite("Agent loop tool calling")
struct AgentLoopToolCallingTests {
    private func makeRuntime(
        provider: ScriptedToolProvider,
        tools: [any AgentTool] = [EchoArgumentTool()],
        transcript: (any SessionTranscriptStore)? = InMemorySessionTranscriptStore(),
        loop: AgentLoopConfiguration = AgentLoopConfiguration(),
        hooks: AgentLoopHooks = AgentLoopHooks(),
        toolsConfiguration: AgentToolsConfiguration = AgentToolsConfiguration()
    ) async throws -> EmbeddedAgentRuntime {
        let router = ModelRouter(defaultProviderID: provider.id, providers: [provider])
        let runtime = EmbeddedAgentRuntime(
            toolRegistry: AgentToolRegistry(tools: tools),
            modelRouter: router,
            transcriptStore: transcript,
            toolsConfiguration: toolsConfiguration,
            loopConfiguration: loop,
            hooks: hooks
        )
        return runtime
    }

    @Test
    func singleToolRoundTripFeedsResultsBack() async throws {
        let provider = ScriptedToolProvider(turns: [
            ScriptedToolProvider.call("echo", id: "call_1", ["text": AnyCodable("hi")]),
            { request in
                let toolText = request.messages.compactMap { message -> String? in
                    if case .toolResult(let result) = message { return result.content.compactMap(\.text).joined() }
                    return nil
                }.joined()
                return ModelGenerationResponse(text: "done \(toolText)", providerID: "scripted", modelID: "scripted-1")
            },
        ])
        let transcript = InMemorySessionTranscriptStore()
        let runtime = try await self.makeRuntime(provider: provider, transcript: transcript)
        let result = try await runtime.run(AgentRunRequest(sessionKey: "s1", prompt: "say hi"))
        #expect(result.output == "done echo:hi")
        #expect(result.toolResults.map(\.name) == ["echo"])
        #expect(result.iterations == 2)
        #expect(result.usage.totalTokens == 12)

        let requests = await provider.recorded()
        #expect(requests.count == 2)
        #expect(requests[0].tools.map(\.name) == ["echo", "llm-task"].filter { $0 == "echo" })
        #expect(requests[0].messages.map(\.role) == [.user])
        #expect(requests[1].messages.map(\.role) == [.user, .assistant, .tool])

        let history = try await runtime.history(sessionKey: "s1")
        #expect(history.map(\.role) == ["user", "assistant", "toolResult", "assistant"])

        // A second run on the same session sees the prior turns.
        _ = try await runtime.run(AgentRunRequest(sessionKey: "s1", prompt: "again"))
        let third = try #require(await provider.recorded().last)
        #expect(third.messages.map(\.role) == [.user, .assistant, .tool, .assistant, .user])
    }

    @Test
    func parallelBatchRunsConcurrentlyAndKeepsCallOrder() async throws {
        let provider = ScriptedToolProvider(turns: [
            { _ in
                ModelGenerationResponse(
                    text: "",
                    providerID: "scripted",
                    toolCalls: [
                        ModelToolCall(id: "a", name: "slow_a", arguments: [:]),
                        ModelToolCall(id: "b", name: "slow_b", arguments: [:]),
                    ]
                )
            },
            ScriptedToolProvider.text("ok"),
        ])
        let log = IntervalLog()
        let runtime = try await self.makeRuntime(
            provider: provider,
            tools: [
                SleepyParallelTool(name: "slow_a", delayNs: 250_000_000, log: log),
                SleepyParallelTool(name: "slow_b", delayNs: 250_000_000, log: log),
            ]
        )
        let result = try await runtime.run(AgentRunRequest(sessionKey: "p", prompt: "go"), timeoutMs: 10_000)
        #expect(result.toolResults.map(\.toolCallID) == ["a", "b"])
        let intervals = await log.intervals
        let first = try #require(intervals["slow_a"])
        let second = try #require(intervals["slow_b"])
        // Overlapping execution windows prove the batch ran concurrently.
        #expect(first.start < second.end && second.start < first.end)
    }

    @Test
    func unknownToolAndInvalidArgumentsBecomeErrorResults() async throws {
        let provider = ScriptedToolProvider(turns: [
            { _ in
                ModelGenerationResponse(
                    text: "",
                    providerID: "scripted",
                    toolCalls: [
                        ModelToolCall(id: "x", name: "nope", arguments: [:]),
                        ModelToolCall(id: "y", name: "echo", arguments: ["text": AnyCodable(42)]),
                    ]
                )
            },
            ScriptedToolProvider.text("recovered"),
        ])
        let runtime = try await self.makeRuntime(provider: provider)
        let result = try await runtime.run(AgentRunRequest(sessionKey: "u", prompt: "go"))
        #expect(result.output == "recovered")
        #expect(result.toolResults.count == 2)
        #expect(result.toolResults[0].isError)
        #expect(result.toolResults[0].output.text == "Tool not found: nope")
        #expect(result.toolResults[1].isError)
        #expect(result.toolResults[1].output.text.contains("Invalid arguments for echo"))
    }

    @Test
    func blockedToolReturnsSyntheticErrorAndRewriteApplies() async throws {
        let provider = ScriptedToolProvider(turns: [
            { _ in
                ModelGenerationResponse(
                    text: "",
                    providerID: "scripted",
                    toolCalls: [
                        ModelToolCall(id: "1", name: "echo", arguments: ["text": AnyCodable("secret")]),
                        ModelToolCall(id: "2", name: "echo", arguments: ["text": AnyCodable("fine")]),
                    ]
                )
            },
            ScriptedToolProvider.text("ok"),
        ])
        let hooks = AgentLoopHooks(beforeToolCall: { context in
            if context.arguments["text"]?.stringValue == "secret" {
                return .block(reason: "no secrets")
            }
            return .rewrite(["text": AnyCodable("rewritten")])
        })
        let runtime = try await self.makeRuntime(provider: provider, hooks: hooks)
        let result = try await runtime.run(AgentRunRequest(sessionKey: "b", prompt: "go"))
        #expect(result.toolResults[0].output.text == "Tool call blocked: no secrets")
        #expect(result.toolResults[1].output.text == "echo:rewritten")
    }

    @Test
    func iterationCapStopsTheLoop() async throws {
        let provider = ScriptedToolProvider(turns: [], fallback: ScriptedToolProvider.call("echo", id: "loop", ["text": AnyCodable("again")]))
        let runtime = try await self.makeRuntime(provider: provider, loop: AgentLoopConfiguration(maxToolIterations: 3))
        var frames: [AgentEventFrame] = []
        for try await frame in runtime.runEvents(AgentRunRequest(sessionKey: "cap", prompt: "go")) {
            frames.append(frame)
        }
        #expect(await provider.recorded().count == 3)
        let end = try #require(frames.last)
        #expect(end.lifecyclePhase == "end")
        #expect(end.data["reason"] == AnyCodable("max_tool_iterations"))
        #expect(frames.map(\.seq) == Array(0..<frames.count))
        #expect(frames.first?.lifecyclePhase == "start")
        #expect(frames.contains { $0.stream == .tool && $0.data["phase"] == AnyCodable("result") })
    }

    @Test
    func terminatingToolEndsRunAfterBatch() async throws {
        let provider = ScriptedToolProvider(turns: [ScriptedToolProvider.call("finish", id: "f")])
        let runtime = try await self.makeRuntime(provider: provider, tools: [TerminatingTool()])
        let result = try await runtime.run(AgentRunRequest(sessionKey: "t", prompt: "go"))
        #expect(result.iterations == 1)
        #expect(await provider.recorded().count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func abortCancelsRunAndRecordsAbortedAssistant() async throws {
        let provider = ScriptedToolProvider(turns: [
            { _ in
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return ModelGenerationResponse(text: "late", providerID: "scripted")
            },
        ])
        let transcript = InMemorySessionTranscriptStore()
        let runtime = try await self.makeRuntime(provider: provider, transcript: transcript)
        let runID = await runtime.start(AgentRunRequest(runID: "abort-me", sessionKey: "a", prompt: "go"), streaming: false)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(await runtime.activeRunIDs(sessionKey: "a") == [runID])
        #expect(await runtime.abort(runID: runID))
        let waited = try #require(await awaitCancellable("aborted run finished") { await runtime.wait(runID: runID) })
        #expect(waited.status == "error")
        #expect(waited.error?.contains("aborted") == true)
        let history = try await runtime.history(sessionKey: "a")
        guard case .assistant(let assistant) = history.last else {
            Issue.record("expected aborted assistant message")
            return
        }
        #expect(assistant.stopReason == .aborted)
    }

    @Test
    func timeoutEmitsLifecycleErrorWithTimedOut() async throws {
        let provider = ScriptedToolProvider(turns: [
            { _ in
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return ModelGenerationResponse(text: "late", providerID: "scripted")
            },
        ])
        let runtime = try await self.makeRuntime(provider: provider)
        var frames: [AgentEventFrame] = []
        do {
            for try await frame in runtime.runEvents(AgentRunRequest(sessionKey: "slow", prompt: "go"), timeoutMs: 80) {
                frames.append(frame)
            }
            Issue.record("expected timeout")
        } catch {
            #expect(error.localizedDescription.contains("timed out"))
        }
        let terminal = try #require(frames.last)
        #expect(terminal.lifecyclePhase == "error")
        #expect(terminal.data["timedOut"] == AnyCodable(true))
    }

    @Test
    func sessionLanesSerializeRunsOnTheSameSession() async throws {
        actor Clock {
            var intervals: [(Date, Date)] = []
            func add(_ start: Date, _ end: Date) { self.intervals.append((start, end)) }
        }
        let clock = Clock()
        let slowTurn: ScriptedToolProvider.Turn = { _ in
            let start = Date()
            try await Task.sleep(nanoseconds: 150_000_000)
            await clock.add(start, Date())
            return ModelGenerationResponse(text: "ok", providerID: "scripted")
        }
        let provider = ScriptedToolProvider(turns: [slowTurn, slowTurn])
        let runtime = try await self.makeRuntime(provider: provider)
        async let first = runtime.run(AgentRunRequest(sessionKey: "lane", prompt: "one"), timeoutMs: 5_000)
        async let second = runtime.run(AgentRunRequest(sessionKey: "lane", prompt: "two"), timeoutMs: 5_000)
        _ = try await (first, second)
        let intervals = await clock.intervals.sorted { $0.0 < $1.0 }
        #expect(intervals.count == 2)
        #expect(intervals[1].0 >= intervals[0].1)
    }

    @Test
    func approvalRequiredByHookWaitsForDecision() async throws {
        let provider = ScriptedToolProvider(turns: [
            ScriptedToolProvider.call("echo", id: "c1", ["text": AnyCodable("one")]),
            ScriptedToolProvider.call("echo", id: "c2", ["text": AnyCodable("two")]),
            ScriptedToolProvider.text("ok"),
        ])
        let hooks = AgentLoopHooks(beforeToolCall: { _ in
            .requireApproval(AgentToolApprovalRequest(title: "Echo", description: "Allow echo?"))
        })
        let runtime = try await self.makeRuntime(provider: provider, hooks: hooks)
        let approvals = runtime.approvals
        let updates = await approvals.updates()
        let resolver = Task {
            var decisions: [ApprovalDecision] = [.allowOnce, .deny]
            for await approval in updates where approval.state == .pending {
                let decision = decisions.removeFirst()
                _ = try? await approvals.resolve(id: approval.id, decision: decision)
                if decisions.isEmpty { break }
            }
        }
        let frames = runtime.events()
        let result = try await runtime.run(AgentRunRequest(runID: "appr-run", sessionKey: "appr", prompt: "go"), timeoutMs: 5_000)
        resolver.cancel()
        var approvalPhases: [String] = []
        for await frame in frames where frame.runID == "appr-run" {
            if frame.stream == .approval, let phase = frame.data["phase"]?.stringValue {
                approvalPhases.append(phase)
            }
            if frame.lifecyclePhase == "end" { break }
        }
        #expect(approvalPhases == ["requested", "resolved", "requested", "resolved"])
        #expect(result.toolResults[0].output.text == "echo:one")
        #expect(result.toolResults[1].isError)
        #expect(result.toolResults[1].output.text.contains("not approved"))
    }

    @Test
    func legacyProvidersGetTheSinglePromptAndNoTools() async throws {
        actor Recorder: ModelProvider {
            let id = "legacy"
            var last: ModelGenerationRequest?
            func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
                self.last = request
                return ModelGenerationResponse(text: "legacy-ok", providerID: self.id)
            }
            func snapshot() -> ModelGenerationRequest? { self.last }
        }
        let provider = Recorder()
        let runtime = EmbeddedAgentRuntime(
            toolRegistry: AgentToolRegistry(tools: [EchoArgumentTool()]),
            modelRouter: ModelRouter(defaultProviderID: "legacy", providers: [provider])
        )
        let result = try await runtime.run(AgentRunRequest(sessionKey: "l", prompt: "hello"))
        #expect(result.output == "legacy-ok")
        let request = try #require(await provider.snapshot())
        #expect(request.tools.isEmpty)
        #expect(request.messages.isEmpty)
        #expect(request.prompt == "hello")
        #expect(request.systemPrompt == nil)
    }

    @Test
    func policyHidesToolsAndReadOnlyStripsMutations() async throws {
        let provider = ScriptedToolProvider(turns: [ScriptedToolProvider.call("echo", id: "p1", ["text": AnyCodable("x")]), ScriptedToolProvider.text("done")])
        let runtime = try await self.makeRuntime(
            provider: provider,
            toolsConfiguration: AgentToolsConfiguration(policy: ToolPolicy(deny: ["echo"]))
        )
        let result = try await runtime.run(AgentRunRequest(sessionKey: "pol", prompt: "go"))
        let first = try #require(await provider.recorded().first)
        #expect(first.tools.map(\.name).contains("echo") == false)
        #expect(result.toolResults.first?.output.text.contains("not allowed") == true)

        let session = SessionRecord(key: "k", agentID: "main", updatedAtMs: 0, permissionMode: .readOnly)
        let policy = AgentLoop.effectivePolicy(base: .allowAll, request: AgentRunRequest(sessionKey: "k", prompt: ""), session: session)
        #expect(policy.allows("write") == false)
        #expect(policy.allows("bash") == false)
        #expect(policy.allows("read"))
    }

    @Test
    func overflowCompactsOnceAndRetries() async throws {
        let transcript = InMemorySessionTranscriptStore()
        let sessionID = SessionTranscriptIdentity.sessionID(forKey: "ovf")
        _ = try await transcript.createSession(id: sessionID, cwd: "", parentSession: nil)
        for index in 0..<6 {
            let question = "old question \(index) " + String(repeating: "x", count: 200)
            _ = try await transcript.appendMessage(.userText(question, timestamp: Int64(index)), sessionID: sessionID)
            _ = try await transcript.appendMessage(
                .assistant(AgentAssistantMessage(content: [.text("old answer \(index)")], provider: "scripted", model: "m", timestamp: Int64(index))),
                sessionID: sessionID
            )
        }
        struct OverflowError: Error, LocalizedError {
            var errorDescription: String? { "400 context length exceeded" }
        }
        let provider = ScriptedToolProvider(turns: [
            { _ in throw OverflowError() },
            { request in
                #expect(request.systemPrompt?.contains("context summarization assistant") == true)
                return ModelGenerationResponse(text: "SUMMARY OF OLD WORK", providerID: "scripted")
            },
            { request in
                let first = request.messages.first?.text ?? ""
                return ModelGenerationResponse(text: first.contains("SUMMARY OF OLD WORK") ? "resumed" : "no-summary", providerID: "scripted")
            },
        ])
        let runtime = try await self.makeRuntime(
            provider: provider,
            transcript: transcript,
            loop: AgentLoopConfiguration(compaction: ContextCompactionSettings(keepRecentTokens: 10))
        )
        var compactionEvents: [AgentEventFrame] = []
        var output = ""
        for try await frame in runtime.runEvents(AgentRunRequest(sessionKey: "ovf", prompt: "continue")) {
            if frame.stream == .compaction { compactionEvents.append(frame) }
            if frame.stream == .assistant { output = frame.data["text"]?.stringValue ?? output }
        }
        #expect(output == "resumed")
        #expect(compactionEvents.map { $0.data["phase"] } == [AnyCodable("start"), AnyCodable("end")])
        #expect(compactionEvents.last?.data["compacted"] == AnyCodable(true))
        let entries = try await transcript.entries(sessionID: sessionID)
        #expect(entries.contains { if case .compaction = $0.payload { return true } else { return false } })
    }

    @Test
    func loopDetectionAbortsRepeatedIdenticalCalls() async throws {
        let provider = ScriptedToolProvider(turns: [], fallback: ScriptedToolProvider.call("echo", id: "same", ["text": AnyCodable("again")]))
        let runtime = try await self.makeRuntime(
            provider: provider,
            toolsConfiguration: AgentToolsConfiguration(loopDetection: AgentLoopDetectionConfiguration(enabled: true, threshold: 3))
        )
        do {
            _ = try await runtime.run(AgentRunRequest(sessionKey: "loopy", prompt: "go"))
            Issue.record("expected loop detection")
        } catch let error as AgentLoopDetectedError {
            #expect(error.repeats == 3)
        }
    }

    @Test
    func streamingEmitsAssistantDeltasAndToolEvents() async throws {
        actor StreamingScripted: ModelProvider {
            let id = "stream"
            nonisolated let capabilities = ModelProviderCapabilities(supportsStreaming: true, supportsTools: true, supportsTranscript: true)
            var turn = 0
            func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
                ModelGenerationResponse(text: "unused", providerID: self.id)
            }
            func nextTurn() -> Int {
                self.turn += 1
                return self.turn
            }
            nonisolated func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
                let turn = await self.nextTurn()
                return AsyncThrowingStream { continuation in
                    if turn == 1 {
                        continuation.yield(ModelStreamChunk(text: "Look"))
                        continuation.yield(ModelStreamChunk(text: "ing"))
                        continuation.yield(.toolCallUpdate(ModelToolCallDelta(index: 0, id: "s1", name: "echo", argumentsDelta: "{\"text\":")))
                        continuation.yield(.toolCallUpdate(ModelToolCallDelta(index: 0, argumentsDelta: "\"hi\"}")))
                        continuation.yield(ModelStreamChunk(kind: .final, stopReason: .toolUse))
                    } else {
                        continuation.yield(.reasoningDelta("think"))
                        continuation.yield(ModelStreamChunk(text: "Done"))
                        continuation.yield(ModelStreamChunk(text: "", isFinal: true))
                    }
                    continuation.finish()
                }
            }
        }
        let runtime = EmbeddedAgentRuntime(
            toolRegistry: AgentToolRegistry(tools: [EchoArgumentTool()]),
            modelRouter: ModelRouter(defaultProviderID: "stream", providers: [StreamingScripted()])
        )
        var deltas: [String] = []
        var toolPhases: [String] = []
        var sawThinking = false
        for try await frame in runtime.runEvents(AgentRunRequest(sessionKey: "st", prompt: "go")) {
            if frame.stream == .assistant, let delta = frame.data["delta"]?.stringValue { deltas.append(delta) }
            if frame.stream == .tool, let phase = frame.data["phase"]?.stringValue { toolPhases.append(phase) }
            if frame.stream == .thinking { sawThinking = true }
        }
        #expect(deltas == ["Look", "ing", "Done"])
        #expect(toolPhases == ["start", "result"])
        #expect(sawThinking)

        var chunks: [AgentRunStreamChunk] = []
        let legacy = EmbeddedAgentRuntime(
            toolRegistry: AgentToolRegistry(tools: [EchoArgumentTool()]),
            modelRouter: ModelRouter(defaultProviderID: "stream", providers: [StreamingScripted()])
        )
        for try await chunk in await legacy.runStream(AgentRunRequest(sessionKey: "st2", prompt: "go")) {
            chunks.append(chunk)
        }
        #expect(chunks.map(\.text).joined() == "LookingDone")
        #expect(chunks.last?.isFinal == true)
    }
}
