import Foundation
import Testing
@testable import OpenClawCore
import OpenClawProtocol

@Suite("Session transcript store")
struct SessionTranscriptStoreTests {
    // Shapes taken from upstream llm-core/agent-core types and session-manager fixtures.
    static let upstreamMessagesJSON = """
    [
      {"role":"user","content":"hello","timestamp":1790000000000},
      {"role":"user","content":[{"type":"text","text":"look"},{"type":"image","data":"AAEC","mimeType":"image/png"}],"timestamp":1790000000001},
      {"role":"assistant","content":[
          {"type":"thinking","thinking":"plan","thinkingSignature":"sig","redacted":false},
          {"type":"text","text":"Calling a tool."},
          {"type":"toolCall","id":"call_1","name":"read","arguments":{"path":"README.md"}}
        ],
        "api":"openai-responses","provider":"openai","model":"gpt-5.4","responseId":"resp_1",
        "usage":{"input":10,"output":5,"cacheRead":2,"cacheWrite":0,"totalTokens":17,
                 "cost":{"input":0.1,"output":0.2,"cacheRead":0,"cacheWrite":0,"total":0.3}},
        "stopReason":"toolUse","timestamp":1790000000002},
      {"role":"toolResult","toolCallId":"call_1","toolName":"read","content":[{"type":"text","text":"# Title"}],
       "details":{"bytes":7},"isError":false,"timestamp":1790000000003},
      {"role":"compactionSummary","summary":"Earlier work","tokensBefore":9000,"timestamp":1790000000004},
      {"role":"bashExecution","command":"ls","output":"a","exitCode":0,"cancelled":false,"truncated":false,"timestamp":1790000000005},
      {"role":"custom","customType":"hook","content":"note","display":true,"timestamp":1790000000006}
    ]
    """

    @Test
    func agentMessageCodecRoundTripsUpstreamShapes() throws {
        let decoder = JSONDecoder()
        let messages = try decoder.decode([AgentMessage].self, from: Data(Self.upstreamMessagesJSON.utf8))
        #expect(messages.map(\.role) == ["user", "user", "assistant", "toolResult", "compactionSummary", "bashExecution", "custom"])
        guard case .assistant(let assistant) = messages[2] else {
            Issue.record("expected assistant")
            return
        }
        #expect(assistant.toolCalls.first?.name == "read")
        #expect(assistant.usage.totalTokens == 17)
        #expect(assistant.usage.cost.total == 0.3)
        #expect(assistant.stopReason == .toolUse)
        #expect(assistant.text == "Calling a tool.")
        #expect(messages[4].text == "Earlier work")

        let encoded = try JSONEncoder().encode(messages)
        let reencoded = try decoder.decode([AgentMessage].self, from: encoded)
        #expect(reencoded == messages)

        // Every upstream key survives the round trip.
        let original = try decoder.decode([AnyCodable].self, from: Data(Self.upstreamMessagesJSON.utf8))
        let roundTripped = try decoder.decode([AnyCodable].self, from: encoded)
        #expect(original == roundTripped)
    }

    @Test
    func entryCodecRoundTripsEveryType() throws {
        let entries: [SessionTranscriptEntry] = [
            SessionTranscriptEntry(id: "a", payload: .message(.userText("hi", timestamp: 1))),
            SessionTranscriptEntry(id: "b", parentID: "a", payload: .thinkingLevelChange("high")),
            SessionTranscriptEntry(id: "c", parentID: "b", payload: .modelChange(provider: "openai", modelID: "gpt-5.4")),
            SessionTranscriptEntry(
                id: "d",
                parentID: "c",
                payload: .compaction(SessionCompactionData(summary: "s", firstKeptEntryId: "a", tokensBefore: 10, tokensAfter: 3))
            ),
            SessionTranscriptEntry(id: "e", parentID: "d", payload: .reset(reason: .cronStale, firstKeptEntryID: nil)),
            SessionTranscriptEntry(id: "f", parentID: "e", payload: .branchSummary(fromID: "a", summary: "branch", details: nil)),
            SessionTranscriptEntry(id: "g", parentID: "f", payload: .custom(customType: "x", data: AnyCodable(["k": AnyCodable(1)]))),
            SessionTranscriptEntry(id: "h", parentID: "g", payload: .label(targetID: "a", label: "star")),
            SessionTranscriptEntry(id: "i", parentID: "h", payload: .sessionInfo(name: "Trip")),
            SessionTranscriptEntry(id: "j", parentID: "i", payload: .customMessage(customType: "ctx", content: .string("c"), display: false, details: nil)),
            SessionTranscriptEntry(id: "k", parentID: "j", payload: .unknown(type: "future", raw: ["x": AnyCodable(true)])),
        ]
        let data = try JSONEncoder().encode(entries)
        let decoded = try JSONDecoder().decode([SessionTranscriptEntry].self, from: data)
        #expect(decoded == entries)
        let raw = try JSONDecoder().decode([[String: AnyCodable]].self, from: data)
        #expect(raw[0]["parentId"]?.isNull == true)
        #expect(raw[1]["type"] == AnyCodable("thinking_level_change"))
        #expect(raw[4]["reason"] == AnyCodable("cron-stale"))
        #expect(SessionTranscriptEntry.makeID().count == 16)
    }

