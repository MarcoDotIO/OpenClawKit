import Foundation
import Testing
@testable import OpenClawKit

@Suite("Auto-reply access policy, pairing and delivery", .serialized)
struct ChannelAutoReplyAccessTests {
    actor RecordingAdapter: ReactingChannelAdapter {
        let id: ChannelID
        private(set) var sent: [OutboundMessage] = []
        private(set) var reactions: [(messageID: String, emoji: String, removed: Bool)] = []
        private(set) var typingStarts = 0
        private(set) var typingStops = 0

        init(id: ChannelID) {
            self.id = id
        }

        nonisolated var supportsTypingIndicator: Bool {
            true
        }

        func start() async throws {}
        func stop() async {}

        func send(_ message: OutboundMessage) async throws {
            self.sent.append(message)
        }

        func sendTypingIndicator(accountID _: String?, peerID _: String) async throws {
            self.typingStarts += 1
        }

        func stopTypingIndicator(accountID _: String?, peerID _: String) async throws {
            self.typingStops += 1
        }

        func addReaction(peerID _: String, messageID: String, emoji: String) async throws {
            self.reactions.append((messageID, emoji, false))
        }

        func removeReaction(peerID _: String, messageID: String, emoji: String) async throws {
            self.reactions.append((messageID, emoji, true))
        }
    }

