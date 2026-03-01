import Foundation
import Testing
@testable import OpenClawKit

@Suite("Runtime diagnostics pipeline")
struct RuntimeDiagnosticsPipelineTests {
    @Test
    func aggregatesRecordedEventsIntoUsageSnapshot() async {
        let pipeline = RuntimeDiagnosticsPipeline(eventLimit: 50)

        await pipeline.record(
            RuntimeDiagnosticEvent(
                subsystem: "runtime",
                name: "run.started",
                runID: "run-1",
                sessionKey: "session-1"
            )
        )
        await pipeline.record(
            RuntimeDiagnosticEvent(
                subsystem: "runtime",
                name: "model.call.completed",
                runID: "run-1",
                sessionKey: "session-1",
                metadata: [
                    "providerID": "openai",
                    "modelID": "gpt-4.1-mini",
                    "latencyMs": "123",
                ]
            )
        )
        await pipeline.record(
            RuntimeDiagnosticEvent(
                subsystem: "channel",
                name: "skill.invoked",
                sessionKey: "session-1",
                metadata: [
                    "skillName": "weather",
                    "durationMs": "42",
                ]
            )
        )
        await pipeline.record(
            RuntimeDiagnosticEvent(
                subsystem: "channel",
                name: "outbound.sent",
                sessionKey: "session-1",
                metadata: [
                    "channel": "discord",
                    "attempts": "3",
                ]
            )
        )
        await pipeline.record(
            RuntimeDiagnosticEvent(
                subsystem: "channel",
                name: "outbound.failed",
                sessionKey: "session-1",
                metadata: [
                    "channel": "discord",
                    "attempts": "2",
                ]
            )
        )
        await pipeline.record(
            RuntimeDiagnosticEvent(
                subsystem: "runtime",
                name: "run.completed",
                runID: "run-1",
                sessionKey: "session-1",
                metadata: ["latencyMs": "333"]
            )
        )
        await pipeline.record(
            RuntimeDiagnosticEvent(
                subsystem: "runtime",
                name: "run.failed",
                runID: "run-2",
                sessionKey: "session-2",
                metadata: [
                    "timedOut": "true",
                    "latencyMs": "5000",
                ]
            )
        )

        let snapshot = await pipeline.usageSnapshot()
        #expect(snapshot.totalEvents == 7)
        #expect(snapshot.runsStarted == 1)
        #expect(snapshot.runsCompleted == 1)
        #expect(snapshot.runsFailed == 1)
        #expect(snapshot.runsTimedOut == 1)
        #expect(snapshot.totalRunLatencyMs == 333)
        #expect(snapshot.modelCalls == 1)
        #expect(snapshot.modelFailures == 0)
        #expect(snapshot.skillInvocations == 1)
        #expect(snapshot.channelDeliveriesSent == 1)
        #expect(snapshot.channelDeliveriesFailed == 1)
        #expect(snapshot.models.first?.providerID == "openai")
        #expect(snapshot.models.first?.modelID == "gpt-4.1-mini")
        #expect(snapshot.models.first?.averageLatencyMs == 123)
        #expect(snapshot.skills.first?.skillName == "weather")
        #expect(snapshot.skills.first?.averageDurationMs == 42)
        #expect(snapshot.channels.first?.channelID == "discord")
        #expect(snapshot.channels.first?.retryAttempts == 3)
    }

    @Test
    func pipelinePersistsDeterministicReplayEventsFromRuntimeAndChannel() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclawkit-runtime-replay-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let replayStore = FileReplayStore(fileURL: root.appendingPathComponent("events.jsonl", isDirectory: false))
        let pipeline = RuntimeDiagnosticsPipeline(eventLimit: 20, replayStore: replayStore)
        await pipeline.record(
            RuntimeDiagnosticEvent(
                subsystem: "runtime",
                name: "run.started",
                runID: "run-r1",
                sessionKey: "session-r1"
            )
        )
        await pipeline.record(
            RuntimeDiagnosticEvent(
                subsystem: "channel",
                name: "inbound.received",
                sessionKey: "session-r1",
                metadata: ["channel": "webchat"]
            )
        )
        await pipeline.record(
            RuntimeDiagnosticEvent(
                subsystem: "runtime",
                name: "run.completed",
                runID: "run-r1",
                sessionKey: "session-r1",
                metadata: ["latencyMs": "99"]
            )
        )

