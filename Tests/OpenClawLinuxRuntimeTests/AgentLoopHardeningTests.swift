import Foundation
import Testing
import OpenClawCore
import OpenClawModels
import OpenClawProtocol
@testable import OpenClawAgents

// MARK: - Helpers

/// Records tool invocations by name.
actor ToolCallLog {
    private(set) var calls: [String] = []

    func record(_ name: String) {
        self.calls.append(name)
    }

    func count(_ name: String) -> Int {
        self.calls.filter { $0 == name }.count
    }

    func contains(_ name: String) -> Bool {
        self.calls.contains(name)
    }
}

/// Tool that records each invocation (and optionally runs a side effect first).
struct RecordingTool: AgentTool {
    let name: String
    let log: ToolCallLog
    var source: AgentToolSource = .core
    var onInvoke: (@Sendable () async -> Void)?

    var descriptor: AgentToolDescriptor {
        AgentToolDescriptor(name: self.name, source: self.source)
    }

    func invoke(_ invocation: AgentToolInvocation, update _: AgentToolUpdateHandler?) async throws -> AgentToolOutput {
        await self.log.record(self.name)
        await self.onInvoke?()
        return .text("\(self.name)-ran")
    }
}

/// Tool that blocks until cancelled.
struct BlockingTool: AgentTool {
    let name = "slow"
    let log: ToolCallLog

    func invoke(_ invocation: AgentToolInvocation, update _: AgentToolUpdateHandler?) async throws -> AgentToolOutput {
        await self.log.record("slow-started")
        try await Task.sleep(nanoseconds: 30_000_000_000)
        return .text("slow-done")
    }
}

/// Provider that rejects requests with unpaired tool calls (like Anthropic and OpenAI), then answers
/// from a script.
actor PairingCheckedProvider: ModelProvider {
    struct PairingError: Error, CustomStringConvertible {
        let description: String
    }

    let id = "strict"
    nonisolated let capabilities = ModelProviderCapabilities(supportsTools: true, supportsTranscript: true)
    private var turns: [ScriptedToolProvider.Turn]
    private(set) var requests: [ModelGenerationRequest] = []

    init(turns: [ScriptedToolProvider.Turn]) {
        self.turns = turns
    }

    func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        self.requests.append(request)
        try Self.checkPairing(request.messages)
        guard !self.turns.isEmpty else {
            return ModelGenerationResponse(text: "fallback", providerID: self.id)
        }
        return try await self.turns.removeFirst()(request)
    }

    func recorded() -> [ModelGenerationRequest] {
        self.requests
    }

    static func checkPairing(_ messages: [ModelMessage]) throws {
        var index = 0
        while index < messages.count {
            switch messages[index] {
            case .assistant(let parts):
                let ids = parts.compactMap { part -> String? in
                    if case .toolCall(let call) = part { return call.id }
                    return nil
                }
                var answered: Set<String> = []
                var next = index + 1
                while next < messages.count, case .toolResult(let result) = messages[next] {
                    guard ids.contains(result.toolCallID), answered.insert(result.toolCallID).inserted else {
                        throw PairingError(description: "unexpected tool result \(result.toolCallID)")
                    }
                    next += 1
                }
                guard answered == Set(ids) else {
                    throw PairingError(description: "tool calls without results: \(Set(ids).subtracting(answered).sorted())")
                }
                index = next
            case .toolResult(let result):
                throw PairingError(description: "orphan tool result \(result.toolCallID)")
            default:
                index += 1
            }
        }
    }
}

/// Streaming provider answering from scripted chunk lists; a turn may fail after its chunks.
actor ScriptedStreamProvider: ModelProvider {
    struct Turn: Sendable {
        var chunks: [ModelStreamChunk]
        var failure: (any Error & Sendable)?
    }

    struct StreamBoom: Error {}

    let id = "streamer"
    nonisolated let capabilities = ModelProviderCapabilities(supportsStreaming: true, supportsTools: true, supportsTranscript: true)
    private var turns: [Turn]

    init(turns: [Turn]) {
        self.turns = turns
    }

    func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        ModelGenerationResponse(text: "unused", providerID: self.id)
    }

    private func nextTurn() -> Turn {
        guard !self.turns.isEmpty else {
            return Turn(chunks: [.completed(text: "done", response: ModelGenerationResponse(text: "done", providerID: "streamer"))])
        }
        return self.turns.removeFirst()
    }

    func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
        let turn = self.nextTurn()
        return AsyncThrowingStream { continuation in
            for chunk in turn.chunks {
                continuation.yield(chunk)
            }
            if let failure = turn.failure {
                continuation.finish(throwing: failure)
            } else {
                continuation.finish()
            }
        }
    }
}

