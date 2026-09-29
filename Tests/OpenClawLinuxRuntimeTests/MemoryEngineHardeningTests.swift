import Foundation
import Testing
import OpenClawAgents
import OpenClawCore
import OpenClawProtocol
@testable import OpenClawMemory

@Suite("Memory engine hardening")
struct MemoryEngineHardeningTests {
    private func workspace(_ files: [String: String]) throws -> URL {
        let root = try RuntimeExtTestSupport.temporaryDirectory("memory-hardening")
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    /// One 5,000+ byte line built from distinct words, so every split part has its own keyword.
    private static func longLine(prefix: String) -> (line: String, words: [String]) {
        let words = (0..<700).map { "\(prefix)\($0)w" }
        return (words.joined(separator: " "), words)
    }

    @Test(arguments: ["ascii", "cjk"])
    func longLinesSplitIntoUniqueChunkIDsAndStaySearchable(variant: String) async throws {
        let line: String
        let probes: [String]
        if variant == "cjk" {
            // 3,000 CJK characters weigh 6,000 chars in the chunker, so the single line splits into parts.
            line = String(repeating: "界", count: 3_000) + " cjkmarker"
            probes = ["cjkmarker"]
        } else {
            let built = Self.longLine(prefix: "tok")
            line = built.line
            probes = [built.words[0], built.words[350], built.words[699]]
        }
        #expect(line.utf8.count >= 5_000)
        let root = try self.workspace(["MEMORY.md": "# Notes\n\(line)\ntrailing line"])
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("state/index.json")
        let engine = MemoryEngine(workspaceRoot: root, indexURL: indexURL)
        await engine.sync()

        let chunks = await engine.indexedChunks()
        let lineTwo = chunks.filter { $0.startLine == 2 && $0.endLine == 2 }
        #expect(lineTwo.count >= 2, "the long line is split into several parts that share one range")
        #expect(lineTwo.map(\.part) == Array(0..<lineTwo.count))

        for probe in probes {
            let first = try await engine.search(query: probe, minScore: 0)
            #expect(first.hits.contains { $0.path == "MEMORY.md" }, "\(probe) is findable")
            let second = try await engine.search(query: probe, minScore: 0)
            #expect(second.hits.count == first.hits.count)
        }

        // A fresh engine loads the persisted index and searches without re-chunking or trapping.
        let reopened = MemoryEngine(workspaceRoot: root, indexURL: indexURL)
        for probe in probes {
            #expect(try await reopened.search(query: probe, minScore: 0).hits.contains { $0.startLine == 2 })
        }
    }

    @Test
    func chunkIDsCarryPartOrdinalsOnlyForRepeatedRanges() {
        var parts: [String: Int] = [:]
        #expect(MemoryEngine.chunkID(path: "MEMORY.md", startLine: 2, endLine: 2, parts: &parts) == "MEMORY.md#L2-2")
        #expect(MemoryEngine.chunkID(path: "MEMORY.md", startLine: 2, endLine: 2, parts: &parts) == "MEMORY.md#L2-2~1")
        #expect(MemoryEngine.chunkID(path: "MEMORY.md", startLine: 2, endLine: 3, parts: &parts) == "MEMORY.md#L2-3")
        #expect(MemoryEngine.chunkID(path: "MEMORY.md", startLine: 2, endLine: 2, parts: &parts) == "MEMORY.md#L2-2~2")
        let path = "memory/~odd~3.md"
        let chunk = MemoryEngine.IndexedChunk(id: "\(path)#L1-1~4", path: path, startLine: 1, endLine: 1, text: "x", hash: "h", datedAt: nil)
        #expect(chunk.part == 4)
        let plain = MemoryEngine.IndexedChunk(id: "\(path)#L1-1", path: path, startLine: 1, endLine: 1, text: "x", hash: "h", datedAt: nil)
        #expect(plain.part == 0)
    }

    @Test
    func persistedIndexWithDuplicateIDsDoesNotTrapAndIsRechunked() async throws {
        let root = try self.workspace(["MEMORY.md": "falcon notes"])
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("state/index.json")
        let data = try Data(contentsOf: root.appendingPathComponent("MEMORY.md"))
        var legacy = MemoryEngine.PersistedIndex()
        legacy.files["MEMORY.md"] = OpenClawCrypto.sha256Hex(data)
        let duplicate = MemoryEngine.IndexedChunk(
            id: "MEMORY.md#L1-1", path: "MEMORY.md", startLine: 1, endLine: 1, text: "falcon notes", hash: "h", datedAt: nil
        )
        legacy.chunks = [duplicate, duplicate]
        try FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(legacy).write(to: indexURL)

        let engine = MemoryEngine(workspaceRoot: root, indexURL: indexURL)
        let outcome = try await engine.search(query: "falcon", minScore: 0)
        #expect(outcome.hits.count == 1)
        let ids = await engine.indexedChunks().map { "\($0.path)#\($0.startLine)-\($0.endLine)~\($0.part)" }
        #expect(Set(ids).count == ids.count, "the duplicate-bearing index was re-chunked")
    }

    @Test
    func hugeModelSuppliedCountsAreClampedInsteadOfTrapping() async throws {
        let lines = (1...30).map { "line \($0) falcon" }.joined(separator: "\n")
        let root = try self.workspace(["memory/log.md": lines])
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = MemoryEngine(workspaceRoot: root)
        let registry = AgentToolRegistry(tools: [MemorySearchTool(engine: engine), MemoryGetTool(engine: engine)])

        for lines in [AnyCodable(1e19), AnyCodable(Int.max), AnyCodable(3_000_000_000.0)] {
            let excerpt = try await registry.invoke(AgentToolCall(name: "memory_get", arguments: ["path": AnyCodable("memory/log.md"), "lines": lines]))
            #expect(!excerpt.isError)
            #expect(excerpt.value.dictionaryValue?["lines"]?.intValue == 30)
        }
        let far = try await registry.invoke(AgentToolCall(name: "memory_get", arguments: ["path": AnyCodable("memory/log.md"), "from": AnyCodable(1e300)]))
        #expect(!far.isError)
        #expect(far.value.dictionaryValue?["lines"]?.intValue == 0)
        let infinite = try await registry.invoke(
            AgentToolCall(name: "memory_get", arguments: ["path": AnyCodable("memory/log.md"), "lines": AnyCodable(Double.infinity)])
        )
        #expect(infinite.isError)

        for maxResults in [AnyCodable(Int.max), AnyCodable(1e19)] {
            let found = try await registry.invoke(AgentToolCall(name: "memory_search", arguments: ["query": AnyCodable("falcon"), "maxResults": maxResults]))
            #expect(!found.isError)
        }
        #expect(await engine.read(path: "memory/log.md", from: 5, lines: Int.max).lines == 26)
        #expect(try await engine.search(query: "falcon", maxResults: Int.max, minScore: 0).hits.isEmpty == false)
    }
}
