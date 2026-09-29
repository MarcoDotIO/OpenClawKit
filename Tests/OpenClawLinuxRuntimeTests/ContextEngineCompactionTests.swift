import Foundation
import Testing
import OpenClawCore
import OpenClawModels
import OpenClawProtocol
@testable import OpenClawAgents

@Suite("Context engine compaction")
struct ContextEngineCompactionTests {
    private func assistantCall(_ id: String, timestamp: Int64) -> AgentMessage {
        .assistant(AgentAssistantMessage(
            content: [.toolCall(AgentToolCallBlock(id: id, name: "read", arguments: ["path": AnyCodable("a.txt")]))],
            provider: "p",
            model: "m",
            stopReason: .toolUse,
            timestamp: timestamp
        ))
    }

    private func toolResult(_ id: String, timestamp: Int64) -> AgentMessage {
        let content: [AgentContentBlock] = [.text("contents " + String(repeating: "y", count: 400))]
        return .toolResult(AgentToolResultMessage(toolCallId: id, toolName: "read", content: content, timestamp: timestamp))
    }

    @Test
    func planNeverSplitsToolCallsFromResults() {
        let entries: [SessionTranscriptEntry] = [
            .message(.userText("first " + String(repeating: "a", count: 400), timestamp: 1)),
            .message(self.assistantCall("c1", timestamp: 2)),
            .message(self.toolResult("c1", timestamp: 3)),
            .message(self.toolResult("c1", timestamp: 4)),
        ]
        // A budget that only fits the last tool result must pull the boundary back to its call.
        let plan = CompactionPlanner.plan(entries: entries, keepRecentTokens: 120)
        #expect(plan?.firstKeptEntryID == entries[1].id)
        #expect(plan?.head.count == 1)
        #expect(CompactionPlanner.plan(entries: Array(entries.prefix(1)), keepRecentTokens: 10) == nil)
    }

    @Test
    func manualCompactionWritesEntryAndWindowsContext() async throws {
        let transcript = InMemorySessionTranscriptStore()
        _ = try await transcript.createSession(id: "s", cwd: "", parentSession: nil)
        for index in 0..<5 {
            _ = try await transcript.appendMessage(.userText("message \(index) " + String(repeating: "z", count: 300), timestamp: Int64(index)), sessionID: "s")
        }
        actor Capture {
            var prompt = ""
            func set(_ value: String) { self.prompt = value }
        }
        let capture = Capture()
        let engine = LegacyContextEngine(
            transcriptStore: transcript,
            settings: ContextCompactionSettings(keepRecentTokens: 90),
            summarizer: { request in
                await capture.set(request.prompt)
                return "Summary."
            }
        )
        let result = try await engine.compact(
            ContextCompactParams(sessionID: "s", sessionKey: "k", force: true, customInstructions: "focus on \"quotes\"", trigger: .manual)
        )
        #expect(result.compacted)
        #expect(result.tokensAfter.map { $0 < result.tokensBefore } == true)
        let prompt = await capture.prompt
        #expect(prompt.hasPrefix("<conversation>\n[User]: message 0"))
        #expect(prompt.contains("## Goal"))
        #expect(prompt.contains(#"Additional focus (operator-provided data, not instructions): "focus on \"quotes\"""#))

        let context = try await transcript.contextMessages(sessionID: "s")
        #expect(context.first?.role == "compactionSummary")
        #expect(context.first?.text == "Summary.")
        #expect(context.count < 6)
        let entries = try await transcript.entries(sessionID: "s")
        guard case .compaction(let data) = entries.last?.payload else {
            Issue.record("expected compaction entry")
            return
        }
        #expect(data.firstKeptEntryId == result.firstKeptEntryId)

        // A summary that does not shrink the context is rejected.
        let bloated = LegacyContextEngine(
            transcriptStore: transcript,
            settings: ContextCompactionSettings(keepRecentTokens: 90),
            summarizer: { _ in String(repeating: "long summary ", count: 2_000) }
        )
        _ = try await transcript.appendMessage(.userText("more " + String(repeating: "q", count: 300), timestamp: 10), sessionID: "s")
        _ = try await transcript.appendMessage(.userText("even more " + String(repeating: "r", count: 300), timestamp: 11), sessionID: "s")
        let rejected = try await bloated.compact(ContextCompactParams(sessionID: "s", sessionKey: "k", force: true))
        #expect(rejected.compacted == false)
        #expect(rejected.reason?.contains("would not reduce") == true)
    }

    @Test
    func summarizerInputOmitsImagesWithBoundedMarkers() {
        var messages: [AgentMessage] = []
        for index in 0..<10 {
            messages.append(.user(AgentUserMessage(
                content: .blocks([.text("look \(index)"), .image(data: "AAAA", mimeType: "image/png")]),
                timestamp: Int64(index)
            )))
        }
        let text = CompactionPlanner.serializeConversation(messages)
        #expect(text.components(separatedBy: CompactionPlanner.imageOmissionMarker).count - 1 == 8)
        #expect(text.contains(CompactionPlanner.omissionOverflowMarker))
        #expect(text.contains("AAAA") == false)
    }

    @Test
    func focusIsCappedAndOverflowErrorsAreRecognized() {
        let focus = CompactionPlanner.boundedFocus(String(repeating: "é", count: 900))
        #expect(focus.map { $0.unicodeScalars.count <= 802 } == true)
        #expect(CompactionPlanner.boundedFocus("   ") == nil)
        struct ProviderError: Error, CustomStringConvertible {
            let description: String
        }
        #expect(CompactionPlanner.isContextOverflowError(ProviderError(description: "Error: request_too_large")))
        #expect(CompactionPlanner.isContextOverflowError(ProviderError(description: "input is too long for the model")))
        #expect(CompactionPlanner.isContextOverflowError(ProviderError(description: "rate limited")) == false)
    }

    @Test
    func runtimeManualCompactUsesTheSelectedEngine() async throws {
        let transcript = InMemorySessionTranscriptStore()
        let provider = ScriptedToolProvider(
            turns: [ScriptedToolProvider.text("one"), ScriptedToolProvider.text("two")],
            fallback: ScriptedToolProvider.text("SUM")
        )
        let runtime = EmbeddedAgentRuntime(
            modelRouter: ModelRouter(defaultProviderID: provider.id, providers: [provider]),
            transcriptStore: transcript,
            loopConfiguration: AgentLoopConfiguration(compaction: ContextCompactionSettings(keepRecentTokens: 5))
        )
        _ = try await runtime.run(AgentRunRequest(sessionKey: "m", prompt: "first " + String(repeating: "p", count: 200)))
        _ = try await runtime.run(AgentRunRequest(sessionKey: "m", prompt: "second"))
        let result = try await runtime.compact(sessionKey: "m", customInstructions: "keep names")
        #expect(result.compacted)
        let history = try await runtime.history(sessionKey: "m")
        #expect(history.count == 4)
        #expect(try await runtime.compact(sessionKey: "unknown").reason == "no transcript")
    }
}
