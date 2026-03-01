import Foundation
import Testing
@testable import OpenClawKit

@Suite("Channels and auto-reply", .serialized)
struct ChannelAutoReplyTests {
    struct PromptEchoProvider: ModelProvider {
        let id = "prompt-echo"

        func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
            ModelGenerationResponse(text: request.prompt, providerID: self.id, modelID: "prompt-echo")
        }
    }

    struct StreamingLocalProvider: ModelProvider {
        let id = LocalModelProvider.providerID

        func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
            ModelGenerationResponse(text: "fallback-\(request.prompt)", providerID: self.id, modelID: "stream-local")
        }

        func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
            _ = request
            return AsyncThrowingStream { continuation in
                continuation.yield(ModelStreamChunk(text: "stream-", isFinal: false))
                continuation.yield(ModelStreamChunk(text: "ok", isFinal: false))
                continuation.yield(ModelStreamChunk(text: "", isFinal: true))
                continuation.finish()
            }
        }
    }

    actor DiagnosticCollector {
        private(set) var events: [RuntimeDiagnosticEvent] = []

        func append(_ event: RuntimeDiagnosticEvent) {
            self.events.append(event)
        }

        func names() -> [String] {
            self.events.map(\.name)
        }

        func snapshot() -> [RuntimeDiagnosticEvent] {
            self.events
        }
    }

    actor FlakyChannelAdapter: ChannelAdapter {
        let id: ChannelID
        private let failuresBeforeSuccess: Int
        private(set) var started = false
        private(set) var attempts = 0
        private(set) var sentMessages: [OutboundMessage] = []

        init(id: ChannelID, failuresBeforeSuccess: Int) {
            self.id = id
            self.failuresBeforeSuccess = failuresBeforeSuccess
        }

        func start() async throws {
            self.started = true
        }

        func stop() async {
            self.started = false
        }

        func send(_ message: OutboundMessage) async throws {
            guard self.started else {
                throw OpenClawCoreError.unavailable("adapter not started")
            }
            self.attempts += 1
            if self.attempts <= self.failuresBeforeSuccess {
                throw OpenClawCoreError.unavailable("temporary network outage")
            }
            self.sentMessages.append(message)
        }
    }

    struct SlowPromptProvider: ModelProvider {
        let id = "slow-prompt"

        func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
            _ = request
            try await Task.sleep(nanoseconds: 140_000_000)
            return ModelGenerationResponse(text: "slow-reply", providerID: self.id, modelID: "slow-prompt")
        }
    }

    actor TypingAwareChannelAdapter: ChannelAdapter {
        let id: ChannelID
        private(set) var started = false
        private(set) var sentMessages: [OutboundMessage] = []
        private(set) var typingSignals = 0

        init(id: ChannelID) {
            self.id = id
        }

        func start() async throws {
            self.started = true
        }

        func stop() async {
            self.started = false
        }

        func send(_ message: OutboundMessage) async throws {
            guard self.started else {
                throw OpenClawCoreError.unavailable("adapter not started")
            }
            self.sentMessages.append(message)
        }

        func sendTypingIndicator(accountID _: String?, peerID _: String) async throws {
            guard self.started else {
                throw OpenClawCoreError.unavailable("adapter not started")
            }
            self.typingSignals += 1
        }
    }

    @Test
    func channelRegistryRoutesMessagesByChannelID() async throws {
        let registry = ChannelRegistry()
        let telegram = InMemoryChannelAdapter(id: .telegram)
        await registry.register(telegram)
        try await telegram.start()

        let outbound = OutboundMessage(channel: .telegram, accountID: "default", peerID: "123", text: "hello")
        try await registry.send(outbound)

        let sent = await telegram.sentMessages()
        #expect(sent.count == 1)
        #expect(sent.first?.text == "hello")
    }

    @Test
    func channelRegistryRetriesTransientFailuresAndRecoversHealth() async throws {
        let registry = ChannelRegistry(
            sendRetryPolicy: ChannelSendRetryPolicy(
                maxAttempts: 3,
                initialBackoffMs: 1,
                maxBackoffMs: 2,
                backoffMultiplier: 1
            )
        )
        let flaky = FlakyChannelAdapter(id: .telegram, failuresBeforeSuccess: 2)
        await registry.register(flaky)
        try await flaky.start()

        let outbound = OutboundMessage(channel: .telegram, accountID: "default", peerID: "peer", text: "hello")
        try await registry.send(outbound)

        let attempts = await flaky.attempts
        let sentCount = await flaky.sentMessages.count
        #expect(attempts == 3)
        #expect(sentCount == 1)
        let health = await registry.healthSnapshot(for: .telegram)
        #expect(health.status == .healthy)
        #expect(health.consecutiveFailures == 0)
        #expect(health.lastSuccessAt != nil)
    }

    @Test
    func channelRegistryMarksOfflineAfterRetryExhaustion() async throws {
        let registry = ChannelRegistry(
            sendRetryPolicy: ChannelSendRetryPolicy(
                maxAttempts: 3,
                initialBackoffMs: 1,
                maxBackoffMs: 2,
                backoffMultiplier: 1
            )
        )
        let flaky = FlakyChannelAdapter(id: .telegram, failuresBeforeSuccess: 10)
        await registry.register(flaky)
        try await flaky.start()

        do {
            try await registry.send(OutboundMessage(channel: .telegram, accountID: "default", peerID: "peer", text: "hello"))
            Issue.record("Expected send failure")
        } catch {
            #expect(String(describing: error).contains("after 3 attempt"))
        }

        let health = await registry.healthSnapshot(for: .telegram)
        #expect(health.status == .offline)
        #expect(health.consecutiveFailures == 3)
        #expect((health.lastError ?? "").contains("Unavailable"))
    }

    @Test
    func channelRegistryDelaysBurstAndRecoversAfterCooldown() async throws {
        let registry = ChannelRegistry(
            sendRetryPolicy: ChannelSendRetryPolicy(
                maxAttempts: 2,
                initialBackoffMs: 1,
                maxBackoffMs: 2,
                backoffMultiplier: 1
            ),
            sendThrottlePolicy: ChannelSendThrottlePolicy(
                maxSendsPerWindow: 1,
                windowMs: 80,
                strategy: .delay
            )
        )
        let telegram = InMemoryChannelAdapter(id: .telegram)
        await registry.register(telegram)
        try await telegram.start()

        let startedAt = Date()
        _ = try await registry.send(OutboundMessage(channel: .telegram, accountID: "default", peerID: "peer", text: "one"))
        _ = try await registry.send(OutboundMessage(channel: .telegram, accountID: "default", peerID: "peer", text: "two"))
        let elapsed = Date().timeIntervalSince(startedAt)

        let sent = await telegram.sentMessages()
        #expect(sent.count == 2)
        #expect(elapsed >= 0.07)
    }

    @Test
    func channelRegistryDropsWhenThrottlePolicyUsesDropStrategy() async throws {
        let collector = DiagnosticCollector()
        let registry = ChannelRegistry(
            sendRetryPolicy: ChannelSendRetryPolicy(maxAttempts: 1),
            sendThrottlePolicy: ChannelSendThrottlePolicy(
                maxSendsPerWindow: 1,
                windowMs: 1_000,
                strategy: .drop
            ),
            diagnosticsSink: { event in
                await collector.append(event)
            }
        )
        let telegram = InMemoryChannelAdapter(id: .telegram)
        await registry.register(telegram)
        try await telegram.start()

        _ = try await registry.send(OutboundMessage(channel: .telegram, accountID: "default", peerID: "peer", text: "one"))
        do {
            _ = try await registry.send(OutboundMessage(channel: .telegram, accountID: "default", peerID: "peer", text: "two"))
            Issue.record("Expected throttle drop failure")
        } catch {
            #expect(String(describing: error).lowercased().contains("throttled"))
        }

        let names = await collector.names()
        #expect(names.contains("channel.throttle.drop"))
    }

    @Test
    func channelRegistryEmitsRetryDiagnosticsOnTransientFailures() async throws {
        let collector = DiagnosticCollector()
        let registry = ChannelRegistry(
            sendRetryPolicy: ChannelSendRetryPolicy(
                maxAttempts: 3,
                initialBackoffMs: 1,
                maxBackoffMs: 2,
                backoffMultiplier: 1
            ),
            sendThrottlePolicy: ChannelSendThrottlePolicy(),
            diagnosticsSink: { event in
                await collector.append(event)
            }
        )
        let flaky = FlakyChannelAdapter(id: .telegram, failuresBeforeSuccess: 1)
        await registry.register(flaky)
        try await flaky.start()

        _ = try await registry.send(OutboundMessage(channel: .telegram, accountID: "default", peerID: "peer", text: "retry"))
        let names = await collector.names()
        #expect(names.contains("channel.delivery.retry"))
    }

    @Test
    func autoReplyEnginePersistsSessionAndDeliversReply() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclawkit-autoreply-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sessionsPath = root.appendingPathComponent("sessions.json", isDirectory: false)

        let config = OpenClawConfig()
        let sessionStore = SessionStore(fileURL: sessionsPath)
        let registry = ChannelRegistry()
        let whatsapp = InMemoryChannelAdapter(id: .whatsapp)
        await registry.register(whatsapp)
        try await whatsapp.start()

        let runtime = EmbeddedAgentRuntime()
        let engine = AutoReplyEngine(
            config: config,
            sessionStore: sessionStore,
            channelRegistry: registry,
            runtime: runtime
        )

        let inbound = InboundMessage(channel: .whatsapp, accountID: "default", peerID: "555123", text: "hi")
        let outbound = try await engine.process(inbound)

        #expect(outbound.channel == .whatsapp)
        #expect(outbound.text == "OK")

        let allSessions = await sessionStore.allRecords()
        #expect(allSessions.count == 1)
        #expect(allSessions.first?.key.contains("whatsapp") == true)
    }

    @Test
    func autoReplyEngineUsesMappedAgentForRoute() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclawkit-autoreply-agent-route-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sessionsPath = root.appendingPathComponent("sessions.json", isDirectory: false)

        let config = OpenClawConfig(
            agents: AgentsConfig(
                defaultAgentID: "main",
                workspaceRoot: "./workspace",
                agentIDs: ["main", "support"],
                routeAgentMap: [
                    AgentsConfig.routeKey(channel: "whatsapp"): "support",
                ]
            )
        )
        let sessionStore = SessionStore(fileURL: sessionsPath)
        let registry = ChannelRegistry()
        let whatsapp = InMemoryChannelAdapter(id: .whatsapp)
        await registry.register(whatsapp)
        try await whatsapp.start()

        let runtime = EmbeddedAgentRuntime()
        let engine = AutoReplyEngine(
            config: config,
            sessionStore: sessionStore,
            channelRegistry: registry,
            runtime: runtime
        )
        let inbound = InboundMessage(channel: .whatsapp, accountID: "default", peerID: "555123", text: "hi")
        _ = try await engine.process(inbound)

        let key = SessionKeyResolver.resolve(
            explicit: nil,
            context: SessionRoutingContext(channel: "whatsapp", accountID: "default", peerID: "555123"),
            config: config
        )
        let record = await sessionStore.recordForKey(key)
        #expect(record?.agentID == "support")
    }

    @Test
    func autoReplyEngineInjectsPersistentConversationContext() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclawkit-autoreply-memory-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionsPath = root.appendingPathComponent("sessions.json", isDirectory: false)
        let memoryPath = root.appendingPathComponent("conversation-memory.json", isDirectory: false)
        let sessionStore = SessionStore(fileURL: sessionsPath)
        let memoryStore = ConversationMemoryStore(fileURL: memoryPath)
        try await sessionStore.load()
        try await memoryStore.load()

        let registry = ChannelRegistry()
        let webchat = InMemoryChannelAdapter(id: .webchat)
        await registry.register(webchat)
        try await webchat.start()

        let runtime = EmbeddedAgentRuntime()
        await runtime.registerModelProvider(PromptEchoProvider())
        try await runtime.setDefaultModelProviderID("prompt-echo")

        let engine = AutoReplyEngine(
            config: OpenClawConfig(),
            sessionStore: sessionStore,
            channelRegistry: registry,
            runtime: runtime,
            conversationMemoryStore: memoryStore,
            memoryContextLimit: 12
        )

        _ = try await engine.process(
            InboundMessage(channel: .webchat, accountID: "user-1", peerID: "peer", text: "first question")
        )
        let second = try await engine.process(
            InboundMessage(channel: .webchat, accountID: "user-1", peerID: "peer", text: "second question")
        )

        #expect(second.text.contains("## Conversation Memory Context"))
        #expect(second.text.contains("[user] first question"))
        #expect(second.text.contains("## New User Message"))
        #expect(second.text.contains("second question"))
    }

    @Test
    func autoReplyEngineForwardsAttachmentsIntoRuntimePromptContext() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclawkit-autoreply-attachment-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionsPath = root.appendingPathComponent("sessions.json", isDirectory: false)
        let sessionStore = SessionStore(fileURL: sessionsPath)
        let registry = ChannelRegistry()
        let webchat = InMemoryChannelAdapter(id: .webchat)
        await registry.register(webchat)
        try await webchat.start()

        let runtime = EmbeddedAgentRuntime()
        await runtime.registerModelProvider(PromptEchoProvider())
        try await runtime.setDefaultModelProviderID("prompt-echo")

        let engine = AutoReplyEngine(
            config: OpenClawConfig(),
            sessionStore: sessionStore,
            channelRegistry: registry,
            runtime: runtime
        )

        let outbound = try await engine.process(
            InboundMessage(
                channel: .webchat,
                accountID: "user-1",
                peerID: "peer",
                text: "Please inspect this",
                attachments: [
                    MediaAttachment(
                        id: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
                        mimeType: "image/png",
                        data: Data([0xAA, 0xBB, 0xCC]),
                        fileName: "receipt.png"
                    ),
                ]
            )
        )

        #expect(outbound.text.contains("## Attachments"))
        #expect(outbound.text.contains("receipt.png"))
        #expect(outbound.text.contains("image/png"))
        #expect(outbound.text.contains("## User Request"))
    }

    @Test
    func autoReplyEngineUsesStreamingRuntimeWhenLocalStreamingEnabled() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclawkit-autoreply-streaming-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionsPath = root.appendingPathComponent("sessions.json", isDirectory: false)
        let sessionStore = SessionStore(fileURL: sessionsPath)
        let registry = ChannelRegistry()
        let webchat = InMemoryChannelAdapter(id: .webchat)
        await registry.register(webchat)
        try await webchat.start()

        let collector = DiagnosticCollector()
        let runtime = EmbeddedAgentRuntime()
        await runtime.registerModelProvider(StreamingLocalProvider())
        try await runtime.setDefaultModelProviderID(LocalModelProvider.providerID)

        let engine = AutoReplyEngine(
            config: OpenClawConfig(
                agents: AgentsConfig(defaultAgentID: "main", workspaceRoot: root.path),
                models: ModelsConfig(
                    defaultProviderID: LocalModelProvider.providerID,
                    local: LocalModelConfig(enabled: true, streamTokens: true)
                )
            ),
            sessionStore: sessionStore,
            channelRegistry: registry,
            runtime: runtime,
            diagnosticsSink: { event in
                await collector.append(event)
            }
        )

        let outbound = try await engine.process(
            InboundMessage(channel: .webchat, accountID: "user-1", peerID: "peer", text: "hello")
        )

        #expect(outbound.text == "stream-ok")
        let events = await collector.snapshot()
        #expect(events.contains(where: { $0.name == "model.stream.chunk" }))
    }

    @Test
    func typingHeartbeatRepeatsAndStopsForDiscord() async throws {
        try await self.verifyTypingHeartbeatLifecycle(channelID: .discord)
    }

    @Test
    func typingHeartbeatRepeatsAndStopsForTelegram() async throws {
        try await self.verifyTypingHeartbeatLifecycle(channelID: .telegram)
    }

    @Test
    func autoReplyEngineInvokesWorkspaceWeatherSkillForNaturalLanguageRequests() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclawkit-autoreply-skill-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let skillRoot = root
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("weather", isDirectory: true)
        let scriptRoot = skillRoot.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptRoot, withIntermediateDirectories: true)
        try """
        ---
        name: weather
        description: Weather helper
        entrypoint: scripts/weather.sh
        primaryEnv: sh
        user-invocable: true
        disable-model-invocation: false
        ---

        Use this skill for weather checks.
        """.write(
            to: skillRoot.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        try """
        #!/usr/bin/env sh
        input="${1:-{}}"
        printf '{"resolved_location":"San Diego, US","input":%s}\n' "$input"
        """.write(
            to: scriptRoot.appendingPathComponent("weather.sh"),
            atomically: true,
            encoding: .utf8
        )

        let sessionsPath = root.appendingPathComponent("sessions.json", isDirectory: false)
        let sessionStore = SessionStore(fileURL: sessionsPath)
        let registry = ChannelRegistry()
        let webchat = InMemoryChannelAdapter(id: .webchat)
        await registry.register(webchat)
        try await webchat.start()

        let runtime = EmbeddedAgentRuntime()
        await runtime.registerModelProvider(PromptEchoProvider())
        try await runtime.setDefaultModelProviderID("prompt-echo")

        let engine = AutoReplyEngine(
            config: OpenClawConfig(
                agents: AgentsConfig(defaultAgentID: "main", workspaceRoot: root.path),
                models: ModelsConfig(defaultProviderID: "prompt-echo")
            ),
            sessionStore: sessionStore,
            channelRegistry: registry,
            runtime: runtime
        )

        let outbound = try await engine.process(
            InboundMessage(
                channel: .webchat,
                accountID: "user-1",
                peerID: "peer",
                text: "Can you check the weather in San Diego today?"
            )
        )

        #expect(outbound.text.contains("## Skill Output (weather)"))
        #expect(outbound.text.contains("resolved_location"))
        #expect(outbound.text.contains("San Diego"))
    }

    private func verifyTypingHeartbeatLifecycle(channelID: ChannelID) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclawkit-autoreply-typing-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionStore = SessionStore(fileURL: root.appendingPathComponent("sessions.json", isDirectory: false))
        let registry = ChannelRegistry()
        let adapter = TypingAwareChannelAdapter(id: channelID)
        await registry.register(adapter)
        try await adapter.start()

        let runtime = EmbeddedAgentRuntime()
        await runtime.registerModelProvider(SlowPromptProvider())
        try await runtime.setDefaultModelProviderID("slow-prompt")

        let engine = AutoReplyEngine(
            config: OpenClawConfig(
                agents: AgentsConfig(defaultAgentID: "main", workspaceRoot: root.path),
                models: ModelsConfig(defaultProviderID: "slow-prompt")
            ),
            sessionStore: sessionStore,
            channelRegistry: registry,
            runtime: runtime,
            typingHeartbeatIntervalMs: 25
        )

        let outbound = try await engine.process(
            InboundMessage(channel: channelID, accountID: "user-1", peerID: "peer", text: "hello")
        )
        #expect(outbound.text == "slow-reply")
        let typingCountAfterReply = await adapter.typingSignals
        #expect(typingCountAfterReply >= 2)

        try await Task.sleep(nanoseconds: 80_000_000)
        let typingCountAfterWait = await adapter.typingSignals
        #expect(typingCountAfterWait == typingCountAfterReply)
    }

    @Test
    func autoReplyEngineInvokesArbitrarySkillByNameReference() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclawkit-autoreply-generic-skill-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let skillRoot = root
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("calendar-helper", isDirectory: true)
        let scriptRoot = skillRoot.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptRoot, withIntermediateDirectories: true)
        try """
        ---
        name: calendar-helper
        description: Generic helper
        entrypoint: scripts/echo.sh
        primaryEnv: sh
        user-invocable: true
        disable-model-invocation: false
        ---

        Use this skill for calendar helper requests.
        """.write(
            to: skillRoot.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        try """
        #!/usr/bin/env sh
        input="${1:-}"
        printf 'calendar-helper-output:%s\n' "$input"
        """.write(
            to: scriptRoot.appendingPathComponent("echo.sh"),
            atomically: true,
            encoding: .utf8
        )

        let sessionsPath = root.appendingPathComponent("sessions.json", isDirectory: false)
        let sessionStore = SessionStore(fileURL: sessionsPath)
        let registry = ChannelRegistry()
        let webchat = InMemoryChannelAdapter(id: .webchat)
        await registry.register(webchat)
        try await webchat.start()

        let runtime = EmbeddedAgentRuntime()
        await runtime.registerModelProvider(PromptEchoProvider())
        try await runtime.setDefaultModelProviderID("prompt-echo")

        let engine = AutoReplyEngine(
            config: OpenClawConfig(
                agents: AgentsConfig(defaultAgentID: "main", workspaceRoot: root.path),
                models: ModelsConfig(defaultProviderID: "prompt-echo")
            ),
            sessionStore: sessionStore,
            channelRegistry: registry,
            runtime: runtime
        )

        let outbound = try await engine.process(
            InboundMessage(
                channel: .webchat,
                accountID: "user-1",
                peerID: "peer",
                text: "Please use calendar helper to summarize Monday appointments"
            )
        )

        #expect(outbound.text.contains("## Skill Output (calendar-helper)"))
        #expect(outbound.text.contains("calendar-helper-output:"))
        #expect(outbound.text.contains("Monday appointments"))
    }

    @Test
    func autoReplyEngineEmitsChannelDiagnostics() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclawkit-autoreply-diagnostics-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionsPath = root.appendingPathComponent("sessions.json", isDirectory: false)
        let sessionStore = SessionStore(fileURL: sessionsPath)
        let registry = ChannelRegistry()
        let webchat = InMemoryChannelAdapter(id: .webchat)
        await registry.register(webchat)
        try await webchat.start()

        let collector = DiagnosticCollector()
        let runtime = EmbeddedAgentRuntime()
        let engine = AutoReplyEngine(
            config: OpenClawConfig(),
            sessionStore: sessionStore,
            channelRegistry: registry,
            runtime: runtime,
            diagnosticsSink: { event in
                await collector.append(event)
            }
        )

        _ = try await engine.process(
            InboundMessage(channel: .webchat, accountID: "user-1", peerID: "peer", text: "hello")
        )

        let names = await collector.names()
        #expect(names.contains("inbound.received"))
        #expect(names.contains("routing.session_resolved"))
        #expect(names.contains("model.call.started"))
        #expect(names.contains("model.call.completed"))
        #expect(names.contains("outbound.sent"))
    }

    @Test
    func autoReplyEngineEmitsOutboundFailureDiagnostics() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclawkit-autoreply-outbound-failure-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionsPath = root.appendingPathComponent("sessions.json", isDirectory: false)
        let sessionStore = SessionStore(fileURL: sessionsPath)
        let registry = ChannelRegistry(
            sendRetryPolicy: ChannelSendRetryPolicy(
                maxAttempts: 2,
                initialBackoffMs: 1,
                maxBackoffMs: 2,
                backoffMultiplier: 1
            )
        )
        let flaky = FlakyChannelAdapter(id: .webchat, failuresBeforeSuccess: 99)
        await registry.register(flaky)
        try await flaky.start()

        let collector = DiagnosticCollector()
        let runtime = EmbeddedAgentRuntime()
        let engine = AutoReplyEngine(
            config: OpenClawConfig(),
            sessionStore: sessionStore,
            channelRegistry: registry,
            runtime: runtime,
            diagnosticsSink: { event in
                await collector.append(event)
            }
        )

        do {
            _ = try await engine.process(
                InboundMessage(channel: .webchat, accountID: "user-1", peerID: "peer", text: "hello")
            )
            Issue.record("Expected outbound send failure")
        } catch {
            #expect(String(describing: error).contains("after 2 attempt"))
        }

        let events = await collector.snapshot()
        let outboundFailure = events.last(where: { $0.name == "outbound.failed" })
        #expect(outboundFailure != nil)
        #expect(outboundFailure?.metadata["attempts"] == "2")
        #expect(outboundFailure?.metadata["status"] == "offline")
    }

    @Test
    func autoReplyEngineHandlesHealthCommand() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclawkit-autoreply-command-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionsPath = root.appendingPathComponent("sessions.json", isDirectory: false)
        let sessionStore = SessionStore(fileURL: sessionsPath)
        let registry = ChannelRegistry()
        let webchat = InMemoryChannelAdapter(id: .webchat)
        await registry.register(webchat)
        try await webchat.start()

        let runtime = EmbeddedAgentRuntime()
        let engine = AutoReplyEngine(
            config: OpenClawConfig(),
            sessionStore: sessionStore,
            channelRegistry: registry,
            runtime: runtime
        )

        let outbound = try await engine.process(
            InboundMessage(channel: .webchat, accountID: "user-1", peerID: "peer", text: "/health")
        )

        #expect(outbound.text.contains("Channel: webchat"))
        #expect(outbound.text.contains("Status:"))
        #expect(outbound.text.contains("RetryPolicy:"))
    }
}

