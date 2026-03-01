import Foundation

/// Exportable timeline record derived from runtime diagnostics.
public struct RuntimeTimelineRecord: Codable, Sendable, Equatable {
    public let subsystem: String
    public let name: String
    public let runID: String?
    public let sessionKey: String?
    public let occurredAt: Date
    public let metadata: [String: String]

    /// Creates a timeline record.
    public init(
        subsystem: String,
        name: String,
        runID: String? = nil,
        sessionKey: String? = nil,
        occurredAt: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.subsystem = subsystem
        self.name = name
        self.runID = runID
        self.sessionKey = sessionKey
        self.occurredAt = occurredAt
        self.metadata = metadata
    }

    /// Creates a timeline record from one runtime diagnostics event.
    public init(event: RuntimeDiagnosticEvent) {
        self.init(
            subsystem: event.subsystem,
            name: event.name,
            runID: event.runID,
            sessionKey: event.sessionKey,
            occurredAt: event.occurredAt,
            metadata: event.metadata
        )
    }
}

/// Sink contract for timeline records.
public protocol RuntimeTimelineSink: Sendable {
    /// Records one timeline event.
    func record(_ record: RuntimeTimelineRecord) async
}

/// In-memory timeline sink useful for tests and export.
public actor BufferedRuntimeTimelineSink: RuntimeTimelineSink {
    private let limit: Int
    private var records: [RuntimeTimelineRecord] = []

    /// Creates a buffered timeline sink.
    /// - Parameter limit: Maximum retained records.
    public init(limit: Int = 2_000) {
        self.limit = max(1, limit)
    }

    public func record(_ record: RuntimeTimelineRecord) async {
        self.records.append(record)
        if self.records.count > self.limit {
            self.records.removeFirst(self.records.count - self.limit)
        }
    }

    /// Returns buffered records in chronological order.
    /// - Parameter limit: Optional max record count.
    public func timeline(limit: Int? = nil) -> [RuntimeTimelineRecord] {
        guard let limit, limit > 0 else {
            return self.records
        }
        if self.records.count <= limit {
            return self.records
        }
        return Array(self.records.suffix(limit))
    }
}

#if canImport(os)
import os

/// Apple timeline sink backed by `os_signpost` events for Instruments.
public actor OSSignpostRuntimeTimelineSink: RuntimeTimelineSink {
    private let log: OSLog

    /// Creates a signpost timeline sink.
    /// - Parameters:
    ///   - subsystem: OSLog subsystem.
    ///   - category: OSLog category.
    public init(subsystem: String = "io.marcodotio.openclawkit", category: String = "runtime.timeline") {
        self.log = OSLog(subsystem: subsystem, category: category)
    }

    public func record(_ record: RuntimeTimelineRecord) async {
        os_signpost(
            .event,
            log: self.log,
            name: "RuntimeTimelineEvent",
            "%{public}s|%{public}s|%{public}s|%{public}s",
            record.subsystem,
            record.name,
            record.runID ?? "",
            record.sessionKey ?? ""
        )
    }
}
#else
/// Portable fallback that keeps API compatibility when signposts are unavailable.
public actor OSSignpostRuntimeTimelineSink: RuntimeTimelineSink {
    /// Creates a no-op signpost timeline sink.
    /// - Parameters:
    ///   - subsystem: Ignored.
    ///   - category: Ignored.
    public init(subsystem _: String = "io.marcodotio.openclawkit", category _: String = "runtime.timeline") {}

    public func record(_: RuntimeTimelineRecord) async {}
}
#endif
