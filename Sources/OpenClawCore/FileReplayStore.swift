import Foundation

/// File-backed replay store using newline-delimited JSON envelopes.
public actor FileReplayStore: ReplayStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var isLoaded = false
    private var cachedEvents: [ReplayEventEnvelope] = []

    /// Creates a file-backed replay store.
    /// - Parameter fileURL: Optional custom replay log URL.
    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultStoreURL()
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public func append(_ envelope: ReplayEventEnvelope) async throws {
        try await self.append(contentsOf: [envelope])
    }

    public func append(contentsOf envelopes: [ReplayEventEnvelope]) async throws {
        guard !envelopes.isEmpty else { return }
        try self.ensureLoaded()

        var nextSequence = (self.cachedEvents.last?.event.sequenceNumber ?? -1) + 1
        for envelope in envelopes {
            var normalized = envelope
            if let provided = normalized.event.sequenceNumber, provided >= nextSequence {
                nextSequence = provided + 1
            } else {
                normalized.event.sequenceNumber = nextSequence
                nextSequence += 1
            }
            normalized.event.schemaVersion = max(1, normalized.event.schemaVersion)
            try self.appendLine(normalized)
            self.cachedEvents.append(normalized)
        }
    }

    public func loadAll() async throws -> [ReplayEventEnvelope] {
        try self.ensureLoaded()
        return self.cachedEvents
    }

    public func load(sinceSequence sequenceNumber: Int64?) async throws -> [ReplayEventEnvelope] {
        try self.ensureLoaded()
        guard let sequenceNumber else {
            return self.cachedEvents
        }
        return self.cachedEvents.filter { ($0.event.sequenceNumber ?? -1) > sequenceNumber }
    }

    @discardableResult
    public func compact(keepingLast maxEvents: Int) async throws -> ReplayStoreCompactionResult {
        guard maxEvents >= 1 else {
            throw ReplayStoreError.invalidCompactionLimit(maxEvents)
        }
        try self.ensureLoaded()
        guard self.cachedEvents.count > maxEvents else {
            return ReplayStoreCompactionResult(
                removedCount: 0,
                remainingCount: self.cachedEvents.count,
                compactedThroughSequence: nil
            )
        }

        let removedCount = self.cachedEvents.count - maxEvents
        let removed = Array(self.cachedEvents.prefix(removedCount))
        let kept = Array(self.cachedEvents.suffix(maxEvents))
        let compactedThroughSequence = removed.last?.event.sequenceNumber
        self.cachedEvents = kept
        try self.writeAll(self.cachedEvents)
        return ReplayStoreCompactionResult(
            removedCount: removedCount,
            remainingCount: kept.count,
            compactedThroughSequence: compactedThroughSequence
        )
    }

    @discardableResult
    public func recover() async throws -> Int {
        let (events, droppedLines) = try self.readValidPrefix()
        let (normalized, changed) = self.normalizeSequences(events)
        if droppedLines > 0 || changed {
            try self.writeAll(normalized)
        }
        self.cachedEvents = normalized
        self.isLoaded = true
        return droppedLines
    }

    private func ensureLoaded() throws {
        guard !self.isLoaded else {
            return
        }
        let (events, droppedLines) = try self.readValidPrefix()
        let (normalized, changed) = self.normalizeSequences(events)
        if droppedLines > 0 || changed {
            try self.writeAll(normalized)
        }
        self.cachedEvents = normalized
        self.isLoaded = true
    }

    private func readValidPrefix() throws -> ([ReplayEventEnvelope], Int) {
        guard FileManager.default.fileExists(atPath: self.fileURL.path) else {
            return ([], 0)
        }
        let data = try Data(contentsOf: self.fileURL)
        guard !data.isEmpty else {
            return ([], 0)
        }

        let rawLines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        var events: [ReplayEventEnvelope] = []
        var droppedLines = 0
        for (index, line) in rawLines.enumerated() {
            do {
                let envelope = try self.decoder.decode(ReplayEventEnvelope.self, from: Data(line))
                events.append(envelope)
            } catch {
                droppedLines = rawLines.count - index
                break
            }
        }
        return (events, droppedLines)
    }

    private func normalizeSequences(_ envelopes: [ReplayEventEnvelope]) -> ([ReplayEventEnvelope], Bool) {
        var normalized: [ReplayEventEnvelope] = []
        normalized.reserveCapacity(envelopes.count)

        var changed = false
        var nextSequence: Int64 = 0
        for original in envelopes {
            var envelope = original
            if let provided = envelope.event.sequenceNumber, provided >= nextSequence {
                nextSequence = provided + 1
            } else {
                envelope.event.sequenceNumber = nextSequence
                nextSequence += 1
                changed = true
            }
            envelope.event.schemaVersion = max(1, envelope.event.schemaVersion)
            normalized.append(envelope)
        }
        return (normalized, changed)
    }

    private func appendLine(_ envelope: ReplayEventEnvelope) throws {
        let line = try self.serializedLine(for: envelope)
        try FileManager.default.createDirectory(
            at: self.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(atPath: self.fileURL.path) {
            let handle = try FileHandle(forWritingTo: self.fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: self.fileURL, options: [.atomic])
        }
    }

    private func writeAll(_ envelopes: [ReplayEventEnvelope]) throws {
        try FileManager.default.createDirectory(
            at: self.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try envelopes.reduce(into: Data()) { partial, envelope in
            partial.append(try self.serializedLine(for: envelope))
        }
        try data.write(to: self.fileURL, options: [.atomic])
    }

    private func serializedLine(for envelope: ReplayEventEnvelope) throws -> Data {
        var payload = try self.encoder.encode(envelope)
        payload.append(UInt8(ascii: "\n"))
        return payload
    }

    private static func defaultStoreURL() -> URL {
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return appSupport
                .appendingPathComponent("OpenClaw", isDirectory: true)
                .appendingPathComponent("replay", isDirectory: true)
                .appendingPathComponent("events.jsonl", isDirectory: false)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw", isDirectory: true)
            .appendingPathComponent("replay", isDirectory: true)
            .appendingPathComponent("events.jsonl", isDirectory: false)
    }
}
