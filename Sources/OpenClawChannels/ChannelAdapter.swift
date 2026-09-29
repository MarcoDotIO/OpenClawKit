import Foundation
import OpenClawCore

/// Async callback invoked for adapter-delivered inbound messages.
public typealias InboundMessageHandler = @Sendable (InboundMessage) async -> Void

/// Result of an adapter credential/connectivity probe (for example Telegram `getMe`, Slack `auth.test`).
public struct ChannelProbeResult: Codable, Sendable, Equatable {
    /// Whether the probe succeeded.
    public var ok: Bool
    /// Whether the adapter supports probing.
    public var supported: Bool
    /// Human-readable detail (bot name, error, ...).
    public var detail: String?
    /// Probe latency in milliseconds.
    public var latencyMs: Int?
    /// Probe time.
    public var probedAt: Date

    /// Creates a probe result.
    /// - Parameters:
    ///   - ok: Whether the probe succeeded.
    ///   - supported: Whether probing is supported.
    ///   - detail: Human-readable detail.
    ///   - latencyMs: Latency in milliseconds.
    ///   - probedAt: Probe time.
    public init(ok: Bool, supported: Bool = true, detail: String? = nil, latencyMs: Int? = nil, probedAt: Date = Date()) {
        self.ok = ok
        self.supported = supported
        self.detail = detail
        self.latencyMs = latencyMs
        self.probedAt = probedAt
    }

    /// Result for adapters without probe support.
    public static var unsupported: ChannelProbeResult {
        ChannelProbeResult(ok: false, supported: false, detail: "probe not supported")
    }
}

/// Pluggable channel transport abstraction.
///
/// - Note: 2026.3.0 added ``supportsTypingIndicator``, ``stopTypingIndicator(accountID:peerID:)``,
///   ``probe(timeoutMs:)`` and ``logout()`` with default implementations. Adapters that implement
///   ``sendTypingIndicator(accountID:peerID:)`` must also return `true` from
///   ``supportsTypingIndicator`` (declare it `nonisolated` on actors) for the auto-reply engine to
///   drive typing keepalives.
public protocol ChannelAdapter: Sendable {
    /// Channel identifier handled by this adapter.
    var id: ChannelID { get }
    /// Starts the adapter transport.
    func start() async throws
    /// Stops the adapter transport.
    func stop() async
    /// Sends an outbound message to the backing channel.
    /// - Parameter message: Outbound payload.
    func send(_ message: OutboundMessage) async throws

    /// Sends a typing indicator for channels that support typing state.
    /// - Parameters:
    ///   - accountID: Channel account key.
    ///   - peerID: Conversation peer/channel identifier.
    func sendTypingIndicator(accountID: String?, peerID: String) async throws

    /// Whether ``sendTypingIndicator(accountID:peerID:)`` does anything (default `false`).
    var supportsTypingIndicator: Bool { get }

    /// Clears a typing indicator (for example Signal `DELETE` or a Slack status reset). Default: no-op.
    /// - Parameters:
    ///   - accountID: Channel account key.
    ///   - peerID: Conversation peer/channel identifier.
    func stopTypingIndicator(accountID: String?, peerID: String) async throws

    /// Probes credentials/connectivity. Default: ``ChannelProbeResult/unsupported``.
    /// - Parameter timeoutMs: Probe timeout in milliseconds.
    /// - Returns: Probe result.
    func probe(timeoutMs: Int) async -> ChannelProbeResult

    /// Logs out (stops and clears session credentials where the platform has them). Default: ``stop()``.
    func logout() async throws
}

public extension ChannelAdapter {
    /// Default no-op typing indicator implementation for channels without typing support.
    func sendTypingIndicator(accountID _: String?, peerID _: String) async throws {}

    /// Default: typing is not supported.
    var supportsTypingIndicator: Bool {
        false
    }

    /// Default no-op typing reset.
    func stopTypingIndicator(accountID _: String?, peerID _: String) async throws {}

    /// Default: probing is not supported.
    func probe(timeoutMs _: Int) async -> ChannelProbeResult {
        .unsupported
    }

    /// Default logout stops the adapter.
    func logout() async throws {
        await self.stop()
    }
}

