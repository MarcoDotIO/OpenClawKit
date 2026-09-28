#if canImport(CoreSpotlight) && !os(tvOS) && !os(watchOS)
import CoreSpotlight
import Foundation
import Testing
import OpenClawProtocol
@testable import OpenClawMemory

@Suite("Spotlight memory backends")
struct SpotlightMemoryTests {
    @Test
    func mirrorBackedSearchAndIdentifierParsing() async throws {
        let index = SpotlightMemoryIndex(indexName: "ai.openclaw.memory.tests.\(UUID().uuidString)", useUserQuery: false)
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

        let item = SpotlightMemoryIndex.item(for: MemoryDocument(id: "x", source: .toolResult, text: String(repeating: "t", count: 100)), domain: "openclaw.memory.main")
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
        let indexer = SpotlightMemoryIndexer(agentID: "tests-\(UUID().uuidString)", protection: nil)
        try await indexer.sync(from: engine)
        let hits = try await indexer.search(query: "quokka")
        #expect(hits.first?.path == "memory/trip.md")
        #expect(hits.first?.startLine == 1)
        try await indexer.reset()
    }

    #if compiler(>=6.4) && canImport(FoundationModels)
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
