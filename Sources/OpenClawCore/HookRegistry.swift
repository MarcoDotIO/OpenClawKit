import Foundation
import OpenClawProtocol

/// Lifecycle hook names emitted by runtime subsystems (upstream `PLUGIN_HOOK_NAMES`, OpenClaw 2026.9.6).
///
/// ``allCases`` lists the 42 upstream names in upstream declaration order. The retired
/// `before_agent_start` hook is kept as a deprecated alias: runtimes fire it right after
/// ``beforeAgentRun`` so handlers registered for the old name keep working.
public enum HookName: String, Sendable, Codable, CaseIterable {
    /// Before the provider/model for a run is resolved (model override).
    case beforeModelResolve = "before_model_resolve"
    /// Before a turn is prepared (prepend/append context).
    case agentTurnPrepare = "agent_turn_prepare"
    /// Before the prompt and system prompt are assembled.
    case beforePromptBuild = "before_prompt_build"
    /// Before the agent replies; a handler may claim the reply.
    case beforeAgentReply = "before_agent_reply"
    /// A model call started.
    case modelCallStarted = "model_call_started"
    /// A model call ended.
    case modelCallEnded = "model_call_ended"
    /// The exact model input of a call (observe-only).
    case llmInput = "llm_input"
    /// The model output of a call (observe-only).
    case llmOutput = "llm_output"
    /// Before the agent run finalizes (continue, revise, or finalize).
    case beforeAgentFinalize = "before_agent_finalize"
    /// The agent run ended.
    case agentEnd = "agent_end"
    /// Before transcript compaction.
    case beforeCompaction = "before_compaction"
    /// After transcript compaction.
    case afterCompaction = "after_compaction"
    /// Before a session reset.
    case beforeReset = "before_reset"
    /// An inbound message may be claimed by a plugin.
    case inboundClaim = "inbound_claim"
    /// A channel created a pending pairing request.
    case channelPairingRequested = "channel_pairing_requested"
    /// An inbound message was received.
    case messageReceived = "message_received"
    /// An outbound message is about to be sent (rewrite or cancel).
    case messageSending = "message_sending"
    /// An outbound reply payload is about to be sent.
    case replyPayloadSending = "reply_payload_sending"
    /// An outbound message was sent.
    case messageSent = "message_sent"
    /// Before a tool call executes (rewrite params, block, or require approval).
    case beforeToolCall = "before_tool_call"
    /// After a tool call finished (observe-only).
    case afterToolCall = "after_tool_call"
    /// Before a tool result message is persisted (rewrite).
    case toolResultPersist = "tool_result_persist"
    /// Before any transcript message is written (rewrite or block).
    case beforeMessageWrite = "before_message_write"
    /// A session started.
    case sessionStart = "session_start"
    /// A session ended.
    case sessionEnd = "session_end"
    /// Resolve the delivery target of a subagent (deprecated upstream).
    case subagentDeliveryTarget = "subagent_delivery_target"
    /// A subagent was spawned.
    case subagentSpawned = "subagent_spawned"
    /// Subagent progress (started/ended).
    case subagentProgress = "subagent_progress"
    /// A subagent ended.
    case subagentEnded = "subagent_ended"
    /// The gateway started.
    case gatewayStart = "gateway_start"
    /// The gateway is stopping.
    case gatewayStop = "gateway_stop"
    /// Contribute text to the heartbeat prompt.
    case heartbeatPromptContribution = "heartbeat_prompt_contribution"
    /// Cron jobs were reconciled with their declarations.
    case cronReconciled = "cron_reconciled"
    /// A cron job changed (added, updated, removed, started, finished, scheduled).
    case cronChanged = "cron_changed"
    /// Evaluate a skill proposal.
    case skillProposalEvaluate = "skill_proposal_evaluate"
    /// A skill proposal changed.
    case skillProposalChanged = "skill_proposal_changed"
    /// A skill changed.
    case skillChanged = "skill_changed"
    /// Before an inbound message is dispatched to the agent.
    case beforeDispatch = "before_dispatch"
    /// A reply is being dispatched.
    case replyDispatch = "reply_dispatch"
    /// Before a skill or plugin install (block with findings).
    case beforeInstall = "before_install"
    /// Gate before an agent run starts (pass or block).
    case beforeAgentRun = "before_agent_run"
    /// Resolve extra environment for exec.
    case resolveExecEnv = "resolve_exec_env"
    /// Retired upstream; fired right after ``beforeAgentRun`` for back-compat.
    @available(*, deprecated, renamed: "beforeAgentRun")
    case beforeAgentStart = "before_agent_start"

