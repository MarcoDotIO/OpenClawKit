#if canImport(CoreSpotlight) && !os(tvOS) && !os(watchOS)
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// The `CSSearchableIndex` operations ``SpotlightMemoryIndex`` performs (a seam so tests never
/// depend on `corespotlightd`).
protocol SpotlightItemIndexing: Sendable {
    /// Whether indexing is available (writes are skipped otherwise).
    var isAvailable: Bool { get }
    /// Indexes items and reports completion.
    func indexItems(_ items: [CSSearchableItem], completion: @escaping @Sendable ((any Error)?) -> Void)
    /// Deletes items by identifier and reports completion.
    func deleteItems(identifiers: [String], completion: @escaping @Sendable ((any Error)?) -> Void)
    /// Deletes items by domain (hierarchically) and reports completion.
    func deleteItems(domains: [String], completion: @escaping @Sendable ((any Error)?) -> Void)
}

/// ``SpotlightItemIndexing`` over a real `CSSearchableIndex` (thread-safe per CoreSpotlight).
final class SystemSpotlightItemIndex: SpotlightItemIndexing, @unchecked Sendable {
    let index: CSSearchableIndex

    init(_ index: CSSearchableIndex) {
        self.index = index
    }

    var isAvailable: Bool {
        CSSearchableIndex.isIndexingAvailable()
    }

    func indexItems(_ items: [CSSearchableItem], completion: @escaping @Sendable ((any Error)?) -> Void) {
        self.index.indexSearchableItems(items) { error in completion(error) }
    }

    func deleteItems(identifiers: [String], completion: @escaping @Sendable ((any Error)?) -> Void) {
        self.index.deleteSearchableItems(withIdentifiers: identifiers) { error in completion(error) }
    }

    func deleteItems(domains: [String], completion: @escaping @Sendable ((any Error)?) -> Void) {
        self.index.deleteSearchableItems(withDomainIdentifiers: domains) { error in completion(error) }
    }
}

