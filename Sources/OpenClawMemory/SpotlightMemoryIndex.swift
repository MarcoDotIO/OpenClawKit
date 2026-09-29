#if canImport(CoreSpotlight) && !os(tvOS) && !os(watchOS)
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// Spotlight-backed ``MemorySearchBackend`` (CoreSpotlight `CSSearchableIndex` + `CSUserQuery`).
///
/// Opt-in: memory text enters the system Spotlight store under the chosen file protection class, so
/// only enable it when the user agreed. Documents are indexed with the domain
/// `<domainPrefix>.<sessionKey>` (or `<domainPrefix>` without a session). ``search(query:maxResults:minScore:)``
/// uses `CSUserQuery` with ranked results (scores follow the rank order, best = 1) and falls back to
/// an in-memory BM25 mirror when Spotlight is unavailable or returns nothing. Unavailable on tvOS,
/// watchOS and Linux, which keep ``MemoryIndex``.
public actor SpotlightMemoryIndex: MemorySearchBackend {
    /// Index name.
    nonisolated public let indexName: String
    /// Domain identifier prefix.
    nonisolated public let domainPrefix: String
    private let index: CSSearchableIndex
    private let mirror = MemoryIndex()
    private var documents: [String: MemoryDocument] = [:]
    private let useUserQuery: Bool
    private let userQueryTimeoutSeconds: Double

    /// Creates the index.
    /// - Parameters:
    ///   - indexName: `CSSearchableIndex` name.
    ///   - domainPrefix: Domain identifier prefix.
    ///   - protection: File protection class for indexed items (`nil` uses the app default).
    ///   - useUserQuery: Query Spotlight (`false` searches the in-memory mirror only).
    ///   - userQueryTimeoutSeconds: Deadline for one `CSUserQuery`; on timeout the query is cancelled and
    ///     the search falls back to the in-memory mirror (the system embedding service can stall).
    public init(
        indexName: String = "ai.openclaw.memory",
        domainPrefix: String = "openclaw.memory",
        protection: FileProtectionType? = .completeUntilFirstUserAuthentication,
        useUserQuery: Bool = true,
        userQueryTimeoutSeconds: Double = 3
    ) {
        self.indexName = indexName
        self.domainPrefix = domainPrefix
        self.useUserQuery = useUserQuery
        self.userQueryTimeoutSeconds = userQueryTimeoutSeconds
        if let protection {
            self.index = CSSearchableIndex(name: indexName, protectionClass: protection)
        } else {
            self.index = CSSearchableIndex(name: indexName)
        }
    }

    /// Whether this device supports Spotlight indexing.
    nonisolated public static var isIndexingAvailable: Bool {
        CSSearchableIndex.isIndexingAvailable()
    }

    /// Warms up semantic search (call early, for example at app launch; iOS 18/macOS 15/visionOS 2+).
    nonisolated public static func prepare() {
        if #available(macOS 15.0, iOS 18.0, visionOS 2.0, *) {
            CSUserQuery.prepare()
        }
    }

    /// Sets the delegate Spotlight uses for reindex requests.
    /// - Parameter delegate: Delegate (held weakly by CoreSpotlight; keep a strong reference).
    public func setDelegate(_ delegate: SpotlightMemoryIndexDelegate) {
        self.index.indexDelegate = delegate
    }

    /// Protection class reported by the index (27+), for diagnostics.
    public func protectionClassDescription() -> String? {
        #if compiler(>=6.4)
        if #available(macOS 27.0, iOS 27.0, visionOS 27.0, *) {
            return self.index.protectionClass.rawValue
        }
        #endif
        return nil
    }

    /// Indexes documents.
    /// - Parameters:
    ///   - docs: Documents.
    ///   - sessionKey: Session used for the domain identifier.
    public func upsert(_ docs: [MemoryDocument], sessionKey: String?) async throws {
        guard !docs.isEmpty else { return }
        let domain = sessionKey.map { "\(self.domainPrefix).\($0)" } ?? self.domainPrefix
        let items = docs.map { Self.item(for: $0, domain: domain) }
        for doc in docs { self.documents[doc.id] = doc }
        await self.mirror.upsert(docs, sessionKey: sessionKey)
        guard Self.isIndexingAvailable else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.index.indexSearchableItems(items) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    /// Deletes documents.
    /// - Parameter ids: Document identifiers.
    public func delete(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        for id in ids { self.documents.removeValue(forKey: id) }
        await self.mirror.delete(ids: ids)
        guard Self.isIndexingAvailable else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.index.deleteSearchableItems(withIdentifiers: ids) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    /// Deletes every document of a session (`deleteSearchableItems(withDomainIdentifiers:)`).
    /// - Parameter sessionKey: Session key.
    public func deleteSession(_ sessionKey: String) async throws {
        let domain = "\(self.domainPrefix).\(sessionKey)"
        let ids = self.documents.values.filter { $0.metadata["sessionKey"] == sessionKey }.map(\.id)
        for id in ids { self.documents.removeValue(forKey: id) }
        await self.mirror.delete(ids: ids)
        try await self.deleteDomains([domain])
    }

    /// Deletes everything this index added (memory reset / forget).
    public func deleteAll() async throws {
        let ids = Array(self.documents.keys)
        self.documents.removeAll()
        await self.mirror.delete(ids: ids)
        try await self.deleteDomains([self.domainPrefix])
    }

    /// Searches memory documents.
    /// - Parameters:
    ///   - query: Query text.
    ///   - maxResults: Maximum results.
    ///   - minScore: Minimum score (rank-derived for Spotlight hits).
    /// - Returns: Ranked results.
    public func search(query: String, maxResults: Int, minScore: Double) async throws -> [MemorySearchResult] {
        let limit = max(1, maxResults)
        if self.useUserQuery, Self.isIndexingAvailable {
            let ids = try await self.userQueryIdentifiers(query: query, limit: limit)
            let results = ids.enumerated().compactMap { offset, id -> MemorySearchResult? in
                guard let doc = self.documents[id] else { return nil }
                let score = 1 - Double(offset) / Double(max(1, ids.count))
                return MemorySearchResult(id: doc.id, score: score, text: doc.text, source: doc.source)
            }
            .filter { $0.score >= minScore }
            if !results.isEmpty {
                return Array(results.prefix(limit))
            }
        }
        return await self.mirror.search(query: query, maxResults: limit, minScore: minScore)
    }

    // MARK: - Internals

    static func item(for doc: MemoryDocument, domain: String) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: UTType.text)
        attributes.title = doc.metadata["title"] ?? String(doc.text.prefix(80))
        attributes.textContent = doc.text
        attributes.contentCreationDate = doc.metadata["createdAt"].flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) } ?? Date()
        attributes.keywords = [doc.source.rawValue]
        let item = CSSearchableItem(uniqueIdentifier: doc.id, domainIdentifier: domain, attributeSet: attributes)
        item.expirationDate = .distantFuture
        return item
    }

    private func deleteDomains(_ domains: [String]) async throws {
        guard Self.isIndexingAvailable else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.index.deleteSearchableItems(withDomainIdentifiers: domains) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func userQueryIdentifiers(query: String, limit: Int) async throws -> [String] {
        let context = CSUserQueryContext()
        context.fetchAttributes = ["title", "textContent"]
        context.maxResultCount = limit
        context.enableRankedResults = true
        let userQuery = UserQueryBox(CSUserQuery(userQueryString: query, userQueryContext: context))
        let identifiers = await SpotlightTimeoutRace.first(
            timeoutSeconds: self.userQueryTimeoutSeconds,
            onTimeout: { userQuery.query.cancel() },
            operation: { () -> [String]? in
                var identifiers: [String] = []
                do {
                    for try await response in userQuery.query.responses {
                        if case .item(let hit) = response {
                            let id = hit.item.uniqueIdentifier
                            if id.isEmpty == false, !identifiers.contains(id) {
                                identifiers.append(id)
                            }
                            if identifiers.count >= limit { break }
                        }
                    }
                } catch {
                    // A failed query falls back to the mirror like an empty one.
                }
                userQuery.query.cancel()
                return identifiers
            }
        )
        return identifiers ?? []
    }

    /// Carries a `CSUserQuery` across the timeout race (CoreSpotlight query objects are thread-safe to cancel).
    private final class UserQueryBox: @unchecked Sendable {
        let query: CSUserQuery

        init(_ query: CSUserQuery) {
            self.query = query
        }
    }
}

