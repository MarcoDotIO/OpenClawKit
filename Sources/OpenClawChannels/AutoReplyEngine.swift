import Foundation
import OpenClawAgents
import OpenClawCore
import OpenClawMemory
import OpenClawProtocol
import OpenClawSkills

/// Outcome of handling one inbound message in ``AutoReplyEngine``.
public enum AutoReplyOutcome: Sendable, Equatable {
    /// The agent replied; `message` carries the full reply text, `deliveries` one entry per chunk.
    case replied(OutboundMessage, deliveries: [ChannelDeliveryOutcome])
    /// A runtime command (`/health`, `/status`, `/help`) was answered.
    case command(OutboundMessage)
    /// The sender must pair; a pairing code reply was sent when `message` is non-nil.
    case pairingChallenge(OutboundMessage?, code: String)
    /// The ingress access policy dropped the message (upstream reason code).
    case blocked(reasonCode: String)
    /// A group message lacked the required mention.
    case mentionRequired
    /// A guard suppressed the message (for example the bot-loop guard).
    case suppressed(reason: String)
    /// An ambient room event ran without auto-posting (`visibleReplies: message_tool`).
    case observed(OutboundMessage)

    /// The outbound message produced for this outcome, when any.
    public var outboundMessage: OutboundMessage? {
        switch self {
        case .replied(let message, _), .command(let message), .observed(let message):
            message
        case .pairingChallenge(let message, _):
            message
        case .blocked, .mentionRequired, .suppressed:
            nil
        }
    }
}

/// Error thrown by ``AutoReplyEngine/process(_:)`` when a message produces no reply.
public struct AutoReplyIngressRejection: Error, LocalizedError, Sendable, Equatable {
    /// Channel the message arrived on.
    public let channel: ChannelID
    /// Upstream reason code (`dm_policy_disabled`, `mention_required`, `bot_loop_suppressed`, ...).
    public let reasonCode: String

    /// Creates a rejection.
    /// - Parameters:
    ///   - channel: Channel id.
    ///   - reasonCode: Reason code.
    public init(channel: ChannelID, reasonCode: String) {
        self.channel = channel
        self.reasonCode = reasonCode
    }

    /// Localized description.
    public var errorDescription: String? {
        "Inbound \(self.channel.rawValue) message was not answered: \(self.reasonCode)"
    }
}

/// Group-chat handling options (upstream `messages.groupChat`).
public struct AutoReplyGroupChatOptions: Sendable, Equatable {
    /// What happens to unmentioned group messages in rooms that do not require a mention.
    public enum UnmentionedInbound: String, Sendable, Equatable, CaseIterable {
        /// Treat them as regular user requests (default).
        case userRequest = "user_request"
        /// Deliver them as ambient ``InboundEventKind/roomEvent`` turns.
        case roomEvent = "room_event"
    }

    /// Whether final replies are posted automatically.
    public enum VisibleReplies: String, Sendable, Equatable, CaseIterable {
        /// Post the final text automatically (default).
        case automatic
        /// Only post through an explicit message tool action.
        case messageTool = "message_tool"
    }

    /// Unmentioned group message handling.
    public var unmentionedInbound: UnmentionedInbound
    /// Reply visibility for ambient room events.
    public var visibleReplies: VisibleReplies

    /// Creates group-chat options.
    /// - Parameters:
    ///   - unmentionedInbound: Unmentioned group message handling.
    ///   - visibleReplies: Reply visibility.
    public init(unmentionedInbound: UnmentionedInbound = .userRequest, visibleReplies: VisibleReplies = .automatic) {
        self.unmentionedInbound = unmentionedInbound
        self.visibleReplies = visibleReplies
    }
}

