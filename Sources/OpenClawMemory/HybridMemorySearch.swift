import Foundation
import OpenClawCore
import OpenClawProtocol

/// Corpus a memory hit came from.
public enum MemoryHitSource: String, Codable, Sendable, Equatable {
    /// Memory files (`MEMORY.md`, `USER.md`, `memory/**`, extra paths).
    case memory
    /// Indexed session transcripts.
    case sessions
}

/// Provenance of a memory entry (upstream `MemoryEntryProvenance`).
public struct MemoryEntryProvenance: Codable, Sendable, Equatable {
    /// `owner`, `agent`, `untrusted` or `system`.
    public var originClass: String
    /// `interactive`, `cron`, `heartbeat`, `subagent` or `unknown`.
    public var sessionKind: String
    /// Observation time in milliseconds since the epoch.
    public var observedAt: Int64
    /// Key of the entry this one supersedes.
    public var supersedesKey: String?

    /// Creates provenance.
    /// - Parameters:
    ///   - originClass: Origin class.
    ///   - sessionKind: Session kind.
    ///   - observedAt: Observation time.
    ///   - supersedesKey: Superseded key.
    public init(originClass: String, sessionKind: String, observedAt: Int64, supersedesKey: String? = nil) {
        self.originClass = originClass
        self.sessionKind = sessionKind
        self.observedAt = observedAt
        self.supersedesKey = supersedesKey
    }
}

/// One ranked memory search hit (upstream `MemorySearchResult`).
public struct MemorySearchHit: Codable, Sendable, Equatable {
    /// File path (workspace-relative for memory files).
    public var path: String
    /// First line (1-based).
    public var startLine: Int
    /// Last line (1-based).
    public var endLine: Int
    /// Final score (after weighting, recency decay and importance).
    public var score: Double
    /// Semantic score, when the vector leg matched.
    public var vectorScore: Double?
    /// Keyword score, when the keyword leg matched.
    public var textScore: Double?
    /// Snippet (at most 700 characters).
    public var snippet: String
    /// Source corpus.
    public var source: MemoryHitSource
    /// Importance multiplier, when known.
    public var importance: Double?
    /// Citation `<path>#L<start>-<end>`.
    public var citation: String?
    /// Provenance, when known.
    public var provenance: MemoryEntryProvenance?

    /// Creates a hit.
    /// - Parameters:
    ///   - path: Path.
    ///   - startLine: First line.
    ///   - endLine: Last line.
    ///   - score: Score.
    ///   - vectorScore: Semantic score.
    ///   - textScore: Keyword score.
    ///   - snippet: Snippet.
    ///   - source: Source.
    ///   - importance: Importance.
    ///   - citation: Citation.
    ///   - provenance: Provenance.
    public init(
        path: String,
        startLine: Int,
        endLine: Int,
        score: Double,
        vectorScore: Double? = nil,
        textScore: Double? = nil,
        snippet: String,
        source: MemoryHitSource = .memory,
        importance: Double? = nil,
        citation: String? = nil,
        provenance: MemoryEntryProvenance? = nil
    ) {
        self.path = path
        self.startLine = startLine
        self.endLine = endLine
        self.score = score
        self.vectorScore = vectorScore
        self.textScore = textScore
        self.snippet = snippet
        self.source = source
        self.importance = importance
        self.citation = citation ?? "\(path)#L\(startLine)-\(endLine)"
        self.provenance = provenance
    }
}