/// `CSSearchableIndexDelegate` that answers Spotlight reindex requests from the app's memory stores.
///
/// Assign it with ``SpotlightMemoryIndex/setDelegate(_:)`` (and keep a strong reference; CoreSpotlight
/// holds delegates weakly). `lookup` resolves identifiers to documents (for example from a
/// `ConversationMemoryStore`); `reindexAll` returns every document.
public final class SpotlightMemoryIndexDelegate: NSObject, CSSearchableIndexDelegate, @unchecked Sendable {
    /// Resolves documents for identifiers.
    public typealias Lookup = @Sendable (_ identifiers: [String]) async -> [MemoryDocument]
    /// Returns every document to reindex.
    public typealias ReindexAll = @Sendable () async -> [MemoryDocument]

    private let domain: String
    private let lookup: Lookup
    private let reindexAll: ReindexAll

    /// Creates the delegate.
    /// - Parameters:
    ///   - domain: Domain identifier for reindexed items.
    ///   - lookup: Identifier lookup.
    ///   - reindexAll: Full reindex source.
    public init(domain: String = "openclaw.memory", lookup: @escaping Lookup, reindexAll: @escaping ReindexAll) {
        self.domain = domain
        self.lookup = lookup
        self.reindexAll = reindexAll
    }

    /// Reindexes everything.
    public func searchableIndex(
        _ searchableIndex: CSSearchableIndex,
        reindexAllSearchableItemsWithAcknowledgementHandler acknowledgementHandler: @escaping () -> Void
    ) {
        nonisolated(unsafe) let index = searchableIndex
        nonisolated(unsafe) let acknowledge = acknowledgementHandler
        let domain = self.domain
        let reindexAll = self.reindexAll
        Task {
            let items = await reindexAll().map { SpotlightMemoryIndex.item(for: $0, domain: domain) }
            try? await index.indexSearchableItems(items)
            acknowledge()
        }
    }

