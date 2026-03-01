import Foundation

/// Structured diagnostics event emitted by runtime and channel subsystems.
public struct RuntimeDiagnosticEvent: Sendable, Equatable {
    /// Event subsystem source (`runtime`, `channel`, etc.).
    public let subsystem: String
    /// Stable event name.
    public let name: String
    /// Optional correlated run identifier.
    public let runID: String?
    /// Optional correlated session key.
    public let sessionKey: String?
    /// Event timestamp.
    public let occurredAt: Date
    /// Additional event metadata values.
    public let metadata: [String: String]

    /// Creates a diagnostics event.
    /// - Parameters:
    ///   - subsystem: Event subsystem.
    ///   - name: Event name.
    ///   - runID: Optional run identifier.
    ///   - sessionKey: Optional session key.
    ///   - occurredAt: Event timestamp.
    ///   - metadata: Additional metadata.
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
}

/// Async sink invoked for each diagnostics event.
public typealias RuntimeDiagnosticSink = @Sendable (RuntimeDiagnosticEvent) async -> Void

/// Per-provider usage aggregates from runtime model calls.
public struct ModelUsageMetrics: Sendable, Equatable {
    public let providerID: String
    public let modelID: String
    public let calls: Int
    public let failures: Int
    public let totalLatencyMs: Int
    public let averageLatencyMs: Int

    /// Creates model usage metrics.
    public init(
        providerID: String,
        modelID: String,
        calls: Int,
        failures: Int,
        totalLatencyMs: Int
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.calls = max(0, calls)
        self.failures = max(0, failures)
        self.totalLatencyMs = max(0, totalLatencyMs)
        self.averageLatencyMs = calls > 0 ? self.totalLatencyMs / calls : 0
    }
}

/// Per-skill invocation aggregates.
public struct SkillUsageMetrics: Sendable, Equatable {
    public let skillName: String
    public let invocations: Int
    public let totalDurationMs: Int
    public let averageDurationMs: Int

    /// Creates skill usage metrics.
    public init(skillName: String, invocations: Int, totalDurationMs: Int) {
        self.skillName = skillName
        self.invocations = max(0, invocations)
        self.totalDurationMs = max(0, totalDurationMs)
        self.averageDurationMs = invocations > 0 ? self.totalDurationMs / invocations : 0
    }
}

/// Per-channel outbound delivery aggregates.
public struct ChannelUsageMetrics: Sendable, Equatable {
    public let channelID: String
    public let sent: Int
    public let failed: Int
    public let retryAttempts: Int

    /// Creates channel usage metrics.
    public init(channelID: String, sent: Int, failed: Int, retryAttempts: Int) {
        self.channelID = channelID
        self.sent = max(0, sent)
        self.failed = max(0, failed)
        self.retryAttempts = max(0, retryAttempts)
    }
}

/// Aggregate diagnostics/usage snapshot consumed by host applications.
public struct RuntimeUsageSnapshot: Sendable, Equatable {
    public let totalEvents: Int
    public let runsStarted: Int
    public let runsCompleted: Int
    public let runsFailed: Int
    public let runsTimedOut: Int
    public let totalRunLatencyMs: Int
    public let averageRunLatencyMs: Int
    public let modelCalls: Int
    public let modelFailures: Int
    public let skillInvocations: Int
    public let channelDeliveriesSent: Int
    public let channelDeliveriesFailed: Int
    public let models: [ModelUsageMetrics]
    public let skills: [SkillUsageMetrics]
    public let channels: [ChannelUsageMetrics]

    /// Creates a runtime usage snapshot.
    public init(
        totalEvents: Int,
        runsStarted: Int,
        runsCompleted: Int,
        runsFailed: Int,
        runsTimedOut: Int,
        totalRunLatencyMs: Int,
        modelCalls: Int,
        modelFailures: Int,
        skillInvocations: Int,
        channelDeliveriesSent: Int,
        channelDeliveriesFailed: Int,
        models: [ModelUsageMetrics],
        skills: [SkillUsageMetrics],
        channels: [ChannelUsageMetrics]
    ) {
        self.totalEvents = max(0, totalEvents)
        self.runsStarted = max(0, runsStarted)
        self.runsCompleted = max(0, runsCompleted)
        self.runsFailed = max(0, runsFailed)
        self.runsTimedOut = max(0, runsTimedOut)
        self.totalRunLatencyMs = max(0, totalRunLatencyMs)
        let latencyBase = max(1, self.runsCompleted)
        self.averageRunLatencyMs = self.totalRunLatencyMs / latencyBase
        self.modelCalls = max(0, modelCalls)
        self.modelFailures = max(0, modelFailures)
        self.skillInvocations = max(0, skillInvocations)
        self.channelDeliveriesSent = max(0, channelDeliveriesSent)
        self.channelDeliveriesFailed = max(0, channelDeliveriesFailed)
        self.models = models.sorted { lhs, rhs in
            if lhs.providerID == rhs.providerID {
                return lhs.modelID < rhs.modelID
            }
            return lhs.providerID < rhs.providerID
        }
        self.skills = skills.sorted { $0.skillName < $1.skillName }
        self.channels = channels.sorted { $0.channelID < $1.channelID }
    }
}