/// Settings for the builtin memory engine (the upstream `memory.search` subset the SDK uses).
///
/// Defaults follow upstream `src/agents/memory-search.ts`: 400-token chunks with 80-token overlap,
/// 6 results, min score 0.35, 0.7 vector / 0.3 text weights, 4x candidates, MMR λ 0.7, and a 30-day
/// recency half-life for dated files.
public struct MemoryEngineConfiguration: Codable, Sendable, Equatable {
    /// `auto` (default: degrade to keyword search when embeddings fail), `none` (keyword only), or
    /// an explicit provider id (failures surface as ``MemoryUnavailableError``).
    public var provider: String?
    /// Embedding model.
    public var model: String?
    /// Extra corpus paths.
    public var extraPaths: [MemoryExtraPath]
    /// Searchable corpora (`memory`, `sessions`).
    public var sources: [MemoryHitSource]
    /// Default maximum results.
    public var maxResults: Int
    /// Default minimum score.
    public var minScore: Double
    /// Vector weight.
    public var vectorWeight: Double
    /// Text weight.
    public var textWeight: Double
    /// Candidate multiplier per leg.
    public var candidateMultiplier: Int
    /// MMR λ (1 disables diversity).
    public var mmrLambda: Double
    /// Recency half-life in days (0 disables decay).
    public var temporalHalfLifeDays: Double
    /// Chunk tokens.
    public var chunkTokens: Int
    /// Chunk overlap tokens.
    public var chunkOverlap: Int
    /// Embedding cache capacity (LRU).
    public var cacheMaxEntries: Int

    /// Creates settings.
    /// - Parameters:
    ///   - provider: Provider mode.
    ///   - model: Model.
    ///   - extraPaths: Extra paths.
    ///   - sources: Corpora.
    ///   - maxResults: Maximum results.
    ///   - minScore: Minimum score.
    ///   - vectorWeight: Vector weight.
    ///   - textWeight: Text weight.
    ///   - candidateMultiplier: Candidate multiplier.
    ///   - mmrLambda: MMR λ.
    ///   - temporalHalfLifeDays: Half-life.
    ///   - chunkTokens: Chunk tokens.
    ///   - chunkOverlap: Chunk overlap.
    ///   - cacheMaxEntries: Cache capacity.
    public init(
        provider: String? = nil,
        model: String? = nil,
        extraPaths: [MemoryExtraPath] = [],
        sources: [MemoryHitSource] = [.memory],
        maxResults: Int = 6,
        minScore: Double = 0.35,
        vectorWeight: Double = 0.7,
        textWeight: Double = 0.3,
        candidateMultiplier: Int = 4,
        mmrLambda: Double = 0.7,
        temporalHalfLifeDays: Double = 30,
        chunkTokens: Int = MemoryChunker.defaultTokens,
        chunkOverlap: Int = MemoryChunker.defaultOverlap,
        cacheMaxEntries: Int = 50_000
    ) {
        self.provider = provider
        self.model = model
        self.extraPaths = extraPaths
        self.sources = sources
        self.maxResults = maxResults
        self.minScore = minScore
        self.vectorWeight = vectorWeight
        self.textWeight = textWeight
        self.candidateMultiplier = candidateMultiplier
        self.mmrLambda = mmrLambda
        self.temporalHalfLifeDays = temporalHalfLifeDays
        self.chunkTokens = chunkTokens
        self.chunkOverlap = chunkOverlap
        self.cacheMaxEntries = cacheMaxEntries
    }

    /// Whether the provider mode is keyword-only.
    public var isKeywordOnly: Bool {
        self.provider?.lowercased() == "none"
    }

    /// Whether embedding failures degrade to keyword search (`auto` or unset).
    public var degradesOnFailure: Bool {
        let mode = self.provider?.lowercased() ?? "auto"
        return mode == "auto" || mode.isEmpty
    }
}

/// Embedding bootstrap failure recorded when `auto` mode degrades to keyword search.
public struct MemoryEmbeddingBootstrapDebug: Codable, Sendable, Equatable {
    /// Always `false`.
    public var ok: Bool
    /// Provider that failed.
    public var provider: String
    /// Failure reason.
    public var reason: String
    /// Always `keyword-only`.
    public var degradedTo: String

    /// Creates the record.
    /// - Parameters:
    ///   - provider: Provider.
    ///   - reason: Reason.
    public init(provider: String, reason: String) {
        self.ok = false
        self.provider = provider
        self.reason = reason
        self.degradedTo = "keyword-only"
    }
}

