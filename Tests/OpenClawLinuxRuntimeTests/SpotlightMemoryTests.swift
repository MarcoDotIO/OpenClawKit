#if canImport(CoreSpotlight) && !os(tvOS) && !os(watchOS)
import CoreSpotlight
import Foundation
import Testing
import OpenClawProtocol
@testable import OpenClawMemory

/// In-memory ``SpotlightItemIndexing`` that models Spotlight's hierarchical domain deletion, so the
/// suite never depends on `corespotlightd` (set `OPENCLAW_LIVE_SPOTLIGHT=1` to use the system index).
final class FakeSpotlightStore: SpotlightItemIndexing, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    private var hangs: Bool
    private var stalled: [@Sendable ((any Error)?) -> Void] = []

    init(hangs: Bool = false) {
        self.hangs = hangs
    }

    /// Answers the calls a hanging store left pending, and every later call.
    func stopHanging() {
        let stalled = self.lock.withLock {
            self.hangs = false
            defer { self.stalled.removeAll() }
            return self.stalled
        }
        for completion in stalled { completion(nil) }
    }

    /// Keeps `completion` pending when the store hangs.
    private func stalls(_ completion: @escaping @Sendable ((any Error)?) -> Void) -> Bool {
        self.lock.withLock {
            if self.hangs { self.stalled.append(completion) }
            return self.hangs
        }
    }

    var isAvailable: Bool {
        true
    }

    /// Indexed identifiers mapped to their domain.
    var snapshot: [String: String] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.items
    }

    func indexItems(_ items: [CSSearchableItem], completion: @escaping @Sendable ((any Error)?) -> Void) {
        guard !self.stalls(completion) else { return }
        self.lock.lock()
        for item in items { self.items[item.uniqueIdentifier] = item.domainIdentifier ?? "" }
        self.lock.unlock()
        completion(nil)
    }

    func deleteItems(identifiers: [String], completion: @escaping @Sendable ((any Error)?) -> Void) {
        guard !self.stalls(completion) else { return }
        self.lock.lock()
        for id in identifiers { self.items.removeValue(forKey: id) }
        self.lock.unlock()
        completion(nil)
    }

    func deleteItems(domains: [String], completion: @escaping @Sendable ((any Error)?) -> Void) {
        guard !self.stalls(completion) else { return }
        self.lock.lock()
        self.items = self.items.filter { _, domain in
            !domains.contains { domain == $0 || domain.hasPrefix($0 + ".") }
        }
        self.lock.unlock()
        completion(nil)
    }
}

/// Tells a stalled test operation to stop.
final class StallFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var ended = false

    var isEnded: Bool {
        self.lock.withLock { self.ended }
    }

    func end() {
        self.lock.withLock { self.ended = true }
    }
}

@Suite("Spotlight memory backends")
struct SpotlightMemoryTests {
    static var live: Bool {
        ProcessInfo.processInfo.environment["OPENCLAW_LIVE_SPOTLIGHT"] == "1"
    }

    static func index(store: FakeSpotlightStore, prefix: String = "openclaw.memory", writeTimeoutSeconds: Double = 10) -> SpotlightMemoryIndex {
        SpotlightMemoryIndex(
            indexName: "ai.openclaw.memory.tests",
            domainPrefix: prefix,
            store: store,
            useUserQuery: false,
            writeTimeoutSeconds: writeTimeoutSeconds
        )
    }

    @Test
    func timeoutRaceAcceptsInfiniteAndHugeDeadlines() async {
        let infinite: Int? = await SpotlightTimeoutRace.first(timeoutSeconds: .infinity) { 42 }
        #expect(infinite == 42)
        let huge: Int? = await SpotlightTimeoutRace.first(timeoutSeconds: 1e12) { 42 }
        #expect(huge == 42)
        let nan: Int? = await SpotlightTimeoutRace.first(timeoutSeconds: .nan) { 42 }
        #expect(nan == 42)
        #expect(SpotlightTimeoutRace.deadlineNanoseconds(.infinity) == nil)
        #expect(SpotlightTimeoutRace.deadlineNanoseconds(2e10) == UInt64(SpotlightTimeoutRace.maxTimeoutSeconds * 1_000_000_000))
        #expect(SpotlightTimeoutRace.deadlineNanoseconds(-5) == 50_000_000)
    }

