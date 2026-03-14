import Foundation
import OpenClawAgents
import OpenClawCore
import OpenClawMemory
import OpenClawProtocol
import OpenClawSkills

/// Stable channel identifiers supported by channel adapters.
public enum ChannelID: String, CaseIterable, Sendable {
    case whatsapp
    case telegram
    case slack
    case googlechat
    case discord
    case signal
    case bluebubbles
    case imessage
    case msteams
    case line
    case webchat
}

/// Normalized inbound message envelope delivered to the runtime.
public struct InboundMessage: Sendable, Equatable {
    public let channel: ChannelID
    public let accountID: String?
    public let peerID: String
    public let text: String
    public let attachments: [MediaAttachment]

    /// Creates an inbound message envelope.
    /// - Parameters:
    ///   - channel: Source channel identifier.
    ///   - accountID: Optional account/user identifier.
    ///   - peerID: Conversation peer/channel identifier.
    ///   - text: Message content.
    ///   - attachments: Optional multimodal attachments.
    public init(
        channel: ChannelID,
        accountID: String? = nil,
        peerID: String,
        text: String,
        attachments: [MediaAttachment] = []
    ) {
        self.channel = channel
        self.accountID = accountID
        self.peerID = peerID
        self.text = text
        self.attachments = attachments
    }
}

/// Normalized outbound message envelope sent through adapters.
public struct OutboundMessage: Sendable, Equatable {
    public let channel: ChannelID
    public let accountID: String?
    public let peerID: String
    public let text: String
    public let attachments: [MediaAttachment]

    /// Creates an outbound message envelope.
    /// - Parameters:
    ///   - channel: Destination channel identifier.
    ///   - accountID: Optional account/user identifier.
    ///   - peerID: Conversation peer/channel identifier.
    ///   - text: Message content.
    ///   - attachments: Optional multimodal attachments.
    public init(
        channel: ChannelID,
        accountID: String? = nil,
        peerID: String,
        text: String,
        attachments: [MediaAttachment] = []
    ) {
        self.channel = channel
        self.accountID = accountID
        self.peerID = peerID
        self.text = text
        self.attachments = attachments
    }
}

/// Async callback invoked for adapter-delivered inbound messages.
public typealias InboundMessageHandler = @Sendable (InboundMessage) async -> Void

/// Pluggable channel transport abstraction.
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
    ///   - accountID: Optional account/user identifier.
    ///   - peerID: Conversation peer/channel identifier.
    func sendTypingIndicator(accountID: String?, peerID: String) async throws
}

public extension ChannelAdapter {
    /// Default no-op typing indicator implementation for channels without typing support.
    func sendTypingIndicator(accountID _: String?, peerID _: String) async throws {}
}

/// Optional adapter capability for channels that can push inbound messages.
public protocol InboundChannelAdapter: ChannelAdapter {
    /// Registers or clears the inbound message callback.
    /// - Parameter handler: Callback invoked when inbound messages are received.
    func setInboundHandler(_ handler: InboundMessageHandler?) async
}

/// High-level health states for channel delivery.
public enum ChannelHealthStatus: String, Sendable {
    case healthy
    case degraded
    case offline
}

/// Channel health snapshot emitted by delivery tracking.
public struct ChannelHealthSnapshot: Sendable, Equatable {
    public let channelID: ChannelID
    public let status: ChannelHealthStatus
    public let consecutiveFailures: Int
    public let lastError: String?
    public let lastSuccessAt: Date?
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
    public let maxAttempts: Int
    public let initialBackoffMs: Int
    public let maxBackoffMs: Int
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
        case delay
        case drop
    }

    public let maxSendsPerWindow: Int
    public let windowMs: Int
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
    public let channelID: ChannelID
    public let attempts: Int
    public let status: ChannelHealthStatus

    /// Creates a delivery outcome.
    /// - Parameters:
    ///   - channelID: Channel that received the outbound message.
    ///   - attempts: Number of send attempts made.
    ///   - status: Final channel health status after send.
    public init(channelID: ChannelID, attempts: Int, status: ChannelHealthStatus) {
        self.channelID = channelID
        self.attempts = max(1, attempts)
        self.status = status
    }
}

/// Terminal outbound delivery error surfaced by channel registry retries.
public struct ChannelDeliveryFailure: Error, LocalizedError, CustomStringConvertible, Sendable {
    public let channelID: ChannelID
    public let attempts: Int
    public let status: ChannelHealthStatus
    public let detail: String

