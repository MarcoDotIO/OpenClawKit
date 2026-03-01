import Foundation

/// Result payload returned by replay store compaction.
public struct ReplayStoreCompactionResult: Sendable, Equatable {
    public let removedCount: Int
    public let remainingCount: Int
    public let compactedThroughSequence: Int64?

    /// Creates a replay compaction result.
    /// - Parameters:
    ///   - removedCount: Number of removed events.
    ///   - remainingCount: Number of events kept.
    ///   - compactedThroughSequence: Highest compacted sequence.
    public init(removedCount: Int, remainingCount: Int, compactedThroughSequence: Int64?) {
        self.removedCount = max(0, removedCount)
        self.remainingCount = max(0, remainingCount)
        self.compactedThroughSequence = compactedThroughSequence
    }
}

/// Replay store contract for append, replay retrieval, compaction, and recovery.
public protocol ReplayStore: Sendable {
    /// Appends one replay event envelope.
    func append(_ envelope: ReplayEventEnvelope) async throws

    /// Appends multiple replay event envelopes.
    func append(contentsOf envelopes: [ReplayEventEnvelope]) async throws

    /// Loads all replay event envelopes in deterministic order.
    func loadAll() async throws -> [ReplayEventEnvelope]

    /// Loads replay event envelopes after the provided sequence.
    /// - Parameter sequenceNumber: Sequence floor (exclusive). `nil` returns all events.
    func load(sinceSequence sequenceNumber: Int64?) async throws -> [ReplayEventEnvelope]

    /// Compacts the store by keeping only the most recent envelopes.
    /// - Parameter maxEvents: Number of events to keep.
    /// - Returns: Compaction result metadata.
    @discardableResult
    func compact(keepingLast maxEvents: Int) async throws -> ReplayStoreCompactionResult

    /// Recovers the store by truncating corrupted trailing lines.
    /// - Returns: Number of dropped corrupted lines.
    @discardableResult
    func recover() async throws -> Int
}

/// Replay store failures.
public enum ReplayStoreError: Error, LocalizedError, Sendable, Equatable {
    /// Indicates an invalid compaction limit was requested.
    case invalidCompactionLimit(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidCompactionLimit(let limit):
            return "Invalid replay compaction limit: \(limit)"
        }
    }
}