/// Optional adapter capability for channels that can push inbound messages.
public protocol InboundChannelAdapter: ChannelAdapter {
    /// Registers or clears the inbound message callback.
    /// - Parameter handler: Callback invoked when inbound messages are received.
    func setInboundHandler(_ handler: InboundMessageHandler?) async
}

/// High-level health states for channel delivery.
public enum ChannelHealthStatus: String, Sendable {
    /// Deliveries succeed.
    case healthy
    /// Recent deliveries failed but retries are in progress.
    case degraded
    /// Not started, or the last delivery failed terminally.
    case offline
}

/// Channel health snapshot emitted by delivery tracking.
public struct ChannelHealthSnapshot: Sendable, Equatable {
    /// Channel identifier.
    public let channelID: ChannelID
    /// Current health status.
    public let status: ChannelHealthStatus
    /// Consecutive send failures.
    public let consecutiveFailures: Int
    /// Last error detail.
    public let lastError: String?
    /// Last successful send.
    public let lastSuccessAt: Date?
    /// Last failed send.
    public let lastFailureAt: Date?

    /// Creates a channel health snapshot.
    /// - Parameters:
    ///   - channelID: Channel identifier.
    ///   - status: Current health status.
    ///   - consecutiveFailures: Consecutive send failures.
    ///   - lastError: Last error detail, if any.
    ///   - lastSuccessAt: Last successful send timestamp.
    ///   - lastFailureAt: Last failed send timestamp.
    public init(
        channelID: ChannelID,
        status: ChannelHealthStatus,
        consecutiveFailures: Int = 0,
        lastError: String? = nil,
        lastSuccessAt: Date? = nil,
        lastFailureAt: Date? = nil
    ) {
        self.channelID = channelID
        self.status = status
        self.consecutiveFailures = max(0, consecutiveFailures)
        self.lastError = lastError
        self.lastSuccessAt = lastSuccessAt
        self.lastFailureAt = lastFailureAt
    }
}

/// Retry/backoff controls for outbound channel sends.
public struct ChannelSendRetryPolicy: Sendable, Equatable {
    /// Maximum send attempts including the first try.
    public let maxAttempts: Int
    /// Backoff before the first retry.
    public let initialBackoffMs: Int
    /// Exponential backoff cap.
    public let maxBackoffMs: Int
    /// Exponential multiplier between retries.
    public let backoffMultiplier: Double

    /// Creates send retry policy values.
    /// - Parameters:
    ///   - maxAttempts: Maximum send attempts including first try.
    ///   - initialBackoffMs: Backoff delay before first retry.
    ///   - maxBackoffMs: Maximum exponential backoff cap.
    ///   - backoffMultiplier: Exponential multiplier between retries.
    public init(
        maxAttempts: Int = 3,
        initialBackoffMs: Int = 250,
        maxBackoffMs: Int = 5_000,
        backoffMultiplier: Double = 2.0
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.initialBackoffMs = max(1, initialBackoffMs)
        self.maxBackoffMs = max(1, maxBackoffMs)
        self.backoffMultiplier = max(1, backoffMultiplier)
    }
}

/// Outbound send throttling controls applied per channel.
public struct ChannelSendThrottlePolicy: Sendable, Equatable {
    /// Strategy used when send rate exceeds configured window.
    public enum Strategy: String, Sendable, Equatable {
        /// Wait until the window frees up.
        case delay
        /// Drop the send.
        case drop
    }

    /// Maximum sends per rolling window (0 disables throttling).
    public let maxSendsPerWindow: Int
    /// Rolling window in milliseconds.
    public let windowMs: Int
    /// Strategy when the limit is exceeded.
    public let strategy: Strategy

    /// Creates channel send throttle policy values.
    /// - Parameters:
    ///   - maxSendsPerWindow: Maximum sends allowed in one rolling window per channel.
    ///   - windowMs: Rolling window duration in milliseconds.
    ///   - strategy: Strategy applied when limit is exceeded.
    public init(
        maxSendsPerWindow: Int = 0,
        windowMs: Int = 1_000,
        strategy: Strategy = .delay
    ) {
        self.maxSendsPerWindow = max(0, maxSendsPerWindow)
        self.windowMs = max(1, windowMs)
        self.strategy = strategy
    }

    var isEnabled: Bool {
        self.maxSendsPerWindow > 0
    }
}

