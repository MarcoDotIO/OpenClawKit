import Foundation
import Testing
import OpenClawAgents
import OpenClawCore
import OpenClawGateway
import OpenClawProtocol
@testable import OpenClawMemory

@Suite("Memory engine, tools and memory.search")
struct MemoryEngineParityTests {
    /// Deterministic "embedding": one dimension per keyword.
    struct KeywordEmbedding: MemoryEmbeddingProvider {
        let id = "keywords"
        let model = "test"
        let dimensions = 3
        func embed(_ texts: [String], inputType _: MemoryEmbeddingInputType) async throws -> [[Float]] {
            texts.map { text in
                let lower = text.lowercased()
                return [lower.contains("deploy") ? 1 : 0, lower.contains("garden") ? 1 : 0, lower.contains("release") ? 1 : 0]
            }
        }
    }

    struct FailingEmbedding: MemoryEmbeddingProvider {
        let id = "broken"
        let model = "x"
        let dimensions = 0
        func embed(_: [String], inputType _: MemoryEmbeddingInputType) async throws -> [[Float]] {
            throw MemoryUnavailableError(provider: "broken", reason: "offline")
        }
    }

    private func workspace(_ files: [String: String]) throws -> URL {
        let root = try RuntimeExtTestSupport.temporaryDirectory("memory")
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    private static let now = Date(timeIntervalSince1970: 1_789_948_800) // 2026-09-21T00:00:00Z

    @Test
    func corpusEnumeratesEvergreenMemoryAndExtraPaths() throws {
        let root = try self.workspace([
            "MEMORY.md": "root",
            "USER.md": "user",
            "memory/2026-01-01.md": "dated",
            "memory/topics/deep.md": "nested",
            "memory/.hidden.md": "hidden",
            "memory/notes.txt": "not markdown",
            "notes/extra.md": "extra",
            "notes/skip.md": "skip",
            "other.md": "not in corpus",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let corpus = MemoryCorpus(workspaceRoot: root, extraPaths: [MemoryExtraPath(path: "notes", pattern: "extra*.md")])
        #expect(corpus.files().map(\.path) == ["MEMORY.md", "USER.md", "memory/2026-01-01.md", "memory/topics/deep.md", "notes/extra.md"])
        #expect(corpus.resolveReadablePath("memory/topics/deep.md") != nil)
        #expect(corpus.resolveReadablePath("notes/extra.md") != nil)
        #expect(corpus.resolveReadablePath("notes/skip.md") == nil)
        #expect(corpus.resolveReadablePath("other.md") == nil)
        #expect(corpus.resolveReadablePath("../etc/passwd") == nil)
        #expect(corpus.resolveReadablePath("memory/../other.md") == nil)
        #expect(corpus.resolveReadablePath("sessions/main.jsonl") == nil)
    }

    @Test
    func chunkerWindowsWithOverlap() {
        let lines = (1...60).map { "line \($0) " + String(repeating: "x", count: 30) }
        let chunks = MemoryChunker(tokens: 100, overlap: 20).chunk(lines.joined(separator: "\n"))
        #expect(chunks.count > 1)
        #expect(chunks.first?.startLine == 1)
        #expect(chunks.last?.endLine == 60)
        for pair in zip(chunks, chunks.dropFirst()) {
            #expect(pair.1.startLine <= pair.0.endLine, "chunks overlap")
            #expect(pair.1.startLine > pair.0.startLine)
        }
        #expect(MemoryChunker.estimatedTokens("abcd") == 1)
        #expect(MemoryChunker.estimatedTokens("你好") == 2)
        let wide = MemoryChunker(tokens: 10, overlap: 0).chunk(String(repeating: "界", count: 25))
        #expect(wide.count == 3)
        #expect(wide.allSatisfy { $0.startLine == 1 })
    }

    @Test
    func recencyDecayRanksNewerDatedFilesHigher() async throws {
        let root = try self.workspace([
            "memory/2026-09-21.md": "Project falcon launch checklist.",
            "memory/2026-08-22-falcon.md": "Project falcon launch checklist.",
            "memory/2025-09-21.md": "Project falcon launch checklist.",
            "MEMORY.md": "Project falcon launch checklist.",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = MemoryEngine(workspaceRoot: root, configuration: MemoryEngineConfiguration(mmrLambda: 1), now: { Self.now })
        let outcome = try await engine.search(query: "falcon launch", maxResults: 10, minScore: 0)
        #expect(outcome.searchMode == "fts-only")
        #expect(outcome.provider == "none")
        let byPath = Dictionary(uniqueKeysWithValues: outcome.hits.map { ($0.path, $0.score) })
        let today = try #require(byPath["memory/2026-09-21.md"])
        let month = try #require(byPath["memory/2026-08-22-falcon.md"])
        let year = try #require(byPath["memory/2025-09-21.md"])
        let evergreen = try #require(byPath["MEMORY.md"])
        #expect(abs(today - evergreen) < 1e-9)
        #expect(abs(month / today - 0.5) < 0.02)
        #expect(year < 0.001)
        #expect(outcome.hits.last?.path == "memory/2025-09-21.md")
        #expect(MemoryEngine.recencyMultiplier(path: "memory/2026-02-30.md", now: Self.now, halfLifeDays: 30) == 1)
        #expect(MemoryEngine.datedMemoryDate("notes/2026-01-01.md") == nil)
        #expect(outcome.hits.first?.citation?.hasSuffix("#L1-1") == true)
    }

    @Test
    func mmrDeduplicatesNearIdenticalSnippets() {
        let hits = [
            MemorySearchHit(path: "a.md", startLine: 1, endLine: 1, score: 1.0, snippet: "deploy the release to production servers"),
            MemorySearchHit(path: "b.md", startLine: 1, endLine: 1, score: 0.99, snippet: "deploy the release to production servers now"),
            MemorySearchHit(path: "c.md", startLine: 1, endLine: 1, score: 0.98, snippet: "garden watering schedule for tomatoes"),
            MemorySearchHit(path: "d.md", startLine: 1, endLine: 1, score: 0.5, snippet: "unrelated trivia about lighthouses"),
        ]
        let reranked = MemoryEngine.mmrRerank(hits, lambda: 0.7)
        #expect(reranked.map(\.path) == ["a.md", "c.md", "b.md", "d.md"])
        #expect(reranked.map(\.score) == [1.0, 0.98, 0.99, 0.5])
        #expect(MemoryEngine.mmrRerank(hits, lambda: 1).map(\.path) == ["a.md", "b.md", "c.md", "d.md"])
    }

    @Test
    func hybridSearchKeywordPreservationAndFilenameRanking() async throws {
        let root = try self.workspace([
            "memory/deploy-notes.md": "Deploy checklist: tag, build, ship.",
            "memory/garden.md": "Water the garden on Sundays.",
            "memory/release.md": "Release train cadence is weekly.",
            "USER.md": "Prefers zebra-striped socks.",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = MemoryEngine(workspaceRoot: root, embeddingProvider: KeywordEmbedding(), now: { Self.now })
        let semantic = try await engine.search(query: "deploy", maxResults: 3)
        #expect(semantic.searchMode == "hybrid")
        #expect(semantic.hits.first?.path == "memory/deploy-notes.md")
        #expect((semantic.hits.first?.vectorScore ?? 0) > 0.9)

        // Only a keyword hit exists and it scores below minScore in hybrid mode: still returned.
        let keywordOnly = try await engine.search(query: "zebra", maxResults: 3)
        #expect(keywordOnly.hits.map(\.path) == ["USER.md"])
        #expect(keywordOnly.hits.first?.score ?? 1 < 0.35)

        let filename = try await engine.search(query: "garden.md", maxResults: 3, minScore: 0)
        #expect(filename.hits.first?.path == "memory/garden.md")

        let status = await engine.status()
        #expect(status.files == 4)
        #expect(status.vector.enabled && status.vector.available)
        #expect(status.vector.dims == 3)
    }

    @Test
    func providerFailuresDegradeOnlyInAutoMode() async throws {
        let root = try self.workspace(["MEMORY.md": "Alpha bravo charlie."])
        defer { try? FileManager.default.removeItem(at: root) }
        let auto = MemoryEngine(workspaceRoot: root, embeddingProvider: FailingEmbedding())
        let degraded = try await auto.search(query: "bravo")
        #expect(degraded.searchMode == "fts-only")
        #expect(degraded.embeddingBootstrap?.degradedTo == "keyword-only")
        #expect(degraded.hits.count == 1)

        let explicit = MemoryEngine(workspaceRoot: root, configuration: MemoryEngineConfiguration(provider: "broken"), embeddingProvider: FailingEmbedding())
        await #expect(throws: MemoryUnavailableError.self) {
            _ = try await explicit.search(query: "bravo")
        }

        let none = MemoryEngine(workspaceRoot: root, configuration: MemoryEngineConfiguration(provider: "none"), embeddingProvider: KeywordEmbedding())
        #expect(try await none.search(query: "bravo").provider == "none")
    }

    @Test
    func indexPersistsAndResyncsChanges() async throws {
        let root = try self.workspace(["memory/a.md": "first version"])
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("state/agents/main/memory/index.json")
        let engine = MemoryEngine(workspaceRoot: root, indexURL: indexURL)
        #expect(await engine.sync() == 1)
        #expect(FileManager.default.fileExists(atPath: indexURL.path))
        #expect(await engine.sync() == 0)
        try "second version".write(to: root.appendingPathComponent("memory/a.md"), atomically: true, encoding: .utf8)
        #expect(await engine.sync() == 1)
        let reopened = MemoryEngine(workspaceRoot: root, indexURL: indexURL)
        await reopened.markDirty()
        #expect(try await reopened.search(query: "second", minScore: 0).hits.count == 1)
        try FileManager.default.removeItem(at: root.appendingPathComponent("memory/a.md"))
        #expect(await engine.sync() == 1)
        #expect(await engine.status().chunks == 0)
    }

    @Test
    func memoryToolsValidateAndJailPaths() async throws {
        let lines = (1...250).map { "line \($0)" }.joined(separator: "\n")
        let root = try self.workspace(["memory/log.md": lines, "MEMORY.md": "Remember the falcon."])
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = MemoryEngine(workspaceRoot: root)
        let search = MemorySearchTool(engine: engine)
        #expect(search.descriptor.parameters["additionalProperties"] == AnyCodable(false))
        #expect(search.descriptor.description.hasPrefix("Mandatory recall step: semantically search MEMORY.md, USER.md, Markdown files recursively under memory/"))
        let registry = AgentToolRegistry(tools: [search, MemoryGetTool(engine: engine)])

        let found = try await registry.invoke(AgentToolCall(name: "memory_search", arguments: ["query": AnyCodable("falcon")]))
        #expect(!found.isError)
        #expect(found.value.dictionaryValue?["results"]?.arrayValue?.first?.dictionaryValue?["path"]?.stringValue == "MEMORY.md")
        #expect(found.value.dictionaryValue?["searchMode"]?.stringValue == "fts-only")

        let bad = try await registry.invoke(AgentToolCall(name: "memory_search", arguments: ["query": AnyCodable("x"), "extra": AnyCodable(1)]))
        #expect(bad.isError)
        let wiki = try await registry.invoke(AgentToolCall(name: "memory_search", arguments: ["query": AnyCodable("x"), "corpus": AnyCodable("wiki")]))
        #expect(wiki.value.dictionaryValue?["disabled"]?.boolValue == true)
        let sessions = try await registry.invoke(AgentToolCall(name: "memory_search", arguments: ["query": AnyCodable("x"), "corpus": AnyCodable("sessions")]))
        #expect(sessions.value.dictionaryValue?["corpora"]?.arrayValue?.first?.dictionaryValue?["status"]?.stringValue == "unavailable")

        let excerpt = try await registry.invoke(AgentToolCall(name: "memory_get", arguments: ["path": AnyCodable("memory/log.md")]))
        let details = try #require(excerpt.value.dictionaryValue)
        #expect(details["status"]?.stringValue == "ok")
        #expect(details["lines"]?.intValue == 200)
        #expect(details["truncated"]?.boolValue == true)
        #expect(details["nextFrom"]?.intValue == 201)
        let tail = try await registry.invoke(AgentToolCall(name: "memory_get", arguments: ["path": AnyCodable("memory/log.md"), "from": AnyCodable(240), "lines": AnyCodable(50)]))
        #expect(tail.value.dictionaryValue?["lines"]?.intValue == 11)
        #expect(tail.value.dictionaryValue?["nextFrom"] == nil)
        let missing = try await registry.invoke(AgentToolCall(name: "memory_get", arguments: ["path": AnyCodable("memory/none.md")]))
        #expect(missing.value.dictionaryValue?["status"]?.stringValue == "not_found")
        let escape = try await registry.invoke(AgentToolCall(name: "memory_get", arguments: ["path": AnyCodable("../secrets.md")]))
        #expect(escape.isError)
    }

    @Test
    func sessionCorpusUsesConversationStore() async throws {
        let root = try self.workspace(["MEMORY.md": "unrelated"])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConversationMemoryStore(fileURL: root.appendingPathComponent("conversations.json"))
        await store.appendUserTurn(sessionKey: "main", channel: "webchat", accountID: nil, peerID: "u", text: "The quokka lives on Rottnest.")
        let engine = MemoryEngine(workspaceRoot: root, configuration: MemoryEngineConfiguration(sources: [.memory, .sessions]))
        let tool = MemorySearchTool(
            engine: engine,
            configuration: MemoryEngineConfiguration(sources: [.memory, .sessions]),
            sessionSearch: ConversationMemorySessionSearch(store: store)
        )
        let output = try await tool.invoke(AgentToolInvocation(arguments: ["query": AnyCodable("quokka"), "corpus": AnyCodable("sessions")]), update: nil)
        let first = output.details?.dictionaryValue?["results"]?.arrayValue?.first?.dictionaryValue
        #expect(first?["source"]?.stringValue == "sessions")
        #expect(first?["path"]?.stringValue == "sessions/main")
        let entry = try #require(await store.allEntries().first)
        #expect(entry.createdAtMs > 1_700_000_000_000)
    }

    @Test
    func memoryPromptSectionGolden() {
        #expect(MemoryPromptSection.build(availableTools: ["read"]).isEmpty)
        #expect(MemoryPromptSection.build(availableTools: ["memory_search", "memory_get", "sessions_search", "sessions_history"]) == [
            "## Memory Recall",
            "Before answering anything about prior work, decisions, dates, people, preferences, or todos: run memory_search; for memory-file hits, "
                + "use memory_get to pull only the needed lines. If low confidence after search, say you checked.",
            "For session hits, use sessions_search with distinctive snippet text (and sessionKey set to the transcript ID when known), then "
                + "sessions_history with the returned sessionKey, messageId, and sessionId for a bounded sanitized excerpt.",
            "Session search line numbers are not history offsets. Never read raw transcript files to expand session hits.",
            "Report partial, unavailable, or stale recall to the user, including returned warning and action guidance.",
            "Citations: include Source: <path#line> when it helps the user verify memory snippets.",
            "",
        ])
        let getOnly = MemoryPromptSection.build(availableTools: ["memory_get"], citationsMode: "off")
        #expect(getOnly.count == 5)
        #expect(getOnly[3].hasPrefix("Citations are disabled"))
    }

    @Test
    func memorySearchRPCClampsAndValidates() async throws {
        let root = try self.workspace(["MEMORY.md": (1...150).map { "falcon fact \($0)" }.joined(separator: "\n\n")])
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = MemoryEngine(workspaceRoot: root, configuration: MemoryEngineConfiguration(chunkTokens: 4, chunkOverlap: 0))
        let server = RuntimeExtTestSupport.makeGatewayServer(root: root)
        await registerMemoryGatewayMethods(on: server, configuration: MemoryGatewayConfiguration(engineProvider: { $0 == "main" ? engine : nil }))

        let response = await RuntimeExtTestSupport.call(server, "memory.search", params: ["query": AnyCodable("falcon"), "maxResults": AnyCodable(500), "minScore": AnyCodable(0)])
        #expect(response.ok)
        let payload = try #require(response.payload?.dictionaryValue)
        #expect(payload["agentId"]?.stringValue == "main")
        #expect(payload["searchMode"]?.stringValue == "fts-only")
        #expect(payload["results"]?.arrayValue?.count == 50)

        let defaults = await RuntimeExtTestSupport.call(server, "memory.search", params: ["query": AnyCodable("falcon"), "minScore": AnyCodable(0)])
        #expect(defaults.payload?.dictionaryValue?["results"]?.arrayValue?.count == 20)
        let empty = await RuntimeExtTestSupport.call(server, "memory.search", params: ["query": AnyCodable("  ")])
        #expect(empty.error?.code == ErrorCode.invalidRequest.rawValue)
        let unknown = await RuntimeExtTestSupport.call(server, "memory.search", params: ["query": AnyCodable("x"), "agentId": AnyCodable("ghost")])
        #expect(unknown.error?.message == "unknown agentId")
        let badNumber = await RuntimeExtTestSupport.call(server, "memory.search", params: ["query": AnyCodable("x"), "maxResults": AnyCodable("many")])
        #expect(badNumber.error?.code == ErrorCode.invalidRequest.rawValue)
    }

    @Test
    func legacyMemoryIndexStillWorks() async throws {
        let index = MemoryIndex()
        await index.upsert(MemoryDocument(id: "1", source: .userMessage, text: "deploy release checklist"))
        await index.upsert(MemoryDocument(id: "2", source: .systemNote, text: "buy groceries"))
        let results = await index.search(query: "release deploy", maxResults: 5, minScore: 0.1)
        #expect(results.map(\.id) == ["1"])
        #expect(results.first?.score == 1)
        let backend: any MemorySearchBackend = index
        try await backend.delete(ids: ["1"])
        #expect(try await backend.search(query: "deploy", maxResults: 5, minScore: 0).isEmpty)
    }
}