    /// Reindexes specific identifiers.
    public func searchableIndex(
        _ searchableIndex: CSSearchableIndex,
        reindexSearchableItemsWithIdentifiers identifiers: [String],
        acknowledgementHandler: @escaping () -> Void
    ) {
        nonisolated(unsafe) let index = searchableIndex
        nonisolated(unsafe) let acknowledge = acknowledgementHandler
        let domain = self.domain
        let lookup = self.lookup
        Task {
            let items = await lookup(identifiers).map { SpotlightMemoryIndex.item(for: $0, domain: domain) }
            try? await index.indexSearchableItems(items)
            acknowledge()
        }
    }

    /// Provides items for identifiers (default protection class; macOS 15.4, iOS 18.4, visionOS 2.4).
    @available(macOS 15.4, iOS 18.4, visionOS 2.4, *)
    public func searchableItems(forIdentifiers identifiers: [String]) async -> [CSSearchableItem] {
        await self.lookup(identifiers).map { SpotlightMemoryIndex.item(for: $0, domain: self.domain) }
    }

    #if compiler(>=6.4)
    /// Provides items for identifiers in a protection class (27+).
    @available(macOS 27.0, iOS 27.0, visionOS 27.0, *)
    public func searchableItems(forIdentifiers identifiers: [String], protectionClass _: FileProtectionType) async -> [CSSearchableItem] {
        await self.lookup(identifiers).map { SpotlightMemoryIndex.item(for: $0, domain: self.domain) }
    }
    #endif
}

