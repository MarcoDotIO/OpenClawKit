import Foundation
import OpenClawCore
#if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
@preconcurrency import ActivityKit
#endif

/// Content state shared by the OpenClaw Live Activity and its widget extension.
///
/// Port of upstream's `OpenClawActivityAttributes.ContentState` (apps/ios LiveActivity). It decodes
/// the older boolean schema (`statusText`, `isIdle`, `isDisconnected`, `isConnecting`) once, because
/// Live Activities can outlive an app update; all writes use the semantic `status` shape.
public struct OpenClawLiveActivityContentState: Codable, Hashable, Sendable {
    /// Semantic presentation status.
    public enum Status: String, CaseIterable, Codable, Hashable, Sendable {
        /// Connecting to the gateway.
        case connecting
        /// Reconnecting after a drop.
        case reconnecting
        /// A pairing approval is required on the gateway.
        case approvalNeeded
        /// A user action is required (for example auth paused).
        case actionRequired
        /// Other attention state with a verbatim detail.
        case attention
        /// A tool call is running.
        case toolRunning
        /// Talk mode is listening.
        case voiceListening
        /// Talk mode is speaking.
        case voiceSpeaking
        /// Talk mode is active but neither listening nor speaking.
        case voiceActive
        /// Paused.
        case paused
        /// Connected and idle.
        case idle
        /// Disconnected.
        case disconnected
    }

    /// Presentation status.
    public var status: Status
    /// Optional verbatim detail shown instead of the localized status label.
    public var verbatimDetail: String?
    /// When the presented lifecycle started.
    public var startedAt: Date
    /// Optional agent badge (emoji).
    public var agentBadge: String?
    /// Running tool name for ``Status/toolRunning``.
    public var toolName: String?
    /// Recent playback-envelope samples, oldest first, quantized from 0...1.
    public var voiceSamples: [UInt8]?

    private enum CodingKeys: String, CodingKey {
        case status
        case verbatimDetail
        case startedAt
        case agentBadge
        case toolName
        case voiceSamples
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case statusText
        case isIdle
        case isDisconnected
        case isConnecting
    }

    /// Creates a content state.
    /// - Parameters:
    ///   - status: Presentation status.
    ///   - verbatimDetail: Optional verbatim detail.
    ///   - startedAt: Lifecycle start time.
    ///   - agentBadge: Optional agent badge.
    ///   - toolName: Optional running tool name.
    ///   - voiceSamples: Optional voice envelope samples.
    public init(
        status: Status,
        verbatimDetail: String?,
        startedAt: Date,
        agentBadge: String? = nil,
        toolName: String? = nil,
        voiceSamples: [UInt8]? = nil)
    {
        self.status = status
        self.verbatimDetail = verbatimDetail
        self.startedAt = startedAt
        self.agentBadge = agentBadge
        self.toolName = toolName
        self.voiceSamples = voiceSamples
    }

    /// Decodes the current schema, falling back to the legacy boolean schema.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.startedAt = try container.decode(Date.self, forKey: .startedAt)

        if let status = try container.decodeIfPresent(Status.self, forKey: .status) {
            self.status = status
            self.verbatimDetail = try container.decodeIfPresent(String.self, forKey: .verbatimDetail)
            self.agentBadge = try container.decodeIfPresent(String.self, forKey: .agentBadge)
            self.toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
            self.voiceSamples = try container.decodeIfPresent([UInt8].self, forKey: .voiceSamples)
            return
        }

        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        let statusText = try legacy.decodeIfPresent(String.self, forKey: .statusText)
        let presentation = try Self.legacyPresentation(
            statusText: statusText,
            isIdle: legacy.decodeIfPresent(Bool.self, forKey: .isIdle) ?? false,
            isDisconnected: legacy.decodeIfPresent(Bool.self, forKey: .isDisconnected) ?? false,
            isConnecting: legacy.decodeIfPresent(Bool.self, forKey: .isConnecting) ?? false)
        self.status = presentation.status
        self.verbatimDetail = presentation.verbatimDetail
        self.agentBadge = nil
        self.toolName = nil
        self.voiceSamples = nil
    }

    /// Encodes the current schema.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.status, forKey: .status)
        try container.encodeIfPresent(self.verbatimDetail, forKey: .verbatimDetail)
        try container.encode(self.startedAt, forKey: .startedAt)
        try container.encodeIfPresent(self.agentBadge, forKey: .agentBadge)
        try container.encodeIfPresent(self.toolName, forKey: .toolName)
        try container.encodeIfPresent(self.voiceSamples, forKey: .voiceSamples)
    }

    private static func legacyPresentation(
        statusText: String?,
        isIdle: Bool,
        isDisconnected: Bool,
        isConnecting: Bool) -> (status: Status, verbatimDetail: String?)
    {
        if isDisconnected {
            return (.disconnected, nil)
        }
        if isIdle {
            return (.idle, nil)
        }

        let trimmed = statusText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let detail = trimmed.isEmpty ? nil : trimmed
        if isConnecting {
            if detail == "Reconnecting..." {
                return (.reconnecting, nil)
            }
            if detail == "Connecting..." {
                return (.connecting, nil)
            }
            return (.connecting, detail)
        }
        if detail == "Approval needed" {
            return (.approvalNeeded, nil)
        }
        if detail == "Action required" {
            return (.actionRequired, nil)
        }
        return (.attention, detail)
    }
}

