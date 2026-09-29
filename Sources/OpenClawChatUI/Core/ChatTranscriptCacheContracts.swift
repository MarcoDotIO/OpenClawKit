import Foundation

// Ported from upstream OpenClaw 2026.9.6 `apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatTranscriptCacheContracts.swift`.
// Store-agnostic: the GRDB-backed implementation ships separately in the `OpenClawChatStore` product.

/// Read-only offline cache seam for chat sessions and transcripts.
///
/// The cache only pre-paints cold opens and covers offline browsing; connected
/// reads always come from the gateway and replace cached content wholesale.
/// Implementations must scope every row by gateway and agent identity so one
/// shared installation database can safely serve all paired gateways.
public protocol OpenClawChatTranscriptCache: Sendable {
    /// Loads cached session rows (legacy, unscoped).
    func loadSessions() async -> [OpenClawChatSessionEntry]
    /// Loads cached session rows for an agent.
    func loadSessions(agentID: String?) async -> [OpenClawChatSessionEntry]
    /// Loads a cached transcript (legacy, unscoped).
    func loadTranscript(sessionKey: String) async -> [OpenClawChatMessage]
    /// Loads a cached transcript for an agent.
    func loadTranscript(sessionKey: String, agentID: String?) async -> [OpenClawChatMessage]
    /// Stores session rows (legacy, unscoped).
    func storeSessions(_ sessions: [OpenClawChatSessionEntry]) async
    /// Stores session rows for an agent.
    func storeSessions(_ sessions: [OpenClawChatSessionEntry], agentID: String?) async
    /// Canonical gateway rows can prove that an ambiguously delivered local
    /// command landed after cancellation and must override local suppression.
    func storeCanonicalTranscript(
        sessionKey: String,
        agentID: String?,
        messages: [OpenClawChatMessage],
        canonicalMessageIdempotencyKeys: Set<String>) async
    /// Synchronous observation closes the session.message -> cancellation
    /// race before asynchronous SQLite confirmation starts.
    func observeCanonicalMessageIdempotencyKeys(_ keys: Set<String>)
}

extension OpenClawChatTranscriptCache {
    /// Legacy conformers have no agent partition; scoped reads fail closed.
    public func loadSessions(agentID: String?) async -> [OpenClawChatSessionEntry] {
        // Legacy conformers have no agent partition. Scoped access must fail
        // closed or an ownerless roster can cross an agent switch.
        guard agentID == nil else { return [] }
        return await self.loadSessions()
    }

    /// Legacy conformers have no agent partition; scoped writes are dropped.
    public func storeSessions(_ sessions: [OpenClawChatSessionEntry], agentID: String?) async {
        guard agentID == nil else { return }
        await self.storeSessions(sessions)
    }

    /// Legacy conformers have no agent partition; scoped reads fail closed.
    public func loadTranscript(sessionKey: String, agentID: String?) async -> [OpenClawChatMessage] {
        guard agentID == nil else { return [] }
        return await self.loadTranscript(sessionKey: sessionKey)
    }

    /// Default: no synchronous observation.
    public func observeCanonicalMessageIdempotencyKeys(_: Set<String>) {}
}

/// Optional atomic merge seam for cache owners that also provide a durable
/// outbox. Keeping this separate preserves source compatibility for read-only
/// transcript-cache conformers.
package protocol OpenClawChatCanonicalTranscriptMerging: OpenClawChatTranscriptCache {
    /// Merges one canonical gateway row proving delivery of an outbox command.
    func mergeCanonicalTranscriptMessage(
        sessionKey: String,
        agentID: String?,
        message: OpenClawChatMessage,
        canonicalMessageIdempotencyKey: String) async
}

/// Durable branch ownership is scoped exactly like outbox delivery routing.
public struct OpenClawChatOutboxScope: Hashable, Sendable {
    /// Presentation session key.
    public let sessionKey: String
    /// Normalized (lowercased) owning agent.
    public let agentID: String?

