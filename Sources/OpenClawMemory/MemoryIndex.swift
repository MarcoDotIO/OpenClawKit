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

/// Actor-backed in-memory document index with simple token scoring.
public actor MemoryIndex {
    private var records: [String: MemoryDocument] = [:]

    /// Creates an empty memory index.
    public init() {}

    /// Inserts or replaces a document in the index.
    /// - Parameter record: Memory document.
    public func upsert(_ record: MemoryDocument) {
        self.records[record.id] = record
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
    }

    /// Upserts a batch of documents.
    /// - Parameter documents: Documents to upsert.
    public func sync(_ documents: [MemoryDocument]) {
        for doc in documents {
            self.records[doc.id] = doc
        }
    }

    /// Performs a token-overlap search over indexed documents.
    /// - Parameters:
    ///   - query: Search text.
    ///   - maxResults: Maximum number of returned results.
    ///   - minScore: Minimum score threshold.
    /// - Returns: Sorted search results by score descending.
    public func search(
        query: String,
        maxResults: Int = 8,
        minScore: Double = 0.0
    ) -> [MemorySearchResult] {
        let normalizedQuery = tokens(query)
        guard !normalizedQuery.isEmpty else { return [] }

        let scored = self.records.values.map { doc -> MemorySearchResult in
            let docTokens = tokens(doc.text)
            let common = normalizedQuery.intersection(docTokens)
            let score = docTokens.isEmpty ? 0.0 : Double(common.count) / Double(docTokens.count)
            return MemorySearchResult(id: doc.id, score: score, text: doc.text, source: doc.source)
        }
        return scored
            .filter { $0.score >= minScore }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.id < rhs.id
                }
                return lhs.score > rhs.score
            }
            .prefix(maxResults)
            .map { $0 }
    }
}

private func tokens(_ text: String) -> Set<String> {
    let split = text
        .lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
    return Set(split)
}