    @Test(.timeLimit(.minutes(1)))
    func indexWritesAreBoundedWhenSpotlightNeverAnswers() async throws {
        let store = FakeSpotlightStore(hangs: true)
        let index = Self.index(store: store, writeTimeoutSeconds: 0.2)
        // The errors name the 0.2 s deadline. A write without one would hang until the time limit,
        // whose cancellation answers the stalled calls so the test can end.
        await withTaskCancellationHandler {
            await #expect(throws: SpotlightTimeoutError(operation: "indexSearchableItems", seconds: 0.2)) {
                try await index.upsert([MemoryDocument(id: "a", source: .systemNote, text: "stalled write")], sessionKey: nil)
            }
            await #expect(throws: SpotlightTimeoutError(operation: "deleteSearchableItems(withDomainIdentifiers:)", seconds: 0.2)) {
                try await index.deleteAll()
            }
        } onCancel: {
            store.stopHanging()
        }
    }

    @Test
    func deleteSessionForgetsDocumentsWithoutSessionMetadata() async throws {
        let store = FakeSpotlightStore()
        let index = Self.index(store: store)
        try await index.upsert([
            MemoryDocument(id: "s1-a", source: .userMessage, text: "The vault code is heron"),
            MemoryDocument(id: "s1-b", source: .userMessage, text: "Heron migration notes"),
        ], sessionKey: "s1")
        try await index.upsert([MemoryDocument(id: "s2-a", source: .userMessage, text: "Heron sighting at the lake")], sessionKey: "s2")
        #expect(try await index.search(query: "heron", maxResults: 5, minScore: 0).count == 3)

        try await index.deleteSession("s1")
        let remaining = try await index.search(query: "heron", maxResults: 5, minScore: 0)
        #expect(remaining.map(\.id) == ["s2-a"])
        #expect(Set(store.snapshot.keys) == ["s2-a"])
    }

    @Test
    func sessionDomainsAreNotDotPrefixesOfEachOther() async throws {
        let store = FakeSpotlightStore()
        let index = Self.index(store: store)
        #expect(index.domain(forSession: "a.b") == "openclaw.memory.a%2Eb")
        #expect(index.domain(forSession: "a%2Eb") == "openclaw.memory.a%252Eb")
        #expect(index.domain(forSession: nil) == "openclaw.memory")
        try await index.upsert([MemoryDocument(id: "short", source: .systemNote, text: "short key")], sessionKey: "agent:dm:alice@example")
        try await index.upsert([MemoryDocument(id: "long", source: .systemNote, text: "long key")], sessionKey: "agent:dm:alice@example.com")
        try await index.deleteSession("agent:dm:alice@example")
        #expect(Set(store.snapshot.keys) == ["long"])
        #expect(try await index.search(query: "long key", maxResults: 5, minScore: 0).map(\.id) == ["long"])
    }

    @Test
    func freshIndexerRemovesChunksIndexedByAnEarlierProcess() async throws {
        let root = try RuntimeExtTestSupport.temporaryDirectory("spotlight-relaunch")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("memory/2026-01-01.md")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "Sensitive entry about the lockbox".write(to: file, atomically: true, encoding: .utf8)
        let engine = MemoryEngine(workspaceRoot: root)
        await engine.sync()
        let store = FakeSpotlightStore()
        let prefix = SpotlightMemoryIndexer.domainPrefix(agentID: "main")
        #expect(prefix == "ai.openclaw.memory.main")
        #expect(SpotlightMemoryIndexer.domainPrefix(agentID: "main.x") == "ai.openclaw.memory.main%2Ex")
        // Another agent whose id starts with "main." must survive agent main's reconciliation.
        let other = SpotlightMemoryIndexer(agentID: "main.x", index: Self.index(store: store, prefix: SpotlightMemoryIndexer.domainPrefix(agentID: "main.x")))
        try await other.sync(from: engine)

        let first = SpotlightMemoryIndexer(agentID: "main", index: Self.index(store: store, prefix: prefix))
        try await first.sync(from: engine)
        let oldID = SpotlightMemoryIndexer.identifier(agentID: "main", path: "memory/2026-01-01.md", startLine: 1, endLine: 1)
        #expect(store.snapshot[oldID] == prefix)

        // Relaunch: the file changed (line ranges moved) and a brand-new indexer syncs.
        try "# Header\n\nUnrelated notes".write(to: file, atomically: true, encoding: .utf8)
        await engine.sync()
        let second = SpotlightMemoryIndexer(agentID: "main", index: Self.index(store: store, prefix: prefix))
        try await second.sync(from: engine)
        let mainIDs = store.snapshot.filter { $0.value == prefix }.map(\.key)
        #expect(!mainIDs.contains(oldID))
        #expect(!mainIDs.isEmpty)
        #expect(store.snapshot.values.contains(SpotlightMemoryIndexer.domainPrefix(agentID: "main.x")))

        // Later syncs in the same indexer delete only what disappeared.
        try FileManager.default.removeItem(at: file)
        await engine.sync()
        try await second.sync(from: engine)
        #expect(store.snapshot.values.contains(prefix) == false)
    }

    @Test
    func splitLineChunksGetDistinctSpotlightIdentifiers() async throws {
        let root = try RuntimeExtTestSupport.temporaryDirectory("spotlight-split")
        defer { try? FileManager.default.removeItem(at: root) }
        let words = (0..<600).map { "part\($0)w" }.joined(separator: " ")
        try "\(words)\n".write(to: root.appendingPathComponent("MEMORY.md"), atomically: true, encoding: .utf8)
        let engine = MemoryEngine(workspaceRoot: root)
        await engine.sync()
        let store = FakeSpotlightStore()
        let indexer = SpotlightMemoryIndexer(agentID: "main", index: Self.index(store: store, prefix: SpotlightMemoryIndexer.domainPrefix(agentID: "main")))
        try await indexer.sync(from: engine)
        let chunkCount = await engine.indexedChunks().count
        #expect(chunkCount >= 2)
        #expect(store.snapshot.count == chunkCount)
        let hits = try await indexer.search(query: "part599w")
        #expect(hits.first?.path == "MEMORY.md")
        #expect(hits.first?.startLine == 1)
    }

    @Test
    func replyCoordinatorRoutesRepliesToOneInvocationAtATime() async throws {
        struct Reply: Sendable, Equatable {
            let label: String
            let complete: Bool
        }
        let (stream, feed) = AsyncStream<Reply>.makeStream()
        let coordinator = SpotlightReplyCoordinator<Reply> { $0.complete }
        coordinator.ensurePump { deliver in
            for await reply in stream { deliver(reply) }
        }
        coordinator.ensurePump { _ in Issue.record("the pump starts only once") }

        // A timed-out invocation must not end the shared stream for later invocations.
        let timedOut = await coordinator.withExclusiveAccess { () -> Reply? in
            coordinator.openSlot()
            let reply = await coordinator.completeReply(timeoutSeconds: 0.1)
            coordinator.closeSlot()
            return reply
        }
        #expect(timedOut == nil)
        feed.yield(Reply(label: "stale", complete: true))

        async let first = coordinator.withExclusiveAccess { () -> Reply? in
            coordinator.openSlot()
            try? await Task.sleep(nanoseconds: 50_000_000)
            feed.yield(Reply(label: "A-partial", complete: false))
            feed.yield(Reply(label: "A", complete: true))
            let reply = await coordinator.completeReply(timeoutSeconds: 5)
            coordinator.closeSlot()
            return reply
        }
        async let second = coordinator.withExclusiveAccess { () -> Reply? in
            coordinator.openSlot()
            feed.yield(Reply(label: "B", complete: true))
            let reply = await coordinator.completeReply(timeoutSeconds: 5)
            coordinator.closeSlot()
            return reply
        }
        let labels = Set([await first?.label, await second?.label].compactMap { $0 })
        #expect(labels == ["A", "B"])
        feed.finish()
    }

    @Test(.timeLimit(.minutes(1)))
    func timeoutRaceReturnsWithoutJoiningAStalledOperation() async throws {
        // The operation ignores cancellation and never finishes on its own, like a stalled CSUserQuery.
        // It stops once the test ends, or when the time limit cancels a race that waits for it.
        let stall = StallFlag()
        defer { stall.end() }
        let value: Int? = await withTaskCancellationHandler {
            await SpotlightTimeoutRace.first(timeoutSeconds: 0.2) {
                while !stall.isEnded {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                return 0
            }
        } onCancel: {
            stall.end()
        }
        #expect(value == nil)
        let fast: Int? = try await awaitCancellable("fast operation won the race") {
            await SpotlightTimeoutRace.first(timeoutSeconds: 3_600) { 42 }
        }
        #expect(fast == 42)
    }

    @Test
    func mirrorBackedSearchAndIdentifierParsing() async throws {
        let index = Self.live
            ? SpotlightMemoryIndex(indexName: "ai.openclaw.memory.tests.\(UUID().uuidString)", useUserQuery: false)
            : Self.index(store: FakeSpotlightStore())
        try await index.upsert([
            MemoryDocument(id: "a", source: .userMessage, text: "The deploy window is Thursday", metadata: ["sessionKey": "main"]),
            MemoryDocument(id: "b", source: .systemNote, text: "Garden watering schedule"),
        ], sessionKey: "main")
        let results = try await index.search(query: "deploy thursday", maxResults: 5, minScore: 0.1)
        #expect(results.map(\.id) == ["a"])
        try await index.delete(ids: ["a"])
        #expect(try await index.search(query: "deploy", maxResults: 5, minScore: 0).isEmpty)
        try await index.deleteAll()

        let id = SpotlightMemoryIndexer.identifier(agentID: "main", path: "memory/2026-01-01.md", startLine: 3, endLine: 9)
        #expect(id == "memory:main:memory/2026-01-01.md#L3-9")
        let parsed = try #require(SpotlightMemoryIndexer.parse(identifier: id, agentID: "main"))
        #expect(parsed.path == "memory/2026-01-01.md" && parsed.startLine == 3 && parsed.endLine == 9)
        #expect(SpotlightMemoryIndexer.parse(identifier: id, agentID: "other") == nil)
        let partID = SpotlightMemoryIndexer.identifier(agentID: "main", path: "memory/2026-01-01.md", startLine: 3, endLine: 3, part: 2)
        #expect(partID == "memory:main:memory/2026-01-01.md#L3-3~2")
        let parsedPart = try #require(SpotlightMemoryIndexer.parse(identifier: partID, agentID: "main"))
        #expect(parsedPart.path == "memory/2026-01-01.md" && parsedPart.startLine == 3 && parsedPart.endLine == 3)
        #expect(SpotlightMemoryIndexer.parse(identifier: "memory:main:x.md#L3-3~zz", agentID: "main") == nil)

        let item = SpotlightMemoryIndex.item(
            for: MemoryDocument(id: "x", source: .toolResult, text: String(repeating: "t", count: 100)),
            domain: "openclaw.memory.main"
        )
        #expect(item.uniqueIdentifier == "x")
        #expect(item.domainIdentifier == "openclaw.memory.main")
        #expect(item.attributeSet.title?.count == 80)
        #expect(item.attributeSet.keywords == ["tool_result"])
    }

    @Test
    func indexerMirrorsEngineChunksAndSearchFallsBack() async throws {
        let root = try RuntimeExtTestSupport.temporaryDirectory("spotlight")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("memory"), withIntermediateDirectories: true)
        try "Remember the quokka photo from Rottnest.".write(to: root.appendingPathComponent("memory/trip.md"), atomically: true, encoding: .utf8)
        let engine = MemoryEngine(workspaceRoot: root)
        await engine.sync()
        let agentID = "tests-\(UUID().uuidString)"
        let indexer = Self.live
            ? SpotlightMemoryIndexer(agentID: agentID, protection: nil)
            : SpotlightMemoryIndexer(
                agentID: agentID,
                index: Self.index(store: FakeSpotlightStore(), prefix: SpotlightMemoryIndexer.domainPrefix(agentID: agentID))
            )
        try await indexer.sync(from: engine)
        let hits = try await indexer.search(query: "quokka")
        #expect(hits.first?.path == "memory/trip.md")
        #expect(hits.first?.startLine == 1)
        try await indexer.reset()
    }

    #if compiler(>=6.4) && canImport(FoundationModels) && arch(arm64)
    @Test
    func spotlightSearchToolSchemaConversion() throws {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, *) else { return }
        let tool = SpotlightSearchAgentTool()
        let descriptor = tool.descriptor
        #expect(descriptor.name == "spotlight_search")
        #expect(descriptor.display?.emoji == "🔎")
        #expect(descriptor.sectionID == "web")
        #expect(descriptor.parameters["type"]?.stringValue == "object")
        #expect(descriptor.parameters["properties"]?.dictionaryValue?.isEmpty == false)
        #expect(!descriptor.description.isEmpty)
    }
    #endif
}
#endif