    /// Creates a scope; the agent is trimmed and lowercased.
    public init(sessionKey: String, agentID: String?) {
        self.sessionKey = sessionKey
        let normalizedAgentID = agentID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.agentID = normalizedAgentID?.isEmpty == false ? normalizedAgentID : nil
    }
}

/// Persisted branch ownership captured before bootstrap can advance the transcript tip.
public struct OpenClawChatOutboxBranchState: Equatable, Sendable {
    /// Branch generation.
    public let epoch: Int
    /// Last observed active leaf.
    public let lastActiveLeafEntryID: String?
    /// Whether commands were pending when captured.
    public let hadPendingCommands: Bool
    /// When a branch switch started, if one is pending.
    public let switchPendingSince: TimeInterval?
    /// Whether replay must wait for reconciliation.
    public let needsReconciliation: Bool
    /// Row revision.
    public let revision: Int

    /// Creates a branch state.
    public init(
        epoch: Int,
        lastActiveLeafEntryID: String?,
        hadPendingCommands: Bool = false,
        switchPendingSince: TimeInterval? = nil,
        needsReconciliation: Bool = false,
        revision: Int = 0)
    {
        self.epoch = epoch
        self.lastActiveLeafEntryID = lastActiveLeafEntryID
        self.hadPendingCommands = hadPendingCommands
        self.switchPendingSince = switchPendingSince
        self.needsReconciliation = needsReconciliation
        self.revision = revision
    }
}

/// The failed-row version a retry must still match.
public struct OpenClawChatOutboxRetryExpectation: Equatable, Sendable {
    /// Attempt version shown to the user.
    public let attemptVersion: Int
    /// Retry count shown to the user.
    public let retryCount: Int
    /// Failure shown to the user.
    public let lastError: String?

    /// Creates a retry expectation.
    public init(attemptVersion: Int, retryCount: Int, lastError: String?) {
        self.attemptVersion = attemptVersion
        self.retryCount = retryCount
        self.lastError = lastError
    }
}

/// One attachment captured with a durable chat command.
public struct OpenClawChatOutboxAttachment: Codable, Hashable, Sendable {
    /// Attachment type.
    public let type: String
    /// MIME type.
    public let mimeType: String
    /// File name.
    public let fileName: String
    /// Bytes.
    public let data: Data
    /// Recorded audio duration.
    public let durationSeconds: Double?

    /// Creates an outbox attachment.
    public init(
        type: String,
        mimeType: String,
        fileName: String,
        data: Data,
        durationSeconds: Double? = nil)
    {
        self.type = type
        self.mimeType = mimeType
        self.fileName = fileName
        self.data = data
        self.durationSeconds = durationSeconds
    }
}

/// One durable queued chat command. `id` is the client UUID
/// that becomes the transport idempotency key on flush, so at-least-once
/// delivery stays safe across retries and app restarts.
///
/// Naming mirrors the watch-side `QueuedCommand` shape (WatchChatCoordinator)
/// so the two queues can merge into one owner later.
public struct OpenClawChatOutboxCommand: Hashable, Sendable, Identifiable {
    /// Routing contract stamped on commands from transports without routing contracts.
    package static let legacyUnboundRoutingContract = "legacy-unbound"

    /// Delivery status.
    public enum Status: String, Sendable {
        /// Waiting to send.
        case queued
        /// Claimed by a sender.
        case sending
        /// Acknowledged; waiting for canonical history.
        case awaitingConfirmation = "awaiting_confirmation"
        /// Needs user action.
        case failed
    }