    /// The 42 upstream hook names in upstream declaration order (excludes the deprecated alias).
    public static let allCases: [HookName] = [
        .beforeModelResolve, .agentTurnPrepare, .beforePromptBuild, .beforeAgentReply,
        .modelCallStarted, .modelCallEnded, .llmInput, .llmOutput, .beforeAgentFinalize, .agentEnd,
        .beforeCompaction, .afterCompaction, .beforeReset, .inboundClaim, .channelPairingRequested,
        .messageReceived, .messageSending, .replyPayloadSending, .messageSent, .beforeToolCall,
        .afterToolCall, .toolResultPersist, .beforeMessageWrite, .sessionStart, .sessionEnd,
        .subagentDeliveryTarget, .subagentSpawned, .subagentProgress, .subagentEnded, .gatewayStart,
        .gatewayStop, .heartbeatPromptContribution, .cronReconciled, .cronChanged,
        .skillProposalEvaluate, .skillProposalChanged, .skillChanged, .beforeDispatch, .replyDispatch,
        .beforeInstall, .beforeAgentRun, .resolveExecEnv,
    ]

    /// Wire name of the retired `before_agent_start` hook.
    public static let legacyBeforeAgentStartName = "before_agent_start"

    /// The deprecated `before_agent_start` alias, resolved without a deprecation warning.
    public static var legacyBeforeAgentStart: HookName {
        HookName(rawValue: Self.legacyBeforeAgentStartName) ?? .beforeAgentRun
    }

    /// Whether this is the retired `before_agent_start` alias.
    public var isDeprecatedAlias: Bool {
        self.rawValue == Self.legacyBeforeAgentStartName
    }

    /// Hooks whose `block: true` / `cancel: true` result is terminal (stops lower-priority handlers).
    public var hasTerminalDecision: Bool {
        switch self {
        case .beforeToolCall, .beforeInstall, .messageSending, .beforeAgentRun, .beforeMessageWrite:
            return true
        default:
            return false
        }
    }
}

/// Hook execution context.
public struct HookContext: Sendable, Equatable {
    /// Optional run identifier.
    public var runID: String?
    /// Optional session key.
    public var sessionKey: String?
    /// Optional agent identifier.
    public var agentID: String?
    /// Typed event payload (JSON form of the hook's event struct, for example ``BeforeToolCallEvent``).
    public var event: AnyCodable?
    /// Arbitrary metadata payload.
    public var metadata: [String: AnyCodable]

    /// Creates a hook execution context.
    /// - Parameters:
    ///   - runID: Optional run identifier.
    ///   - sessionKey: Optional session key.
    ///   - agentID: Optional agent identifier.
    ///   - event: Optional typed event payload in JSON form.
    ///   - metadata: Arbitrary metadata payload.
    public init(
        runID: String? = nil,
        sessionKey: String? = nil,
        agentID: String? = nil,
        event: AnyCodable? = nil,
        metadata: [String: AnyCodable] = [:]
    ) {
        self.runID = runID
        self.sessionKey = sessionKey
        self.agentID = agentID
        self.event = event
        self.metadata = metadata
    }

    /// Decodes ``event`` into a typed hook event.
    /// - Parameter type: Event type.
    /// - Returns: The decoded event, or `nil` when absent or not decodable.
    public func decodeEvent<Event: Decodable>(_ type: Event.Type = Event.self) -> Event? {
        guard let event else { return nil }
        return HookPayloadCoding.decode(type, from: event)
    }
}

/// Hook return value.
public struct HookResult: Sendable, Equatable {
    /// Arbitrary metadata returned by hook handlers.
    public var metadata: [String: AnyCodable]
    /// Typed result payload (JSON form of the hook's result struct, for example ``BeforeToolCallDecision``).
    public var payload: AnyCodable?

    /// Creates a hook result payload.
    /// - Parameters:
    ///   - metadata: Result metadata map.
    ///   - payload: Optional typed result in JSON form.
    public init(metadata: [String: AnyCodable] = [:], payload: AnyCodable? = nil) {
        self.metadata = metadata
        self.payload = payload
    }