func waitUntil(_ condition: @Sendable () async -> Bool) async throws {
    for _ in 0..<500 {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    Issue.record("condition not met in time")
}

func temporarySessionStore(_ label: String) -> SessionStore {
    SessionStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)/sessions.json"))
}

func toolResults(_ messages: [AgentMessage]) -> [AgentToolResultMessage] {
    messages.compactMap { message in
        if case .toolResult(let result) = message { return result }
        return nil
    }
}

// MARK: - Tests

@Suite("Agent loop hardening")
struct AgentLoopHardeningTests {
    // MARK: Tool-call pairing after interruptions

    @Test(.timeLimit(.minutes(1)))
    func abortDuringAToolKeepsEveryCallPairedAndTheSessionUsable() async throws {
        let log = ToolCallLog()
        let provider = PairingCheckedProvider(turns: [
            { _ in
                ModelGenerationResponse(
                    text: "",
                    providerID: "strict",
                    toolCalls: [
                        ModelToolCall(id: "t1", name: "echo", arguments: ["text": AnyCodable("one")]),
                        ModelToolCall(id: "t2", name: "slow", arguments: [:]),
                    ]
                )
            },
            ScriptedToolProvider.text("recovered"),
        ])
        let runtime = EmbeddedAgentRuntime(
            toolRegistry: AgentToolRegistry(tools: [EchoArgumentTool(), BlockingTool(log: log)]),
            modelRouter: ModelRouter(defaultProviderID: provider.id, providers: [provider]),
            transcriptStore: InMemorySessionTranscriptStore()
        )
        let runID = await runtime.start(AgentRunRequest(runID: "pair-1", sessionKey: "pair", prompt: "go"), streaming: false)
        try await waitUntil { await log.contains("slow-started") }
        #expect(await runtime.abort(runID: runID))
        #expect(await runtime.wait(runID: runID)?.status == "error")

        let history = try await runtime.history(sessionKey: "pair")
        let results = toolResults(history)
        #expect(results.map(\.toolCallId) == ["t1", "t2"])
        #expect(results.first?.text == "echo:one")
        #expect(results.first?.isError == false)
        #expect(results.last?.isError == true)
        #expect(results.last?.text == AgentLoop.interruptedToolResultText)

        let second = try await runtime.run(AgentRunRequest(sessionKey: "pair", prompt: "again"), timeoutMs: 10_000)
        #expect(second.output == "recovered")
    }

    @Test
    func replayRepairsTranscriptsBrokenOnDisk() async throws {
        let transcript = InMemorySessionTranscriptStore()
        let sessionID = SessionTranscriptIdentity.sessionID(forKey: "broken")
        try await transcript.ensureSession(id: sessionID)
        try await transcript.appendMessage(.userText("first", timestamp: 1), sessionID: sessionID)
        try await transcript.appendMessage(
            .assistant(AgentAssistantMessage(
                content: [.toolCall(AgentToolCallBlock(id: "x", name: "echo")), .toolCall(AgentToolCallBlock(id: "y", name: "echo"))],
                provider: "p",
                model: "m",
                stopReason: .toolUse,
                timestamp: 2
            )),
            sessionID: sessionID
        )
        try await transcript.appendMessage(
            .toolResult(AgentToolResultMessage(toolCallId: "y", toolName: "echo", content: [.text("y-result")], timestamp: 3)),
            sessionID: sessionID
        )
        try await transcript.appendMessage(
            .toolResult(AgentToolResultMessage(toolCallId: "y", toolName: "echo", content: [.text("duplicate")], timestamp: 4)),
            sessionID: sessionID
        )
        try await transcript.appendMessage(
            .assistant(AgentAssistantMessage(content: [.text("half an ans")], provider: "p", model: "m", stopReason: .aborted, timestamp: 5)),
            sessionID: sessionID
        )
        try await transcript.appendMessage(
            .toolResult(AgentToolResultMessage(toolCallId: "ghost", toolName: "echo", content: [.text("orphan")], timestamp: 6)),
            sessionID: sessionID
        )
        let provider = PairingCheckedProvider(turns: [ScriptedToolProvider.text("fine")])
        let runtime = EmbeddedAgentRuntime(
            toolRegistry: AgentToolRegistry(tools: [EchoArgumentTool()]),
            modelRouter: ModelRouter(defaultProviderID: provider.id, providers: [provider]),
            transcriptStore: transcript
        )
        let result = try await runtime.run(AgentRunRequest(sessionKey: "broken", prompt: "next"), timeoutMs: 10_000)
        #expect(result.output == "fine")
        let messages = try #require(await provider.recorded().first?.messages)
        let replayedResults = messages.compactMap { message -> ModelToolResult? in
            if case .toolResult(let result) = message { return result }
            return nil
        }
        #expect(replayedResults.map(\.toolCallID) == ["y", "x"])
        #expect(replayedResults.last?.content.first?.text == AgentMessageConversion.missingToolResultText)
        #expect(replayedResults.last?.isError == true)
        #expect(messages.contains { $0.text.contains(AgentMessageConversion.failedAssistantReplayText) })
        #expect(!messages.contains { $0.text.contains("half an ans") || $0.text.contains("orphan") || $0.text.contains("duplicate") })
    }