    /// Client UUID, also the `chat.send` idempotency key.
    public let id: String
    /// Presentation/cache key captured when the user queued the command.
    public let sessionKey: String
    /// Canonical transport key captured at enqueue time. This must never be
    /// re-resolved from a mutable main/default alias during reconnect.
    public let deliverySessionKey: String
    /// Gateway main-routing contract (scope, main key, default agent) captured
    /// with the command. A changed contract must fail closed before replay.
    public let routingContract: String?
    /// Durable routing owner, required for the literal `global` session and
    /// retained for ownership checks on canonical agent-scoped keys.
    public let agentID: String?
    /// Local branch generation captured when this delivery attempt was queued.
    public let branchEpoch: Int
    /// Scope epoch observed alongside this row snapshot.
    public let scopeBranchEpoch: Int?
    /// Message text.
    public let text: String
    /// Attachment bytes remain owned by SQLite until canonical history proves
    /// delivery or the user explicitly deletes the command.
    public let attachments: [OpenClawChatOutboxAttachment]
    /// Thinking level captured when the command was queued, so a later flush
    /// never borrows the setting of whichever session is visible then.
    public let thinking: String
    /// Permission and tool state captured with this command. Durable replay
    /// must use this command-owned fence, never the currently visible session.
    public let expectedSessionSettings: OpenClawChatSessionSettingsExpectation?
    /// Seconds since 1970; flush order is strictly ascending `createdAt`.
    public let createdAt: Double
    /// Delivery status.
    public var status: Status
    /// Immutable ownership token for one delivery lifecycle. Every automatic
    /// or user-initiated retry increments it before another send can start.
    public let attemptVersion: Int
    /// Automatic retries consumed.
    public var retryCount: Int
    /// Last failure code or message.
    public var lastError: String?

    /// Creates an outbox command.
    public init(
        id: String,
        sessionKey: String,
        deliverySessionKey: String? = nil,
        routingContract: String? = nil,
        agentID: String? = nil,
        branchEpoch: Int = 0,
        scopeBranchEpoch: Int? = nil,
        text: String,
        attachments: [OpenClawChatOutboxAttachment] = [],
        thinking: String,
        expectedSessionSettings: OpenClawChatSessionSettingsExpectation? = nil,
        createdAt: Double,
        status: Status,
        attemptVersion: Int = 1,
        retryCount: Int,
        lastError: String?)
    {
        self.id = id
        self.sessionKey = sessionKey
        if let deliverySessionKey {
            self.deliverySessionKey = deliverySessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            self.deliverySessionKey = sessionKey
        }
        let normalizedRoutingContract = routingContract?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.routingContract = normalizedRoutingContract?.isEmpty == false ? normalizedRoutingContract : nil
        let normalizedAgentID = agentID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.agentID = normalizedAgentID?.isEmpty == false ? normalizedAgentID : nil
        self.branchEpoch = branchEpoch
        self.scopeBranchEpoch = scopeBranchEpoch ?? branchEpoch
        self.text = text
        self.attachments = attachments
        self.thinking = thinking
        self.expectedSessionSettings = expectedSessionSettings
        self.createdAt = createdAt
        self.status = status
        self.attemptVersion = attemptVersion
        self.retryCount = retryCount
        self.lastError = lastError
    }
}

/// Stable failure codes stored in `OpenClawChatOutboxCommand.lastError` by durable outbox stores.
public enum OpenClawChatOutboxErrorCode {
    /// Longest a command may stay queued before it fails as expired (48 hours).
    public static let commandMaxAge: TimeInterval = 48 * 60 * 60
    /// The command expired while queued.
    public static let expired = "expired"
    /// Delivery is ambiguous; canonical history or an explicit retry must resolve it.
    public static let unconfirmed = "delivery_unconfirmed"
    /// The delivery target could not be verified.
    public static let unknownTarget = "delivery_target_unknown"
    /// The gateway routing contract changed after the command was queued.
    public static let changedTarget = "delivery_target_changed"
    /// A previous client version could not safely replay the command.
    public static let clientUpgradeRequired = "client_upgrade_required"
    /// A previous client version did not capture session settings.
    public static let settingsUpgradeRequired = "settings_client_upgrade_required"
    /// The gateway cannot fence queued sends on session settings.
    public static let settingsGatewayUpgradeRequired = "settings_gateway_upgrade_required"
    /// Session settings were not captured with the command.
    public static let settingsReviewRequired = "settings_review_required"
    /// Session settings changed after the command was queued.
    public static let settingsChanged = "settings_changed"