    actor CountingProvider: ModelProvider {
        nonisolated let id = "fixed"
        let text: String
        private(set) var calls = 0

        init(text: String) {
            self.text = text
        }

        func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
            self.calls += 1
            return ModelGenerationResponse(text: self.text, providerID: self.id, modelID: "fixed")
        }
    }

    actor DiagnosticCollector {
        private(set) var events: [RuntimeDiagnosticEvent] = []
        func append(_ event: RuntimeDiagnosticEvent) {
            self.events.append(event)
        }
    }

    struct Harness {
        let engine: AutoReplyEngine
        let adapter: RecordingAdapter
        let provider: CountingProvider
        let sessionStore: SessionStore
        let diagnostics: DiagnosticCollector
        let root: URL
    }

    private func makeHarness(
        channel: ChannelID = .telegram,
        channels: ChannelsConfig = ChannelsConfig(),
        output: String = "reply",
        groupChat: AutoReplyGroupChatOptions = AutoReplyGroupChatOptions(),
        workspaceRoot: URL? = nil
    ) async throws -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-autoreply-access", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var agents = AgentsConfig()
        if let workspaceRoot {
            agents = AgentsConfig(defaultAgentID: "main", workspaceRoot: workspaceRoot.path)
        }
        let sessionStore = SessionStore(fileURL: root.appendingPathComponent("sessions.json"))
        let registry = ChannelRegistry(
            sendRetryPolicy: ChannelSendRetryPolicy(maxAttempts: 1),
            sendThrottlePolicy: ChannelSendThrottlePolicy()
        )
        let adapter = RecordingAdapter(id: channel)
        await registry.register(adapter)
        let provider = CountingProvider(text: output)
        let runtime = EmbeddedAgentRuntime()
        await runtime.registerModelProvider(provider)
        try await runtime.setDefaultModelProviderID("fixed")
        let diagnostics = DiagnosticCollector()
        let engine = AutoReplyEngine(
            config: OpenClawConfig(agents: agents, channels: channels, models: ModelsConfig(defaultProviderID: "fixed")),
            sessionStore: sessionStore,
            channelRegistry: registry,
            runtime: runtime,
            typingHeartbeatIntervalMs: 10,
            diagnosticsSink: { event in await diagnostics.append(event) },
            groupChat: groupChat
        )
        return Harness(engine: engine, adapter: adapter, provider: provider, sessionStore: sessionStore, diagnostics: diagnostics, root: root)
    }

    private func dm(_ sender: String = "42", text: String = "hello", messageID: String? = nil) -> InboundMessage {
        InboundMessage(channel: .telegram, peerID: sender, text: text, senderID: sender, chatType: .direct, messageID: messageID)
    }

    @Test
    func unknownDMSenderPairsBeforeTheModelRuns() async throws {
        let harness = try await self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let first = try await harness.engine.handle(self.dm())
        guard case .pairingChallenge(let reply?, let code) = first else {
            Issue.record("expected a pairing challenge, got \(first)")
            return
        }
        #expect(reply.text.contains("Pairing code:"))
        #expect(reply.text.contains("openclaw pairing approve telegram \(code)"))
        #expect(reply.text.contains("Your Telegram user id: 42"))
        #expect(await harness.adapter.sent.count == 1)
        #expect(await harness.provider.calls == 0)

        let repeated = try await harness.engine.handle(self.dm())
        #expect(repeated == .pairingChallenge(nil, code: code))
        #expect(await harness.adapter.sent.count == 1)

        _ = try await harness.engine.pairingStore.approve(channel: .telegram, code: code)
        let approved = try await harness.engine.handle(self.dm())
        guard case .replied(let outbound, _) = approved else {
            Issue.record("expected a reply after approval, got \(approved)")
            return
        }
        #expect(outbound.text == "reply")
        #expect(await harness.provider.calls == 1)
    }

    @Test
    func blockedGroupMessagesEmitRedactedDiagnostics() async throws {
        let harness = try await self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let group = InboundMessage(channel: .telegram, peerID: "-100", text: "hi", senderID: "secret-sender", chatType: .group, wasMentioned: true)

        #expect(try await harness.engine.handle(group) == .blocked(reasonCode: "group_policy_empty_allowlist"))
        #expect(try await harness.engine.processIfAllowed(group) == nil)
        await #expect(throws: AutoReplyIngressRejection.self) {
            _ = try await harness.engine.process(group)
        }
        let blocked = await harness.diagnostics.events.first { $0.name == "access.blocked" }
        #expect(blocked?.metadata["reasonCode"] == "group_policy_empty_allowlist")
        #expect(blocked?.metadata.values.contains("secret-sender") == false)
        #expect(await harness.provider.calls == 0)
    }

    @Test
    func legacyAllowAllRestoresPreviousBehavior() async throws {
        let harness = try await self.makeHarness(
            channels: ChannelsConfig(compatibility: ChannelsCompatibilityConfig(ingressAccessPolicy: .legacyAllowAll))
        )
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let outbound = try await harness.engine.process(self.dm())
        #expect(outbound.text == "reply")
    }

    @Test
    func chunksLongRepliesAndOnlyTheFirstChunkRepliesNatively() async throws {
        let long = (1...3).map { String(repeating: "paragraph\($0) ", count: 300) }.joined(separator: "\n\n")
        let harness = try await self.makeHarness(
            channels: ChannelsConfig(telegram: TelegramChannelConfig(policy: ChannelMessagingPolicyConfig(dmPolicy: .open))),
            output: long
        )
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let outcome = try await harness.engine.handle(self.dm(messageID: "777"))
        guard case .replied(let outbound, let deliveries) = outcome else {
            Issue.record("expected reply, got \(outcome)")
            return
        }
        let sent = await harness.adapter.sent
        #expect(sent.count >= 2)
        #expect(deliveries.count == sent.count)
        #expect(sent.allSatisfy { $0.text.count <= 4_000 })
        #expect(sent.first?.replyToID == "777")
        #expect(sent.dropFirst().allSatisfy { $0.replyToID == nil })
        // The full reply text is returned (the runtime trims trailing line whitespace).
        #expect(outbound.text.replacingOccurrences(of: " ", with: "") == long.replacingOccurrences(of: " ", with: ""))
    }

    @Test
    func legacySessionKeysKeepPreUpgradeRouting() async throws {
        var inbound = self.dm()
        inbound.legacyRoutingAccountID = "42"
        let modern = OpenClawConfig()
        let legacy = OpenClawConfig(channels: ChannelsConfig(compatibility: ChannelsCompatibilityConfig(legacySessionAccountKeys: true)))
        #expect(ChannelSessionRouting.sessionKey(for: inbound, config: modern) == "telegram:42")
        #expect(ChannelSessionRouting.sessionKey(for: inbound, config: legacy) == "telegram:42:42")
        var accountScoped = inbound
        accountScoped.accountID = "work"
        #expect(ChannelSessionRouting.sessionKey(for: accountScoped, config: modern) == "telegram:work:42")
        let hostEnvelope = InboundMessage(channel: .webchat, accountID: "user-1", peerID: "peer", text: "hi")
        #expect(ChannelSessionRouting.sessionKey(for: hostEnvelope, config: modern) == "webchat:user-1:peer")
        #expect(ChannelSessionRouting.sessionKey(for: hostEnvelope, config: legacy) == "webchat:user-1:peer")
    }

    @Test
    func acknowledgesMentionedGroupMessagesAndRemovesTheReaction() async throws {
        let harness = try await self.makeHarness(
            channels: ChannelsConfig(
                telegram: TelegramChannelConfig(policy: ChannelMessagingPolicyConfig(groupPolicy: .open, groupAllowFrom: ["42"]))
            )
        )
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let group = InboundMessage(
            channel: .telegram,
            peerID: "-100",
            text: "hey bot",
            senderID: "42",
            chatType: .group,
            messageID: "m1",
            wasMentioned: true
        )
        _ = try await harness.engine.handle(group)
        let reactions = await harness.adapter.reactions
        #expect(reactions.count == 2)
        #expect(reactions.first?.emoji == "👀")
        #expect(reactions.first?.removed == false)
        #expect(reactions.last?.removed == true)

        // DMs are outside the default group-mentions scope.
        let dmHarness = try await self.makeHarness(
            channels: ChannelsConfig(telegram: TelegramChannelConfig(policy: ChannelMessagingPolicyConfig(dmPolicy: .open)))
        )
        defer { try? FileManager.default.removeItem(at: dmHarness.root) }
        _ = try await dmHarness.engine.handle(self.dm(messageID: "m2"))
        #expect(await dmHarness.adapter.reactions.isEmpty)
        #expect(await dmHarness.adapter.typingStarts >= 1)
    }

    @Test
    func typingModeNeverDisablesTypingIndicators() async throws {
        var policy = ChannelMessagingPolicyConfig(dmPolicy: .open)
        policy.typingMode = .never
        let harness = try await self.makeHarness(channels: ChannelsConfig(telegram: TelegramChannelConfig(policy: policy)))
        defer { try? FileManager.default.removeItem(at: harness.root) }
        _ = try await harness.engine.handle(self.dm())
        #expect(await harness.adapter.typingStarts == 0)
    }

    @Test
    func botLoopGuardSuppressesRepeatedBotPairs() async throws {
        var policy = ChannelMessagingPolicyConfig(dmPolicy: .open)
        policy.allowBots = .enabled
        policy.botLoopProtection = ChannelBotLoopProtectionConfig(maxEventsPerWindow: 2)
        let harness = try await self.makeHarness(channels: ChannelsConfig(telegram: TelegramChannelConfig(policy: policy)))
        defer { try? FileManager.default.removeItem(at: harness.root) }
        var outcomes: [AutoReplyOutcome] = []
        for index in 0..<3 {
            var bot = self.dm("bot-a")
            bot.isFromBot = true
            bot.recipientID = "bot-b"
            bot.messageID = "evt-\(index)"
            outcomes.append(try await harness.engine.handle(bot))
        }
        #expect(outcomes.last == .suppressed(reason: "bot_loop_suppressed"))
        #expect(await harness.provider.calls == 2)
    }

    /// Workspace with a user-invocable `echo` skill whose script appends to `marker.txt`.
    private func skillWorkspace() throws -> (root: URL, marker: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-autoreply-skill-auth", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let skillRoot = root.appendingPathComponent("skills/echo", isDirectory: true)
        try FileManager.default.createDirectory(at: skillRoot.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        let marker = root.appendingPathComponent("marker.txt")
        try """
        ---
        name: echo
        description: Echo helper
        entrypoint: scripts/echo.sh
        primaryEnv: sh
        user-invocable: true
        disable-model-invocation: false
        ---

        Echo the input.
        """.write(to: skillRoot.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try """
        #!/usr/bin/env sh
        echo "ran" >> "\(marker.path)"
        printf '{"ok":true}\n'
        """.write(to: skillRoot.appendingPathComponent("scripts/echo.sh"), atomically: true, encoding: .utf8)
        return (root, marker)
    }

    @Test
    func skillCommandsFromUnauthorizedGroupSendersNeverRunSkills() async throws {
        let workspace = try self.skillWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let harness = try await self.makeHarness(
            channels: ChannelsConfig(telegram: TelegramChannelConfig(policy: ChannelMessagingPolicyConfig(groupPolicy: .open))),
            workspaceRoot: workspace.root
        )
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let explicit = InboundMessage(channel: .telegram, peerID: "-100", text: "/skill echo hi", senderID: "666", chatType: .group, wasMentioned: false)
        #expect(try await harness.engine.handle(explicit) == .blocked(reasonCode: "control_command_unauthorized"))
        let direct = InboundMessage(channel: .telegram, peerID: "-100", text: "/echo@openclaw_bot hi", senderID: "666", chatType: .group, wasMentioned: false)
        #expect(try await harness.engine.handle(direct) == .blocked(reasonCode: "control_command_unauthorized"))
        let inferred = InboundMessage(channel: .telegram, peerID: "-100", text: "@bot run echo please", senderID: "666", chatType: .group, wasMentioned: true)
        guard case .replied = try await harness.engine.handle(inferred) else {
            Issue.record("expected the mentioned message to be answered")
            return
        }
        #expect(FileManager.default.fileExists(atPath: workspace.marker.path) == false)
    }

    @Test
    func allowlistedGroupSendersStillRunSkillsButRoomEventsNeverDo() async throws {
        let workspace = try self.skillWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        var policy = ChannelMessagingPolicyConfig(groupPolicy: .open, requireMention: false)
        policy.groupAllowFrom = ["42"]
        let harness = try await self.makeHarness(
            channels: ChannelsConfig(telegram: TelegramChannelConfig(mentionOnly: false, policy: policy)),
            groupChat: AutoReplyGroupChatOptions(unmentionedInbound: .roomEvent, visibleReplies: .messageTool),
            workspaceRoot: workspace.root
        )
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let ambient = InboundMessage(channel: .telegram, peerID: "-100", text: "what does echo do?", senderID: "42", chatType: .group, wasMentioned: false)
        guard case .observed = try await harness.engine.handle(ambient) else {
            Issue.record("expected an ambient room event")
            return
        }
        #expect(FileManager.default.fileExists(atPath: workspace.marker.path) == false)

        let command = InboundMessage(channel: .telegram, peerID: "-100", text: "/echo hi", senderID: "42", chatType: .group, wasMentioned: false)
        guard case .replied = try await harness.engine.handle(command) else {
            Issue.record("expected the allowlisted skill command to be answered")
            return
        }
        #expect(FileManager.default.fileExists(atPath: workspace.marker.path))
    }

    @Test
    func ambientRoomEventsRunWithoutPosting() async throws {
        var policy = ChannelMessagingPolicyConfig(groupPolicy: .open, requireMention: false)
        policy.groupAllowFrom = ["42"]
        let harness = try await self.makeHarness(
            channels: ChannelsConfig(telegram: TelegramChannelConfig(mentionOnly: false, policy: policy)),
            groupChat: AutoReplyGroupChatOptions(unmentionedInbound: .roomEvent, visibleReplies: .messageTool)
        )
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let ambient = InboundMessage(channel: .telegram, peerID: "-100", text: "chatter", senderID: "42", chatType: .group, wasMentioned: false)
        let outcome = try await harness.engine.handle(ambient)
        guard case .observed(let observed) = outcome else {
            Issue.record("expected observed room event, got \(outcome)")
            return
        }
        #expect(observed.text == "reply")
        #expect(await harness.adapter.sent.isEmpty)
        #expect(await harness.adapter.typingStarts == 0)
        #expect(await harness.provider.calls == 1)
    }

    @Test
    func joinIntroductionsPostOncePerRoom() async throws {
        let harness = try await self.makeHarness(output: "Hi everyone, I'm the OpenClaw bot.")
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let history = (0..<150).map { ChannelRoomHistoryMessage(sender: "user\($0)", text: String(repeating: "x", count: 100)) }
        let event = ChannelJoinEvent(channel: .telegram, peerID: "-200", roomName: "Team", recentMessages: history)
        let posted = try await harness.engine.handleJoin(event)
        #expect(posted?.text == "Hi everyone, I'm the OpenClaw bot.")
        #expect(try await harness.engine.handleJoin(event) == nil)
        #expect(await harness.adapter.sent.count == 1)

        let bounded = ChannelJoinIntro.boundedSnapshot(history)
        #expect(bounded.count <= ChannelJoinIntro.maxSnapshotMessages)
        #expect(bounded.map { $0.sender.count + $0.text.count + 2 }.reduce(0, +) <= ChannelJoinIntro.maxSnapshotCharacters)
        #expect(bounded.last?.sender == "user149")
        #expect(ChannelJoinIntro.prompt(for: event).contains("<untrusted_room_history>"))

        let unsupported = ChannelJoinEvent(channel: .signal, peerID: "g")
        #expect(try await harness.engine.handleJoin(unsupported) == nil)
    }
}