/// One producer's requested Live Activity presentation.
public struct OpenClawLiveActivityPresentationRequest: Equatable, Sendable {
    /// Requested content state.
    public var state: OpenClawLiveActivityContentState
    /// Stale date for the content.
    public var staleDate: Date?
    /// Agent display name (activity attribute).
    public var agentName: String
    /// Session key (activity attribute).
    public var sessionKey: String

    /// Creates a presentation request.
    /// - Parameters:
    ///   - state: Content state.
    ///   - staleDate: Stale date.
    ///   - agentName: Agent display name.
    ///   - sessionKey: Session key.
    public init(state: OpenClawLiveActivityContentState, staleDate: Date?, agentName: String, sessionKey: String) {
        self.state = state
        self.staleDate = staleDate
        self.agentName = agentName
        self.sessionKey = sessionKey
    }
}

/// Bounded buffer of quantized voice envelope samples for the Live Activity waveform.
public struct OpenClawLiveActivityVoiceSampleBuffer: Sendable, Equatable {
    /// Samples, oldest first.
    public private(set) var values: [UInt8] = []
    /// Maximum retained samples.
    public let capacity: Int

    /// Creates a sample buffer.
    /// - Parameter capacity: Maximum retained samples (at least 1).
    public init(capacity: Int = 24) {
        self.capacity = max(capacity, 1)
    }

    /// Samples for the content state, or `nil` when empty.
    public var payload: [UInt8]? {
        self.values.isEmpty ? nil : self.values
    }

    /// Quantizes a 0...1 level to a byte.
    /// - Parameter level: Audio level.
    /// - Returns: Quantized sample, or `nil` for missing/non-finite levels.
    public static func quantize(_ level: Double?) -> UInt8? {
        guard let level, level.isFinite else { return nil }
        let clamped = min(max(level, 0), 1)
        return UInt8((clamped * 255).rounded())
    }

    /// Appends a sample, dropping the oldest beyond capacity.
    /// - Parameter sample: Quantized sample.
    public mutating func append(_ sample: UInt8) {
        self.values.append(sample)
        if self.values.count > self.capacity {
            self.values.removeFirst(self.values.count - self.capacity)
        }
    }

    /// Removes all samples.
    public mutating func reset() {
        self.values.removeAll(keepingCapacity: true)
    }
}

/// Keeps independent producers (connection, attention, tools, voice) from overwriting
/// higher-priority Live Activity state; ActivityKit receives one reconciled presentation.
///
/// Port of upstream's `LiveActivityPresentationArbiter`. Priority: attention, then the most
/// recently started tool, then voice, then connection, then a hydrated tool fallback.
public struct OpenClawLiveActivityPresentationArbiter: Sendable, Equatable {
    private struct ToolIdentity: Hashable, Sendable {
        let sessionKey: String
        let id: String
    }

    /// Connection presentation (connecting / reconnecting).
    public private(set) var connection: OpenClawLiveActivityPresentationRequest?
    /// Attention presentation (approval needed / action required).
    public private(set) var attention: OpenClawLiveActivityPresentationRequest?
    /// Voice presentation.
    public private(set) var voice: OpenClawLiveActivityPresentationRequest?
    /// One-time fallback adopted from an activity that survived a relaunch.
    public private(set) var hydratedToolFallback: OpenClawLiveActivityPresentationRequest?
    private var toolsByIdentity: [ToolIdentity: OpenClawLiveActivityPresentationRequest] = [:]
    private var toolOrder: [ToolIdentity] = []