    /// User-facing text for a stored failure (strips internal branch-park markers).
    public static func displayMessage(_ lastError: String?) -> String? {
        guard let lastError else { return nil }
        switch lastError {
        case self.clientUpgradeRequired, self.settingsUpgradeRequired:
            return String(localized: "A previous app version could not safely send this message. Review and retry it.")
        case self.settingsGatewayUpgradeRequired:
            return String(localized: "Update the gateway before sending queued messages with session settings.")
        case self.settingsReviewRequired:
            return String(localized: "Session settings were not captured. Review and retry this message.")
        case self.settingsChanged:
            return String(localized: "Session settings changed. Review and retry this message.")
        default:
            break
        }
        guard
            let marker = lastError.range(of: "\n# branch-park:")
        else { return lastError }
        return String(lastError[..<marker.lowerBound])
    }
}

/// Result of a conditional outbox transition.
public enum OpenClawChatOutboxUpdateResult: Equatable, Sendable {
    /// The row changed.
    case updated
    /// Canonical history already confirmed the row.
    case confirmed
    /// The row no longer exists.
    case missing
    /// A newer attempt owns the row.
    case superseded
    /// Storage is unavailable.
    case unavailable
}

/// Cross-view-model outbox change notification.
public enum OpenClawChatOutboxChange: Equatable, Sendable {
    /// A command was canceled.
    case canceled(gatewayID: String, id: String)
    /// A command was confirmed by canonical history.
    case confirmed(gatewayID: String, id: String)
    /// A scope's commands changed and must be reloaded.
    case invalidated(gatewayID: String, scope: OpenClawChatOutboxScope)

    /// Gateway the change belongs to.
    package var gatewayID: String {
        switch self {
        case let .canceled(gatewayID, _), let .confirmed(gatewayID, _), let .invalidated(gatewayID, _):
            gatewayID
        }
    }
}