    @Test
    func branchAndLeafSemantics() async throws {
        let store = InMemorySessionTranscriptStore()
        _ = try await store.createSession(id: "s", cwd: "/tmp", parentSession: nil)
        let first = try await store.appendMessage(.userText("one", timestamp: 1), sessionID: "s")
        let second = try await store.appendMessage(.userText("two", timestamp: 2), sessionID: "s")
        #expect(try await store.leafID(sessionID: "s") == second)

        // Rewind to the first message and branch.
        try await store.setLeaf(first, sessionID: "s")
        let branched = try await store.appendMessage(.userText("two-b", timestamp: 3), sessionID: "s")
        let path = try await store.activePath(sessionID: "s")
        #expect(path.map(\.id) == [first, branched])
        #expect(path.last?.parentID == first)

        let branches = try await store.branches(sessionID: "s")
        #expect(Set(branches.map(\.leafEntryId)) == [second, branched])
        #expect(branches.first(where: \.active)?.leafEntryId == branched)

        // A stale writer is fenced.
        do {
            try await store.append(.message(.userText("late", timestamp: 4)), sessionID: "s", expectedLeafID: .some(second))
            Issue.record("expected stale leaf")
        } catch let error as SessionTranscriptError {
            #expect(error == .staleLeaf(expected: second, actual: branched))
        }
        try await store.append(.message(.userText("ok", timestamp: 4)), sessionID: "s", expectedLeafID: .some(branched))
    }

    @Test
    func contextWindowHonorsCompactionFirstKeptEntry() async throws {
        let store = InMemorySessionTranscriptStore()
        _ = try await store.createSession(id: "s", cwd: "", parentSession: nil)
        _ = try await store.appendMessage(.userText("old-1", timestamp: 1), sessionID: "s")
        let kept = try await store.appendMessage(.userText("kept", timestamp: 2), sessionID: "s")
        _ = try await store.append(
            SessionTranscriptEntry(payload: .compaction(SessionCompactionData(summary: "Summary of old-1", firstKeptEntryId: kept, tokensBefore: 100))),
            sessionID: "s"
        )
        _ = try await store.append(SessionTranscriptEntry(payload: .modelChange(provider: "p", modelID: "m")), sessionID: "s")
        _ = try await store.appendMessage(.userText("new", timestamp: 3), sessionID: "s")

        let context = try await store.contextMessages(sessionID: "s")
        #expect(context.map(\.role) == ["compactionSummary", "user", "user"])
        #expect(context.map(\.text) == ["Summary of old-1", "kept", "new"])
    }

    @Test
    func resetBoundaryDropsHistoryAndOrphanedToolResults() async throws {
        let store = InMemorySessionTranscriptStore()
        _ = try await store.createSession(id: "s", cwd: "", parentSession: nil)
        _ = try await store.appendMessage(.userText("before", timestamp: 1), sessionID: "s")
        let orphan = try await store.appendMessage(
            .toolResult(AgentToolResultMessage(toolCallId: "gone", toolName: "read", content: [.text("x")], timestamp: 2)),
            sessionID: "s"
        )
        _ = try await store.append(SessionTranscriptEntry(payload: .reset(reason: .reset, firstKeptEntryID: orphan)), sessionID: "s")
        _ = try await store.appendMessage(.userText("after", timestamp: 3), sessionID: "s")
        let context = try await store.contextMessages(sessionID: "s")
        #expect(context.map(\.text) == ["after"])
    }

    @Test
    func jsonlStorePersistsEntriesAndLeafMoves() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("transcripts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONLSessionTranscriptStore(directory: directory)
        _ = try await store.createSession(id: "abc", cwd: "/work", parentSession: "prev")
        let first = try await store.appendMessage(.userText("one", timestamp: 1), sessionID: "abc")
        _ = try await store.appendMessage(.userText("two", timestamp: 2), sessionID: "abc")
        try await store.setLeaf(first, sessionID: "abc")

        let reopened = JSONLSessionTranscriptStore(directory: directory)
        let header = try #require(try await reopened.header(sessionID: "abc"))
        #expect(header.cwd == "/work")
        #expect(header.parentSession == "prev")
        #expect(try await reopened.entries(sessionID: "abc").count == 2)
        #expect(try await reopened.leafID(sessionID: "abc") == first)
        #expect(try await reopened.sessionIDs() == ["abc"])

        // Garbage lines are skipped.
        let file = directory.appendingPathComponent("abc.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n".utf8))
        try handle.close()
        await reopened.invalidateCache()
        #expect(try await reopened.entries(sessionID: "abc").count == 2)

        try await reopened.delete(sessionID: "abc")
        #expect(try await reopened.header(sessionID: "abc") == nil)
        #expect(JSONLSessionTranscriptStore.defaultDirectory(stateDirectory: URL(fileURLWithPath: "/state"), agentID: "Ops").path
            == "/state/agents/ops/sessions")
    }

    @Test
    func importerTurnsLegacyRowsIntoMessages() async throws {
        let store = InMemorySessionTranscriptStore()
        let count = try await SessionTranscriptImporter.importRows(
            [
                SessionTranscriptImportRow(role: "assistant", text: "hi there", timestampMs: 20),
                SessionTranscriptImportRow(role: "user", text: "hello", timestampMs: 10),
                SessionTranscriptImportRow(role: "system", text: "ignored", timestampMs: 30),
            ],
            into: store,
            sessionID: "legacy"
        )
        #expect(count == 2)
        let context = try await store.contextMessages(sessionID: "legacy")
        #expect(context.map(\.role) == ["user", "assistant"])
    }

    @Test
    func tokenEstimatorWeighsCJKAndImages() {
        #expect(TokenEstimator.estimate("abcd") == 1)
        #expect(TokenEstimator.estimate("你好世界") == 4)
        #expect(TokenEstimator.estimate([AgentContentBlock.image(data: "", mimeType: "image/png")]) == TokenEstimator.imageTokens)
        #expect(TokenEstimator.estimate(AgentMessage.userText("abcdefgh", timestamp: 0)) == 2 + TokenEstimator.messageOverheadTokens)
    }
}