    /// Decodes ``payload`` into a typed hook result.
    /// - Parameter type: Result type.
    /// - Returns: The decoded result, or `nil` when absent or not decodable.
    public func decodePayload<Result: Decodable>(_ type: Result.Type = Result.self) -> Result? {
        guard let payload else { return nil }
        return HookPayloadCoding.decode(type, from: payload)
    }
}

/// Async hook handler signature.
public typealias HookHandler = @Sendable (HookContext) async throws -> HookResult?

/// Stable identifier returned by ``HookRegistry/register(_:priority:pluginID:handler:)``.
public struct HookRegistrationID: RawRepresentable, Sendable, Hashable, Codable {
    /// Identifier value.
    public let rawValue: String

    /// Creates an identifier.
    /// - Parameter rawValue: Identifier value.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Snapshot of one hook registration (diagnostics and `hooks.status`).
public struct HookRegistrationInfo: Sendable, Equatable, Codable {
    /// Registration identifier.
    public let id: HookRegistrationID
    /// Hook name.
    public let hook: HookName
    /// Owning plugin, when registered through a plugin.
    public let pluginID: String?
    /// Priority (higher runs first).
    public let priority: Int

    /// Creates a registration snapshot.
    /// - Parameters:
    ///   - id: Registration identifier.
    ///   - hook: Hook name.
    ///   - pluginID: Owning plugin.
    ///   - priority: Priority.
    public init(id: HookRegistrationID, hook: HookName, pluginID: String?, priority: Int) {
        self.id = id
        self.hook = hook
        self.pluginID = pluginID
        self.priority = priority
    }
}

/// Actor-backed registry for lifecycle hook handlers shared by the runtime and plugins.
///
/// Handlers run sequentially: higher ``HookRegistrationInfo/priority`` first, ties in registration
/// order. The typed runners (``runBeforeToolCall(_:context:)`` and friends) implement upstream merge
/// rules: `block: true` / `cancel: true` on terminal hooks stops lower-priority handlers
/// (`block: false` is a no-op), rewrites chain (each handler observes the previous rewrite), and
/// handler errors fail open except for ``HookName/beforeAgentRun`` which fails closed (blocks).
public actor HookRegistry {
    private struct Entry: Sendable {
        let info: HookRegistrationInfo
        let sequence: Int
        let handler: HookHandler
    }

    private var entries: [HookName: [Entry]] = [:]
    private var nextSequence = 0
    private let diagnostics: RuntimeDiagnosticSink?

    /// Creates an empty hook registry.
    /// - Parameter diagnostics: Optional sink receiving `hooks.handler_failed` events for fail-open errors.
    public init(diagnostics: RuntimeDiagnosticSink? = nil) {
        self.diagnostics = diagnostics
    }

    // MARK: - Registration

    /// Registers a hook handler.
    /// - Parameters:
    ///   - hook: Hook name.
    ///   - priority: Priority; higher runs first, ties run in registration order.
    ///   - pluginID: Owning plugin (used by ``unregisterAll(pluginID:)`` and `hooks.status`).
    ///   - handler: Async hook handler.
    /// - Returns: Registration identifier for ``unregister(_:)``.
    @discardableResult
    public func register(
        _ hook: HookName,
        priority: Int = 0,
        pluginID: String? = nil,
        handler: @escaping HookHandler
    ) -> HookRegistrationID {
        self.nextSequence += 1
        let id = HookRegistrationID(rawValue: "hook-\(self.nextSequence)-\(UUID().uuidString.lowercased())")
        let trimmedPlugin = pluginID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let info = HookRegistrationInfo(
            id: id,
            hook: hook,
            pluginID: trimmedPlugin?.isEmpty == false ? trimmedPlugin : nil,
            priority: priority
        )
        var current = self.entries[hook] ?? []
        current.append(Entry(info: info, sequence: self.nextSequence, handler: handler))
        self.entries[hook] = current
        return id
    }

    /// Registers a typed hook handler.
    ///
    /// The handler receives the decoded ``HookContext/event``; contexts without a decodable event
    /// skip the handler. A non-`nil` return value is encoded into ``HookResult/payload``.
    /// - Parameters:
    ///   - hook: Hook name.
    ///   - priority: Priority; higher runs first.
    ///   - pluginID: Owning plugin.
    ///   - event: Event type.
    ///   - handler: Typed handler.
    /// - Returns: Registration identifier.
    @discardableResult
    public func register<Event: Decodable & Sendable, Result: Encodable & Sendable>(
        _ hook: HookName,
        priority: Int = 0,
        pluginID: String? = nil,
        event: Event.Type,
        handler: @escaping @Sendable (Event, HookContext) async throws -> Result?
    ) -> HookRegistrationID {
        self.register(hook, priority: priority, pluginID: pluginID) { context in
            guard let decoded = context.decodeEvent(Event.self) else {
                return nil
            }
            guard let result = try await handler(decoded, context) else {
                return nil
            }
            return HookResult(payload: try AnyCodable(encoding: result))
        }
    }

    /// Removes one registration.
    /// - Parameter id: Registration identifier.
    /// - Returns: `true` when a registration was removed.
    @discardableResult
    public func unregister(_ id: HookRegistrationID) -> Bool {
        for (hook, list) in self.entries {
            if let index = list.firstIndex(where: { $0.info.id == id }) {
                var updated = list
                updated.remove(at: index)
                self.entries[hook] = updated.isEmpty ? nil : updated
                return true
            }
        }
        return false
    }

    /// Removes every registration owned by a plugin.
    /// - Parameter pluginID: Plugin identifier.
    /// - Returns: Number of removed registrations.
    @discardableResult
    public func unregisterAll(pluginID: String) -> Int {
        var removed = 0
        for (hook, list) in self.entries {
            let kept = list.filter { $0.info.pluginID != pluginID }
            removed += list.count - kept.count
            self.entries[hook] = kept.isEmpty ? nil : kept
        }
        return removed
    }

    /// Registrations for a hook in execution order.
    /// - Parameter hook: Hook name.
    /// - Returns: Registration snapshots.
    public func registrations(for hook: HookName) -> [HookRegistrationInfo] {
        self.ordered(hook).map(\.info)
    }

    /// Every registration, grouped by hook in ``HookName/allCases`` order (deprecated alias last).
    /// - Returns: Registration snapshots.
    public func allRegistrations() -> [HookRegistrationInfo] {
        let names = HookName.allCases + [HookName.legacyBeforeAgentStart]
        return names.flatMap { self.registrations(for: $0) }
    }

    /// Whether any handler is registered for a hook.
    /// - Parameter hook: Hook name.
    /// - Returns: `true` when at least one handler exists.
    public func hasHandlers(for hook: HookName) -> Bool {
        !(self.entries[hook] ?? []).isEmpty
    }

    // MARK: - Emission

    /// Emits a hook and collects non-nil handler results in execution order.
    ///
    /// Errors thrown by a handler propagate to the caller (legacy behavior); the typed runners below
    /// fail open instead.
    /// - Parameters:
    ///   - hook: Hook name to emit.
    ///   - context: Hook execution context.
    /// - Returns: Collected hook results.
    public func emit(_ hook: HookName, context: HookContext) async throws -> [HookResult] {
        var results: [HookResult] = []
        for entry in self.ordered(hook) {
            if let result = try await entry.handler(context) {
                results.append(result)
            }
        }
        return results
    }

    /// Emits an observe-only hook with a typed event; handler errors are reported and ignored.
    /// - Parameters:
    ///   - hook: Hook name.
    ///   - event: Typed event payload.
    ///   - context: Base context (its `event` is replaced).
    public func emitObserving<Event: Encodable & Sendable>(_ hook: HookName, event: Event, context: HookContext = HookContext()) async {
        var context = context
        context.event = HookPayloadCoding.encode(event)
        for entry in self.ordered(hook) {
            do {
                _ = try await entry.handler(context)
            } catch {
                await self.reportFailure(hook: hook, entry: entry, error: error)
            }
        }
    }

    /// Runs a modifying hook with a custom merge (the building block of the typed runners).
    ///
    /// Each handler sees `eventForHandler(event, merged)` so rewrites chain. After each merge,
    /// `shouldStop` decides whether the merged result is terminal.
    /// - Parameters:
    ///   - hook: Hook name.
    ///   - event: Initial event.
    ///   - context: Base context.
    ///   - failClosed: Result used when a handler throws (`nil` fails open).
    ///   - eventForHandler: Event passed to the next handler given the merged result so far.
    ///   - merge: Merges the accumulated result with the next handler's result.
    ///   - shouldStop: Whether the merged result stops lower-priority handlers.
    /// - Returns: The merged result, or `nil` when no handler returned one.
    public func runModifying<Event: Codable & Sendable, Result: Codable & Sendable>(
        _ hook: HookName,
        event: Event,
        context: HookContext = HookContext(),
        failClosed: Result? = nil,
        eventForHandler: @Sendable (Event, Result?) -> Event = { event, _ in event },
        merge: @Sendable (Result?, Result) -> Result = { _, next in next },
        shouldStop: @Sendable (Result) -> Bool = { _ in false }
    ) async -> Result? {
        var merged: Result?
        for entry in self.ordered(hook) {
            var handlerContext = context
            handlerContext.event = HookPayloadCoding.encode(eventForHandler(event, merged))
            let next: Result?
            do {
                next = try await entry.handler(handlerContext)?.decodePayload(Result.self)
            } catch {
                await self.reportFailure(hook: hook, entry: entry, error: error)
                if let failClosed {
                    return merge(merged, failClosed)
                }
                continue
            }
            guard let next else { continue }
            let combined = merge(merged, next)
            merged = combined
            if shouldStop(combined) {
                break
            }
        }
        return merged
    }

    // MARK: - Typed runners

    /// Runs `before_tool_call`: params rewrites chain, `block: true` is sticky and terminal, the first
    /// approval request wins (params are frozen once approval is requested).
    /// - Parameters:
    ///   - event: Tool call about to run.
    ///   - context: Base context.
    /// - Returns: Merged decision, or `nil` when no handler decided.
    public func runBeforeToolCall(_ event: BeforeToolCallEvent, context: HookContext = HookContext()) async -> BeforeToolCallDecision? {
        await self.runModifying(
            .beforeToolCall,
            event: event,
            context: context,
            eventForHandler: { event, merged in
                var next = event
                if let params = merged?.params {
                    next.params = params
                }
                return next
            },
            merge: { accumulated, next in
                guard let accumulated else {
                    return BeforeToolCallDecision(
                        params: next.params,
                        block: next.block == true ? true : nil,
                        blockReason: next.blockReason,
                        requireApproval: next.requireApproval
                    )
                }
                if accumulated.block == true {
                    return accumulated
                }
                let approvalRequested = accumulated.requireApproval != nil
                return BeforeToolCallDecision(
                    params: approvalRequested ? accumulated.params : (next.params ?? accumulated.params),
                    block: (accumulated.block == true || next.block == true) ? true : nil,
                    blockReason: next.blockReason ?? accumulated.blockReason,
                    requireApproval: accumulated.requireApproval ?? next.requireApproval
                )
            },
            shouldStop: { $0.block == true }
        )
    }

    /// Runs `before_agent_run` (fail-closed gate): the first `block` wins and stops lower-priority
    /// handlers; handler errors block. Afterwards the deprecated `before_agent_start` alias fires
    /// (observe-only) when the run passes.
    /// - Parameters:
    ///   - event: Run about to start.
    ///   - context: Base context.
    /// - Returns: The gate decision (`.pass` when no handler decided).
    public func runBeforeAgentRun(_ event: BeforeAgentRunEvent, context: HookContext = HookContext()) async -> InputGateDecision {
        let decision = await self.runModifying(
            .beforeAgentRun,
            event: event,
            context: context,
            failClosed: InputGateDecision.block(reason: "before_agent_run handler failed"),
            merge: { accumulated, next in
                guard let accumulated else { return next }
                if case .block = accumulated { return accumulated }
                return next
            },
            shouldStop: { $0.isBlock }
        ) ?? .pass
        if !decision.isBlock {
            await self.emitObserving(HookName.legacyBeforeAgentStart, event: event, context: context)
        }
        return decision
    }

    /// Runs `before_model_resolve`: the first defined override wins (higher priority first).
    /// - Parameters:
    ///   - event: Model resolution request.
    ///   - context: Base context.
    /// - Returns: Merged overrides.
    public func runBeforeModelResolve(_ event: BeforeModelResolveEvent, context: HookContext = HookContext()) async -> BeforeModelResolveResult? {
        await self.runModifying(.beforeModelResolve, event: event, context: context, merge: { accumulated, next in
            BeforeModelResolveResult(
                modelOverride: accumulated?.modelOverride ?? next.modelOverride,
                providerOverride: accumulated?.providerOverride ?? next.providerOverride
            )
        })
    }

    /// Runs `before_prompt_build`: the first system prompt wins, context segments concatenate with a
    /// blank line, and `toolsAllow` lists intersect (`*` matches everything).
    /// - Parameters:
    ///   - event: Prompt build input.
    ///   - context: Base context.
    /// - Returns: Merged prompt contributions.
    public func runBeforePromptBuild(_ event: BeforePromptBuildEvent, context: HookContext = HookContext()) async -> BeforePromptBuildResult? {
        await self.runModifying(.beforePromptBuild, event: event, context: context, merge: { accumulated, next in
            BeforePromptBuildResult(
                systemPrompt: accumulated?.systemPrompt ?? next.systemPrompt,
                prependContext: Self.concatSegments(accumulated?.prependContext, next.prependContext),
                appendContext: Self.concatSegments(accumulated?.appendContext, next.appendContext),
                prependSystemContext: Self.concatSegments(accumulated?.prependSystemContext, next.prependSystemContext),
                appendSystemContext: Self.concatSegments(accumulated?.appendSystemContext, next.appendSystemContext),
                toolsAllow: Self.intersectToolsAllow(accumulated?.toolsAllow, next.toolsAllow)
            )
        })
    }

    /// Runs `before_agent_reply`: the first `handled: true` result claims the reply.
    /// - Parameters:
    ///   - event: Reply candidate.
    ///   - context: Base context.
    /// - Returns: The claiming result, or `nil` when no handler claimed.
    public func runBeforeAgentReply(_ event: BeforeAgentReplyEvent, context: HookContext = HookContext()) async -> BeforeAgentReplyResult? {
        let result: BeforeAgentReplyResult? = await self.runModifying(
            .beforeAgentReply,
            event: event,
            context: context,
            merge: { (accumulated: BeforeAgentReplyResult?, next: BeforeAgentReplyResult) -> BeforeAgentReplyResult in
                if let accumulated, accumulated.handled { return accumulated }
                return next
            },
            shouldStop: { $0.handled }
        )
        return result?.handled == true ? result : nil
    }

    /// Runs `tool_result_persist`: each handler may replace the message passed to the next one.
    /// - Parameters:
    ///   - event: Tool result about to be persisted.
    ///   - context: Base context.
    /// - Returns: The final replacement message, or `nil` when unchanged.
    public func runToolResultPersist(_ event: ToolResultPersistEvent, context: HookContext = HookContext()) async -> ToolResultPersistResult? {
        await self.runModifying(
            .toolResultPersist,
            event: event,
            context: context,
            eventForHandler: { event, merged in
                var next = event
                if let message = merged?.message { next.message = message }
                return next
            },
            merge: { accumulated, next in ToolResultPersistResult(message: next.message ?? accumulated?.message) }
        )
    }

    /// Runs `before_message_write`: `block: true` is terminal; message replacements chain.
    /// - Parameters:
    ///   - event: Message about to be written.
    ///   - context: Base context.
    /// - Returns: `block: true`, a replacement message, or `nil` when unchanged.
    public func runBeforeMessageWrite(_ event: BeforeMessageWriteEvent, context: HookContext = HookContext()) async -> BeforeMessageWriteResult? {
        let result: BeforeMessageWriteResult? = await self.runModifying(
            .beforeMessageWrite,
            event: event,
            context: context,
            eventForHandler: { (event: BeforeMessageWriteEvent, merged: BeforeMessageWriteResult?) -> BeforeMessageWriteEvent in
                var next = event
                if let message = merged?.message { next.message = message }
                return next
            },
            merge: { (accumulated: BeforeMessageWriteResult?, next: BeforeMessageWriteResult) -> BeforeMessageWriteResult in
                if let accumulated, accumulated.block == true { return accumulated }
                return BeforeMessageWriteResult(block: next.block == true ? true : nil, message: next.message ?? accumulated?.message)
            },
            shouldStop: { $0.block == true }
        )
        if result?.block == true {
            return BeforeMessageWriteResult(block: true)
        }
        return result?.message == nil ? nil : result
    }

    /// Runs `message_sending`: `cancel: true` is terminal; content rewrites chain.
    /// - Parameters:
    ///   - event: Outbound message.
    ///   - context: Base context.
    /// - Returns: Merged result.
    public func runMessageSending(_ event: MessageSendingEvent, context: HookContext = HookContext()) async -> MessageSendingResult? {
        await self.runModifying(
            .messageSending,
            event: event,
            context: context,
            eventForHandler: { (event: MessageSendingEvent, merged: MessageSendingResult?) -> MessageSendingEvent in
                var next = event
                if let content = merged?.content { next.content = content }
                return next
            },
            merge: { (accumulated: MessageSendingResult?, next: MessageSendingResult) -> MessageSendingResult in
                if let accumulated, accumulated.cancel == true { return accumulated }
                return MessageSendingResult(
                    content: next.content ?? accumulated?.content,
                    cancel: next.cancel == true ? true : nil,
                    cancelReason: next.cancelReason ?? accumulated?.cancelReason,
                    metadata: next.metadata ?? accumulated?.metadata
                )
            },
            shouldStop: { $0.cancel == true }
        )
    }

    /// Runs `before_install`: findings accumulate, `block: true` is terminal.
    /// - Parameters:
    ///   - event: Install request.
    ///   - context: Base context.
    /// - Returns: Merged result.
    public func runBeforeInstall(_ event: BeforeInstallEvent, context: HookContext = HookContext()) async -> BeforeInstallResult? {
        await self.runModifying(
            .beforeInstall,
            event: event,
            context: context,
            merge: { accumulated, next in
                BeforeInstallResult(
                    findings: (accumulated?.findings ?? []) + (next.findings ?? []),
                    block: (accumulated?.block == true || next.block == true) ? true : nil,
                    blockReason: next.blockReason ?? accumulated?.blockReason
                )
            },
            shouldStop: { $0.block == true }
        )
    }

    // MARK: - Helpers

    private func ordered(_ hook: HookName) -> [Entry] {
        (self.entries[hook] ?? []).sorted { lhs, rhs in
            if lhs.info.priority != rhs.info.priority {
                return lhs.info.priority > rhs.info.priority
            }
            return lhs.sequence < rhs.sequence
        }
    }

    private func reportFailure(hook: HookName, entry: Entry, error: Error) async {
        guard let diagnostics else { return }
        await diagnostics(
            RuntimeDiagnosticEvent(
                subsystem: "hooks",
                name: "hooks.handler_failed",
                metadata: [
                    "hook": hook.rawValue,
                    "pluginID": entry.info.pluginID ?? "",
                    "error": String(describing: error),
                ]
            )
        )
    }

    static func concatSegments(_ left: String?, _ right: String?) -> String? {
        if let left, let right, !left.isEmpty, !right.isEmpty {
            return left + "\n\n" + right
        }
        if let right, !right.isEmpty { return right }
        return left
    }

    static func intersectToolsAllow(_ left: [String]?, _ right: [String]?) -> [String]? {
        guard let right else { return left }
        guard let left else { return right }
        if left.isEmpty || right.isEmpty { return [] }
        let normalizedLeft = left.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let normalizedRight = right.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        if normalizedLeft.contains("*") { return normalizedRight }
        if normalizedRight.contains("*") { return normalizedLeft }
        let rightSet = Set(normalizedRight)
        var seen = Set<String>()
        return normalizedLeft.filter { rightSet.contains($0) && seen.insert($0).inserted }
    }
}

/// JSON bridging used to carry typed hook events and results through ``HookContext`` and ``HookResult``.
public enum HookPayloadCoding {
    /// Encodes a typed payload into its JSON form (`nil` when it cannot be encoded).
    /// - Parameter value: Payload.
    /// - Returns: JSON form.
    public static func encode<Value: Encodable>(_ value: Value) -> AnyCodable? {
        try? AnyCodable(encoding: value)
    }

    /// Decodes a typed payload from its JSON form.
    /// - Parameters:
    ///   - type: Payload type.
    ///   - value: JSON form.
    /// - Returns: The decoded payload, or `nil`.
    public static func decode<Value: Decodable>(_ type: Value.Type, from value: AnyCodable) -> Value? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