/// Result metadata for one outbound channel delivery attempt sequence.
public struct ChannelDeliveryOutcome: Sendable, Equatable {
    /// Channel that received the outbound message.
    public let channelID: ChannelID
    /// Number of send attempts made.
    public let attempts: Int
    /// Final channel health status after the send.
    public let status: ChannelHealthStatus
    /// Platform receipt, when the adapter returns one (``ReceiptingChannelAdapter``).
    public let receipt: ChannelSendReceipt?

    /// Creates a delivery outcome.
    /// - Parameters:
    ///   - channelID: Channel that received the outbound message.
    ///   - attempts: Number of send attempts made.
    ///   - status: Final channel health status after send.
    ///   - receipt: Platform receipt.
    public init(channelID: ChannelID, attempts: Int, status: ChannelHealthStatus, receipt: ChannelSendReceipt? = nil) {
        self.channelID = channelID
        self.attempts = max(1, attempts)
        self.status = status
        self.receipt = receipt
    }
}

/// Terminal outbound delivery error surfaced by channel registry retries.
public struct ChannelDeliveryFailure: Error, LocalizedError, CustomStringConvertible, Sendable {
    /// Channel identifier.
    public let channelID: ChannelID
    /// Attempts performed before failure.
    public let attempts: Int
    /// Final health status.
    public let status: ChannelHealthStatus
    /// Human-readable failure detail.
    public let detail: String
    /// Classification of the last failure.
    public let classification: ChannelSendError?

    /// Creates a channel delivery failure payload.
    /// - Parameters:
    ///   - channelID: Channel identifier.
    ///   - attempts: Attempts performed before failure.
    ///   - status: Final health status.
    ///   - detail: Human-readable failure detail.
    ///   - classification: Classification of the last failure.
    public init(
        channelID: ChannelID,
        attempts: Int,
        status: ChannelHealthStatus,
        detail: String,
        classification: ChannelSendError? = nil
    ) {
        self.channelID = channelID
        self.attempts = max(1, attempts)
        self.status = status
        self.detail = detail
        self.classification = classification
    }

    /// Localized description.
    public var errorDescription: String? {
        "Failed to deliver message via \(self.channelID.rawValue) after \(self.attempts) attempt(s): \(self.detail)"
    }

    /// Debug description.
    public var description: String {
        self.errorDescription ?? "Channel delivery failure"
    }
}

/// Registry-tracked lifecycle state of one channel adapter.
public struct ChannelRuntimeState: Sendable, Equatable {
    /// Whether the registry started the adapter (or it delivered successfully).
    public var running: Bool
    /// Last start time.
    public var lastStartAt: Date?
    /// Last stop time.
    public var lastStopAt: Date?
    /// Last inbound message time.
    public var lastInboundAt: Date?
    /// Last successful outbound time.
    public var lastOutboundAt: Date?
    /// Last start or delivery error.
    public var lastError: String?
    /// Last probe result.
    public var lastProbe: ChannelProbeResult?
    /// Why the adapter was not started (``ChannelConfigurationStatus/unconfigured(reason:)``).
    public var unconfiguredReason: String?

    /// Creates runtime state.
    /// - Parameters:
    ///   - running: Whether the adapter runs.
    ///   - lastStartAt: Last start time.
    ///   - lastStopAt: Last stop time.
    ///   - lastInboundAt: Last inbound time.
    ///   - lastOutboundAt: Last outbound time.
    ///   - lastError: Last error.
    ///   - lastProbe: Last probe result.
    ///   - unconfiguredReason: Why the adapter was not started.
    public init(
        running: Bool = false,
        lastStartAt: Date? = nil,
        lastStopAt: Date? = nil,
        lastInboundAt: Date? = nil,
        lastOutboundAt: Date? = nil,
        lastError: String? = nil,
        lastProbe: ChannelProbeResult? = nil,
        unconfiguredReason: String? = nil
    ) {
        self.running = running
        self.lastStartAt = lastStartAt
        self.lastStopAt = lastStopAt
        self.lastInboundAt = lastInboundAt
        self.lastOutboundAt = lastOutboundAt
        self.lastError = lastError
        self.lastProbe = lastProbe
        self.unconfiguredReason = unconfiguredReason
    }
}