/// Result of ``MemoryEngine/search(query:maxResults:minScore:)``.
public struct MemorySearchOutcome: Sendable, Equatable {
    /// Ranked hits.
    public let hits: [MemorySearchHit]
    /// Provider id (`none` for keyword-only).
    public let provider: String
    /// `hybrid` or `fts-only`.
    public let searchMode: String
    /// Embedding bootstrap failure, when degraded.
    public let embeddingBootstrap: MemoryEmbeddingBootstrapDebug?

    /// Creates an outcome.
    /// - Parameters:
    ///   - hits: Hits.
    ///   - provider: Provider.
    ///   - searchMode: Mode.
    ///   - embeddingBootstrap: Degradation record.
    public init(hits: [MemorySearchHit], provider: String, searchMode: String, embeddingBootstrap: MemoryEmbeddingBootstrapDebug? = nil) {
        self.hits = hits
        self.provider = provider
        self.searchMode = searchMode
        self.embeddingBootstrap = embeddingBootstrap
    }
}

/// Engine status (upstream `MemoryProviderStatus` subset).
public struct MemoryEngineStatus: Codable, Sendable, Equatable {
    /// Leg availability.
    public struct Leg: Codable, Sendable, Equatable {
        /// Enabled by configuration.
        public var enabled: Bool
        /// Currently usable.
        public var available: Bool
        /// Vector dimensions.
        public var dims: Int?
    }

    /// Always `builtin`.
    public var backend: String
    /// Provider id.
    public var provider: String
    /// Model.
    public var model: String?
    /// Indexed files.
    public var files: Int
    /// Indexed chunks.
    public var chunks: Int
    /// Whether the corpus changed since the last sync.
    public var dirty: Bool
    /// Keyword leg.
    public var fts: Leg
    /// Vector leg.
    public var vector: Leg
    /// Last sync error.
    public var lastSyncError: String?
}

/// Result of ``MemoryEngine/read(path:from:lines:)`` (upstream `MemoryReadResult`).
public struct MemoryReadResult: Codable, Sendable, Equatable {
    /// `ok`, `not_found` or `error`.
    public var status: String
    /// Excerpt text.
    public var text: String
    /// Requested path.
    public var path: String
    /// Whether more lines follow.
    public var truncated: Bool?
    /// First line returned (1-based).
    public var from: Int?
    /// Number of lines returned.
    public var lines: Int?
    /// Line to continue from.
    public var nextFrom: Int?

    /// Creates a read result.
    /// - Parameters:
    ///   - status: Status.
    ///   - text: Text.
    ///   - path: Path.
    ///   - truncated: Truncated flag.
    ///   - from: First line.
    ///   - lines: Line count.
    ///   - nextFrom: Continuation line.
    public init(status: String, text: String, path: String, truncated: Bool? = nil, from: Int? = nil, lines: Int? = nil, nextFrom: Int? = nil) {
        self.status = status
        self.text = text
        self.path = path
        self.truncated = truncated
        self.from = from
        self.lines = lines
        self.nextFrom = nextFrom
    }
}