    /// Creates a channel delivery failure payload.
    /// - Parameters:
    ///   - channelID: Channel identifier.
    ///   - attempts: Attempts performed before failure.
    ///   - status: Final health status.
    ///   - detail: Human-readable failure detail.
    public init(channelID: ChannelID, attempts: Int, status: ChannelHealthStatus, detail: String) {
        self.channelID = channelID
        self.attempts = max(1, attempts)
        self.status = status
        self.detail = detail
    }

    public var errorDescription: String? {
        "Failed to deliver message via \(self.channelID.rawValue) after \(self.attempts) attempt(s): \(self.detail)"
    }

    public var description: String {
        self.errorDescription ?? "Channel delivery failure"
    }
}

/// Registry that tracks channel adapters and dispatches outbound sends.
public actor ChannelRegistry {
    private var adapters: [ChannelID: any ChannelAdapter] = [:]
    private var sentMessages: [OutboundMessage] = []
    private var healthSnapshots: [ChannelID: ChannelHealthSnapshot] = [:]
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

    /// Sends an outbound message using the registered adapter.
    /// - Parameter message: Outbound message.
    /// - Returns: Delivery outcome metadata including attempts and final channel status.
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

        for attempt in 1...maxAttempts {
            attempts = attempt
            do {
                try await adapter.send(message)
                self.sentMessages.append(message)
                let snapshot = self.recordSendSuccess(channelID: message.channel)
                return ChannelDeliveryOutcome(
                    channelID: message.channel,
                    attempts: attempt,
                    status: snapshot.status
                )
            } catch {
                lastError = error
                let retryable = self.isRetryable(error)
                let terminal = !retryable || attempt >= maxAttempts
                self.recordSendFailure(channelID: message.channel, error: error, terminal: terminal)
                if terminal {
                    break
                }
                await self.emitDiagnostic(
                    name: "channel.delivery.retry",
                    metadata: [
                        "channel": message.channel.rawValue,
                        "attempt": String(attempt),
                        "nextAttempt": String(attempt + 1),
                        "backoffMs": String(backoffMs),
                        "error": String(describing: error),
                    ]
                )
                let sleepNs = UInt64(max(1, backoffMs)) * 1_000_000
                try? await Task.sleep(nanoseconds: sleepNs)
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
            detail: self.mapDeliveryError(error: lastError)
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
        let errorDetail = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        self.healthSnapshots[channelID] = ChannelHealthSnapshot(
            channelID: channelID,
            status: terminal ? .offline : .degraded,
            consecutiveFailures: failureCount,
            lastError: errorDetail,
            lastSuccessAt: previous.lastSuccessAt,
            lastFailureAt: Date()
        )
    }

    private func isRetryable(_ error: Error) -> Bool {
        if let core = error as? OpenClawCoreError {
            switch core {
            case .invalidConfiguration:
                return false
            case .unavailable:
                return true
            }
        }
        return true
    }

    private func mapDeliveryError(error: Error?) -> String {
        let detail = (error as? LocalizedError)?.errorDescription ?? String(describing: error ?? OpenClawCoreError.unavailable("unknown"))
        return detail
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

/// End-to-end auto-reply pipeline coordinating routing, runtime, and outbound delivery.
public actor AutoReplyEngine {
    private let config: OpenClawConfig
    private let sessionStore: SessionStore
    private let channelRegistry: ChannelRegistry
    private let runtime: EmbeddedAgentRuntime
    private let conversationMemoryStore: ConversationMemoryStore?
    private let memoryContextLimit: Int
    private let typingHeartbeatIntervalMs: Int
    private let diagnosticsSink: RuntimeDiagnosticSink?
    private static let typingHeartbeatChannels: Set<ChannelID> = [.discord, .telegram]

    /// Creates an auto-reply engine.
    /// - Parameters:
    ///   - config: Runtime configuration.
    ///   - sessionStore: Session storage actor.
    ///   - channelRegistry: Adapter registry for outbound dispatch.
    ///   - runtime: Embedded runtime to execute prompts/tools.
    ///   - conversationMemoryStore: Optional persistent conversation memory store.
    ///   - memoryContextLimit: Number of turns included in prompt context.
    ///   - typingHeartbeatIntervalMs: Typing heartbeat cadence for supported channels.
    public init(
        config: OpenClawConfig,
        sessionStore: SessionStore,
        channelRegistry: ChannelRegistry,
        runtime: EmbeddedAgentRuntime,
        conversationMemoryStore: ConversationMemoryStore? = nil,
        memoryContextLimit: Int = 12,
        typingHeartbeatIntervalMs: Int = 4_000,
        diagnosticsSink: RuntimeDiagnosticSink? = nil
    ) {
        self.config = config
        self.sessionStore = sessionStore
        self.channelRegistry = channelRegistry
        self.runtime = runtime
        self.conversationMemoryStore = conversationMemoryStore
        self.memoryContextLimit = max(1, memoryContextLimit)
        self.typingHeartbeatIntervalMs = max(1, typingHeartbeatIntervalMs)
        self.diagnosticsSink = diagnosticsSink
    }

    /// Processes an inbound message and returns the outbound response.
    /// - Parameter message: Inbound message envelope.
    /// - Returns: Outbound message delivered through channel registry.
    public func process(_ message: InboundMessage) async throws -> OutboundMessage {
        await self.emitDiagnostic(
            name: "inbound.received",
            sessionKey: nil,
            metadata: [
                "channel": message.channel.rawValue,
                "accountID": message.accountID ?? "",
                "peerID": message.peerID,
                "attachmentCount": String(message.attachments.count),
            ]
        )
        let routingContext = SessionRoutingContext(
            channel: message.channel.rawValue,
            accountID: message.accountID,
            peerID: message.peerID
        )
        let sessionKey = SessionKeyResolver.resolve(
            explicit: nil,
            context: routingContext,
            config: self.config
        )
        let resolvedAgentID = self.config.agents.resolvedAgentID(for: routingContext)
        let sessionRecord = await self.sessionStore.resolveOrCreate(
            sessionKey: sessionKey,
            defaultAgentID: resolvedAgentID,
            route: SessionRoute(
                channel: message.channel.rawValue,
                accountID: message.accountID,
                peerID: message.peerID
            ),
            defaults: self.config.agents
        )
        let resolvedSession = sessionRecord.resolved(using: self.config.agents)
        await self.emitDiagnostic(
            name: "routing.session_resolved",
            sessionKey: sessionKey,
            metadata: [
                "agentID": resolvedSession.agentID,
                "channel": message.channel.rawValue,
                "modelOverride": resolvedSession.modelOverride ?? "",
            ]
        )
        try await self.sessionStore.save()

        if let commandReply = await self.handleCommandIfRequested(message, sessionKey: sessionKey) {
            await self.emitDiagnostic(
                name: "command.handled",
                sessionKey: sessionKey,
                metadata: [
                    "channel": commandReply.channel.rawValue,
                    "peerID": commandReply.peerID,
                ]
            )
            try await self.channelRegistry.send(commandReply)
            return commandReply
        }

        let typingHeartbeatTask = await self.startTypingHeartbeat(for: message, sessionKey: sessionKey)
        defer {
            typingHeartbeatTask?.cancel()
            if typingHeartbeatTask != nil {
                Task {
                    await self.emitDiagnostic(
                        name: "typing.heartbeat.stopped",
                        sessionKey: sessionKey,
                        metadata: ["channel": message.channel.rawValue]
                    )
                }
            }
        }

        let memoryContext = await self.conversationMemoryStore?.formattedContext(
            sessionKey: sessionKey,
            limit: self.memoryContextLimit
        ) ?? ""
        await self.emitDiagnostic(
            name: "memory.context_loaded",
            sessionKey: sessionKey,
            metadata: ["contextLength": String(memoryContext.count)]
        )
        if let store = self.conversationMemoryStore {
            await store.appendUserTurn(
                sessionKey: sessionKey,
                channel: message.channel.rawValue,
                accountID: message.accountID,
                peerID: message.peerID,
                text: message.text
            )
            try await store.save()
        }
        let skillOutput = try await self.invokeSkillIfRequested(message.text)
        if let skillOutput {
            var metadata: [String: String] = [
                "skillName": skillOutput.skillName,
                "outputLength": String(skillOutput.output.count),
            ]
            if let executorID = skillOutput.executorID {
                metadata["executorID"] = executorID
            }
            if let durationMs = skillOutput.durationMs {
                metadata["durationMs"] = String(durationMs)
            }
            await self.emitDiagnostic(
                name: "skill.invoked",
                sessionKey: sessionKey,
                metadata: metadata
            )
        }
        let runtimePrompt = Self.composeRuntimePrompt(
            memoryContext: memoryContext,
            inboundText: message.text,
            skillOutput: skillOutput
        )
        await self.emitDiagnostic(
            name: "model.call.started",
            sessionKey: sessionKey,
            metadata: [
                "providerID": self.config.models.defaultProviderID,
                "attachmentCount": String(message.attachments.count),
            ]
        )
        let runtimeRequest = AgentRunRequest(
            sessionKey: sessionKey,
            prompt: runtimePrompt,
            modelProviderID: resolvedSession.providerOverrideID,
            modelID: resolvedSession.modelOverrideID,
            thinkingLevel: resolvedSession.thinkingLevel,
            reasoningLevel: resolvedSession.reasoningLevel,
            verboseLevel: resolvedSession.verboseLevel,
            responseUsage: resolvedSession.responseUsage,
            elevatedLevel: resolvedSession.elevatedLevel,
            fastMode: sessionRecord.fastMode,
            workspaceRootPath: self.config.agents.workspaceRoot,
            attachments: message.attachments
        )
        let runtimeOutput: String
        if self.shouldUseStreamingRuntime() {
            runtimeOutput = try await self.collectStreamingRuntimeOutput(
                request: runtimeRequest,
                sessionKey: sessionKey
            )
        } else {
            let result = try await self.runtime.run(runtimeRequest)
            runtimeOutput = result.output
        }

        let outbound = OutboundMessage(
            channel: message.channel,
            accountID: message.accountID,
            peerID: message.peerID,
            text: runtimeOutput
        )
        await self.emitDiagnostic(
            name: "runtime.completed",
            sessionKey: sessionKey,
            metadata: ["outputLength": String(runtimeOutput.count)]
        )
        await self.emitDiagnostic(
            name: "model.call.completed",
            sessionKey: sessionKey,
            metadata: ["outputLength": String(runtimeOutput.count)]
        )
        if let store = self.conversationMemoryStore {
            await store.appendAssistantTurn(
                sessionKey: sessionKey,
                channel: outbound.channel.rawValue,
                accountID: outbound.accountID,
                peerID: outbound.peerID,
                text: outbound.text
            )
            try await store.save()
        }
        await self.emitDiagnostic(
            name: "outbound.dispatching",
            sessionKey: sessionKey,
            metadata: [
                "channel": outbound.channel.rawValue,
                "peerID": outbound.peerID,
            ]
        )
        do {
            let delivery = try await self.channelRegistry.send(outbound)
            await self.emitDiagnostic(
                name: "outbound.sent",
                sessionKey: sessionKey,
                metadata: [
                    "channel": outbound.channel.rawValue,
                    "peerID": outbound.peerID,
                    "attempts": String(delivery.attempts),
                    "status": delivery.status.rawValue,
                ]
            )
            return outbound
        } catch {
            let attempts: String
            let status: String
            if let deliveryError = error as? ChannelDeliveryFailure {
                attempts = String(deliveryError.attempts)
                status = deliveryError.status.rawValue
            } else {
                let snapshot = await self.channelRegistry.healthSnapshot(for: outbound.channel)
                attempts = String(max(1, snapshot.consecutiveFailures))
                status = snapshot.status.rawValue
            }
            await self.emitDiagnostic(
                name: "outbound.failed",
                sessionKey: sessionKey,
                metadata: [
                    "channel": outbound.channel.rawValue,
                    "peerID": outbound.peerID,
                    "attempts": attempts,
                    "status": status,
                    "error": String(describing: error),
                ]
            )
            throw error
        }
    }

    private static func composeRuntimePrompt(
        memoryContext: String,
        inboundText: String,
        skillOutput: SkillInvocationResult?
    ) -> String {
        let context = memoryContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let skillText = skillOutput?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if context.isEmpty && skillText.isEmpty {
            return inboundText
        }

        var sections: [String] = []
        if !context.isEmpty {
            sections.append(context)
        }
        if let skillOutput, !skillText.isEmpty {
            sections.append("## Skill Output (\(skillOutput.skillName))\n\(skillText)")
        }
        sections.append("## New User Message\n\(inboundText)")
        return sections.joined(separator: "\n\n")
    }

    private func startTypingHeartbeat(
        for message: InboundMessage,
        sessionKey: String
    ) async -> Task<Void, Never>? {
        guard Self.typingHeartbeatChannels.contains(message.channel) else {
            return nil
        }
        guard let adapter = await self.channelRegistry.adapter(for: message.channel) else {
            return nil
        }

        do {
            try await adapter.sendTypingIndicator(accountID: message.accountID, peerID: message.peerID)
            await self.emitDiagnostic(
                name: "typing.heartbeat.started",
                sessionKey: sessionKey,
                metadata: ["channel": message.channel.rawValue]
            )
        } catch {
            await self.emitDiagnostic(
                name: "typing.heartbeat.error",
                sessionKey: sessionKey,
                metadata: [
                    "channel": message.channel.rawValue,
                    "error": String(describing: error),
                ]
            )
            return nil
        }

        let intervalNs = UInt64(self.typingHeartbeatIntervalMs) * 1_000_000
        return Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: intervalNs)
                } catch {
                    return
                }
                guard !Task.isCancelled else {
                    return
                }
                do {
                    try await adapter.sendTypingIndicator(accountID: message.accountID, peerID: message.peerID)
                    await self.emitDiagnostic(
                        name: "typing.heartbeat.tick",
                        sessionKey: sessionKey,
                        metadata: ["channel": message.channel.rawValue]
                    )
                } catch {
                    await self.emitDiagnostic(
                        name: "typing.heartbeat.error",
                        sessionKey: sessionKey,
                        metadata: [
                            "channel": message.channel.rawValue,
                            "error": String(describing: error),
                        ]
                    )
                    return
                }
            }
        }
    }

    private func shouldUseStreamingRuntime() -> Bool {
        let local = self.config.models.local
        return local.enabled && local.streamTokens
    }

    private func collectStreamingRuntimeOutput(
        request: AgentRunRequest,
        sessionKey: String
    ) async throws -> String {
        var output = ""
        let stream = await self.runtime.runStream(request)
        for try await chunk in stream {
            if !chunk.text.isEmpty {
                output += chunk.text
            }
            await self.emitDiagnostic(
                name: "model.stream.chunk",
                sessionKey: sessionKey,
                metadata: [
                    "chunkLength": String(chunk.text.count),
                    "isFinal": String(chunk.isFinal),
                ]
            )
        }
        return output
    }

    private func handleCommandIfRequested(
        _ message: InboundMessage,
        sessionKey: String
    ) async -> OutboundMessage? {
        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else {
            return nil
        }
        let command = trimmed
            .split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            .first?
            .lowercased() ?? ""

        switch command {
        case "/health", "/status":
            let snapshot = await self.channelRegistry.healthSnapshot(for: message.channel)
            let policy = await self.channelRegistry.retryPolicy()
            let text = """
            Channel: \(snapshot.channelID.rawValue)
            Status: \(snapshot.status.rawValue)
            ConsecutiveFailures: \(snapshot.consecutiveFailures)
            LastError: \(snapshot.lastError ?? "none")
            RetryPolicy: attempts=\(policy.maxAttempts), initialBackoffMs=\(policy.initialBackoffMs), maxBackoffMs=\(policy.maxBackoffMs)
            SessionKey: \(sessionKey)
            """
            return OutboundMessage(
                channel: message.channel,
                accountID: message.accountID,
                peerID: message.peerID,
                text: text
            )
        case "/help":
            return OutboundMessage(
                channel: message.channel,
                accountID: message.accountID,
                peerID: message.peerID,
                text: """
                Available runtime commands:
                - /health or /status: Show channel delivery health and retry policy.
                - /help: Show this command list.
                """
            )
        default:
            return nil
        }
    }

    private func invokeSkillIfRequested(_ messageText: String) async throws -> SkillInvocationResult? {
        let workspaceRoot = self.config.agents.workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspaceRoot.isEmpty else {
            return nil
        }
        let invoker = SkillInvocationEngine(
            workspaceRoot: URL(fileURLWithPath: workspaceRoot, isDirectory: true),
            invocationTimeoutMs: self.config.agents.skillInvocationTimeoutMs
        )
        return try await invoker.invokeIfRequested(message: messageText)
    }

    private func emitDiagnostic(name: String, sessionKey: String?, metadata: [String: String] = [:]) async {
        guard let diagnosticsSink else { return }
        await diagnosticsSink(
            RuntimeDiagnosticEvent(
                subsystem: "channel",
                name: name,
                sessionKey: sessionKey,
                metadata: metadata
            )
        )
    }
}
