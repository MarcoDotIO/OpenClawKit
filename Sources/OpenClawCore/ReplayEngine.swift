import Foundation

/// Closed replay time window used for deterministic replay queries.
public struct ReplayTimeWindow: Sendable, Equatable {
    public let start: Date
    public let end: Date

    /// Creates a replay time window.
    /// - Parameters:
    ///   - start: Inclusive lower timestamp bound.
    ///   - end: Inclusive upper timestamp bound.
    public init(start: Date, end: Date) {
        if start <= end {
            self.start = start
            self.end = end
        } else {
            self.start = end
            self.end = start
        }
    }

    func contains(_ date: Date) -> Bool {
        (self.start ... self.end).contains(date)
    }
}

/// Replay query filters for deterministic event selection.
public struct ReplayQuery: Sendable, Equatable {
    public var runID: String?
    public var sessionKey: String?
    public var window: ReplayTimeWindow?
    public var limit: Int?

    /// Creates a replay query.
    /// - Parameters:
    ///   - runID: Optional run identifier filter.
    ///   - sessionKey: Optional session key filter.
    ///   - window: Optional time window filter.
    ///   - limit: Optional maximum number of returned events.
    public init(
        runID: String? = nil,
        sessionKey: String? = nil,
        window: ReplayTimeWindow? = nil,
        limit: Int? = nil
    ) {
        self.runID = runID
        self.sessionKey = sessionKey
        self.window = window
        self.limit = limit
    }
}

/// Query/replay facade over a replay store.
public struct ReplayEngine: Sendable {
    private let store: any ReplayStore

    /// Creates a replay engine.
    /// - Parameter store: Replay event store.
    public init(store: any ReplayStore) {
        self.store = store
    }

    /// Fetches events filtered by run identifier.
    /// - Parameters:
    ///   - runID: Target run identifier.
    ///   - limit: Optional maximum number of returned events.
    public func events(forRunID runID: String, limit: Int? = nil) async throws -> [ReplayEventEnvelope] {
        try await self.events(matching: ReplayQuery(runID: runID, limit: limit))
    }

    /// Fetches events filtered by session key.
    /// - Parameters:
    ///   - sessionKey: Target session key.
    ///   - limit: Optional maximum number of returned events.
    public func events(forSessionKey sessionKey: String, limit: Int? = nil) async throws -> [ReplayEventEnvelope] {
        try await self.events(matching: ReplayQuery(sessionKey: sessionKey, limit: limit))
    }

    /// Fetches events filtered by time window.
    /// - Parameters:
    ///   - window: Inclusive time window.
    ///   - limit: Optional maximum number of returned events.
    public func events(in window: ReplayTimeWindow, limit: Int? = nil) async throws -> [ReplayEventEnvelope] {
        try await self.events(matching: ReplayQuery(window: window, limit: limit))
    }

    /// Fetches events using the provided filter query.
    /// - Parameter query: Replay query filters.
    /// - Returns: Deterministically ordered replay events.
    public func events(matching query: ReplayQuery = ReplayQuery()) async throws -> [ReplayEventEnvelope] {
        let loaded = try await self.store.loadAll()
        let sorted = loaded.sorted(by: Self.deterministicLessThan)
        let filtered = sorted.filter { envelope in
            if let runID = query.runID, envelope.event.runID != runID {
                return false
            }
            if let sessionKey = query.sessionKey, envelope.event.sessionKey != sessionKey {
                return false
            }
            if let window = query.window, !window.contains(envelope.event.occurredAt) {
                return false
            }
            return true
        }
        guard let limit = query.limit, limit > 0 else {
            return filtered
        }
        if filtered.count <= limit {
            return filtered
        }
        return Array(filtered.suffix(limit))
    }

    /// Replays events with optional per-event callback.
    /// - Parameters:
    ///   - query: Replay query.
    ///   - onEvent: Optional callback invoked for each replayed event in order.
    /// - Returns: Replayed events.
    public func replay(
        matching query: ReplayQuery = ReplayQuery(),
        onEvent: (@Sendable (ReplayEventEnvelope) async throws -> Void)? = nil
    ) async throws -> [ReplayEventEnvelope] {
        let events = try await self.events(matching: query)
        if let onEvent {
            for event in events {
                try await onEvent(event)
            }
        }
        return events
    }

    private static func deterministicLessThan(_ lhs: ReplayEventEnvelope, _ rhs: ReplayEventEnvelope) -> Bool {
        let lhsSequence = lhs.event.sequenceNumber ?? Int64.min
        let rhsSequence = rhs.event.sequenceNumber ?? Int64.min
        if lhsSequence != rhsSequence {
            return lhsSequence < rhsSequence
        }
        if lhs.event.occurredAt != rhs.event.occurredAt {
            return lhs.event.occurredAt < rhs.event.occurredAt
        }
        return lhs.event.eventID.uuidString < rhs.event.eventID.uuidString
    }
}
