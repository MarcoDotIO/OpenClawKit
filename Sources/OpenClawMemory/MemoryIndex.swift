import Foundation
import OpenClawProtocol

/// Memory source categories used for indexed documents.
public enum MemorySource: String, Codable, Sendable {
    case userMessage = "user_message"
    case toolResult = "tool_result"
    case systemNote = "system_note"
}

/// Persisted memory document.
public struct MemoryDocument: Codable, Sendable, Equatable {
    /// Stable document identifier.
    public let id: String
    /// Document source category.
    public let source: MemorySource
    /// Plaintext document content.
    public let text: String
    /// Optional document metadata.
    public let metadata: [String: String]

    /// Creates a memory document.
    /// - Parameters:
    ///   - id: Document identifier.
    ///   - source: Source category.
    ///   - text: Document text content.
    ///   - metadata: Optional metadata.
    public init(id: String, source: MemorySource, text: String, metadata: [String: String] = [:]) {
        self.id = id
        self.source = source
        self.text = text
        self.metadata = metadata
    }
}

/// Ranked memory search result.
public struct MemorySearchResult: Sendable, Equatable {
    /// Document identifier.
    public let id: String
    /// Similarity score.
    public let score: Double
    /// Matched text content.
    public let text: String
    /// Source category.
    public let source: MemorySource

    /// Creates a search result payload.
    /// - Parameters:
    ///   - id: Document identifier.
    ///   - score: Similarity score.
    ///   - text: Matched text content.
    ///   - source: Source category.
    public init(id: String, score: Double, text: String, source: MemorySource) {
        self.id = id
        self.score = score
        self.text = text
        self.source = source
    }
}

/// Document-level memory search backend (in-memory index, Spotlight, …).
public protocol MemorySearchBackend: Actor {
    /// Inserts or replaces documents.
    /// - Parameters:
    ///   - docs: Documents.
    ///   - sessionKey: Optional session the documents belong to.
    func upsert(_ docs: [MemoryDocument], sessionKey: String?) async throws

    /// Deletes documents.
    /// - Parameter ids: Document identifiers.
    func delete(ids: [String]) async throws

    /// Searches documents.
    /// - Parameters:
    ///   - query: Query text.
    ///   - maxResults: Maximum results.
    ///   - minScore: Minimum score.
    /// - Returns: Ranked results.
    func search(query: String, maxResults: Int, minScore: Double) async throws -> [MemorySearchResult]
}

/// Actor-backed in-memory document index, scored with BM25 (normalized to `0...1` by the best hit).
public actor MemoryIndex: MemorySearchBackend {
    private var records: [String: MemoryDocument] = [:]
    private var bm25 = BM25Index()

    /// Creates an empty memory index.
    public init() {}

    /// Inserts or replaces a document in the index.
    /// - Parameter record: Memory document.
    public func upsert(_ record: MemoryDocument) {
        self.records[record.id] = record
        self.bm25.upsert(id: record.id, text: record.text)
    }

    /// Inserts or replaces documents (``MemorySearchBackend`` conformance).
    /// - Parameters:
    ///   - docs: Documents.
    ///   - sessionKey: Ignored by the in-memory index.
    public func upsert(_ docs: [MemoryDocument], sessionKey _: String?) {
        self.sync(docs)
    }

    /// Fetches a document by ID.
    /// - Parameter key: Document identifier.
    /// - Returns: Matching document when present.
    public func get(key: String) -> MemoryDocument? {
        self.records[key]
    }

    /// Deletes a document from the index.
    /// - Parameter key: Document identifier.
    public func delete(key: String) {
        self.records.removeValue(forKey: key)
        self.bm25.remove(id: key)
    }

    /// Deletes documents (``MemorySearchBackend`` conformance).
    /// - Parameter ids: Document identifiers.
    public func delete(ids: [String]) {
        for id in ids { self.delete(key: id) }
    }

    /// Upserts a batch of documents.
    /// - Parameter documents: Documents to upsert.
    public func sync(_ documents: [MemoryDocument]) {
        for doc in documents {
            self.upsert(doc)
        }
    }

    /// Searches indexed documents with BM25.
    /// - Parameters:
    ///   - query: Search text.
    ///   - maxResults: Maximum number of returned results.
    ///   - minScore: Minimum score threshold (scores are normalized to `0...1`).
    /// - Returns: Sorted search results by score descending (ties by id).
    public func search(
        query: String,
        maxResults: Int = 8,
        minScore: Double = 0.0
    ) -> [MemorySearchResult] {
        let hits = self.bm25.search(query, limit: max(0, self.records.count))
        guard let best = hits.first?.score, best > 0 else { return [] }
        return hits.compactMap { hit -> MemorySearchResult? in
            guard let doc = self.records[hit.id] else { return nil }
            return MemorySearchResult(id: doc.id, score: hit.score / best, text: doc.text, source: doc.source)
        }
        .filter { $0.score >= minScore }
        .sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
        .prefix(max(0, maxResults))
        .map { $0 }
    }
}