/// Builtin memory engine: file corpus, chunking, BM25 + filename search, optional embeddings,
/// recency decay, and MMR (upstream memory-core semantics).
///
/// Call ``sync()`` after the corpus changes (``search(query:maxResults:minScore:)`` syncs lazily when
/// dirty). The index and embedding cache persist to `indexURL` when given (for example
/// `<stateDir>/agents/<id>/memory/index.json`).
public actor MemoryEngine {
    /// Upstream snippet cap.
    public static let snippetMaxChars = 700
    /// Default `memory_get` excerpt length (SDK choice).
    public static let defaultReadLines = 200
    /// Separator between a chunk's line range and its part ordinal in chunk identifiers
    /// (`MEMORY.md#L12-12~1`), used when one long line is split into several chunks.
    public static let chunkPartMarker = "~"

    struct IndexedChunk: Codable, Equatable {
        let id: String
        let path: String
        let startLine: Int
        let endLine: Int
        let text: String
        let hash: String
        let datedAt: Date?

        /// Ordinal among chunks of the same file and line range (0 for the first; a line wider than
        /// the chunk size is split into several parts that share one range).
        var part: Int {
            guard let lines = self.id.range(of: "#L", options: .backwards) else { return 0 }
            let range = self.id[lines.upperBound...]
            guard let marker = range.range(of: MemoryEngine.chunkPartMarker),
                  let part = Int(range[marker.upperBound...]), part > 0
            else {
                return 0
            }
            return part
        }
    }

    struct PersistedIndex: Codable {
        var version = 1
        var files: [String: String] = [:]
        var chunks: [IndexedChunk] = []
        var embeddings: [String: [Float]] = [:]
        var embeddingOrder: [String] = []
    }

    /// Corpus.
    nonisolated public let corpus: MemoryCorpus
    private var configuration: MemoryEngineConfiguration
    private let embeddingProvider: (any MemoryEmbeddingProvider)?
    private let indexURL: URL?
    private let now: @Sendable () -> Date
    private var index = PersistedIndex()
    private var bm25 = BM25Index()
    private var dirty = true
    private var lastSyncError: String?
    private var vectorAvailable = true

    /// Creates an engine.
    /// - Parameters:
    ///   - workspaceRoot: Workspace root.
    ///   - configuration: Settings.
    ///   - embeddingProvider: Embedding provider (`nil` or provider `none` means keyword-only).
    ///   - indexURL: Persisted index location.
    ///   - now: Clock (recency decay).
    public init(
        workspaceRoot: URL,
        configuration: MemoryEngineConfiguration = MemoryEngineConfiguration(),
        embeddingProvider: (any MemoryEmbeddingProvider)? = nil,
        indexURL: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.corpus = MemoryCorpus(workspaceRoot: workspaceRoot, extraPaths: configuration.extraPaths)
        self.configuration = configuration
        self.embeddingProvider = configuration.isKeywordOnly ? nil : embeddingProvider
        self.indexURL = indexURL
        self.now = now
        if let indexURL, let data = try? Data(contentsOf: indexURL), var decoded = try? JSONDecoder().decode(PersistedIndex.self, from: data) {
            if Set(decoded.chunks.map(\.id)).count != decoded.chunks.count {
                // An index written before chunk ids carried part ordinals can hold duplicate ids;
                // forget the file digests so the next sync re-chunks every file.
                decoded.files.removeAll()
            }
            self.index = decoded
            var bm25 = BM25Index()
            for chunk in decoded.chunks { bm25.upsert(id: chunk.id, text: chunk.text) }
            self.bm25 = bm25
        }
    }

    /// Current settings.
    public var currentConfiguration: MemoryEngineConfiguration {
        self.configuration
    }

    /// Marks the corpus dirty (the next search re-syncs).
    public func markDirty() {
        self.dirty = true
    }

    /// Re-indexes changed files and removes deleted ones.
    /// - Returns: Number of files (re)indexed.
    @discardableResult
    public func sync() async -> Int {
        let files = self.corpus.files()
        let chunker = MemoryChunker(tokens: self.configuration.chunkTokens, overlap: self.configuration.chunkOverlap)
        var changed = 0
        var seen = Set<String>()
        for file in files {
            seen.insert(file.path)
            guard let data = try? Data(contentsOf: file.url) else { continue }
            let digest = OpenClawCrypto.sha256Hex(data)
            if self.index.files[file.path] == digest { continue }
            changed += 1
            self.removeChunks(forPath: file.path)
            let text = String(decoding: data, as: UTF8.self)
            let datedAt = Self.datedMemoryDate(file.path)
            var parts: [String: Int] = [:]
            for chunk in chunker.chunk(text) where !chunk.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let id = Self.chunkID(path: file.path, startLine: chunk.startLine, endLine: chunk.endLine, parts: &parts)
                let indexed = IndexedChunk(
                    id: id,
                    path: file.path,
                    startLine: chunk.startLine,
                    endLine: chunk.endLine,
                    text: chunk.text,
                    hash: OpenClawCrypto.sha256Hex(Data(chunk.text.utf8)),
                    datedAt: datedAt
                )
                self.index.chunks.append(indexed)
                self.bm25.upsert(id: id, text: chunk.text)
            }
            self.index.files[file.path] = digest
        }
        for path in self.index.files.keys where !seen.contains(path) {
            self.removeChunks(forPath: path)
            self.index.files.removeValue(forKey: path)
            changed += 1
        }
        self.lastSyncError = nil
        if self.embeddingProvider != nil {
            await self.embedMissingChunks()
        }
        self.dirty = false
        self.persist()
        return changed
    }

    /// Searches the corpus.
    /// - Parameters:
    ///   - query: Query text.
    ///   - maxResults: Maximum hits (default from settings).
    ///   - minScore: Minimum score (default from settings).
    /// - Returns: Ranked hits and the search mode.
    /// - Throws: ``MemoryUnavailableError`` when an explicitly named provider fails.
    public func search(query: String, maxResults: Int? = nil, minScore: Double? = nil) async throws -> MemorySearchOutcome {
        if self.dirty { await self.sync() }
        let limit = max(1, maxResults ?? self.configuration.maxResults)
        let threshold = minScore ?? self.configuration.minScore
        let (product, overflow) = limit.multipliedReportingOverflow(by: max(1, self.configuration.candidateMultiplier))
        let candidates = overflow ? Int.max : product
        let byID = Dictionary(self.index.chunks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Keyword leg: BM25 over chunk text, normalized by the best score, plus filename matches.
        var textScores: [String: Double] = [:]
        let bm25Hits = self.bm25.search(query, limit: candidates)
        if let best = bm25Hits.first?.score, best > 0 {
            for hit in bm25Hits { textScores[hit.id] = hit.score / best }
        }
        for (id, score) in self.filenameScores(query: query) where score > (textScores[id] ?? 0) {
            textScores[id] = score
        }

        // Vector leg.
        var vectorScores: [String: Double] = [:]
        var bootstrap: MemoryEmbeddingBootstrapDebug?
        var vectorLeg = false
        if let provider = self.embeddingProvider, !self.vectorAvailable {
            bootstrap = MemoryEmbeddingBootstrapDebug(provider: provider.id, reason: self.lastSyncError ?? "embedding provider unavailable")
        }
        if let provider = self.embeddingProvider, self.vectorAvailable {
            do {
                if let queryVector = try await provider.embed([query], inputType: .query).first {
                    vectorLeg = true
                    let scored = self.index.chunks.compactMap { chunk -> (String, Double)? in
                        guard let vector = self.index.embeddings[self.cacheKey(chunk.hash, provider: provider)] else { return nil }
                        return (chunk.id, max(0, Self.cosine(queryVector, vector)))
                    }
                    for (id, score) in scored.sorted(by: { $0.1 > $1.1 }).prefix(candidates) {
                        vectorScores[id] = score
                    }
                }
            } catch {
                if self.configuration.degradesOnFailure {
                    bootstrap = MemoryEmbeddingBootstrapDebug(provider: provider.id, reason: error.localizedDescription)
                } else {
                    throw MemoryUnavailableError(provider: provider.id, reason: error.localizedDescription)
                }
            }
        }

        let hybrid = vectorLeg && !self.configuration.isKeywordOnly
        var hits: [MemorySearchHit] = []
        for id in Set(textScores.keys).union(vectorScores.keys) {
            guard let chunk = byID[id] else { continue }
            let text = textScores[id]
            let vector = vectorScores[id]
            var score: Double
            if hybrid {
                score = self.configuration.vectorWeight * (vector ?? 0) + self.configuration.textWeight * (text ?? 0)
            } else {
                score = text ?? vector ?? 0
            }
            score *= self.decayMultiplier(for: chunk)
            hits.append(
                MemorySearchHit(
                    path: chunk.path,
                    startLine: chunk.startLine,
                    endLine: chunk.endLine,
                    score: score,
                    vectorScore: vector,
                    textScore: text,
                    snippet: String(chunk.text.prefix(Self.snippetMaxChars))
                )
            )
        }
        hits.sort { $0.score == $1.score ? ($0.path, $0.startLine) < ($1.path, $1.startLine) : $0.score > $1.score }
        let reranked = Self.mmrRerank(hits, lambda: self.configuration.mmrLambda)

        var selected = reranked.filter { $0.score >= threshold }
        if selected.isEmpty {
            // Keyword preservation: surface keyword hits even when everything scored below minScore.
            selected = reranked.filter { ($0.textScore ?? 0) > 0 }
        } else if hybrid, selected.count < limit {
            let chosen = Set(selected.map(\.citation))
            selected += reranked.filter { $0.vectorScore == nil && ($0.textScore ?? 0) > 0 && !chosen.contains($0.citation) }
        }
        let provider = self.embeddingProvider?.id ?? "none"
        return MemorySearchOutcome(
            hits: Array(selected.prefix(limit)),
            provider: provider,
            searchMode: hybrid ? "hybrid" : "fts-only",
            embeddingBootstrap: bootstrap
        )
    }

    /// Reads an excerpt of a corpus file (`memory_get`).
    /// - Parameters:
    ///   - path: Workspace-relative path.
    ///   - from: First line (1-based, default 1).
    ///   - lines: Line count (default 200).
    /// - Returns: The excerpt, `not_found`, or `error` for disallowed paths.
    public func read(path: String, from: Int? = nil, lines: Int? = nil) -> MemoryReadResult {
        guard let url = self.corpus.resolveReadablePath(path) else {
            return MemoryReadResult(
                status: "error",
                text: "path is not a readable memory file (MEMORY.md, USER.md, memory/**, or a configured extra path)",
                path: path
            )
        }
        guard let data = try? Data(contentsOf: url) else {
            return MemoryReadResult(status: "not_found", text: "", path: path)
        }
        let allLines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        let start = max(1, from ?? 1)
        let count = max(1, lines ?? Self.defaultReadLines)
        guard start <= allLines.count else {
            return MemoryReadResult(status: "ok", text: "", path: path, truncated: false, from: start, lines: 0)
        }
        let end = count > allLines.count - start ? allLines.count : start + count - 1
        let excerpt = allLines[(start - 1)..<end].joined(separator: "\n")
        let truncated = end < allLines.count
        return MemoryReadResult(
            status: "ok",
            text: excerpt,
            path: path,
            truncated: truncated,
            from: start,
            lines: end - start + 1,
            nextFrom: truncated ? end + 1 : nil
        )
    }

    /// Engine status.
    public func status() -> MemoryEngineStatus {
        MemoryEngineStatus(
            backend: "builtin",
            provider: self.embeddingProvider?.id ?? "none",
            model: self.embeddingProvider?.model ?? self.configuration.model,
            files: self.index.files.count,
            chunks: self.index.chunks.count,
            dirty: self.dirty,
            fts: MemoryEngineStatus.Leg(enabled: true, available: true, dims: nil),
            vector: MemoryEngineStatus.Leg(
                enabled: self.embeddingProvider != nil,
                available: self.embeddingProvider != nil && self.vectorAvailable,
                dims: self.embeddingProvider.map(\.dimensions).flatMap { $0 > 0 ? $0 : nil }
            ),
            lastSyncError: self.lastSyncError
        )
    }

    /// Indexed chunks (path, lines, text, part) for mirroring into other backends such as Spotlight.
    ///
    /// `part` is 0 for the first chunk of a line range and counts up for further parts of a line
    /// that was split because it exceeded the chunk size.
    public func indexedChunks() -> [(path: String, startLine: Int, endLine: Int, text: String, part: Int)] {
        self.index.chunks.map { ($0.path, $0.startLine, $0.endLine, $0.text, $0.part) }
    }

    /// Chunk identifier `path#Lstart-end`, with a `~k` part ordinal for the k-th further chunk that
    /// shares the same range (a line wider than the chunk size is split into several parts).
    static func chunkID(path: String, startLine: Int, endLine: Int, parts: inout [String: Int]) -> String {
        let base = "\(path)#L\(startLine)-\(endLine)"
        let part = parts[base, default: 0]
        parts[base] = part + 1
        return part == 0 ? base : "\(base)\(Self.chunkPartMarker)\(part)"
    }

    // MARK: - Ranking helpers

    /// Recency multiplier `0.5^(ageDays / halfLife)` for dated files (`memory/**/YYYY-MM-DD[-slug].md`);
    /// evergreen and undated files return 1.
    /// - Parameters:
    ///   - path: Workspace-relative path.
    ///   - now: Reference time.
    ///   - halfLifeDays: Half-life.
    /// - Returns: Multiplier in `0...1`.
    public static func recencyMultiplier(path: String, now: Date, halfLifeDays: Double) -> Double {
        guard halfLifeDays > 0, let date = self.datedMemoryDate(path) else { return 1 }
        let ageDays = max(0, now.timeIntervalSince(date) / 86_400)
        return exp(-(log(2) / halfLifeDays) * ageDays)
    }

    /// Date encoded in a dated memory path (upstream `DATED_MEMORY_PATH_RE`).
    /// - Parameter path: Path.
    /// - Returns: The UTC date, when the path is a valid dated file.
    public static func datedMemoryDate(_ path: String) -> Date? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/").replacingOccurrences(of: "^\\./", with: "", options: .regularExpression)
        let pattern = "(?:^|/)memory/(?:[^/]+/)*(\\d{4})-(\\d{2})-(\\d{2})(?:-[^/]+)?\\.md$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
              let yearRange = Range(match.range(at: 1), in: normalized),
              let monthRange = Range(match.range(at: 2), in: normalized),
              let dayRange = Range(match.range(at: 3), in: normalized),
              let year = Int(normalized[yearRange]), let month = Int(normalized[monthRange]), let day = Int(normalized[dayRange])
        else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components),
              calendar.component(.year, from: date) == year,
              calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == day
        else {
            return nil
        }
        return date
    }

    /// Maximal Marginal Relevance re-ranking (upstream `mmrRerank`): scores are kept, only the order changes.
    /// - Parameters:
    ///   - hits: Hits sorted by score.
    ///   - lambda: Relevance weight (1 keeps score order).
    /// - Returns: Re-ranked hits.
    public static func mmrRerank(_ hits: [MemorySearchHit], lambda: Double) -> [MemorySearchHit] {
        guard hits.count > 1 else { return hits }
        let clamped = min(1, max(0, lambda))
        if clamped == 1 { return hits.sorted { $0.score > $1.score } }
        let tokens = hits.map { MemoryTokenizer.tokenSet($0.snippet) }
        let emptyTexts = hits.map { $0.snippet.lowercased() }
        let maxScore = hits.map(\.score).max() ?? 0
        let minScore = hits.map(\.score).min() ?? 0
        let range = maxScore - minScore
        let relevance = hits.map { range == 0 ? 1 : ($0.score - minScore) / range }
        var maxSimilarity = Array(repeating: 0.0, count: hits.count)
        var remaining = Array(hits.indices)
        var selected: [MemorySearchHit] = []
        while !remaining.isEmpty {
            var bestIndex = remaining[0]
            var bestScore = -Double.infinity
            for index in remaining {
                let mmr = clamped * relevance[index] - (1 - clamped) * maxSimilarity[index]
                if mmr > bestScore || (mmr == bestScore && hits[index].score > hits[bestIndex].score) {
                    bestScore = mmr
                    bestIndex = index
                }
            }
            selected.append(hits[bestIndex])
            remaining.removeAll { $0 == bestIndex }
            for index in remaining {
                let similarity = tokens[index].isEmpty && tokens[bestIndex].isEmpty
                    ? (emptyTexts[index] == emptyTexts[bestIndex] ? 1 : 0)
                    : MemoryTokenizer.jaccard(tokens[index], tokens[bestIndex])
                maxSimilarity[index] = max(maxSimilarity[index], similarity)
            }
        }
        return selected
    }

    static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot: Double = 0
        var left: Double = 0
        var right: Double = 0
        for index in lhs.indices {
            let a = Double(lhs[index])
            let b = Double(rhs[index])
            dot += a * b
            left += a * a
            right += b * b
        }
        guard left > 0, right > 0 else { return 0 }
        return dot / (left.squareRoot() * right.squareRoot())
    }

    // MARK: - Internals

    private func filenameScores(query: String) -> [String: Double] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return [:] }
        let queryTokens = MemoryTokenizer.tokenSet(normalized)
        var firstChunk: [String: IndexedChunk] = [:]
        for chunk in self.index.chunks where firstChunk[chunk.path] == nil || chunk.startLine < firstChunk[chunk.path]!.startLine {
            firstChunk[chunk.path] = chunk
        }
        var scores: [String: Double] = [:]
        for (path, chunk) in firstChunk {
            let lowerPath = path.lowercased()
            let basename = (lowerPath as NSString).lastPathComponent
            let stem = (basename as NSString).deletingPathExtension
            let score: Double
            if lowerPath == normalized {
                score = 1.0
            } else if basename == normalized {
                score = 0.9
            } else if stem == normalized {
                score = 0.8
            } else {
                let pathTokens = MemoryTokenizer.tokenSet(lowerPath)
                let overlap = queryTokens.intersection(pathTokens).count
                score = queryTokens.isEmpty ? 0 : 0.5 * Double(overlap) / Double(queryTokens.count)
            }
            if score > 0 { scores[chunk.id] = score }
        }
        return scores
    }

    private func decayMultiplier(for chunk: IndexedChunk) -> Double {
        guard self.configuration.temporalHalfLifeDays > 0, let date = chunk.datedAt else { return 1 }
        let ageDays = max(0, self.now().timeIntervalSince(date) / 86_400)
        return exp(-(log(2) / self.configuration.temporalHalfLifeDays) * ageDays)
    }

    private func removeChunks(forPath path: String) {
        let removed = self.index.chunks.filter { $0.path == path }
        for chunk in removed { self.bm25.remove(id: chunk.id) }
        self.index.chunks.removeAll { $0.path == path }
    }

    private func cacheKey(_ hash: String, provider: any MemoryEmbeddingProvider) -> String {
        OpenClawCrypto.sha256Hex(Data("\(provider.id)|\(provider.model)|\(hash)".utf8))
    }

    private func embedMissingChunks() async {
        guard let provider = self.embeddingProvider else { return }
        let missing = self.index.chunks.filter { self.index.embeddings[self.cacheKey($0.hash, provider: provider)] == nil }
        guard !missing.isEmpty else { return }
        do {
            for batch in stride(from: 0, to: missing.count, by: 64).map({ Array(missing[$0..<min(missing.count, $0 + 64)]) }) {
                let vectors = try await provider.embed(batch.map(\.text), inputType: .document)
                for (chunk, vector) in zip(batch, vectors) {
                    let key = self.cacheKey(chunk.hash, provider: provider)
                    self.index.embeddings[key] = vector
                    self.index.embeddingOrder.append(key)
                }
            }
            self.vectorAvailable = true
        } catch {
            self.lastSyncError = error.localizedDescription
            self.vectorAvailable = self.configuration.degradesOnFailure ? false : true
        }
        let overflow = self.index.embeddingOrder.count - max(1, self.configuration.cacheMaxEntries)
        if overflow > 0 {
            for key in self.index.embeddingOrder.prefix(overflow) { self.index.embeddings.removeValue(forKey: key) }
            self.index.embeddingOrder.removeFirst(overflow)
        }
    }

    private func persist() {
        guard let indexURL else { return }
        try? FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self.index) {
            try? data.write(to: indexURL, options: [.atomic])
        }
    }
}