/// Actor that centralizes runtime/channel diagnostics and usage metrics.
public actor RuntimeDiagnosticsPipeline {
    private struct MutableModelMetrics {
        var modelID: String
        var calls = 0
        var failures = 0
        var totalLatencyMs = 0
    }

    private struct MutableSkillMetrics {
        var invocations = 0
        var totalDurationMs = 0
    }

    private struct MutableChannelMetrics {
        var sent = 0
        var failed = 0
        var retryAttempts = 0
    }

    private let eventLimit: Int
    private let replayStore: (any ReplayStore)?
    private var events: [RuntimeDiagnosticEvent] = []
    private var replaySequence = Int64(0)
    private var replaySequenceInitialized = false

    private var runsStarted = 0
    private var runsCompleted = 0
    private var runsFailed = 0
    private var runsTimedOut = 0
    private var totalRunLatencyMs = 0

    private var modelCalls = 0
    private var modelFailures = 0
    private var skillInvocations = 0
    private var channelDeliveriesSent = 0
    private var channelDeliveriesFailed = 0

    private var modelMetrics: [String: MutableModelMetrics] = [:]
    private var skillMetrics: [String: MutableSkillMetrics] = [:]
    private var channelMetrics: [String: MutableChannelMetrics] = [:]

    /// Creates a diagnostics pipeline.
    /// - Parameter eventLimit: Maximum number of recent events retained.
    /// - Parameter replayStore: Optional replay store used for deterministic event capture.
    public init(eventLimit: Int = 500, replayStore: (any ReplayStore)? = nil) {
        self.eventLimit = max(1, eventLimit)
        self.replayStore = replayStore
    }

    /// Returns a sink closure suitable for runtime/channel injection.
    public func sink() -> RuntimeDiagnosticSink {
        { [weak self] event in
            await self?.record(event)
        }
    }

    /// Records one diagnostics event and updates usage aggregates.
    /// - Parameter event: Diagnostics event.
    public func record(_ event: RuntimeDiagnosticEvent) async {
        self.events.append(event)
        if self.events.count > self.eventLimit {
            self.events.removeFirst(self.events.count - self.eventLimit)
        }
        self.apply(event)
        await self.appendReplayEvent(for: event)
    }

    /// Returns recent events in chronological order.
    /// - Parameter limit: Maximum number of events to return.
    /// - Returns: Chronological recent events.
    public func recentEvents(limit: Int = 100) -> [RuntimeDiagnosticEvent] {
        let clamped = max(1, limit)
        if self.events.count <= clamped {
            return self.events
        }
        return Array(self.events.suffix(clamped))
    }

    /// Returns the current aggregate usage snapshot.
    public func usageSnapshot() -> RuntimeUsageSnapshot {
        RuntimeUsageSnapshot(
            totalEvents: self.events.count,
            runsStarted: self.runsStarted,
            runsCompleted: self.runsCompleted,
            runsFailed: self.runsFailed,
            runsTimedOut: self.runsTimedOut,
            totalRunLatencyMs: self.totalRunLatencyMs,
            modelCalls: self.modelCalls,
            modelFailures: self.modelFailures,
            skillInvocations: self.skillInvocations,
            channelDeliveriesSent: self.channelDeliveriesSent,
            channelDeliveriesFailed: self.channelDeliveriesFailed,
            models: self.modelMetrics.map { key, value in
                ModelUsageMetrics(
                    providerID: key,
                    modelID: value.modelID,
                    calls: value.calls,
                    failures: value.failures,
                    totalLatencyMs: value.totalLatencyMs
                )
            },
            skills: self.skillMetrics.map { key, value in
                SkillUsageMetrics(
                    skillName: key,
                    invocations: value.invocations,
                    totalDurationMs: value.totalDurationMs
                )
            },
            channels: self.channelMetrics.map { key, value in
                ChannelUsageMetrics(
                    channelID: key,
                    sent: value.sent,
                    failed: value.failed,
                    retryAttempts: value.retryAttempts
                )
            }
        )
    }

    /// Clears retained events and aggregate counters.
    public func reset() {
        self.events.removeAll(keepingCapacity: true)
        self.runsStarted = 0
        self.runsCompleted = 0
        self.runsFailed = 0
        self.runsTimedOut = 0
        self.totalRunLatencyMs = 0
        self.modelCalls = 0
        self.modelFailures = 0
        self.skillInvocations = 0
        self.channelDeliveriesSent = 0
        self.channelDeliveriesFailed = 0
        self.modelMetrics.removeAll(keepingCapacity: true)
        self.skillMetrics.removeAll(keepingCapacity: true)
        self.channelMetrics.removeAll(keepingCapacity: true)
    }

    private func apply(_ event: RuntimeDiagnosticEvent) {
        switch (event.subsystem, event.name) {
        case ("runtime", "run.started"):
            self.runsStarted += 1
        case ("runtime", "run.completed"):
            self.runsCompleted += 1
            self.totalRunLatencyMs += max(0, Self.intValue(event.metadata["latencyMs"]))
        case ("runtime", "run.failed"):
            self.runsFailed += 1
            if Self.boolValue(event.metadata["timedOut"]) {
                self.runsTimedOut += 1
            }
        case ("runtime", "model.call.completed"):
            self.modelCalls += 1
            let providerID = Self.stringValue(event.metadata["providerID"], fallback: "unknown")
            let modelID = Self.stringValue(event.metadata["modelID"], fallback: "unknown")
            let latencyMs = max(0, Self.intValue(event.metadata["latencyMs"]))
            var current = self.modelMetrics[providerID] ?? MutableModelMetrics(modelID: modelID)
            current.modelID = modelID
            current.calls += 1
            current.totalLatencyMs += latencyMs
            self.modelMetrics[providerID] = current
        case ("runtime", "model.call.failed"):
            self.modelFailures += 1
            let providerID = Self.stringValue(
                event.metadata["providerID"] ?? event.metadata["requestedProviderID"],
                fallback: "unknown"
            )
            let modelID = Self.stringValue(event.metadata["modelID"], fallback: "unknown")
            var current = self.modelMetrics[providerID] ?? MutableModelMetrics(modelID: modelID)
            current.modelID = modelID
            current.failures += 1
            self.modelMetrics[providerID] = current
        case ("channel", "skill.invoked"):
            self.skillInvocations += 1
            let skillName = Self.stringValue(event.metadata["skillName"], fallback: "unknown")
            let durationMs = max(0, Self.intValue(event.metadata["durationMs"]))
            var current = self.skillMetrics[skillName] ?? MutableSkillMetrics()
            current.invocations += 1
            current.totalDurationMs += durationMs
            self.skillMetrics[skillName] = current
        case ("channel", "outbound.sent"):
            self.channelDeliveriesSent += 1
            let channelID = Self.stringValue(event.metadata["channel"], fallback: "unknown")
            let attempts = max(1, Self.intValue(event.metadata["attempts"]))
            var current = self.channelMetrics[channelID] ?? MutableChannelMetrics()
            current.sent += 1
            current.retryAttempts += max(0, attempts - 1)
            self.channelMetrics[channelID] = current
        case ("channel", "outbound.failed"):
            self.channelDeliveriesFailed += 1
            let channelID = Self.stringValue(event.metadata["channel"], fallback: "unknown")
            let attempts = max(1, Self.intValue(event.metadata["attempts"]))
            var current = self.channelMetrics[channelID] ?? MutableChannelMetrics()
            current.failed += 1
            current.retryAttempts += max(0, attempts - 1)
            self.channelMetrics[channelID] = current
        default:
            break
        }
    }

    private func appendReplayEvent(for event: RuntimeDiagnosticEvent) async {
        guard let replayStore else {
            return
        }
        await self.ensureReplaySequenceInitialized(using: replayStore)

        let sequence = self.replaySequence
        self.replaySequence += 1
        let replayEvent = ReplayEvent(
            diagnosticEvent: event,
            sequenceNumber: sequence
        )
        do {
            try await replayStore.append(ReplayEventEnvelope(event: replayEvent))
        } catch {
            // Replay persistence must never fail the diagnostics pipeline.
        }
    }

    private func ensureReplaySequenceInitialized(using replayStore: any ReplayStore) async {
        guard !self.replaySequenceInitialized else {
            return
        }
        if let events = try? await replayStore.loadAll(),
           let last = events.last?.event.sequenceNumber {
            self.replaySequence = last + 1
        } else {
            self.replaySequence = 0
        }
        self.replaySequenceInitialized = true
    }

    private static func intValue(_ raw: String?) -> Int {
        guard let raw else { return 0 }
        return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private static func boolValue(_ raw: String?) -> Bool {
        guard let raw else { return false }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
    }

    private static func stringValue(_ raw: String?, fallback: String) -> String {
        guard let raw else { return fallback }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