    /// Creates an empty arbiter.
    public init() {}

    /// The presentation that should be visible, or `nil` when the activity should end.
    public var current: OpenClawLiveActivityPresentationRequest? {
        if let attention {
            return attention
        }
        if let toolIdentity = toolOrder.last,
           let tool = toolsByIdentity[toolIdentity]
        {
            return tool
        }
        return self.voice ?? self.connection ?? self.hydratedToolFallback
    }

    /// Number of running tools.
    public var activeToolCount: Int {
        self.toolsByIdentity.count
    }

    /// Maps talk flags to a voice status.
    /// - Parameters:
    ///   - isListening: Whether talk is listening.
    ///   - isSpeaking: Whether talk is speaking.
    /// - Returns: Voice status.
    public static func voiceStatus(isListening: Bool, isSpeaking: Bool) -> OpenClawLiveActivityContentState.Status {
        if isSpeaking {
            return .voiceSpeaking
        }
        if isListening {
            return .voiceListening
        }
        return .voiceActive
    }

    /// Sets or clears the connection presentation.
    /// - Parameter request: Presentation, or `nil`.
    public mutating func setConnection(_ request: OpenClawLiveActivityPresentationRequest?) {
        if request != nil {
            self.hydratedToolFallback = nil
        }
        self.connection = request
    }

    /// Sets or clears the attention presentation.
    /// - Parameter request: Presentation, or `nil`.
    public mutating func setAttention(_ request: OpenClawLiveActivityPresentationRequest?) {
        self.attention = request
    }

    /// Sets or clears the voice presentation.
    /// - Parameter request: Presentation, or `nil`.
    public mutating func setVoice(_ request: OpenClawLiveActivityPresentationRequest?) {
        if request != nil {
            self.hydratedToolFallback = nil
        }
        self.voice = request
    }

    /// Adopts the presentation of an activity that survived a relaunch (process-start hydration only).
    /// - Parameter request: Hydrated presentation.
    public mutating func adoptInitialHydratedToolFallback(_ request: OpenClawLiveActivityPresentationRequest?) {
        self.hydratedToolFallback = request
    }

    /// Refreshes the voice presentation's stale date.
    /// - Parameter staleDate: New stale date.
    public mutating func refreshVoice(staleDate: Date) {
        self.voice?.staleDate = staleDate
    }

    /// Starts (or updates) a tool presentation.
    /// - Parameters:
    ///   - id: Tool call id.
    ///   - request: Presentation.
    public mutating func startTool(id: String, request: OpenClawLiveActivityPresentationRequest) {
        guard !id.isEmpty else { return }
        self.hydratedToolFallback = nil
        let identity = ToolIdentity(sessionKey: request.sessionKey, id: id)
        if self.toolsByIdentity[identity] == nil {
            self.toolOrder.append(identity)
        }
        self.toolsByIdentity[identity] = request
    }

    /// Ends a tool presentation.
    /// - Parameters:
    ///   - id: Tool call id.
    ///   - sessionKey: Session key the tool ran in.
    public mutating func endTool(id: String, sessionKey: String) {
        self.hydratedToolFallback = nil
        let identity = ToolIdentity(sessionKey: sessionKey, id: id)
        self.toolsByIdentity[identity] = nil
        self.toolOrder.removeAll { $0 == identity }
    }

    /// Refreshes every running tool's stale date.
    /// - Parameter staleDate: New stale date.
    public mutating func refreshTools(staleDate: Date) {
        for identity in self.toolsByIdentity.keys {
            self.toolsByIdentity[identity]?.staleDate = staleDate
        }
    }

    /// Clears connection and attention state (the gateway reconnected).
    public mutating func clearConnectionState() {
        self.connection = nil
        self.attention = nil
        self.hydratedToolFallback = nil
    }

    /// Clears every presentation.
    public mutating func clearAll() {
        self.connection = nil
        self.attention = nil
        self.voice = nil
        self.hydratedToolFallback = nil
        self.toolsByIdentity.removeAll(keepingCapacity: true)
        self.toolOrder.removeAll(keepingCapacity: true)
    }
}

