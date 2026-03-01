import Foundation
import OpenClawProtocol

/// Stable deterministic event contract captured by the replay runtime.
public struct ReplayEvent: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var eventID: UUID
    public var sequenceNumber: Int64?
    public var subsystem: String
    public var name: String
    public var runID: String?
    public var sessionKey: String?
    public var occurredAt: Date
    public var metadata: [String: String]
    public var payload: AnyCodable?

    /// Creates a replay event.
    /// - Parameters:
    ///   - schemaVersion: Event contract schema version.
    ///   - eventID: Event identity.
    ///   - sequenceNumber: Optional deterministic sequence.
    ///   - subsystem: Event subsystem.
    ///   - name: Stable event name.
    ///   - runID: Optional correlated run identifier.
    ///   - sessionKey: Optional correlated session key.
    ///   - occurredAt: Event timestamp.
    ///   - metadata: Flat deterministic metadata.
    ///   - payload: Optional structured payload.
    public init(
        schemaVersion: Int = ReplayEvent.currentSchemaVersion,
        eventID: UUID = UUID(),
        sequenceNumber: Int64? = nil,
        subsystem: String,
        name: String,
        runID: String? = nil,
        sessionKey: String? = nil,
        occurredAt: Date = Date(),
        metadata: [String: String] = [:],
        payload: AnyCodable? = nil
    ) {
        self.schemaVersion = max(1, schemaVersion)
        self.eventID = eventID
        self.sequenceNumber = sequenceNumber
        self.subsystem = subsystem.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.runID = runID
        self.sessionKey = sessionKey
        self.occurredAt = occurredAt
        self.metadata = metadata
        self.payload = payload
    }

    /// Creates a replay event from runtime diagnostics.
    /// - Parameters:
    ///   - event: Diagnostics event.
    ///   - sequenceNumber: Optional deterministic sequence.
    ///   - schemaVersion: Event schema version.
    public init(
        diagnosticEvent event: RuntimeDiagnosticEvent,
        sequenceNumber: Int64? = nil,
        schemaVersion: Int = ReplayEvent.currentSchemaVersion
    ) {
        self.init(
            schemaVersion: schemaVersion,
            sequenceNumber: sequenceNumber,
            subsystem: event.subsystem,
            name: event.name,
            runID: event.runID,
            sessionKey: event.sessionKey,
            occurredAt: event.occurredAt,
            metadata: event.metadata,
            payload: nil
        )
    }
}