/// Registry that tracks channel adapters and dispatches outbound sends.
///
/// Sends are retried only when the failure is safe to retry (``ChannelSendError/isRetryable``):
/// sends with an unknown outcome (timeouts, dropped connections) are never retried blindly,
/// which prevents duplicate messages; adapters conforming to ``UnknownSendReconciling`` can
/// resolve them. `Retry-After` delays (capped at 60 s) are honored.
public actor ChannelRegistry {
    private var adapters: [ChannelID: any ChannelAdapter] = [:]
    private var sentMessages: [OutboundMessage] = []
    private var healthSnapshots: [ChannelID: ChannelHealthSnapshot] = [:]
    private var runtimeStates: [ChannelID: ChannelRuntimeState] = [:]
    private let sendRetryPolicy: ChannelSendRetryPolicy
    private let sendThrottlePolicy: ChannelSendThrottlePolicy
    private let diagnosticsSink: RuntimeDiagnosticSink?
    private var sendTimestampsByChannel: [ChannelID: [Date]] = [:]

    /// Creates an empty channel registry with default retry policy.
    public init() {
        self.sendRetryPolicy = ChannelSendRetryPolicy()
        self.sendThrottlePolicy = ChannelSendThrottlePolicy()
        self.diagnosticsSink = nil
    }

    /// Creates a channel registry with an explicit retry policy.
    /// - Parameter sendRetryPolicy: Retry policy for outbound delivery failures.
    public init(sendRetryPolicy: ChannelSendRetryPolicy) {
        self.sendRetryPolicy = sendRetryPolicy
        self.sendThrottlePolicy = ChannelSendThrottlePolicy()
        self.diagnosticsSink = nil
    }

    /// Creates a channel registry with explicit retry and throttle policies.
    /// - Parameters:
    ///   - sendRetryPolicy: Retry policy for outbound delivery failures.
    ///   - sendThrottlePolicy: Per-channel throttling controls.
    ///   - diagnosticsSink: Optional diagnostics sink for retry/throttle events.
    public init(
        sendRetryPolicy: ChannelSendRetryPolicy,
        sendThrottlePolicy: ChannelSendThrottlePolicy,
        diagnosticsSink: RuntimeDiagnosticSink? = nil
    ) {
        self.sendRetryPolicy = sendRetryPolicy
        self.sendThrottlePolicy = sendThrottlePolicy
        self.diagnosticsSink = diagnosticsSink
    }

    /// Registers (or replaces) a channel adapter.
    /// - Parameter adapter: Adapter implementation.
    public func register(_ adapter: any ChannelAdapter) {
        self.adapters[adapter.id] = adapter
        if self.healthSnapshots[adapter.id] == nil {
            self.healthSnapshots[adapter.id] = ChannelHealthSnapshot(
                channelID: adapter.id,
                status: .offline
            )
        }
        if self.runtimeStates[adapter.id] == nil {
            self.runtimeStates[adapter.id] = ChannelRuntimeState()
        }
    }

    /// Returns whether an adapter exists for an ID.
    /// - Parameter id: Channel identifier.
    /// - Returns: `true` when adapter is registered.
    public func hasAdapter(id: ChannelID) -> Bool {
        self.adapters[id] != nil
    }

    /// Lists registered channel IDs in sorted order.
    /// - Returns: Sorted adapter channel IDs.
    public func adapterIDs() -> [ChannelID] {
        self.adapters.keys.sorted { $0.rawValue < $1.rawValue }
    }

    /// Returns the adapter for a channel ID, if present.
    /// - Parameter id: Channel identifier.
    /// - Returns: Matching adapter or `nil`.
    public func adapter(for id: ChannelID) -> (any ChannelAdapter)? {
        self.adapters[id]
    }

    // MARK: Lifecycle

    /// Starts one registered adapter and records its runtime state.
    ///
    /// Adapters conforming to ``ChannelConfigurationReporting`` that report
    /// ``ChannelConfigurationStatus/unconfigured(reason:)`` are not started and do not throw: the
    /// reason is recorded in ``ChannelRuntimeState/unconfiguredReason`` (upstream `unconfigured`).
    /// - Parameter id: Channel identifier.
    /// - Throws: `OpenClawCoreError.unavailable` when no adapter is registered, or the start error.
    public func start(id: ChannelID) async throws {
        guard let adapter = self.adapters[id] else {
            throw OpenClawCoreError.unavailable("No adapter registered for \(id.rawValue)")
        }
        var state = self.runtimeStates[id] ?? ChannelRuntimeState()
        state.lastStartAt = Date()
        if let reporting = adapter as? any ChannelConfigurationReporting,
           case .unconfigured(let reason) = reporting.configurationStatus
        {
            state.running = false
            state.unconfiguredReason = reason
            state.lastError = reason
            self.runtimeStates[id] = state
            await self.emitDiagnostic(name: "channel.unconfigured", metadata: ["channel": id.rawValue, "reason": reason])
            return
        }
        state.unconfiguredReason = nil
        do {
            try await adapter.start()
            state.running = true
            state.lastError = nil
            self.runtimeStates[id] = state
            await self.emitDiagnostic(name: "channel.started", metadata: ["channel": id.rawValue])
        } catch {
            state.running = false
            state.lastError = ChannelErrorText.describe(error)
            self.runtimeStates[id] = state
            await self.emitDiagnostic(name: "channel.start_failed", metadata: ["channel": id.rawValue])
            throw error
        }
    }

    /// Stops one registered adapter.
    /// - Parameter id: Channel identifier.
    /// - Throws: `OpenClawCoreError.unavailable` when no adapter is registered.
    public func stop(id: ChannelID) async throws {
        guard let adapter = self.adapters[id] else {
            throw OpenClawCoreError.unavailable("No adapter registered for \(id.rawValue)")
        }
        await adapter.stop()
        self.markStopped(id)
        await self.emitDiagnostic(name: "channel.stopped", metadata: ["channel": id.rawValue])
    }

    /// Logs one adapter out (``ChannelAdapter/logout()``) and marks it stopped.
    /// - Parameter id: Channel identifier.
    /// - Throws: `OpenClawCoreError.unavailable` when no adapter is registered, or the logout error.
    public func logout(id: ChannelID) async throws {
        guard let adapter = self.adapters[id] else {
            throw OpenClawCoreError.unavailable("No adapter registered for \(id.rawValue)")
        }
        try await adapter.logout()
        self.markStopped(id)
        await self.emitDiagnostic(name: "channel.logged_out", metadata: ["channel": id.rawValue])
    }

    /// Starts every registered adapter, collecting failures instead of throwing.
    /// - Returns: Start errors keyed by channel.
    @discardableResult
    public func startAll() async -> [ChannelID: String] {
        var failures: [ChannelID: String] = [:]
        for id in self.adapterIDs() {
            do {
                try await self.start(id: id)
            } catch {
                failures[id] = ChannelErrorText.describe(error)
            }
        }
        return failures
    }

    /// Stops every registered adapter.
    public func stopAll() async {
        for id in self.adapterIDs() {
            try? await self.stop(id: id)
        }
    }

    /// Probes one adapter and records the result.
    /// - Parameters:
    ///   - id: Channel identifier.
    ///   - timeoutMs: Probe timeout.
    /// - Returns: Probe result (unsupported when no adapter is registered).
    public func probe(id: ChannelID, timeoutMs: Int = 10_000) async -> ChannelProbeResult {
        guard let adapter = self.adapters[id] else {
            return ChannelProbeResult(ok: false, supported: false, detail: "no adapter registered")
        }
        var result = await adapter.probe(timeoutMs: timeoutMs)
        result.detail = result.detail.map(ChannelErrorText.redact)
        var state = self.runtimeStates[id] ?? ChannelRuntimeState()
        state.lastProbe = result
        self.runtimeStates[id] = state
        return result
    }

    /// Records an inbound message for status reporting.
    /// - Parameter id: Channel identifier.
    public func recordInbound(channel id: ChannelID) {
        var state = self.runtimeStates[id] ?? ChannelRuntimeState()
        state.lastInboundAt = Date()
        self.runtimeStates[id] = state
    }

    /// Returns tracked runtime state for a channel.
    /// - Parameter id: Channel identifier.
    /// - Returns: Runtime state (`running` also reflects successful deliveries).
    public func runtimeState(for id: ChannelID) -> ChannelRuntimeState {
        var state = self.runtimeStates[id] ?? ChannelRuntimeState()
        if !state.running, state.lastStopAt == nil, let health = self.healthSnapshots[id], health.status != .offline {
            state.running = true
        }
        return state
    }

    // MARK: Sending

    /// Sends an outbound message using the registered adapter.
    /// - Parameter message: Outbound message.
    /// - Returns: Delivery outcome metadata including attempts, final channel status and receipt.
    /// - Throws: ``ChannelDeliveryFailure`` after the last attempt, or `OpenClawCoreError.unavailable`
    ///   when no adapter is registered.
    @discardableResult
    public func send(_ message: OutboundMessage) async throws -> ChannelDeliveryOutcome {
        guard let adapter = self.adapters[message.channel] else {
            throw OpenClawCoreError.unavailable("No adapter registered for \(message.channel.rawValue)")
        }

        do {
            try await self.applyThrottleIfNeeded(channelID: message.channel)
        } catch {
            self.recordSendFailure(channelID: message.channel, error: error, terminal: true)
            throw error
        }

        let maxAttempts = self.sendRetryPolicy.maxAttempts
        var backoffMs = self.sendRetryPolicy.initialBackoffMs
        var attempts = 0
        var lastError: Error?
        var lastClassification: ChannelSendError?

        for attempt in 1...maxAttempts {
            attempts = attempt
            let attemptStartedAt = Date()
            do {
                let receipt = try await Self.deliver(message, via: adapter)
                return self.recordDelivered(message, attempts: attempt, receipt: receipt)
            } catch {
                if error is CancellationError {
                    self.recordSendFailure(channelID: message.channel, error: error, terminal: true)
                    throw error
                }
                var classification = ChannelSendError.classify(error)
                if case .unknownOutcome = classification, let reconciler = adapter as? any UnknownSendReconciling {
                    switch await reconciler.reconcile(message, attemptStartedAt: attemptStartedAt) {
                    case .sent(let receipt):
                        await self.emitDiagnostic(
                            name: "channel.delivery.reconciled",
                            metadata: ["channel": message.channel.rawValue, "result": "sent"]
                        )
                        return self.recordDelivered(message, attempts: attempt, receipt: receipt)
                    case .notSent:
                        classification = .notSent(underlying: classification.errorDescription ?? "reconciled as not sent")
                    case .unresolved:
                        break
                    }
                }
                lastError = error
                lastClassification = classification
                let terminal = !classification.isRetryable || attempt >= maxAttempts
                self.recordSendFailure(channelID: message.channel, error: error, terminal: terminal)
                if terminal {
                    if case .unknownOutcome = classification {
                        await self.emitDiagnostic(
                            name: "channel.delivery.unknown_outcome",
                            metadata: ["channel": message.channel.rawValue, "attempt": String(attempt)]
                        )
                    }
                    break
                }
                let delayMs = await self.retryDelay(
                    backoffMs: backoffMs,
                    classification: classification,
                    channel: message.channel,
                    attempt: attempt
                )
                await self.emitDiagnostic(
                    name: "channel.delivery.retry",
                    metadata: [
                        "channel": message.channel.rawValue,
                        "attempt": String(attempt),
                        "nextAttempt": String(attempt + 1),
                        "backoffMs": String(delayMs),
                        "error": ChannelErrorText.describe(error),
                    ]
                )
                await ChannelAsync.sleep(milliseconds: max(1, delayMs))
                let grown = Int(Double(backoffMs) * self.sendRetryPolicy.backoffMultiplier)
                backoffMs = min(self.sendRetryPolicy.maxBackoffMs, max(1, grown))
            }
        }

        let failureSnapshot = self.healthSnapshots[message.channel] ?? ChannelHealthSnapshot(
            channelID: message.channel,
            status: .offline
        )
        throw ChannelDeliveryFailure(
            channelID: message.channel,
            attempts: attempts,
            status: failureSnapshot.status,
            detail: self.mapDeliveryError(error: lastError),
            classification: lastClassification
        )
    }

    /// Returns outbound message history captured by registry dispatches.
    public func outboundHistory() -> [OutboundMessage] {
        self.sentMessages
    }

    /// Returns tracked health snapshot for a channel.
    /// - Parameter id: Channel identifier.
    /// - Returns: Channel health snapshot.
    public func healthSnapshot(for id: ChannelID) -> ChannelHealthSnapshot {
        self.healthSnapshots[id] ?? ChannelHealthSnapshot(channelID: id, status: .offline)
    }

    /// Returns all known channel health snapshots sorted by channel ID.
    public func allHealthSnapshots() -> [ChannelHealthSnapshot] {
        self.healthSnapshots.values.sorted { $0.channelID.rawValue < $1.channelID.rawValue }
    }

    /// Returns retry policy used for channel delivery attempts.
    public func retryPolicy() -> ChannelSendRetryPolicy {
        self.sendRetryPolicy
    }

    /// Returns throttle policy used for channel delivery attempts.
    public func throttlePolicy() -> ChannelSendThrottlePolicy {
        self.sendThrottlePolicy
    }

    private static func deliver(_ message: OutboundMessage, via adapter: any ChannelAdapter) async throws -> ChannelSendReceipt? {
        if let receipting = adapter as? any ReceiptingChannelAdapter {
            return try await receipting.sendReturningReceipt(message)
        }
        try await adapter.send(message)
        return nil
    }

    private func retryDelay(
        backoffMs: Int,
        classification: ChannelSendError,
        channel: ChannelID,
        attempt: Int
    ) async -> Int {
        var delayMs = backoffMs
        if let retryAfterMs = classification.retryAfterMs {
            delayMs = max(delayMs, retryAfterMs)
        }
        if case .rateLimited = classification {
            var metadata = ["channel": channel.rawValue, "attempt": String(attempt)]
            metadata["retryAfterMs"] = classification.retryAfterMs.map(String.init)
            await self.emitDiagnostic(name: "channel.delivery.rate_limited", metadata: metadata)
        } else if let retryAfterMs = classification.retryAfterMs {
            await self.emitDiagnostic(
                name: "channel.delivery.rate_limited",
                metadata: ["channel": channel.rawValue, "attempt": String(attempt), "retryAfterMs": String(retryAfterMs)]
            )
        }
        return delayMs
    }

    private func markStopped(_ id: ChannelID) {
        var state = self.runtimeStates[id] ?? ChannelRuntimeState()
        state.running = false
        state.lastStopAt = Date()
        self.runtimeStates[id] = state
        let previous = self.healthSnapshots[id]
        self.healthSnapshots[id] = ChannelHealthSnapshot(
            channelID: id,
            status: .offline,
            consecutiveFailures: previous?.consecutiveFailures ?? 0,
            lastError: previous?.lastError,
            lastSuccessAt: previous?.lastSuccessAt,
            lastFailureAt: previous?.lastFailureAt
        )
    }

    private func recordDelivered(_ message: OutboundMessage, attempts: Int, receipt: ChannelSendReceipt?) -> ChannelDeliveryOutcome {
        self.sentMessages.append(message)
        let snapshot = self.recordSendSuccess(channelID: message.channel)
        var state = self.runtimeStates[message.channel] ?? ChannelRuntimeState()
        state.lastOutboundAt = Date()
        self.runtimeStates[message.channel] = state
        return ChannelDeliveryOutcome(
            channelID: message.channel,
            attempts: attempts,
            status: snapshot.status,
            receipt: receipt
        )
    }

    private func recordSendSuccess(channelID: ChannelID) -> ChannelHealthSnapshot {
        let previous = self.healthSnapshots[channelID] ?? ChannelHealthSnapshot(channelID: channelID, status: .offline)
        let snapshot = ChannelHealthSnapshot(
            channelID: channelID,
            status: .healthy,
            consecutiveFailures: 0,
            lastError: nil,
            lastSuccessAt: Date(),
            lastFailureAt: previous.lastFailureAt
        )
        self.healthSnapshots[channelID] = snapshot
        return snapshot
    }

    private func applyThrottleIfNeeded(channelID: ChannelID) async throws {
        guard self.sendThrottlePolicy.isEnabled else {
            return
        }
        let now = Date()
        let windowStart = now.addingTimeInterval(-Double(self.sendThrottlePolicy.windowMs) / 1000.0)
        var timestamps = (self.sendTimestampsByChannel[channelID] ?? []).filter { $0 >= windowStart }

        if timestamps.count < self.sendThrottlePolicy.maxSendsPerWindow {
            timestamps.append(now)
            self.sendTimestampsByChannel[channelID] = timestamps
            return
        }

        switch self.sendThrottlePolicy.strategy {
        case .drop:
            await self.emitDiagnostic(
                name: "channel.throttle.drop",
                metadata: [
                    "channel": channelID.rawValue,
                    "windowMs": String(self.sendThrottlePolicy.windowMs),
                    "maxSendsPerWindow": String(self.sendThrottlePolicy.maxSendsPerWindow),
                ]
            )
            throw ChannelDeliveryFailure(
                channelID: channelID,
                attempts: 1,
                status: .degraded,
                detail: "Throttled by channel send policy"
            )
        case .delay:
            let earliest = timestamps.first ?? now
            let releaseAt = earliest.addingTimeInterval(Double(self.sendThrottlePolicy.windowMs) / 1000.0)
            let delayMs = max(1, Int(releaseAt.timeIntervalSince(now) * 1000))
            await self.emitDiagnostic(
                name: "channel.throttle.delay",
                metadata: [
                    "channel": channelID.rawValue,
                    "delayMs": String(delayMs),
                    "windowMs": String(self.sendThrottlePolicy.windowMs),
                    "maxSendsPerWindow": String(self.sendThrottlePolicy.maxSendsPerWindow),
                ]
            )
            let sleepNs = UInt64(delayMs) * 1_000_000
            try await Task.sleep(nanoseconds: sleepNs)

            let afterDelay = Date()
            let delayedWindowStart = afterDelay.addingTimeInterval(-Double(self.sendThrottlePolicy.windowMs) / 1000.0)
            timestamps = (self.sendTimestampsByChannel[channelID] ?? []).filter { $0 >= delayedWindowStart }
            timestamps.append(afterDelay)
            self.sendTimestampsByChannel[channelID] = timestamps
        }
    }

    private func recordSendFailure(channelID: ChannelID, error: Error, terminal: Bool) {
        let previous = self.healthSnapshots[channelID] ?? ChannelHealthSnapshot(channelID: channelID, status: .offline)
        let failureCount = previous.consecutiveFailures + 1
        let errorDetail = ChannelErrorText.describe(error)
        self.healthSnapshots[channelID] = ChannelHealthSnapshot(
            channelID: channelID,
            status: terminal ? .offline : .degraded,
            consecutiveFailures: failureCount,
            lastError: errorDetail,
            lastSuccessAt: previous.lastSuccessAt,
            lastFailureAt: Date()
        )
        var state = self.runtimeStates[channelID] ?? ChannelRuntimeState()
        state.lastError = errorDetail
        self.runtimeStates[channelID] = state
    }

    private func mapDeliveryError(error: Error?) -> String {
        ChannelErrorText.describe(error ?? OpenClawCoreError.unavailable("unknown"))
    }

    private func emitDiagnostic(name: String, metadata: [String: String]) async {
        guard let diagnosticsSink else { return }
        await diagnosticsSink(
            RuntimeDiagnosticEvent(
                subsystem: "channel",
                name: name,
                metadata: metadata
            )
        )
    }
}

/// Lightweight in-memory adapter used for tests and local demos.
public actor InMemoryChannelAdapter: ChannelAdapter {
    /// Adapter channel identifier.
    public let id: ChannelID
    private(set) var started = false
    private var sent: [OutboundMessage] = []

    /// Creates an in-memory adapter bound to a channel ID.
    /// - Parameter id: Adapter channel identifier.
    public init(id: ChannelID) {
        self.id = id
    }

    /// Marks adapter as started.
    public func start() async throws {
        self.started = true
    }

    /// Marks adapter as stopped.
    public func stop() async {
        self.started = false
    }

    /// Captures an outbound message while started.
    /// - Parameter message: Outbound payload.
    public func send(_ message: OutboundMessage) async throws {
        guard self.started else {
            throw OpenClawCoreError.unavailable("Adapter \(self.id.rawValue) is not started")
        }
        self.sent.append(message)
    }

    /// Returns outbound messages captured by this adapter.
    public func sentMessages() -> [OutboundMessage] {
        self.sent
    }
}