/// Durable offline outbox for chat commands. Implementations expose one
/// gateway-scoped facade over installation-wide client state so queued sends
/// survive app restarts and flush on reconnect.
public protocol OpenClawChatCommandOutbox: Sendable {
    /// Returns false when the row or attachment-byte budget is full, or
    /// storage is unavailable; callers surface that instead of dropping text.
    func enqueueCommand(_ command: OpenClawChatOutboxCommand) async -> Bool
    /// Gateway-scoped rows in `createdAt` order. Applies the staleness gate:
    /// old queued or unconfirmed rows become failed so reconnect never sends
    /// stale or ambiguously delivered commands silently.
    func loadCommands() async -> [OpenClawChatOutboxCommand]
    /// Availability-aware read used by the FIFO restoration gate. Nil means
    /// storage was not readable, not that the queue was empty.
    func loadCommandsIfAvailable() async -> [OpenClawChatOutboxCommand]?
    /// Crash safety: rows stuck in 'sending' from a previous process become
    /// failed once per store lifetime. Delivery is ambiguous after a crash,
    /// so only explicit user retry may replay them; acknowledged rows stay
    /// awaiting canonical history confirmation.
    /// Returns false while storage is unavailable so callers can retry later.
    @discardableResult
    func recoverInterruptedSends() async -> Bool
    /// Atomically claims the oldest queued row when no other row is sending.
    /// Nil means another flusher owns the queue or no deliverable row remains.
    func claimNextCommand() async -> OpenClawChatOutboxCommand?
    /// Safe automatic retry: only the completing attempt may requeue the row,
    /// and a successful requeue mints the next attempt version atomically.
    func markCommandQueued(
        id: String,
        attemptVersion: Int,
        retryCount: Int,
        lastError: String?) async -> OpenClawChatOutboxUpdateResult
    /// Moves an acknowledged attempt to awaiting canonical confirmation.
    func markCommandAwaitingConfirmation(
        id: String,
        attemptVersion: Int) async -> OpenClawChatOutboxUpdateResult
    /// Result-bearing terminal transition for callers that must stop their
    /// FIFO when durable storage is unavailable.
    func markCommandFailedIfPresent(
        id: String,
        attemptVersion: Int,
        retryCount: Int,
        lastError: String?) async -> OpenClawChatOutboxUpdateResult
    /// Captures the persisted scope state before bootstrap history can advance its tip.
    func branchState(for scope: OpenClawChatOutboxScope) async -> OpenClawChatOutboxBranchState?
    /// Installs the cross-view-model transcript-mutation barrier only when no
    /// delivery is already unresolved for the scope.
    func beginBranchSwitch(_ scope: OpenClawChatOutboxScope) async -> Bool
    /// Rolls back a barrier when the server rejected the switch.
    func cancelBranchSwitch(_ scope: OpenClawChatOutboxScope) async -> Bool
    /// The server changed the branch but local refresh failed; block replay
    /// until reconciliation establishes the active leaf.
    func demoteBranchSwitchToReconcile(_ scope: OpenClawChatOutboxScope) async -> Bool
    /// Reconciles a bootstrap branch snapshot before automatic replay is enabled.
    /// A nil active leaf represents a successfully listed empty transcript.
    func reconcileBranchScope(
        _ scope: OpenClawChatOutboxScope,
        previousState: OpenClawChatOutboxBranchState,
        activeLeafEntryID: String?,
        branchLeafEntryIDs: Set<String>,
        activeTranscriptEntryIDs: Set<String>,
        lastError: String) async -> [OpenClawChatOutboxCommand]?
    /// Atomically records a confirmed server-side branch change and parks rows
    /// stamped with the superseded generation.
    func confirmBranchChange(
        _ scope: OpenClawChatOutboxScope,
        activeLeafEntryID: String,
        lastError: String) async -> [OpenClawChatOutboxCommand]?
    /// Advances the observed transcript tip only while branch ownership still
    /// matches the epoch captured by the caller.
    func updateLastActiveLeafEntryID(
        _ leafEntryID: String,
        expectedEpoch: Int,
        for scope: OpenClawChatOutboxScope) async -> Bool
    /// Retry only if the failed row still matches the version shown to the user.
    /// The default fails closed so a store cannot bypass branch-change parking.
    func markCommandRetriedIfPresent(
        id: String,
        expectation: OpenClawChatOutboxRetryExpectation,
        agentID: String?,
        deliverySessionKey: String,
        routingContract: String,
        expectedSessionSettings: OpenClawChatSessionSettingsExpectation,
        replacementID: String?) async -> OpenClawChatOutboxUpdateResult
    /// Persistently parks automatic replay after a failed settings mutation.
    func parkQueuedCommands(
        in scope: OpenClawChatOutboxScope,
        lastError: String) async -> Bool
    /// User cancellation succeeds only before a sender claims the row. The
    /// status predicate is the cross-view-model cancellation boundary.
    func cancelCommand(id: String) async -> OpenClawChatOutboxUpdateResult
    /// Canonical gateway history may complete the matching attempt, including
    /// a sending row whose request ACK was lost.
    func confirmCommand(id: String, attemptVersion: Int) async -> OpenClawChatOutboxUpdateResult
    /// Cross-view-model invalidation.
    func changes() -> AsyncStream<OpenClawChatOutboxChange>
}

extension OpenClawChatCommandOutbox {
    /// Default: cannot park (fails closed).
    public func parkQueuedCommands(
        in _: OpenClawChatOutboxScope,
        lastError _: String) async -> Bool
    {
        false
    }

    /// Default: storage unavailable.
    public func markCommandQueued(
        id _: String,
        attemptVersion _: Int,
        retryCount _: Int,
        lastError _: String?) async -> OpenClawChatOutboxUpdateResult
    {
        .unavailable
    }