/// Spotlight-backed ``MemorySearchBackend`` (CoreSpotlight `CSSearchableIndex` + `CSUserQuery`).
///
/// Opt-in: memory text enters the system Spotlight store under the chosen file protection class, so
/// only enable it when the user agreed. Documents are indexed with the domain
/// `<domainPrefix>.<encoded sessionKey>` (or `<domainPrefix>` without a session); the session key is
/// encoded with ``domainComponent(_:)`` so a key can never be a dot-prefix (sub-domain) of another.
/// ``deleteSession(_:)`` removes every document upserted under that session from Spotlight and from
/// the in-memory mirror. ``search(query:maxResults:minScore:)`` uses `CSUserQuery` with ranked
/// results (scores follow the rank order, best = 1) and falls back to an in-memory BM25 mirror when
/// Spotlight is unavailable or returns nothing. Index writes and deletes are bounded by
/// `writeTimeoutSeconds` and throw ``SpotlightTimeoutError`` when `corespotlightd` does not answer.
/// Unavailable on tvOS, watchOS and Linux, which keep ``MemoryIndex``.
public actor SpotlightMemoryIndex: MemorySearchBackend {
    /// Index name.
    nonisolated public let indexName: String
    /// Domain identifier prefix.
    nonisolated public let domainPrefix: String
    private let index: CSSearchableIndex
    private let store: any SpotlightItemIndexing
    private let mirror = MemoryIndex()
    private var documents: [String: MemoryDocument] = [:]
    private var documentSessions: [String: String] = [:]
    private let useUserQuery: Bool
    private let userQueryTimeoutSeconds: Double
    private let writeTimeoutSeconds: Double

    /// Creates the index.
    /// - Parameters:
    ///   - indexName: `CSSearchableIndex` name.
    ///   - domainPrefix: Domain identifier prefix.
    ///   - protection: File protection class for indexed items (`nil` uses the app default).
    ///   - useUserQuery: Query Spotlight (`false` searches the in-memory mirror only).
    ///   - userQueryTimeoutSeconds: Deadline for one `CSUserQuery`; on timeout the query is cancelled and
    ///     the search falls back to the in-memory mirror (the system embedding service can stall).
    ///     Clamped to 50 ms...one year; `.infinity` waits without a deadline.
    ///   - writeTimeoutSeconds: Deadline for one index write or delete (same clamping); on timeout the
    ///     call throws ``SpotlightTimeoutError``.
    public init(
        indexName: String = "ai.openclaw.memory",
        domainPrefix: String = "openclaw.memory",
        protection: FileProtectionType? = .completeUntilFirstUserAuthentication,
        useUserQuery: Bool = true,
        userQueryTimeoutSeconds: Double = 3,
        writeTimeoutSeconds: Double = 10
    ) {
        let index = protection.map { CSSearchableIndex(name: indexName, protectionClass: $0) } ?? CSSearchableIndex(name: indexName)
        self.init(
            indexName: indexName,
            domainPrefix: domainPrefix,
            index: index,
            store: SystemSpotlightItemIndex(index),
            useUserQuery: useUserQuery,
            userQueryTimeoutSeconds: userQueryTimeoutSeconds,
            writeTimeoutSeconds: writeTimeoutSeconds
        )
    }

    /// Creates the index over an injected store (tests).
    init(
        indexName: String,
        domainPrefix: String,
        index: CSSearchableIndex? = nil,
        store: any SpotlightItemIndexing,
        useUserQuery: Bool,
        userQueryTimeoutSeconds: Double = 3,
        writeTimeoutSeconds: Double = 10
    ) {
        self.indexName = indexName
        self.domainPrefix = domainPrefix
        self.index = index ?? CSSearchableIndex(name: indexName)
        self.store = store
        self.useUserQuery = useUserQuery
        self.userQueryTimeoutSeconds = userQueryTimeoutSeconds
        self.writeTimeoutSeconds = writeTimeoutSeconds
    }

    /// Whether this device supports Spotlight indexing.
    nonisolated public static var isIndexingAvailable: Bool {
        CSSearchableIndex.isIndexingAvailable()
    }

    /// Encodes one domain component so it contains no `.` (Spotlight treats dotted domain identifiers
    /// as a hierarchy, so `a.b` would otherwise be a sub-domain of `a`): `%` becomes `%25` and `.`
    /// becomes `%2E`.
    /// - Parameter value: Raw component (session key, agent id).
    /// - Returns: The encoded component.
    public static func domainComponent(_ value: String) -> String {
        value.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: ".", with: "%2E")
    }

    /// Domain identifier used for a session's documents.
    /// - Parameter sessionKey: Session key (`nil` for session-less documents).
    /// - Returns: `<domainPrefix>.<encoded sessionKey>`, or `domainPrefix`.
    nonisolated public func domain(forSession sessionKey: String?) -> String {
        sessionKey.map { "\(self.domainPrefix).\(Self.domainComponent($0))" } ?? self.domainPrefix
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
    ///   - sessionKey: Session used for the domain identifier; ``deleteSession(_:)`` removes these
    ///     documents again. Re-upserting a document moves it to the new session (or to none).
    /// - Throws: The CoreSpotlight error, or ``SpotlightTimeoutError``.
    public func upsert(_ docs: [MemoryDocument], sessionKey: String?) async throws {
        guard !docs.isEmpty else { return }
        let domain = self.domain(forSession: sessionKey)
        let items = docs.map { Self.item(for: $0, domain: domain) }
        for doc in docs {
            self.documents[doc.id] = doc
            if let sessionKey {
                self.documentSessions[doc.id] = sessionKey
            } else {
                self.documentSessions.removeValue(forKey: doc.id)
            }
        }
        await self.mirror.upsert(docs, sessionKey: sessionKey)
        guard self.store.isAvailable else { return }
        let store = self.store
        try await SpotlightTimeoutRace.completion(timeoutSeconds: self.writeTimeoutSeconds, operation: "indexSearchableItems") { completion in
            store.indexItems(items, completion: completion)
        }
    }

    /// Deletes documents.
    /// - Parameter ids: Document identifiers.
    /// - Throws: The CoreSpotlight error, or ``SpotlightTimeoutError``.
    public func delete(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        for id in ids {
            self.documents.removeValue(forKey: id)
            self.documentSessions.removeValue(forKey: id)
        }
        await self.mirror.delete(ids: ids)
        try await self.deleteIdentifiers(ids)
    }

    /// Deletes every document of a session: the documents upserted with that `sessionKey` (and, for
    /// compatibility, documents whose `metadata["sessionKey"]` matches) leave the in-memory mirror, and
    /// the session's Spotlight domain is deleted.
    /// - Parameter sessionKey: Session key.
    /// - Throws: The CoreSpotlight error, or ``SpotlightTimeoutError``.
    public func deleteSession(_ sessionKey: String) async throws {
        var ids = Set(self.documentSessions.compactMap { $0.value == sessionKey ? $0.key : nil })
        ids.formUnion(self.documents.values.filter { $0.metadata["sessionKey"] == sessionKey }.map(\.id))
        let sorted = ids.sorted()
        for id in sorted {
            self.documents.removeValue(forKey: id)
            self.documentSessions.removeValue(forKey: id)
        }
        await self.mirror.delete(ids: sorted)
        try await self.deleteDomains([self.domain(forSession: sessionKey)])
        // Documents matched by metadata may have been indexed under another domain.
        try await self.deleteIdentifiers(sorted)
    }

    /// Deletes everything this index added (memory reset / forget).
    /// - Throws: The CoreSpotlight error, or ``SpotlightTimeoutError``.
    public func deleteAll() async throws {
        let ids = Array(self.documents.keys)
        self.documents.removeAll()
        self.documentSessions.removeAll()
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
        if self.useUserQuery, self.store.isAvailable {
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
        guard self.store.isAvailable else { return }
        let store = self.store
        try await SpotlightTimeoutRace.completion(timeoutSeconds: self.writeTimeoutSeconds, operation: "deleteSearchableItems(withDomainIdentifiers:)") { completion in
            store.deleteItems(domains: domains, completion: completion)
        }
    }

    private func deleteIdentifiers(_ ids: [String]) async throws {
        guard !ids.isEmpty, self.store.isAvailable else { return }
        let store = self.store
        try await SpotlightTimeoutRace.completion(timeoutSeconds: self.writeTimeoutSeconds, operation: "deleteSearchableItems(withIdentifiers:)") { completion in
            store.deleteItems(identifiers: ids, completion: completion)
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

/// Mirrors builtin memory engine chunks into Spotlight (`memory:<agentId>:<path>#L<start>-<end>`, with a
/// `~k` part suffix when one long line was split into several chunks).
///
/// Opt-in: create one per agent and call ``sync(from:)`` after ``MemoryEngine/sync()`` once the user
/// has agreed to Spotlight indexing. The first sync of each indexer clears the agent's Spotlight
/// domain (`ai.openclaw.memory.<encoded agentId>`) before re-indexing, so chunks removed while the app
/// was not running (or by another process) do not linger in the system index; later syncs delete only
/// the chunks that disappeared. ``search(query:maxResults:)`` maps Spotlight hits back to
/// ``MemorySearchHit`` values by parsing the identifier.
public actor SpotlightMemoryIndexer {
    /// Agent identifier.
    nonisolated public let agentID: String
    private let index: SpotlightMemoryIndex
    private var indexedIDs: Set<String> = []
    private var didInitialSync = false

    /// Creates the indexer.
    /// - Parameters:
    ///   - agentID: Agent identifier.
    ///   - protection: File protection class.
    public init(agentID: String, protection: FileProtectionType? = .completeUntilFirstUserAuthentication) {
        self.agentID = agentID
        self.index = SpotlightMemoryIndex(indexName: "OpenClawMemory", domainPrefix: Self.domainPrefix(agentID: agentID), protection: protection)
    }

    /// Creates the indexer over an existing index (tests).
    init(agentID: String, index: SpotlightMemoryIndex) {
        self.agentID = agentID
        self.index = index
    }

    /// Spotlight domain holding an agent's chunks (`ai.openclaw.memory.<encoded agentId>`; the agent id is
    /// encoded with ``SpotlightMemoryIndex/domainComponent(_:)`` so agent `main` never covers `main.x`).
    /// - Parameter agentID: Agent identifier.
    /// - Returns: The domain identifier.
    public static func domainPrefix(agentID: String) -> String {
        "ai.openclaw.memory.\(SpotlightMemoryIndex.domainComponent(agentID))"
    }

    /// Unique identifier for a chunk.
    /// - Parameters:
    ///   - agentID: Agent.
    ///   - path: Relative path.
    ///   - startLine: First line.
    ///   - endLine: Last line.
    ///   - part: Part ordinal among chunks sharing the range (0 omits the suffix).
    /// - Returns: Identifier.
    public static func identifier(agentID: String, path: String, startLine: Int, endLine: Int, part: Int = 0) -> String {
        let base = "memory:\(agentID):\(path)#L\(startLine)-\(endLine)"
        return part > 0 ? "\(base)\(MemoryEngine.chunkPartMarker)\(part)" : base
    }

    /// Parses an identifier back into `(path, startLine, endLine)` (a `~k` part suffix is ignored).
    /// - Parameters:
    ///   - identifier: Identifier.
    ///   - agentID: Expected agent.
    /// - Returns: The components, or `nil` for foreign identifiers.
    public static func parse(identifier: String, agentID: String) -> (path: String, startLine: Int, endLine: Int)? {
        let prefix = "memory:\(agentID):"
        guard identifier.hasPrefix(prefix), let hash = identifier.range(of: "#L", options: .backwards) else { return nil }
        let path = String(identifier[identifier.index(identifier.startIndex, offsetBy: prefix.count)..<hash.lowerBound])
        var range = identifier[hash.upperBound...]
        if let marker = range.range(of: MemoryEngine.chunkPartMarker) {
            guard let part = Int(range[marker.upperBound...]), part > 0 else { return nil }
            range = range[..<marker.lowerBound]
        }
        let lines = range.split(separator: "-", omittingEmptySubsequences: false)
        guard lines.count == 2, let start = Int(lines[0]), let end = Int(lines[1]) else { return nil }
        return (path, start, end)
    }

    /// Upserts the engine's chunks and deletes chunks that disappeared (the first sync of an indexer
    /// clears the agent's domain first, since it cannot know what an earlier process indexed).
    /// - Parameter engine: Memory engine.
    /// - Throws: The CoreSpotlight error, or ``SpotlightTimeoutError``.
    public func sync(from engine: MemoryEngine) async throws {
        let chunks = await engine.indexedChunks()
        let docs = chunks.map { chunk in
            MemoryDocument(
                id: Self.identifier(agentID: self.agentID, path: chunk.path, startLine: chunk.startLine, endLine: chunk.endLine, part: chunk.part),
                source: .systemNote,
                text: chunk.text,
                metadata: ["title": chunk.path]
            )
        }
        let current = Set(docs.map(\.id))
        if self.didInitialSync {
            try await self.index.delete(ids: Array(self.indexedIDs.subtracting(current)).sorted())
        } else {
            try await self.index.deleteAll()
            self.indexedIDs.removeAll()
        }
        try await self.index.upsert(docs, sessionKey: nil)
        self.indexedIDs = current
        self.didInitialSync = true
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
        self.didInitialSync = true
    }
}
#endif