        let replayEvents = try await replayStore.loadAll()
        #expect(replayEvents.map { $0.event.sequenceNumber ?? -1 } == [0, 1, 2])
        #expect(replayEvents.map(\.event.subsystem) == ["runtime", "channel", "runtime"])
        #expect(replayEvents.map(\.event.name) == ["run.started", "inbound.received", "run.completed"])
    }

    @Test
    func modelFailureMetricsFallbackToRequestedProviderID() async {
        let pipeline = RuntimeDiagnosticsPipeline(eventLimit: 10)
        await pipeline.record(
            RuntimeDiagnosticEvent(
                subsystem: "runtime",
                name: "model.call.failed",
                runID: "run-fallback",
                sessionKey: "session-fallback",
                metadata: [
                    "requestedProviderID": "anthropic",
                    "modelID": "claude",
                    "timedOut": "false",
                ]
            )
        )

        let snapshot = await pipeline.usageSnapshot()
        #expect(snapshot.modelFailures == 1)
        #expect(snapshot.models.first?.providerID == "anthropic")
        #expect(snapshot.models.first?.modelID == "claude")
    }

    @Test
    func pipelinePublishesRecordsToTimelineSink() async {
        let timelineSink = BufferedRuntimeTimelineSink(limit: 20)
        let pipeline = RuntimeDiagnosticsPipeline(
            eventLimit: 20,
            timelineSink: timelineSink
        )
        await pipeline.record(
            RuntimeDiagnosticEvent(
                subsystem: "runtime",
                name: "run.started",
                runID: "timeline-1",
                sessionKey: "timeline-session"
            )
        )
        await pipeline.record(
            RuntimeDiagnosticEvent(
                subsystem: "runtime",
                name: "run.completed",
                runID: "timeline-1",
                sessionKey: "timeline-session"
            )
        )

        let records = await timelineSink.timeline()
        #expect(records.map(\.name) == ["run.started", "run.completed"])
        #expect(records.map(\.runID) == ["timeline-1", "timeline-1"])
    }

    @Test
    func sdkExportsTimelineJSON() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclawkit-timeline-export-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let pipeline = RuntimeDiagnosticsPipeline(eventLimit: 10)
        await pipeline.record(RuntimeDiagnosticEvent(subsystem: "runtime", name: "run.started", runID: "export-1"))
        await pipeline.record(RuntimeDiagnosticEvent(subsystem: "runtime", name: "run.completed", runID: "export-1"))

        let destination = root.appendingPathComponent("timeline.json", isDirectory: false)
        let exported = try await OpenClawSDK.shared.exportRuntimeTimeline(
            from: pipeline,
            limit: 10,
            to: destination
        )
        let data = try Data(contentsOf: exported)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let records = try decoder.decode([RuntimeTimelineRecord].self, from: data)
        #expect(records.count == 2)
        #expect(records.first?.name == "run.started")
        #expect(records.last?.name == "run.completed")
    }

    @Test
    func runtimeEmitsMetricsThroughPipelineSink() async throws {
        let pipeline = RuntimeDiagnosticsPipeline(eventLimit: 100)
        let sink = await pipeline.sink()
        let runtime = EmbeddedAgentRuntime(diagnosticsSink: sink)

        _ = try await runtime.run(
            AgentRunRequest(
                runID: "diag-run-1",
                sessionKey: "session-a",
                prompt: "hello diagnostics"
            )
        )

        let snapshot = await pipeline.usageSnapshot()
        #expect(snapshot.runsStarted == 1)
        #expect(snapshot.runsCompleted == 1)
        #expect(snapshot.modelCalls == 1)
        #expect(snapshot.totalRunLatencyMs >= 0)
        let events = await pipeline.recentEvents(limit: 20)
        #expect(events.contains(where: { $0.subsystem == "runtime" && $0.name == "run.started" }))
        #expect(events.contains(where: { $0.subsystem == "runtime" && $0.name == "run.completed" }))
        #expect(events.contains(where: { $0.subsystem == "runtime" && $0.name == "model.call.completed" }))
    }

    @Test
    func sdkFacadeInjectsPipelineIntoAutoReplyFlow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclawkit-runtime-diagnostics-sdk-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionStoreURL = root.appendingPathComponent("sessions.json", isDirectory: false)
        let sdk = OpenClawSDK.shared
        let pipeline = sdk.makeDiagnosticsPipeline(eventLimit: 200)

        let outbound = try await sdk.getReplyFromConfig(
            config: OpenClawConfig(),
            sessionStoreURL: sessionStoreURL,
            inbound: InboundMessage(channel: .webchat, accountID: "user-1", peerID: "peer", text: "hello"),
            diagnosticsPipeline: pipeline
        )

        #expect(outbound.channel == .webchat)
        let snapshot = await pipeline.usageSnapshot()
        #expect(snapshot.runsStarted == 1)
        #expect(snapshot.runsCompleted == 1)
        #expect(snapshot.channelDeliveriesSent == 1)
        let channels = snapshot.channels.map(\.channelID)
        #expect(channels.contains("webchat"))
    }
}