    /// Default: storage unavailable.
    public func markCommandAwaitingConfirmation(
        id _: String,
        attemptVersion _: Int) async -> OpenClawChatOutboxUpdateResult
    {
        .unavailable
    }

    /// Default: storage unavailable.
    public func markCommandFailedIfPresent(
        id _: String,
        attemptVersion _: Int,
        retryCount _: Int,
        lastError _: String?) async -> OpenClawChatOutboxUpdateResult
    {
        .unavailable
    }

    /// Default: storage unavailable.
    public func confirmCommand(
        id _: String,
        attemptVersion _: Int) async -> OpenClawChatOutboxUpdateResult
    {
        .unavailable
    }

    /// Default: no branch state.
    public func branchState(for _: OpenClawChatOutboxScope) async -> OpenClawChatOutboxBranchState? {
        nil
    }

    /// Default: barrier refused.
    public func beginBranchSwitch(_: OpenClawChatOutboxScope) async -> Bool {
        false
    }

    /// Default: nothing to cancel.
    public func cancelBranchSwitch(_: OpenClawChatOutboxScope) async -> Bool {
        false
    }

    /// Default: nothing to demote.
    public func demoteBranchSwitchToReconcile(_: OpenClawChatOutboxScope) async -> Bool {
        false
    }

    /// Default: reconciliation unavailable.
    public func reconcileBranchScope(
        _: OpenClawChatOutboxScope,
        previousState _: OpenClawChatOutboxBranchState,
        activeLeafEntryID _: String?,
        branchLeafEntryIDs _: Set<String>,
        activeTranscriptEntryIDs _: Set<String>,
        lastError _: String) async -> [OpenClawChatOutboxCommand]?
    {
        nil
    }

    /// Default: confirmation unavailable.
    public func confirmBranchChange(
        _: OpenClawChatOutboxScope,
        activeLeafEntryID _: String,
        lastError _: String) async -> [OpenClawChatOutboxCommand]?
    {
        nil
    }

    /// Default: tip not recorded.
    public func updateLastActiveLeafEntryID(
        _: String,
        expectedEpoch _: Int,
        for _: OpenClawChatOutboxScope) async -> Bool
    {
        false
    }

    /// Default: retry unavailable (fails closed).
    public func markCommandRetriedIfPresent(
        id _: String,
        expectation _: OpenClawChatOutboxRetryExpectation,
        agentID _: String?,
        deliverySessionKey _: String,
        routingContract _: String,
        expectedSessionSettings _: OpenClawChatSessionSettingsExpectation,
        replacementID _: String? = nil) async -> OpenClawChatOutboxUpdateResult
    {
        .unavailable
    }
}

/// Gateway session routing identity (`scope`, main session key, default agent).
public struct OpenClawChatSessionRoutingIdentity: Equatable, Sendable {
    /// Session scope.
    public let scope: String
    /// Main session key.
    public let mainSessionKey: String
    /// Default agent.
    public let defaultAgentID: String
    /// Normalized `scope|mainKey|defaultAgentId` contract.
    public let contract: String

    /// Parses a routing contract.
    public init?(contract: String?) {
        guard let components = OpenClawChatSessionRoutingContract.parse(contract) else { return nil }
        self.scope = components.scope
        self.mainSessionKey = components.mainKey
        self.defaultAgentID = components.defaultAgentID
        self.contract = "\(components.scope)|\(components.mainKey)|\(components.defaultAgentID)"
    }

    /// Builds an identity from its components.
    public init?(scope: String?, mainSessionKey: String?, defaultAgentID: String?) {
        guard let contract = OpenClawChatSessionRoutingContract.make(
            scope: scope,
            mainKey: mainSessionKey,
            defaultAgentID: defaultAgentID)
        else { return nil }
        self.init(contract: contract)
    }
}
