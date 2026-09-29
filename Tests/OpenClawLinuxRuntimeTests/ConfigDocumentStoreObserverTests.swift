import Foundation
import Testing
@testable import OpenClawCore

@Suite("Config document store events")
struct ConfigDocumentStoreObserverTests {
    final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [OpenClawConfigDocumentStore.Event] = []

        func append(_ event: OpenClawConfigDocumentStore.Event) {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.storage.append(event)
        }

        var events: [OpenClawConfigDocumentStore.Event] {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.storage
        }
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclawkit-config-store-events-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test
    func reportsLoadsSavesConflictsAndParseFailures() async throws {
        let directory = try self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("openclaw.json")
        let log = EventLog()
        let store = OpenClawConfigDocumentStore(fileURL: url, environment: [:], observer: { log.append($0) })
        #expect(store.usesDefaultLocation == false)

        let missing = try await store.load()
        #expect(log.events == [.loaded(missing)])

        var document = OpenClawConfigDocument()
        document.additionalProperties["memorySearch"] = .init(.object(["enabled": .init(.bool(true))]))
        let saved = try await store.save(document, expectedHash: nil)
        guard case .saved(let reported, let applied)? = log.events.last else {
            Issue.record("expected a saved event")
            return
        }
        #expect(reported == saved)
        #expect(!applied.isEmpty)

        do {
            try await store.save(OpenClawConfigDocument(), expectedHash: "stale")
            Issue.record("expected a conflict")
        } catch {}
        guard case .writeRefused(.conflict(let expected, _), _)? = log.events.last else {
            Issue.record("expected a refused write")
            return
        }
        #expect(expected == "stale")

        try Data("{ not json".utf8).write(to: url)
        await #expect(throws: (any Error).self) {
            _ = try await store.load()
        }
        guard case .loadFailed? = log.events.last else {
            Issue.record("expected a load failure")
            return
        }
    }

    @Test
    func defaultLocationIsDetected() {
        let environment = ["OPENCLAW_STATE_DIR": "/tmp/openclaw-state-\(UUID().uuidString)"]
        let implicit = OpenClawConfigDocumentStore(fileURL: nil, environment: environment, observer: nil)
        #expect(implicit.usesDefaultLocation)
        let explicitDefault = OpenClawConfigDocumentStore(
            fileURL: OpenClawConfigDocumentStore.defaultConfigURL(environment: environment),
            environment: environment
        )
        #expect(explicitDefault.usesDefaultLocation)
    }
}