/// Gateway connection events that drive the Live Activity connection/attention presentation.
public enum OpenClawLiveActivityConnectionEvent: Sendable, Equatable {
    /// A connect attempt started (`attempt == 0` is the first attempt, later ones are reconnects).
    case connecting(attempt: Int)
    /// The gateway connected.
    case connected
    /// Connected with nothing to show.
    case idle
    /// The gateway disconnected (manual disconnect, loop stopped, background idle).
    case disconnected
    /// A connection problem was reported.
    case problem(needsPairingApproval: Bool, pausesReconnect: Bool)
}

extension OpenClawLiveActivityPresentationArbiter {
    /// Stale interval for connecting presentations (upstream: 120 seconds).
    public static let connectingStaleInterval: TimeInterval = 120

    /// Applies upstream's connection rules.
    ///
    /// Connected, idle and disconnected states end the activity unless another producer (tool,
    /// voice) still presents something; attention is only shown for approval-required or
    /// reconnect-paused problems; connect attempts show `connecting`/`reconnecting`.
    /// - Parameters:
    ///   - event: Connection event.
    ///   - agentName: Active agent display name.
    ///   - sessionKey: Main session key.
    ///   - now: Current time.
    /// - Returns: The presentation to show, or `nil` when the activity should end.
    @discardableResult
    public mutating func apply(
        _ event: OpenClawLiveActivityConnectionEvent,
        agentName: String,
        sessionKey: String,
        now: Date = Date()) -> OpenClawLiveActivityPresentationRequest?
    {
        switch event {
        case let .connecting(attempt):
            let startedAt = Self.lifecycleStartedAt(self.connection, agentName: agentName, sessionKey: sessionKey, now: now)
            self.setConnection(OpenClawLiveActivityPresentationRequest(
                state: OpenClawLiveActivityContentState(
                    status: attempt == 0 ? .connecting : .reconnecting,
                    verbatimDetail: nil,
                    startedAt: startedAt),
                staleDate: now.addingTimeInterval(Self.connectingStaleInterval),
                agentName: agentName,
                sessionKey: sessionKey))
        case .connected:
            self.clearConnectionState()
        case .idle, .disconnected:
            self.clearAll()
        case let .problem(needsPairingApproval, pausesReconnect):
            guard needsPairingApproval || pausesReconnect else { break }
            let startedAt = Self.lifecycleStartedAt(self.attention, agentName: agentName, sessionKey: sessionKey, now: now)
            self.setAttention(OpenClawLiveActivityPresentationRequest(
                state: OpenClawLiveActivityContentState(
                    status: needsPairingApproval ? .approvalNeeded : .actionRequired,
                    verbatimDetail: nil,
                    startedAt: startedAt),
                staleDate: nil,
                agentName: agentName,
                sessionKey: sessionKey))
        }
        return self.current
    }

    private static func lifecycleStartedAt(
        _ existing: OpenClawLiveActivityPresentationRequest?,
        agentName: String,
        sessionKey: String,
        now: Date) -> Date
    {
        guard let existing, existing.agentName == agentName, existing.sessionKey == sessionKey else {
            return now
        }
        return existing.state.startedAt
    }
}

/// Content state for a per-run agent Live Activity.
public struct OpenClawAgentRunActivityContentState: Codable, Hashable, Sendable {
    /// Run phase.
    public var phase: OpenClawRunPhase
    /// Short, non-sensitive detail (never prompt or reply text).
    public var detail: String
    /// Completed fraction (0...1).
    public var progress: Double
    /// Last update time.
    public var updatedAt: Date

    /// Creates a run content state.
    /// - Parameters:
    ///   - phase: Run phase.
    ///   - detail: Short detail.
    ///   - progress: Completed fraction.
    ///   - updatedAt: Update time.
    public init(phase: OpenClawRunPhase, detail: String, progress: Double, updatedAt: Date) {
        self.phase = phase
        self.detail = detail
        self.progress = min(1, max(0, progress))
        self.updatedAt = updatedAt
    }
}

/// Reduces runtime diagnostics events to Live Activity updates for agent runs.
///
/// Pure state machine (no ActivityKit), so hosts and widget code can share it and tests run on any
/// platform. Progress follows ``OpenClawRunProgress``.
public struct OpenClawAgentRunActivityReducer: Sendable {
    /// Update to apply to the run's activity.
    public enum Action: Equatable, Sendable {
        /// Start or update the activity.
        case upsert(runID: String, sessionKey: String, state: OpenClawAgentRunActivityContentState)
        /// End the activity (`immediately` for failures, default dismissal otherwise).
        case end(runID: String, sessionKey: String, state: OpenClawAgentRunActivityContentState, immediately: Bool)
    }