/// Mirrors builtin memory engine chunks into Spotlight (`memory:<agentId>:<path>#L<start>-<end>`).
///
/// Opt-in (see ``MemoryEngineConfiguration/appleSpotlight``). ``search(query:maxResults:)`` maps
/// Spotlight hits back to ``MemorySearchHit`` values by parsing the identifier.
public actor SpotlightMemoryIndexer {
    /// Agent identifier.
    nonisolated public let agentID: String
    private let index: SpotlightMemoryIndex
    private var indexedIDs: Set<String> = []

    /// Creates the indexer.
    /// - Parameters:
    ///   - agentID: Agent identifier.
    ///   - protection: File protection class.
    public init(agentID: String, protection: FileProtectionType? = .completeUntilFirstUserAuthentication) {
        self.agentID = agentID
        self.index = SpotlightMemoryIndex(indexName: "OpenClawMemory", domainPrefix: "ai.openclaw.memory.\(agentID)", protection: protection)
    }

    /// Unique identifier for a chunk.
    /// - Parameters:
    ///   - agentID: Agent.
    ///   - path: Relative path.
    ///   - startLine: First line.
    ///   - endLine: Last line.
    /// - Returns: Identifier.
    public static func identifier(agentID: String, path: String, startLine: Int, endLine: Int) -> String {
        "memory:\(agentID):\(path)#L\(startLine)-\(endLine)"
    }

    /// Parses an identifier back into `(path, startLine, endLine)`.
    /// - Parameters:
    ///   - identifier: Identifier.
    ///   - agentID: Expected agent.
    /// - Returns: The components, or `nil` for foreign identifiers.
    public static func parse(identifier: String, agentID: String) -> (path: String, startLine: Int, endLine: Int)? {
        let prefix = "memory:\(agentID):"
        guard identifier.hasPrefix(prefix), let hash = identifier.range(of: "#L", options: .backwards) else { return nil }
        let path = String(identifier[identifier.index(identifier.startIndex, offsetBy: prefix.count)..<hash.lowerBound])
        let lines = identifier[hash.upperBound...].split(separator: "-")
        guard lines.count == 2, let start = Int(lines[0]), let end = Int(lines[1]) else { return nil }
        return (path, start, end)
    }

    /// Upserts the engine's chunks and deletes chunks that disappeared.
    /// - Parameter engine: Memory engine.
    public func sync(from engine: MemoryEngine) async throws {
        let chunks = await engine.indexedChunks()
        let docs = chunks.map { chunk in
            MemoryDocument(
                id: Self.identifier(agentID: self.agentID, path: chunk.path, startLine: chunk.startLine, endLine: chunk.endLine),
                source: .systemNote,
                text: chunk.text,
                metadata: ["title": chunk.path]
            )
        }
        let current = Set(docs.map(\.id))
        try await self.index.delete(ids: Array(self.indexedIDs.subtracting(current)))
        try await self.index.upsert(docs, sessionKey: nil)
        self.indexedIDs = current
    }

    /// Searches the mirrored chunks.
    /// - Parameters:
    ///   - query: Query.
    ///   - maxResults: Maximum hits.
    /// - Returns: Hits with rank-derived scores.
    public func search(query: String, maxResults: Int = 6) async throws -> [MemorySearchHit] {
        try await self.index.search(query: query, maxResults: maxResults, minScore: 0).compactMap { result in
            guard let parsed = Self.parse(identifier: result.id, agentID: self.agentID) else { return nil }
            return MemorySearchHit(
                path: parsed.path,
                startLine: parsed.startLine,
                endLine: parsed.endLine,
                score: result.score,
                vectorScore: result.score,
                snippet: String(result.text.prefix(MemoryEngine.snippetMaxChars))
            )
        }
    }

    /// Removes every mirrored chunk (memory reset).
    public func reset() async throws {
        try await self.index.deleteAll()
        self.indexedIDs.removeAll()
    }
}
#endif