    @Test
    func blockedToolResultWriteLeavesAPlaceholder() async throws {
        let hooks = HookRegistry()
        await hooks.register(.beforeMessageWrite, event: BeforeMessageWriteEvent.self) { event, _ -> BeforeMessageWriteResult? in
            event.message.dictionaryValue?["role"]?.stringValue == "toolResult" ? BeforeMessageWriteResult(block: true) : nil
        }
        let provider = PairingCheckedProvider(turns: [
            ScriptedToolProvider.call("echo", id: "e1", ["text": AnyCodable("secret")]),
            ScriptedToolProvider.text("done"),
        ])
        let runtime = EmbeddedAgentRuntime(
            toolRegistry: AgentToolRegistry(tools: [EchoArgumentTool()]),
            modelRouter: ModelRouter(defaultProviderID: provider.id, providers: [provider]),
            transcriptStore: InMemorySessionTranscriptStore(),
            hookRegistry: hooks
        )
        let result = try await runtime.run(AgentRunRequest(sessionKey: "blocked-write", prompt: "go"), timeoutMs: 10_000)
        #expect(result.output == "done")
        let results = toolResults(try await runtime.history(sessionKey: "blocked-write"))
        #expect(results.map(\.toolCallId) == ["e1"])
        #expect(results.first?.text == AgentLoop.blockedToolResultText)
        #expect(results.first?.text.contains("secret") == false)
    }

    // MARK: Interrupted-turn text

