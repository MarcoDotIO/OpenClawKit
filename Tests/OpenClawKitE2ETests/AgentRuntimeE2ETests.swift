import Foundation
import Testing
@testable import OpenClawKit

@Suite("Agent runtime E2E")
struct AgentRuntimeE2ETests {
    struct E2ETool: AgentTool {
        let name = "e2e_tool"

        func execute(arguments: [String: AnyCodable]) async throws -> AnyCodable {
            arguments["value"] ?? AnyCodable("missing")
        }
    }

    @Test
    func runIncludesToolLifecycleEvents() async throws {
        let runtime = EmbeddedAgentRuntime()
        await runtime.registerTool(E2ETool())

        let result = try await runtime.run(
            AgentRunRequest(
                runID: "e2e-1",
                sessionKey: "main",
                prompt: "run e2e",
                toolCalls: [AgentToolCall(name: "e2e_tool", arguments: ["value": AnyCodable("ok")])]
            )
        )

        #expect(result.output == "OK")
        #expect(result.toolResults.count == 1)
        #expect(result.events.map(\.kind) == [.runStarted, .toolStarted, .toolCompleted, .runCompleted])
    }

    @Test
    func sdkReplayAPIsFilterByRunSessionAndTimeWindow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclawkit-replay-e2e-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sdk = OpenClawSDK.shared
        let replayStore = sdk.makeReplayStore(fileURL: root.appendingPathComponent("events.jsonl", isDirectory: false))
        let pipeline = sdk.makeDiagnosticsPipeline(eventLimit: 200, replayStore: replayStore)
        let runtime = EmbeddedAgentRuntime(diagnosticsSink: await pipeline.sink())

        let runID = "e2e-replay-run"
        let sessionKey = "e2e-replay-session"
        let result = try await runtime.run(
            AgentRunRequest(
                runID: runID,
                sessionKey: sessionKey,
                prompt: "replay me"
            )
        )
        #expect(result.output == "OK")

        let byRun = try await sdk.replayEvents(forRunID: runID, from: replayStore)
        #expect(byRun.isEmpty == false)
        #expect(byRun.allSatisfy { $0.event.runID == runID })

        let bySession = try await sdk.replayEvents(forSessionKey: sessionKey, from: replayStore)
        #expect(bySession.isEmpty == false)
        #expect(bySession.allSatisfy { $0.event.sessionKey == sessionKey })

        let all = try await replayStore.loadAll()
        let minOccurredAt = all.first?.event.occurredAt ?? Date()
        let maxOccurredAt = all.last?.event.occurredAt ?? minOccurredAt
        let byWindow = try await sdk.replayEvents(
            in: ReplayTimeWindow(
                start: minOccurredAt.addingTimeInterval(-1),
                end: maxOccurredAt.addingTimeInterval(1)
            ),
            from: replayStore
        )
        #expect(byWindow.count == all.count)

        let replayed = try await sdk.makeReplayEngine(store: replayStore).replay(
            matching: ReplayQuery(runID: runID)
        )
        #expect(replayed.map(\.event.name) == byRun.map(\.event.name))
    }
}
