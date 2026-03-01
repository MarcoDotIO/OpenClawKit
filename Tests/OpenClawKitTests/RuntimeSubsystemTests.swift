import Foundation
import Testing
@testable import OpenClawKit

@Suite("Runtime subsystems")
struct RuntimeSubsystemTests {
    @Test
    func memorySearchReturnsScoredResults() async {
        let memory = MemoryIndex()
        await memory.upsert(MemoryDocument(id: "1", source: .userMessage, text: "deploy release checklist"))
        await memory.upsert(MemoryDocument(id: "2", source: .systemNote, text: "buy groceries"))

        let results = await memory.search(query: "release deploy", maxResults: 5, minScore: 0.1)
        #expect(results.count == 1)
        #expect(results.first?.id == "1")
    }

    @Test
    func mediaPipelineClassifiesMimeTypes() async throws {
        let media = MediaPipeline(maxBytes: 1024)
        let kind = await media.kind(for: "image/png")
        #expect(kind == .image)

        let blob = MediaBlob(mimeType: "image/png", data: Data(repeating: 1, count: 100))
        let normalized = try await media.normalize(blob)
        #expect(normalized.mimeType == "image/png")
    }

    @Test
    func hookRegistryEmitsHandlers() async throws {
        let hooks = HookRegistry()
        await hooks.register(.gatewayStart) { context in
            HookResult(metadata: ["session": AnyCodable(context.sessionKey ?? "")])
        }

        let result = try await hooks.emit(.gatewayStart, context: HookContext(sessionKey: "main"))
        #expect(result.count == 1)
    }

    @Test
    func cronSchedulerRunsDueJobs() async {
        let scheduler = CronScheduler()
        await scheduler.addOrUpdate(
            CronJob(
                id: "job-a",
                intervalSeconds: 60,
                payload: "run report",
                nextRunAt: Date().addingTimeInterval(-5)
            )
        )

        let due = await scheduler.runDue()
        #expect(due.count == 1)
        #expect(due.first?.jobID == "job-a")
    }

    @Test
    func securityRuntimeTracksPairingAndApprovals() async {
        let security = SecurityRuntime()
        await security.approveDevice(deviceID: "device-1", role: "operator", token: "tok-1")
        await security.setExecApproval(command: "ls", approved: true)

        #expect(await security.pairedDevice("device-1")?.role == "operator")
        #expect(await security.isExecApproved(command: "ls") == true)
    }

    @Test
    func replayStoreAppendsAndLoadsInDeterministicOrder() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclawkit-replay-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("events.jsonl", isDirectory: false)
        let store = FileReplayStore(fileURL: path)

        try await store.append(contentsOf: [
            makeReplayEnvelope(name: "run.started"),
            makeReplayEnvelope(name: "model.call.completed"),
            makeReplayEnvelope(name: "run.completed"),
        ])

        let loaded = try await store.loadAll()
        #expect(loaded.map(\.event.name) == ["run.started", "model.call.completed", "run.completed"])
        #expect(loaded.map { $0.event.sequenceNumber ?? -1 } == [0, 1, 2])
    }

    @Test
    func replayStoreCompactsAndRecoversCorruptedTail() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclawkit-replay-compact-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("events.jsonl", isDirectory: false)
        let store = FileReplayStore(fileURL: path)

        for index in 0..<5 {
            try await store.append(makeReplayEnvelope(name: "event.\(index)"))
        }

        let compacted = try await store.compact(keepingLast: 2)
        #expect(compacted.removedCount == 3)
        #expect(compacted.remainingCount == 2)
        #expect(compacted.compactedThroughSequence == 2)

        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("invalid-json-line\n".utf8))

        let dropped = try await store.recover()
        #expect(dropped == 1)
        let loaded = try await store.loadAll()
        #expect(loaded.count == 2)
        #expect(loaded.map(\.event.name) == ["event.3", "event.4"])
        #expect(loaded.map { $0.event.sequenceNumber ?? -1 } == [3, 4])
    }

    private func makeReplayEnvelope(name: String) -> ReplayEventEnvelope {
        ReplayEventEnvelope(
            event: ReplayEvent(
                subsystem: "runtime",
                name: name,
                runID: "run-1",
                sessionKey: "main",
                occurredAt: Date(timeIntervalSince1970: 123_000),
                metadata: ["source": "test"]
            )
        )
    }
}