    @Test(.timeLimit(.minutes(1)))
    func abortAfterAPersistedStreamedTurnDoesNotDuplicateItsText() async throws {
        let log = ToolCallLog()
        let provider = ScriptedToolProvider(turns: [
            { _ in
                ModelGenerationResponse(
                    text: "Let me check the files.",
                    providerID: "scripted",
                    toolCalls: [ModelToolCall(id: "s1", name: "slow", arguments: [:])]
                )
            },
        ])
        let runtime = EmbeddedAgentRuntime(
            toolRegistry: AgentToolRegistry(tools: [BlockingTool(log: log)]),
            modelRouter: ModelRouter(defaultProviderID: provider.id, providers: [provider]),
            transcriptStore: InMemorySessionTranscriptStore()
        )
        let runID = await runtime.start(AgentRunRequest(sessionKey: "stream-abort", prompt: "look"), streaming: true)
        try await waitUntil { await log.contains("slow-started") }
        await runtime.abort(runID: runID)
        _ = await runtime.wait(runID: runID)
        let history = try await runtime.history(sessionKey: "stream-abort")
        #expect(history.filter { $0.text.contains("Let me check") }.count == 1)
        guard case .assistant(let aborted) = try #require(history.last) else {
            Issue.record("expected a trailing assistant message")
            return
        }
        #expect(aborted.stopReason == .aborted)
        #expect(aborted.content.isEmpty)
    }

    @Test
    func providerErrorRecordsOnlyTheFailedTurnsText() async throws {
        let firstTurn = ModelGenerationResponse(
            text: "First turn.",
            providerID: "streamer",
            toolCalls: [ModelToolCall(id: "e1", name: "echo", arguments: ["text": AnyCodable("x")])]
        )
        let provider = ScriptedStreamProvider(turns: [
            ScriptedStreamProvider.Turn(chunks: [ModelStreamChunk(text: "First turn."), .completed(text: "", response: firstTurn)]),
            ScriptedStreamProvider.Turn(chunks: [ModelStreamChunk(text: "partial two")], failure: ScriptedStreamProvider.StreamBoom()),
        ])
        let runtime = EmbeddedAgentRuntime(
            toolRegistry: AgentToolRegistry(tools: [EchoArgumentTool()]),
            modelRouter: ModelRouter(defaultProviderID: provider.id, providers: [provider]),
            transcriptStore: InMemorySessionTranscriptStore()
        )
        let runID = await runtime.start(AgentRunRequest(sessionKey: "stream-error", prompt: "go"), streaming: true)
        #expect(await runtime.wait(runID: runID)?.status == "error")
        let history = try await runtime.history(sessionKey: "stream-error")
        #expect(history.filter { $0.text.contains("First turn.") }.count == 1)
        guard case .assistant(let failed) = try #require(history.last) else {
            Issue.record("expected a trailing assistant message")
            return
        }
        #expect(failed.stopReason == .error)
        #expect(failed.text == "partial two")
    }

    // MARK: Canonical tool names for hooks

    @Test
    func hooksSeeTheResolvedToolNameForAliasesAndCaseVariants() async throws {
        let hooks = HookRegistry()
        await hooks.register(.beforeToolCall, event: BeforeToolCallEvent.self) { event, _ -> BeforeToolCallDecision? in
            event.toolName == "exec" ? BeforeToolCallDecision(block: true, blockReason: "exec needs approval") : nil
        }
        let seen = LockedStrings()
        let log = ToolCallLog()
        let provider = ScriptedToolProvider(turns: [
            ScriptedToolProvider.call("Bash", id: "b1", [:]),
            ScriptedToolProvider.call("EXEC", id: "b2", [:]),
            ScriptedToolProvider.text("ok"),
        ])
        let runtime = EmbeddedAgentRuntime(
            toolRegistry: AgentToolRegistry(tools: [RecordingTool(name: "exec", log: log)]),
            modelRouter: ModelRouter(defaultProviderID: provider.id, providers: [provider]),
            transcriptStore: InMemorySessionTranscriptStore(),
            hooks: AgentLoopHooks(beforeToolCall: { context in
                seen.append("\(context.toolName)|\(context.rawToolName)")
                return .proceed
            }),
            hookRegistry: hooks
        )
        let result = try await runtime.run(AgentRunRequest(sessionKey: "alias", prompt: "go"), timeoutMs: 10_000)
        #expect(result.toolResults.map(\.name) == ["Bash", "EXEC"])
        #expect(result.toolResults.allSatisfy { $0.isError && $0.output.text == "Tool call blocked: exec needs approval" })
        #expect(await log.count("exec") == 0)
        #expect(seen.values == ["exec|Bash", "exec|EXEC"])
    }

    // MARK: Execution-time enforcement of hidden tools

    @Test
    func toolsAllowIsEnforcedWhenTheModelCallsAHiddenToolByName() async throws {
        let hooks = HookRegistry()
        await hooks.register(.beforePromptBuild, event: BeforePromptBuildEvent.self) { _, _ -> BeforePromptBuildResult? in
            BeforePromptBuildResult(toolsAllow: ["finish"])
        }
        let log = ToolCallLog()
        let provider = ScriptedToolProvider(turns: [
            ScriptedToolProvider.call("echo", id: "e1", ["text": AnyCodable("x")]),
            ScriptedToolProvider.text("ok"),
        ])
        let runtime = EmbeddedAgentRuntime(
            toolRegistry: AgentToolRegistry(tools: [RecordingTool(name: "echo", log: log), TerminatingTool()]),
            modelRouter: ModelRouter(defaultProviderID: provider.id, providers: [provider]),
            transcriptStore: InMemorySessionTranscriptStore(),
            hookRegistry: hooks
        )
        let result = try await runtime.run(AgentRunRequest(sessionKey: "tools-allow", prompt: "go"), timeoutMs: 10_000)
        #expect(await provider.recorded().first?.tools.map(\.name) == ["finish"])
        #expect(result.toolResults.first?.output.text == "Tool echo is not available in this run")
        #expect(await log.count("echo") == 0)
    }

    @Test
    func disabledMCPServerToolsAreRefusedEvenWithSanitizedNames() async throws {
        let store = temporarySessionStore("mcp-override")
        _ = await store.resolveOrCreate(sessionKey: "agent:main:mcp", defaultAgentID: "main", route: nil)
        _ = await store.update(forKey: "agent:main:mcp") { record in
            record.toolOverrides = SessionToolOverrides(mcpServers: ["docs.internal": false])
        }
        let log = ToolCallLog()
        let tool = RecordingTool(name: "docs-internal__delete_page", log: log, source: .mcp(server: "docs.internal", toolName: "delete_page"))
        let provider = ScriptedToolProvider(turns: [
            ScriptedToolProvider.call("docs-internal__delete_page", id: "m1", [:]),
            ScriptedToolProvider.text("ok"),
        ])
        let runtime = EmbeddedAgentRuntime(
            toolRegistry: AgentToolRegistry(tools: [tool]),
            modelRouter: ModelRouter(defaultProviderID: provider.id, providers: [provider]),
            sessionStore: store,
            transcriptStore: InMemorySessionTranscriptStore()
        )
        let result = try await runtime.run(AgentRunRequest(sessionKey: "agent:main:mcp", prompt: "go"), timeoutMs: 10_000)
        #expect(result.toolResults.first?.isError == true)
        #expect(await log.count("docs-internal__delete_page") == 0)
    }

    // MARK: Mid-run permission changes

    @Test
    func tighteningThePermissionModeMidRunDeniesTheNextToolCall() async throws {
        let store = temporarySessionStore("mid-run")
        let key = "agent:main:mid"
        _ = await store.resolveOrCreate(sessionKey: key, defaultAgentID: "main", route: nil)
        _ = await store.update(forKey: key) { $0.permissionMode = .full }
        let log = ToolCallLog()
        // The first write stands in for an operator switching the session to read-only mid-run.
        let write = RecordingTool(name: "write", log: log) {
            _ = await store.update(forKey: key) { $0.permissionMode = .readOnly }
        }
        let provider = ScriptedToolProvider(turns: [
            ScriptedToolProvider.call("write", id: "w1", [:]),
            ScriptedToolProvider.call("write", id: "w2", [:]),
            ScriptedToolProvider.text("done"),
        ])
        let runtime = EmbeddedAgentRuntime(
            toolRegistry: AgentToolRegistry(tools: [write]),
            modelRouter: ModelRouter(defaultProviderID: provider.id, providers: [provider]),
            sessionStore: store,
            transcriptStore: InMemorySessionTranscriptStore()
        )
        let result = try await runtime.run(AgentRunRequest(sessionKey: key, prompt: "go"), timeoutMs: 10_000)
        #expect(await log.count("write") == 1)
        #expect(result.toolResults.map(\.isError) == [false, true])
        #expect(result.toolResults.last?.output.text == "Tool write is not allowed by the current tool policy")
        let requests = await provider.recorded()
        #expect(requests.count == 3)
        #expect(requests[1].tools.map(\.name).contains("write") == false)
        #expect(requests[1].messages.contains { $0.text.contains("Permission change.") && $0.text.contains("read-only") })
    }

    @Test
    func aPatchDuringABatchAppliesToTheNextCallOfThatBatch() async throws {
        let store = temporarySessionStore("mid-batch")
        let key = "agent:main:batch"
        _ = await store.resolveOrCreate(sessionKey: key, defaultAgentID: "main", route: nil)
        let log = ToolCallLog()
        let write = RecordingTool(name: "write", log: log) {
            _ = await store.update(forKey: key) { $0.permissionMode = .readOnly }
        }
        let provider = ScriptedToolProvider(turns: [
            { _ in
                ModelGenerationResponse(
                    text: "",
                    providerID: "scripted",
                    toolCalls: [ModelToolCall(id: "w1", name: "write", arguments: [:]), ModelToolCall(id: "w2", name: "write", arguments: [:])]
                )
            },
            ScriptedToolProvider.text("done"),
        ])
        let runtime = EmbeddedAgentRuntime(
            toolRegistry: AgentToolRegistry(tools: [write]),
            modelRouter: ModelRouter(defaultProviderID: provider.id, providers: [provider]),
            sessionStore: store,
            transcriptStore: InMemorySessionTranscriptStore()
        )
        let result = try await runtime.run(AgentRunRequest(sessionKey: key, prompt: "go"), timeoutMs: 10_000)
        #expect(await log.count("write") == 1)
        #expect(result.toolResults.map(\.isError) == [false, true])
    }
}
