import Foundation

/// Optional detached signature attached to replay event envelopes.
public struct ReplayEventSignature: Codable, Sendable, Equatable {
    public var algorithm: String
    public var keyID: String
    public var value: String

    /// Creates a replay signature payload.
    /// - Parameters:
    ///   - algorithm: Signature algorithm identifier.
    ///   - keyID: Key identity that produced the signature.
    ///   - value: Signature bytes encoded as base64.
    public init(algorithm: String, keyID: String, value: String) {
        self.algorithm = algorithm
        self.keyID = keyID
        self.value = value
    }
}

/// Persisted envelope that wraps one replay event and ledger metadata.
public struct ReplayEventEnvelope: Codable, Sendable, Equatable {
    public var event: ReplayEvent
    public var previousEventHash: String?
    public var eventHash: String?
    public var signature: ReplayEventSignature?
    public var recordedAt: Date

    /// Creates a replay event envelope.
    /// - Parameters:
    ///   - event: Event payload.
    ///   - previousEventHash: Optional previous chain hash.
    ///   - eventHash: Optional hash of current event.
    ///   - signature: Optional detached signature.
    ///   - recordedAt: Persistence timestamp.
    public init(
        event: ReplayEvent,
        previousEventHash: String? = nil,
        eventHash: String? = nil,
        signature: ReplayEventSignature? = nil,
        recordedAt: Date = Date()
    ) {
        self.event = event
        self.previousEventHash = previousEventHash
        self.eventHash = eventHash
        self.signature = signature
        self.recordedAt = recordedAt
    }
}