    private var runs: [String: OpenClawRunProgress] = [:]

    /// Creates a reducer.
    public init() {}

    /// Applies one diagnostics event.
    /// - Parameter event: Diagnostics event.
    /// - Returns: The activity update, or `nil` when the event is irrelevant.
    public mutating func reduce(_ event: RuntimeDiagnosticEvent) -> Action? {
        guard event.subsystem == "runtime",
              let runID = event.runID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !runID.isEmpty
        else {
            return nil
        }
        let sessionKey = event.sessionKey ?? "default"
        let progress: OpenClawRunProgress
        if let existing = self.runs[runID] {
            progress = existing
        } else {
            guard event.name == "run.started" || event.name == "model.call.started" else { return nil }
            progress = OpenClawRunProgress(backing: .legacyProgress)
            self.runs[runID] = progress
        }
        progress.record(event)
        let provider = event.metadata["providerID"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let providerDetail = provider.isEmpty ? nil : "Provider: \(provider)"
        switch event.name {
        case "run.started":
            return .upsert(runID: runID, sessionKey: sessionKey, state: .init(
                phase: .running, detail: "Preparing run", progress: progress.fractionCompleted, updatedAt: event.occurredAt))
        case "model.call.started":
            return .upsert(runID: runID, sessionKey: sessionKey, state: .init(
                phase: .running,
                detail: providerDetail ?? "Generating response",
                progress: progress.fractionCompleted,
                updatedAt: event.occurredAt))
        case "tool.call.started", "tool.started":
            return .upsert(runID: runID, sessionKey: sessionKey, state: .init(
                phase: .toolRunning, detail: "Running tool", progress: progress.fractionCompleted, updatedAt: event.occurredAt))
        case "model.call.completed":
            return .upsert(runID: runID, sessionKey: sessionKey, state: .init(
                phase: .running,
                detail: providerDetail ?? "Finishing run",
                progress: progress.fractionCompleted,
                updatedAt: event.occurredAt))
        case "run.completed":
            self.runs[runID] = nil
            return .end(runID: runID, sessionKey: sessionKey, state: .init(
                phase: .completed, detail: "Run completed", progress: 1, updatedAt: event.occurredAt), immediately: false)
        case "run.failed":
            self.runs[runID] = nil
            let timedOut = event.metadata["timedOut"]?.lowercased() == "true"
            return .end(runID: runID, sessionKey: sessionKey, state: .init(
                phase: .failed,
                detail: timedOut ? "Run timed out" : "Run failed",
                progress: 1,
                updatedAt: event.occurredAt), immediately: true)
        default:
            return nil
        }
    }
}

#if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
/// Live Activity attributes for OpenClaw connection, attention, tool and voice state.
///
/// Shared schema for the host app and its widget extension (port of upstream
/// `OpenClawActivityAttributes`). Hosts own the widget UI; drive the content with
/// ``OpenClawLiveActivityPresentationArbiter``.
public struct OpenClawActivityAttributes: ActivityAttributes {
    /// Dynamic content.
    public typealias ContentState = OpenClawLiveActivityContentState

    /// Agent display name.
    public var agentName: String
    /// Session key.
    public var sessionKey: String

    /// Creates attributes.
    /// - Parameters:
    ///   - agentName: Agent display name.
    ///   - sessionKey: Session key.
    public init(agentName: String, sessionKey: String) {
        self.agentName = agentName
        self.sessionKey = sessionKey
    }
}

/// Live Activity attributes for one agent run (progress, phase, short detail).
public struct OpenClawAgentRunActivityAttributes: ActivityAttributes {
    /// Dynamic content.
    public typealias ContentState = OpenClawAgentRunActivityContentState

    /// Run id.
    public var runID: String
    /// Session key.
    public var sessionKey: String

    /// Creates attributes.
    /// - Parameters:
    ///   - runID: Run id.
    ///   - sessionKey: Session key.
    public init(runID: String, sessionKey: String) {
        self.runID = runID
        self.sessionKey = sessionKey
    }
}
#endif