/// End-to-end auto-reply pipeline coordinating access policy, routing, runtime, and delivery.
///
/// For every inbound message the engine:
/// 1. applies the ingress access policy (``ChannelAccessPolicyEvaluator``) unless the channel is
///    the SDK-owned WebChat surface or ``ChannelsCompatibilityConfig/ingressAccessPolicy`` is
///    `legacy-allow-all`; unknown DM senders get a pairing code (upstream default `dmPolicy: pairing`);
/// 2. suppresses bot-to-bot loops (``ChannelBotLoopGuard``);
/// 3. resolves the session (see ``ChannelSessionRouting``), answers runtime commands, sends an
///    acknowledgement reaction and typing keepalives, runs the agent, and
/// 4. delivers the reply in per-channel chunks (``ChannelTextChunker``); only the first chunk carries
///    the native reply target. Conversation memory records the full text once.
///
/// - Important: 2026.3.0 enforces upstream access defaults (`dmPolicy: pairing`,
///   `groupPolicy: allowlist`). Configure `allowFrom`/`dmPolicy` per channel, approve pairing
///   codes (``pairingStore``), or set `channels.compatibility.ingressAccessPolicy` to
///   `legacy-allow-all` to restore the previous admit-everything behavior.
public actor AutoReplyEngine {
    private let config: OpenClawConfig
    private let sessionStore: SessionStore
    private let channelRegistry: ChannelRegistry
    private let runtime: EmbeddedAgentRuntime
    private let conversationMemoryStore: ConversationMemoryStore?
    private let memoryContextLimit: Int
    private let typingHeartbeatIntervalMs: Int?
    private let diagnosticsSink: RuntimeDiagnosticSink?
    private let accessEvaluator = ChannelAccessPolicyEvaluator()
    private let groupChat: AutoReplyGroupChatOptions
    /// Pairing store used for DM pairing challenges; share it with ``registerChannelGatewayMethods(on:context:)``.
    nonisolated public let pairingStore: ChannelPairingStore
    /// Bot-loop guard shared across messages handled by this engine.
    nonisolated public let botLoopGuard: ChannelBotLoopGuard
    /// Join-introduction claims (one introduction per room per 90 days).
    nonisolated public let joinIntroClaims: ChannelJoinIntroClaimStore

    /// Creates an auto-reply engine.
    /// - Parameters:
    ///   - config: Runtime configuration.
    ///   - sessionStore: Session storage actor.
    ///   - channelRegistry: Adapter registry for outbound dispatch.
    ///   - runtime: Embedded runtime to execute prompts/tools.
    ///   - conversationMemoryStore: Optional persistent conversation memory store.
    ///   - memoryContextLimit: Number of turns included in prompt context.
    ///   - typingHeartbeatIntervalMs: Typing keepalive cadence; `nil` uses the per-channel default
    ///     (Telegram 4000 ms, others 3000 ms) or the channel's `typingIntervalMs`.
    ///   - diagnosticsSink: Optional diagnostics sink.
    ///   - pairingStore: DM pairing store (defaults to an in-memory store; pass a file-backed store
    ///     so approvals survive restarts).
    ///   - botLoopGuard: Bot-loop guard (defaults to a fresh guard).
    ///   - joinIntroClaims: Join-introduction claim store (defaults to in-memory claims).
    ///   - groupChat: Group-chat handling options.
    public init(
        config: OpenClawConfig,
        sessionStore: SessionStore,
        channelRegistry: ChannelRegistry,
        runtime: EmbeddedAgentRuntime,
        conversationMemoryStore: ConversationMemoryStore? = nil,
        memoryContextLimit: Int = 12,
        typingHeartbeatIntervalMs: Int? = nil,
        diagnosticsSink: RuntimeDiagnosticSink? = nil,
        pairingStore: ChannelPairingStore? = nil,
        botLoopGuard: ChannelBotLoopGuard? = nil,
        joinIntroClaims: ChannelJoinIntroClaimStore? = nil,
        groupChat: AutoReplyGroupChatOptions = AutoReplyGroupChatOptions()
    ) {
        self.config = config
        self.sessionStore = sessionStore
        self.channelRegistry = channelRegistry
        self.runtime = runtime
        self.conversationMemoryStore = conversationMemoryStore
        self.memoryContextLimit = max(1, memoryContextLimit)
        self.typingHeartbeatIntervalMs = typingHeartbeatIntervalMs.map { max(1, $0) }
        self.diagnosticsSink = diagnosticsSink
        self.pairingStore = pairingStore ?? ChannelPairingStore()
        self.botLoopGuard = botLoopGuard ?? ChannelBotLoopGuard()
        self.joinIntroClaims = joinIntroClaims ?? ChannelJoinIntroClaimStore()
        self.groupChat = groupChat
    }

    /// Processes an inbound message and returns the outbound response.
    ///
    /// Pairing challenges return the pairing reply. Messages that produce no reply (blocked by
    /// access policy, missing mention, suppressed) throw ``AutoReplyIngressRejection``; use
    /// ``processIfAllowed(_:)`` or ``handle(_:)`` to observe them without an error.
    /// - Parameter message: Inbound message envelope.
    /// - Returns: Outbound message delivered through channel registry.
    public func process(_ message: InboundMessage) async throws -> OutboundMessage {
        let outcome = try await self.handle(message)
        if let outbound = outcome.outboundMessage {
            return outbound
        }
        throw AutoReplyIngressRejection(channel: message.channel, reasonCode: Self.reasonCode(for: outcome))
    }

    /// Processes an inbound message, returning `nil` when nothing was sent.
    /// - Parameter message: Inbound message envelope.
    /// - Returns: The delivered reply (or pairing challenge), or `nil`.
    public func processIfAllowed(_ message: InboundMessage) async throws -> OutboundMessage? {
        let outcome = try await self.handle(message)
        if case .observed = outcome {
            return nil
        }
        return outcome.outboundMessage
    }

    /// Handles one inbound message and reports what happened.
    /// - Parameter message: Inbound message envelope.
    /// - Returns: Outcome.
    public func handle(_ message: InboundMessage) async throws -> AutoReplyOutcome {
        var message = message
        await self.emitDiagnostic(
            name: "inbound.received",
            sessionKey: nil,
            metadata: [
                "channel": message.channel.rawValue,
                "accountID": message.accountID ?? "",
                "peerID": message.peerID,
                "chatType": message.chatType.rawValue,
                "attachmentCount": String(message.attachments.count),
            ]
        )
        await self.channelRegistry.recordInbound(channel: message.channel)
        let policy = self.config.channels.messagingPolicy(for: message.channel.rawValue, accountID: message.accountID)

        // 1. Ingress access policy. Skill commands (`/skill`, `/<skill>`) need an authorized
        // sender like control commands do (upstream treats every registered command as one).
        var commandAuthorized = true
        let skillCommands = await self.skillCommandNames(for: message.text)
        if self.enforcesAccessPolicy(for: message.channel) {
            let evaluation = await self.accessEvaluator.evaluateDetailed(
                message,
                config: policy,
                store: self.pairingStore,
                additionalCommands: skillCommands
            )
            commandAuthorized = evaluation.commandAuthorized
            switch evaluation.decision {
            case .allow:
                break
            case .block(let reason):
                await self.emitDiagnostic(
                    name: "access.blocked",
                    sessionKey: nil,
                    metadata: ["channel": message.channel.rawValue, "reasonCode": reason]
                )
                return .blocked(reasonCode: reason)
            case .mentionRequired:
                await self.emitDiagnostic(
                    name: "access.blocked",
                    sessionKey: nil,
                    metadata: ["channel": message.channel.rawValue, "reasonCode": ChannelAccessReasonCode.mentionRequired.rawValue]
                )
                return .mentionRequired
            case .pairingRequired(let code, let created):
                return try await self.issuePairingChallenge(message, code: code, created: created)
            }
        }
        // Unmentioned traffic in rooms that do not require a mention becomes an ambient room event.
        if message.chatType != .direct,
           self.groupChat.unmentionedInbound == .roomEvent,
           (policy.groupConfig(for: message.peerID)?.requireMention ?? policy.requireMention ?? true) == false,
           message.wasMentioned != true,
           message.implicitMentionKinds.isEmpty,
           !ChannelAccessPolicyEvaluator.isControlCommand(message.text, additionalCommands: skillCommands)
        {
            message.eventKind = .roomEvent
        }

        // 2. Bot-loop protection.
        if case .suppressed(let until) = await self.botLoopGuard.check(message, policy: policy) {
            await self.emitDiagnostic(
                name: "bot_loop.suppressed",
                sessionKey: nil,
                metadata: [
                    "channel": message.channel.rawValue,
                    "cooldownUntilMs": String(Int64(until.timeIntervalSince1970 * 1_000)),
                ]
            )
            return .suppressed(reason: "bot_loop_suppressed")
        }

        // 3. Session resolution.
        let routingContext = ChannelSessionRouting.routingContext(for: message, config: self.config)
        let sessionKey = SessionKeyResolver.resolve(explicit: nil, context: routingContext, config: self.config)
        let resolvedAgentID = self.config.agents.resolvedAgentID(for: routingContext)
        let sessionRecord = await self.sessionStore.resolveOrCreate(
            sessionKey: sessionKey,
            defaultAgentID: resolvedAgentID,
            route: SessionRoute(
                channel: message.channel.rawValue,
                accountID: routingContext.accountID,
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

        if commandAuthorized, let commandReply = await self.handleCommandIfRequested(message, sessionKey: sessionKey) {
            await self.emitDiagnostic(
                name: "command.handled",
                sessionKey: sessionKey,
                metadata: [
                    "channel": commandReply.channel.rawValue,
                    "peerID": commandReply.peerID,
                ]
            )
            try await self.channelRegistry.send(commandReply)
            return .command(commandReply)
        }

        // 4. Acknowledgement reaction and typing.
        let ackHandle = await self.sendAckReactionIfNeeded(for: message, policy: policy, sessionKey: sessionKey)
        let typingTask = await self.startTypingHeartbeat(for: message, policy: policy, sessionKey: sessionKey)
        defer {
            typingTask?.cancel()
            if typingTask != nil {
                Task {
                    await self.stopTyping(for: message, sessionKey: sessionKey)
                }
            }
        }

        // 5. Runtime turn.
        let runtimeOutput = try await self.runTurn(
            message,
            sessionKey: sessionKey,
            routingAccountID: routingContext.accountID,
            resolvedSession: resolvedSession,
            fastMode: sessionRecord.fastMode,
            skillsAuthorized: commandAuthorized
        )
        typingTask?.cancel()

        let replyTarget = self.replyTarget(for: message, policy: policy)
        let outbound = OutboundMessage(
            channel: message.channel,
            accountID: message.accountID,
            peerID: message.peerID,
            text: runtimeOutput,
            replyToID: replyTarget.replyToID,
            threadID: replyTarget.threadID,
            chatType: message.chatType
        )
        if let store = self.conversationMemoryStore {
            await store.appendAssistantTurn(
                sessionKey: sessionKey,
                channel: outbound.channel.rawValue,
                accountID: routingContext.accountID,
                peerID: outbound.peerID,
                text: outbound.text
            )
            try await store.save()
        }

        if message.eventKind == .roomEvent, self.groupChat.visibleReplies == .messageTool {
            await self.emitDiagnostic(
                name: "outbound.suppressed",
                sessionKey: sessionKey,
                metadata: ["channel": outbound.channel.rawValue, "reason": "room_event_message_tool"]
            )
            await self.removeAckReaction(ackHandle, message: message)
            return .observed(outbound)
        }

        // 6. Chunked delivery.
        let deliveries = try await self.deliverChunks(outbound, policy: policy, replyMode: replyTarget.mode, sessionKey: sessionKey)
        await self.removeAckReaction(ackHandle, message: message)
        return .replied(outbound, deliveries: deliveries)
    }

    // MARK: - Access and pairing

    private func enforcesAccessPolicy(for channel: ChannelID) -> Bool {
        guard self.config.channels.compatibility.ingressAccessPolicy == .enforce else {
            return false
        }
        // The SDK-owned WebChat surface is authenticated by the host; upstream has no DM policy for it.
        return channel.metadata.distribution != .core
    }

    private func issuePairingChallenge(_ message: InboundMessage, code: String, created: Bool) async throws -> AutoReplyOutcome {
        await self.emitDiagnostic(
            name: "access.pairing_required",
            sessionKey: nil,
            metadata: [
                "channel": message.channel.rawValue,
                "created": String(created),
                "reasonCode": ChannelAccessReasonCode.dmPolicyPairingRequired.rawValue,
            ]
        )
        guard created else {
            // Upstream only replies when a new request is issued; repeat messages stay silent.
            return .pairingChallenge(nil, code: code)
        }
        let idLine = ChannelPairingReply.idLine(channel: message.channel, senderID: message.senderID ?? message.peerID)
        let reply = OutboundMessage(
            channel: message.channel,
            accountID: message.accountID,
            peerID: message.peerID,
            text: ChannelPairingReply.text(channel: message.channel, idLine: idLine, code: code),
            chatType: message.chatType
        )
        do {
            try await self.channelRegistry.send(reply)
        } catch {
            await self.emitDiagnostic(
                name: "access.pairing_reply_failed",
                sessionKey: nil,
                metadata: ["channel": message.channel.rawValue, "error": ChannelErrorText.describe(error)]
            )
        }
        return .pairingChallenge(reply, code: code)
    }

    private static func reasonCode(for outcome: AutoReplyOutcome) -> String {
        switch outcome {
        case .blocked(let reasonCode):
            reasonCode
        case .mentionRequired:
            ChannelAccessReasonCode.mentionRequired.rawValue
        case .suppressed(let reason):
            reason
        case .pairingChallenge:
            ChannelAccessReasonCode.dmPolicyPairingRequired.rawValue
        case .replied, .command, .observed:
            "none"
        }
    }

    // MARK: - Runtime turn

    private func runTurn(
        _ message: InboundMessage,
        sessionKey: String,
        routingAccountID: String?,
        resolvedSession: ResolvedSessionState,
        fastMode: Bool?,
        skillsAuthorized: Bool
    ) async throws -> String {
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
                accountID: routingAccountID,
                peerID: message.peerID,
                text: message.text
            )
            try await store.save()
        }
        // Skills run local processes with the sender's text: only for senders authorized to run
        // commands, and never from ambient room events.
        let skillOutput = skillsAuthorized && message.eventKind != .roomEvent
            ? try await self.invokeSkillIfRequested(message.text)
            : nil
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
            await self.emitDiagnostic(name: "skill.invoked", sessionKey: sessionKey, metadata: metadata)
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
            fastMode: fastMode,
            workspaceRootPath: self.config.agents.workspaceRoot,
            attachments: message.attachments
        )
        let runtimeOutput: String
        if self.shouldUseStreamingRuntime() {
            runtimeOutput = try await self.collectStreamingRuntimeOutput(request: runtimeRequest, sessionKey: sessionKey)
        } else {
            runtimeOutput = try await self.runtime.run(runtimeRequest).output
        }
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
        return runtimeOutput
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

    // MARK: - Delivery

    private func replyTarget(
        for message: InboundMessage,
        policy: ChannelMessagingPolicyConfig
    ) -> (replyToID: String?, threadID: String?, mode: ChannelReplyToMode) {
        let capabilities = message.channel.metadata.capabilities
        let mode = policy.replyToMode ?? .first
        let canReply = capabilities.reply || capabilities.threads
        let replyToID = (mode != .off && canReply) ? message.messageID : nil
        let threadID = capabilities.threads ? message.threadID : nil
        return (replyToID, threadID, mode)
    }

    private func deliverChunks(
        _ outbound: OutboundMessage,
        policy: ChannelMessagingPolicyConfig,
        replyMode: ChannelReplyToMode,
        sessionKey: String
    ) async throws -> [ChannelDeliveryOutcome] {
        let chunks = self.chunks(for: outbound, policy: policy)
        await self.emitDiagnostic(
            name: "outbound.dispatching",
            sessionKey: sessionKey,
            metadata: [
                "channel": outbound.channel.rawValue,
                "peerID": outbound.peerID,
                "chunkCount": String(chunks.count),
            ]
        )
        var deliveries: [ChannelDeliveryOutcome] = []
        for (index, text) in chunks.enumerated() {
            var chunk = outbound
            chunk.text = text
            if index > 0, replyMode != .all {
                chunk.replyToID = nil
            }
            do {
                let delivery = try await self.channelRegistry.send(chunk)
                deliveries.append(delivery)
                await self.emitDiagnostic(
                    name: "outbound.sent",
                    sessionKey: sessionKey,
                    metadata: [
                        "channel": outbound.channel.rawValue,
                        "peerID": outbound.peerID,
                        "attempts": String(delivery.attempts),
                        "status": delivery.status.rawValue,
                        "chunk": String(index + 1),
                    ]
                )
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
                        "chunk": String(index + 1),
                        "error": ChannelErrorText.describe(error),
                    ]
                )
                throw error
            }
        }
        return deliveries
    }

    private func chunks(for outbound: OutboundMessage, policy: ChannelMessagingPolicyConfig) -> [String] {
        let metadata = outbound.channel.metadata
        guard metadata.textChunking != nil || policy.textChunkLimit != nil else {
            return [outbound.text]
        }
        let richMessages = outbound.channel == .telegram && self.config.channels.telegram.richMessages
        let chunks = ChannelTextChunker.chunk(outbound.text, for: outbound.channel, policy: policy, richMessages: richMessages)
        return chunks.isEmpty ? [outbound.text] : chunks
    }

    // MARK: - Ack reactions

    private struct AckHandle: Sendable {
        let adapter: any ReactingChannelAdapter
        let messageID: String
        let emoji: String
    }

    private func sendAckReactionIfNeeded(
        for message: InboundMessage,
        policy: ChannelMessagingPolicyConfig,
        sessionKey: String
    ) async -> AckHandle? {
        guard let messageID = message.messageID,
              let adapter = await self.channelRegistry.adapter(for: message.channel) as? any ReactingChannelAdapter
        else {
            return nil
        }
        let capabilities = message.channel.metadata.capabilities
        let isGroup = message.chatType != .direct
        let should = ChannelAckReactions.shouldAckReaction(
            scope: policy.ackReactionScope,
            eventKind: message.eventKind,
            isDirect: message.chatType == .direct,
            isGroup: isGroup,
            isMentionableGroup: isGroup,
            canDetectMention: message.wasMentioned != nil,
            wasMentioned: message.wasMentioned == true || !message.implicitMentionKinds.isEmpty
        )
        guard should, capabilities.reactions else { return nil }
        let emoji = policy.ackReaction?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? ChannelAckReactions.defaultEmoji
        do {
            try await adapter.addReaction(peerID: message.peerID, messageID: messageID, emoji: emoji)
            await self.emitDiagnostic(name: "ack.reaction.sent", sessionKey: sessionKey, metadata: ["channel": message.channel.rawValue])
            return AckHandle(adapter: adapter, messageID: messageID, emoji: emoji)
        } catch {
            await self.emitDiagnostic(
                name: "ack.reaction.error",
                sessionKey: sessionKey,
                metadata: ["channel": message.channel.rawValue, "error": ChannelErrorText.describe(error)]
            )
            return nil
        }
    }

    private func removeAckReaction(_ handle: AckHandle?, message: InboundMessage) async {
        guard let handle else { return }
        try? await handle.adapter.removeReaction(peerID: message.peerID, messageID: handle.messageID, emoji: handle.emoji)
    }

    // MARK: - Typing

    private func startTypingHeartbeat(
        for message: InboundMessage,
        policy: ChannelMessagingPolicyConfig,
        sessionKey: String
    ) async -> Task<Void, Never>? {
        guard message.eventKind == .userRequest, policy.typingMode != .never else {
            return nil
        }
        guard let adapter = await self.channelRegistry.adapter(for: message.channel), adapter.supportsTypingIndicator else {
            return nil
        }
        let interval = policy.typingIntervalMs.map { max(1, $0) }
            ?? self.typingHeartbeatIntervalMs
            ?? ChannelTypingSettings.defaultKeepaliveIntervalMs(for: message.channel)
        let settings = ChannelTypingSettings(keepaliveIntervalMs: interval)
        var consecutiveFailures = 0
        do {
            try await adapter.sendTypingIndicator(accountID: message.accountID, peerID: message.peerID)
            await self.emitDiagnostic(
                name: "typing.heartbeat.started",
                sessionKey: sessionKey,
                metadata: ["channel": message.channel.rawValue]
            )
        } catch {
            consecutiveFailures = 1
            await self.emitDiagnostic(
                name: "typing.heartbeat.error",
                sessionKey: sessionKey,
                metadata: ["channel": message.channel.rawValue, "error": String(describing: error)]
            )
        }
        let startedAt = Date()
        let intervalNs = UInt64(settings.keepaliveIntervalMs) * 1_000_000
        let initialFailures = consecutiveFailures
        return Task {
            var failures = initialFailures
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: intervalNs)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                if Date().timeIntervalSince(startedAt) * 1_000 >= Double(settings.maxDurationMs) {
                    await self.emitDiagnostic(
                        name: "typing.heartbeat.ttl_exceeded",
                        sessionKey: sessionKey,
                        metadata: ["channel": message.channel.rawValue]
                    )
                    return
                }
                do {
                    // Ticks run sequentially, so a slow start never overlaps the next one.
                    try await adapter.sendTypingIndicator(accountID: message.accountID, peerID: message.peerID)
                    failures = 0
                    await self.emitDiagnostic(
                        name: "typing.heartbeat.tick",
                        sessionKey: sessionKey,
                        metadata: ["channel": message.channel.rawValue]
                    )
                } catch {
                    failures += 1
                    await self.emitDiagnostic(
                        name: "typing.heartbeat.error",
                        sessionKey: sessionKey,
                        metadata: ["channel": message.channel.rawValue, "error": ChannelErrorText.describe(error)]
                    )
                    if failures >= settings.maxConsecutiveFailures {
                        return
                    }
                }
            }
        }
    }

    private func stopTyping(for message: InboundMessage, sessionKey: String) async {
        if let adapter = await self.channelRegistry.adapter(for: message.channel) {
            try? await adapter.stopTypingIndicator(accountID: message.accountID, peerID: message.peerID)
        }
        await self.emitDiagnostic(
            name: "typing.heartbeat.stopped",
            sessionKey: sessionKey,
            metadata: ["channel": message.channel.rawValue]
        )
    }

    // MARK: - Helpers

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
        let rawCommand = trimmed
            .split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            .first
            .map { String($0).lowercased() } ?? ""
        let command = rawCommand.split(separator: "@", maxSplits: 1).first.map(String.init) ?? rawCommand

        switch command {
        case "/health", "/status":
            let snapshot = await self.channelRegistry.healthSnapshot(for: message.channel)
            let policy = await self.channelRegistry.retryPolicy()
            let text = """
            Channel: \(snapshot.channelID.rawValue)
            Status: \(snapshot.status.rawValue)
            ConsecutiveFailures: \(snapshot.consecutiveFailures)
            LastError: \(snapshot.lastError.map(ChannelErrorText.redact) ?? "none")
            RetryPolicy: attempts=\(policy.maxAttempts), initialBackoffMs=\(policy.initialBackoffMs), maxBackoffMs=\(policy.maxBackoffMs)
            SessionKey: \(sessionKey)
            """
            return OutboundMessage(
                channel: message.channel,
                accountID: message.accountID,
                peerID: message.peerID,
                text: text,
                threadID: message.threadID,
                chatType: message.chatType
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
                """,
                threadID: message.threadID,
                chatType: message.chatType
            )
        default:
            return nil
        }
    }

    /// Registered skill commands (`/skill` plus `/<name>` for user-invocable skills) when `text`
    /// starts with a slash; empty otherwise (skills are only loaded for slash messages).
    private func skillCommandNames(for text: String) async -> Set<String> {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") else { return [] }
        let workspaceRoot = self.config.agents.workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspaceRoot.isEmpty else { return [] }
        let registry = SkillRegistry(workspaceRoot: URL(fileURLWithPath: workspaceRoot, isDirectory: true))
        let skills = ((try? await registry.loadSkills()) ?? []).filter(\.invocation.userInvocable)
        guard !skills.isEmpty else { return [] }
        var names: Set<String> = ["/skill"]
        for skill in skills {
            let lookup = skill.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                .replacingOccurrences(of: "[\\s_]+", with: "-", options: .regularExpression)
            names.insert("/" + lookup)
        }
        for spec in SkillCommandNaming.commandSpecs(for: skills) {
            names.insert("/" + spec.name.lowercased())
        }
        return names
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

// MARK: - Join introductions

public extension AutoReplyEngine {
    /// Posts a one-time room introduction after the bot joins a group (upstream `joinIntro`).
    ///
    /// Runs only on channels with ``ChannelCapabilities/roomIntroductions`` when the channel's
    /// `joinIntro` is not `false`, at most once per (channel, account, room) per 90 days. The turn
    /// runs without tools, is bounded to 60 seconds, and sees at most 100 messages / 12,000
    /// characters of history wrapped as untrusted content.
    /// - Parameter event: Join event.
    /// - Returns: The posted introduction, or `nil` when skipped.
    func handleJoin(_ event: ChannelJoinEvent) async throws -> OutboundMessage? {
        guard ChannelJoinIntro.isSupported(event.channel) else {
            return nil
        }
        let policy = self.config.channels.messagingPolicy(for: event.channel.rawValue, accountID: event.accountID)
        guard policy.joinIntro ?? true else {
            return nil
        }
        guard await self.joinIntroClaims.claim(channel: event.channel, accountID: event.accountID, peerID: event.peerID) else {
            await self.emitDiagnostic(
                name: "join_intro.skipped",
                sessionKey: nil,
                metadata: ["channel": event.channel.rawValue, "reason": "already_claimed"]
            )
            return nil
        }
        let inbound = InboundMessage(
            channel: event.channel,
            accountID: event.accountID,
            peerID: event.peerID,
            text: "",
            chatType: event.chatType,
            eventKind: .roomEvent
        )
        let sessionKey = ChannelSessionRouting.sessionKey(for: inbound, config: self.config)
        let request = AgentRunRequest(
            sessionKey: sessionKey,
            prompt: ChannelJoinIntro.prompt(for: event),
            workspaceRootPath: self.config.agents.workspaceRoot
        )
        let runtime = self.runtime
        let output = try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                try await runtime.run(request).output
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(ChannelJoinIntro.turnTimeoutSeconds * 1_000_000_000))
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let text = output?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            await self.emitDiagnostic(
                name: "join_intro.skipped",
                sessionKey: sessionKey,
                metadata: ["channel": event.channel.rawValue, "reason": output == nil ? "timeout" : "empty"]
            )
            return nil
        }
        let outbound = OutboundMessage(
            channel: event.channel,
            accountID: event.accountID,
            peerID: event.peerID,
            text: text,
            chatType: event.chatType
        )
        _ = try await self.deliverChunks(outbound, policy: policy, replyMode: .off, sessionKey: sessionKey)
        await self.emitDiagnostic(name: "join_intro.posted", sessionKey: sessionKey, metadata: ["channel": event.channel.rawValue])
        return outbound
    }
}

private extension String {
    var nilIfEmpty: String? {
        self.isEmpty ? nil : self
    }
}
