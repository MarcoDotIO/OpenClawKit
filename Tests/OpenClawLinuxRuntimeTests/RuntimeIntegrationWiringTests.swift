import Foundation
import Testing
import OpenClawCore
import OpenClawMCP
import OpenClawMemory
import OpenClawModels
import OpenClawProtocol
import OpenClawSkills
@testable import OpenClawAgents

@Suite("Runtime integration wiring")
struct RuntimeIntegrationWiringTests {
    private static func document(_ json: String) throws -> OpenClawConfigDocument {
        try OpenClawConfigDocument.decode(Data(json.utf8))
    }

    // MARK: Config -> runtime mapping

    @Test
    func configDocumentMapsOntoRuntimeSettings() throws {
        let document = try Self.document(
            """
            {
              "tools": {
                "profile": "coding",
                "alsoAllow": ["web_search"],
                "deny": ["exec"],
                "loopDetection": {"enabled": true},
                "toolSearch": {"mode": "directory", "maxSearchLimit": 30}
              },
              "agents": {
                "defaults": {
                  "fastModeDefault": "auto",
                  "thinkingDefault": "high",
                  "compaction": {"enabled": false, "keepRecentTokens": 1234, "model": "openai/gpt-6-astra"},
                  "subagents": {"maxConcurrent": 2, "maxSpawnDepth": 3, "runTimeoutSeconds": 90}
                },
                "entries": {
                  "writer": {"tools": {"deny": ["write"]}, "subagents": {"maxConcurrent": 7}, "fastModeDefault": false}
                }
              },
              "plugins": {"slots": {"contextEngine": "legacy"}},
              "models": {"providers": {"local-llm": {"baseUrl": "http://127.0.0.1:1234/v1", "api": "openai-completions",
                "models": [{"id": "tiny", "name": "Tiny", "input": ["text"], "contextWindow": 4096}]}}}
            }
            """
        )
        let settings = AgentRuntimeSettings(document: document)
        #expect(settings.tools.policy == ToolPolicy(profile: .coding, alsoAllow: ["web_search"], deny: ["exec"]))
        #expect(settings.tools.loopDetection.enabled)
        #expect(settings.tools.toolSearch?.mode == .directory)
        #expect(settings.tools.toolSearch?.maxSearchLimit == 30)
        #expect(settings.compaction == ContextCompactionSettings(enabled: false, keepRecentTokens: 1234, model: "openai/gpt-6-astra"))
        #expect(settings.subagents.maxConcurrent == 2)
        #expect(settings.subagents.maxDepth == 3)
        #expect(settings.subagents.defaultRunTimeoutSeconds == 90)
        #expect(settings.contextEngineID == "legacy")
        #expect(settings.sessionKeyFormat == .legacy)
        #expect(settings.fastModeDefault == .auto)
        #expect(settings.thinkingDefault == .high)
        #expect(settings.providerConfigs["local-llm"]?.models.first?.id == "tiny")

        let writer = AgentRuntimeSettings(document: document, agentID: "Writer")
        // A per-agent deny adds to the global deny (upstream stages); it never re-enables `exec`.
        #expect(writer.tools.policy.deny == ["exec", "write"])
        #expect(!writer.tools.policy.allows("exec"))
        #expect(!writer.tools.policy.allows("write"))
        #expect(writer.tools.policy.allows("read"))
        #expect(writer.tools.policy.allows("web_search"))
        #expect(writer.subagents.maxConcurrent == 7)
        #expect(writer.fastModeDefault == .off)

        let loop = settings.applying(to: AgentLoopConfiguration())
        #expect(loop.compaction.enabled == false)
        #expect(loop.fastModeDefault == .auto)
        #expect(loop.providerConfigs["local-llm"] != nil)
    }

    @Test
    func emptyDocumentsKeepRuntimeDefaults() throws {
        let settings = AgentRuntimeSettings(document: OpenClawConfigDocument())
        #expect(settings.tools == AgentToolsConfiguration())
        #expect(settings.compaction == ContextCompactionSettings())
        #expect(settings.subagents == SubagentConfiguration())
        #expect(settings.contextEngineID == nil)
        #expect(ToolSearchConfiguration.resolve(from: OpenClawConfigDocument()) == .embeddedDefault)
        #expect(SessionKeyFormat.resolve(from: try Self.document(#"{"routing": {"sessionKeyFormat": "canonical"}}"#)) == .canonical)
    }

    @Test
    func runtimeAppliesSettingsAndSelectsTheContextEngine() async throws {
        let runtime = EmbeddedAgentRuntime(transcriptStore: InMemorySessionTranscriptStore(), mediaUnderstandingServices: .none)
        let document = try Self.document(#"{"tools": {"deny": ["exec"]}, "plugins": {"slots": {"contextEngine": "legacy"}}}"#)
        try await runtime.apply(AgentRuntimeSettings(document: document))
        #expect(await runtime.currentToolsConfiguration().policy.deny == ["exec"])
        #expect(await runtime.contextEngines.selectedEngineID() == "legacy")
        let missing = try Self.document(#"{"plugins": {"slots": {"contextEngine": "lossless"}}}"#)
        await #expect(throws: OpenClawCoreError.self) {
            try await runtime.apply(AgentRuntimeSettings(document: missing))
        }
    }

    @Test
    func mcpSkillsAndMemorySectionsDecodeFromTheDocument() throws {
        let document = try Self.document(
            """
            {
              "mcp": {"servers": {"docs": {"url": "https://mcp.example.com/mcp", "enabled": false}}},
              "skills": {"allowBundled": ["weather"], "entries": {"greeter": {"enabled": false}}, "limits": {"maxSkillsInPrompt": 5}},
              "memory": {"search": {"provider": "none", "sources": ["memory", "sessions"], "extraPaths": ["notes"],
                                    "query": {"maxResults": 3, "minScore": 2}}},
              "agents": {"entries": {"quiet": {"memory": {"search": {"enabled": false}}},
                                     "focused": {"memory": {"search": {"query": {"maxResults": 9}}}}}}
            }
            """
        )
        let mcp = try MCPConfig.resolve(from: document)
        #expect(mcp.server(named: "docs")?.url == "https://mcp.example.com/mcp")
        #expect(mcp.server(named: "docs")?.isEnabled == false)
        #expect(try MCPConfig.resolve(from: OpenClawConfigDocument()) == MCPConfig())

        let skills = try SkillsConfiguration.resolve(from: document)
        #expect(skills.allowBundled == ["weather"])
        #expect(skills.entry(for: "greeter")?.enabled == false)
        #expect(skills.limits.maxSkillsInPrompt == 5)

        let memory = try #require(MemoryEngineConfiguration.resolve(from: document))
        #expect(memory.isKeywordOnly)
        #expect(memory.sources == [.memory, .sessions])
        #expect(memory.extraPaths.map(\.path) == ["notes"])
        #expect(memory.maxResults == 3)
        #expect(memory.minScore == 1)
        #expect(MemoryEngineConfiguration.resolve(from: document, agentID: "quiet") == nil)
        #expect(MemoryEngineConfiguration.resolve(from: document, agentID: "focused")?.maxResults == 9)
    }

    // MARK: MCP

    @Test
    func sessionOverridesMapOntoMCPOverrides() {
        let overrides = SessionToolOverrides(mcpServers: ["docs": false, "search": true], mcpToolsDeny: ["search": ["delete"]])
        let mapped = MCPSessionToolOverrides(overrides)
        #expect(mapped.disabledServers == ["docs"])
        #expect(mapped.deniedTools == ["search": ["delete"]])
        #expect(MCPSessionToolOverrides(nil) == MCPSessionToolOverrides())
    }

    @Test
    func mcpToolsRegisterIntoTheRuntimeAndRespectSessionOverrides() async throws {
        let http = MCPClientTransportTests.streamableServer()
        let config = MCPConfig(servers: [(name: "fake", config: MCPServerConfig(url: "https://mcp.example.com/mcp", transport: "streamable-http"))])
        let manager = MCPClientManager(config: config, transportFactory: { _, server, _ in
            MCPStreamableHTTPTransport(url: URL(string: server.url!)!, http: http)
        })
        let provider = ScriptedToolProvider(turns: [], fallback: ScriptedToolProvider.text("ok"))
        let store = SessionStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID().uuidString).json"))
        let runtime = EmbeddedAgentRuntime(
            toolRegistry: AgentToolRegistry(tools: [EchoArgumentTool()]),
            modelRouter: ModelRouter(defaultProviderID: provider.id, providers: [provider]),
            sessionStore: store,
            transcriptStore: InMemorySessionTranscriptStore(),
            mediaUnderstandingServices: .none
        )
        let registered = await runtime.registerMCPTools(from: manager)
        #expect(registered.contains("fake__echo"))
        let descriptor = try #require(await runtime.toolRegistry.tool(named: "fake__echo")?.descriptor)
        #expect(descriptor.source == .mcp(server: "fake", toolName: "echo"))

        _ = try await runtime.run(AgentRunRequest(sessionKey: "mcp-open", prompt: "hi"))
        #expect(await provider.recorded().last?.tools.map(\.name).contains("fake__echo") == true)

        _ = await store.resolveOrCreate(sessionKey: "mcp-closed", defaultAgentID: "main", route: nil)
        _ = await store.update(forKey: "mcp-closed") { record in
            record.toolOverrides = SessionToolOverrides(mcpServers: ["fake": false])
        }
        _ = try await runtime.run(AgentRunRequest(sessionKey: "mcp-closed", prompt: "hi"))
        let closed = try #require(await provider.recorded().last).tools.map(\.name)
        #expect(!closed.contains { $0.hasPrefix("fake__") })
        #expect(closed.contains("echo"))

        let removed = await runtime.unregisterMCPTools()
        #expect(removed.sorted() == registered.sorted())
        #expect(await runtime.toolRegistry.tool(named: "fake__echo") == nil)
        await manager.shutdown()
    }

    // MARK: Memory

    @Test
    func memoryInstallRegistersToolsAndTheRecallSection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "Project codename: Bluebird".write(to: root.appendingPathComponent("MEMORY.md"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = ScriptedToolProvider(turns: [ScriptedToolProvider.text("ok"), ScriptedToolProvider.text("ok")])
        let runtime = EmbeddedAgentRuntime(
            toolRegistry: AgentToolRegistry(tools: []),
            modelRouter: ModelRouter(defaultProviderID: provider.id, providers: [provider]),
            transcriptStore: InMemorySessionTranscriptStore(),
            mediaUnderstandingServices: .none
        )
        let installation = await runtime.installMemory(
            engine: MemoryEngine(workspaceRoot: root, configuration: MemoryEngineConfiguration(provider: "none")),
            citationsMode: "off"
        )
        #expect(installation.memoryTools == ["memory_search", "memory_get"])
        #expect(installation.spotlightSearch == false)
        _ = try await runtime.run(AgentRunRequest(sessionKey: "memory", prompt: "codename?"))
        let request = try #require(await provider.recorded().first)
        #expect(request.tools.map(\.name) == ["memory_get", "memory_search"])
        let system = try #require(request.systemPrompt)
        #expect(system.contains("## Memory Recall"))
        #expect(system.contains("Citations are disabled"))

        // A policy that hides the memory tools drops the section too.
        await runtime.setToolsConfiguration(AgentToolsConfiguration(policy: ToolPolicy(deny: ["memory_*"])))
        _ = try await runtime.run(AgentRunRequest(sessionKey: "memory", prompt: "again"))
        #expect(await provider.recorded().last?.systemPrompt?.contains("## Memory Recall") != true)
        #expect(MemoryRuntimeIntegration.promptSection(availableTools: []) == nil)
    }

    @Test
    func spotlightRegistrationAcceptsAMemoryIndexDelegate() async throws {
        // Objects that are not CSSearchableIndexDelegates are ignored; availability matches the plain call.
        final class NotADelegate: @unchecked Sendable {}
        let plain = AgentToolRegistry()
        let expected = await MemoryToolRegistration.registerSpotlightSearch(into: plain)
        let registry = AgentToolRegistry()
        let registered = await MemoryToolRegistration.registerSpotlightSearch(into: registry, indexDelegate: NotADelegate())
        #expect(registered == expected)
        #expect(await registry.hasTool(named: "spotlight_search") == registered)
        #if canImport(CoreSpotlight) && !os(tvOS) && !os(watchOS)
        let delegate = SpotlightMemoryIndexDelegate(lookup: { _ in [] }, reindexAll: { [] })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spotlight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = ScriptedToolProvider(turns: [ScriptedToolProvider.text("ok")])
        let runtime = EmbeddedAgentRuntime(
            toolRegistry: AgentToolRegistry(tools: []),
            modelRouter: ModelRouter(defaultProviderID: provider.id, providers: [provider]),
            transcriptStore: InMemorySessionTranscriptStore(),
            mediaUnderstandingServices: .none
        )
        let installation = await runtime.installMemory(
            engine: MemoryEngine(workspaceRoot: root, configuration: MemoryEngineConfiguration(provider: "none")),
            spotlightSearch: true,
            spotlightIndexDelegate: delegate
        )
        #expect(installation.spotlightSearch == expected)
        #expect(await runtime.toolRegistry.hasTool(named: "spotlight_search") == expected)
        #endif
    }

    @Test
    func conversationMemoryImportsIntoTranscripts() async throws {
        let entries = [
            ConversationMemoryEntry(
                id: "b", sessionKey: "s", channel: "webchat", accountID: nil, peerID: "p", role: .assistant, text: "hello", createdAtMs: 2_000
            ),
            ConversationMemoryEntry(
                id: "a", sessionKey: "s", channel: "webchat", accountID: nil, peerID: "p", role: .user, text: "hi", createdAtMs: 1_000
            ),
        ]
        let rows = MemoryRuntimeIntegration.transcriptImportRows(from: entries)
        #expect(rows.map(\.role) == ["user", "assistant"])
        #expect(rows.first?.timestampMs == Int64(1_000))
        let store = InMemorySessionTranscriptStore()
        let imported = try await MemoryRuntimeIntegration.importConversationMemory(entries, into: store, sessionID: "imported")
        #expect(imported == 2)
        #expect(try await store.contextMessages(sessionID: "imported").map(\.role) == ["user", "assistant"])
    }

    @Test
    func closureEmbeddingProviderForwardsToTheEmbedder() async throws {
        let provider = ClosureMemoryEmbeddingProvider(id: "coreai", model: "minilm", dimensions: 2) { texts, inputType in
            texts.map { [Float($0.count), inputType == .query ? 1 : 0] }
        }
        #expect(provider.id == "coreai")
        #expect(provider.dimensions == 2)
        #expect(try await provider.embed(["abc"], inputType: .query) == [[3, 1]])
    }

    // MARK: Automations

    @Test
    func automationsInstallRegistersTheToolExecutorAndCronHook() async throws {
        let hooks = HookRegistry()
        let log = HookEventLog()
        await hooks.register(.cronChanged) { context in
            await log.record(.cronChanged, context)
            return nil
        }
        let provider = ScriptedToolProvider(turns: [], fallback: ScriptedToolProvider.text("automated"))
        let runtime = EmbeddedAgentRuntime(
            toolRegistry: AgentToolRegistry(tools: []),
            modelRouter: ModelRouter(defaultProviderID: provider.id, providers: [provider]),
            transcriptStore: InMemorySessionTranscriptStore(),
            hookRegistry: hooks,
            mediaUnderstandingServices: .none
        )
        let scheduler = CronScheduler()
        await runtime.installAutomations(scheduler: scheduler)
        #expect(await runtime.toolRegistry.tool(named: "automations") != nil)
        let tool = try #require(await runtime.toolRegistry.tool(named: "automations"))
        let added = try await tool.invoke(
            AgentToolInvocation(
                arguments: [
                    "action": AnyCodable("add"),
                    "job": AnyCodable([
                        "name": AnyCodable("ping"),
                        "schedule": AnyCodable(["kind": AnyCodable("every"), "everyMs": AnyCodable(60_000)]),
                        "payload": AnyCodable(["kind": AnyCodable("agentTurn"), "message": AnyCodable("ping")]),
                    ]),
                ],
                context: AgentToolInvocationContext(sessionKey: "main", agentID: "main")
            ),
            update: nil
        )
        #expect(!added.isError, "\(added.text)")
        let jobID = try #require(await scheduler.automationJobList().first?.id)
        let record = try #require(try await scheduler.runJob(id: jobID))
        #expect(record.status == .ok)
        #expect(await provider.recorded().last?.prompt.contains("ping") == true)
        #expect(await log.names.contains("cron_changed"))
    }

    // MARK: Providers and auth

    @Test
    func routerResolvesProviderAliases() async throws {
        let apple = ScriptedToolProvider(id: "apple-fm", turns: [], fallback: ScriptedToolProvider.text("apple"))
        let router = ModelRouter(defaultProviderID: "echo", providers: [EchoModelProvider(), apple])
        let response = try await router.generate(ModelGenerationRequest(sessionKey: "s", prompt: "hi", providerID: "foundation"))
        #expect(response.text == "apple")
        #expect(await router.registeredProviderID(for: "apple-foundation") == "apple-fm")
        #expect(await router.registeredProviderID(for: "unknown-provider") == "unknown-provider")
        try await router.setDefaultProviderID("foundation")
        #expect(await router.primaryProvider(for: ModelGenerationRequest(sessionKey: "s", prompt: "x"))?.id == "apple-fm")
        #expect(ModelProviderSecrets.isNonSecretAuthMarker(" apple-fm-local "))
        #expect(!ModelProviderSecrets.isNonSecretAuthMarker("sk-live"))
    }

    @Test
    func factoryRoutesEveryAppleAliasToFoundationModels() throws {
        for id in ["apple-fm", "foundation", "apple-foundation"] {
            let config = ModelProviderConfig(api: .openAIResponses)
            #expect(try ModelProviderFactory.makeProvider(providerID: id, config: config) is FoundationModelsProvider)
        }
        #expect(OpenClawReferenceProviderCatalog.metadataEntry(for: "apple-media-understanding")?.capabilities.contains(.mediaUnderstanding) == true)
        #expect(OpenClawReferenceProviderCatalog.mediaUnderstandingMetadata(for: "apple-media-understanding")?.supports(.video) == true)
    }

    @Test
    func catalogDefinitionsCarryRuntimeFields() throws {
        let row = ModelCatalogModel(
            id: "reasoner",
            baseURL: "https://example.com/v1",
            reasoning: true,
            contextTokens: 100_000,
            thinkingLevelMap: ModelCatalogThinkingLevelMap(["minimal": .disabled, "high": .mapped("hard")]),
            cost: ModelCatalogCost(
                input: 1,
                output: 2,
                tieredPricing: [ModelCatalogPricingTier(input: 3, output: 4, cacheRead: 0, cacheWrite: 0, range: [0, 200_000])]
            ),
            compat: try JSONDecoder().decode(
                ModelCatalogCompatConfig.self,
                from: Data(#"{"supportedReasoningEfforts":["low","high"],"reasoningEffortMap":{"high":"HIGH"},"supportsTemperature":false}"#.utf8)
            ),
            params: ["network": AnyCodable("required")]
        )
        let definition = row.definitionConfig()
        #expect(definition.baseURL == "https://example.com/v1")
        #expect(definition.contextTokens == 100_000)
        #expect(definition.params?["network"]?.stringValue == "required")
        #expect(definition.compat?.supportedReasoningEfforts == ["low", "high"])
        #expect(definition.compat?.reasoningEffortMap == ["high": "HIGH"])
        #expect(definition.compat?.supportsTemperature == false)
        #expect(definition.cost.tieredPricing?.count == 1)
        #expect(definition.thinkingLevelMap?.entries["minimal"] == .some(nil))
        #expect(definition.thinkingLevelMap?.entries["high"] == "hard")
        #expect(ModelCatalogModel(definition: definition).definitionConfig() == definition)
    }

    @Test
    func authCatalogResolvesLegacyCodexToOpenAI() {
        let openai = InteractiveAuthFlowCatalog.descriptors(forProvider: "codex")
        #expect(openai.map(\.kind) == [.browserOAuth, .deviceCode])
        #expect(InteractiveAuthFlowCatalog.descriptor(for: "openai")?.callbackURL == OpenAIChatGPTOAuthConfiguration.callbackURL)
        #expect(InteractiveAuthFlowCatalog.descriptor(for: "qwen-portal")?.kind == .deviceCode)
        #expect(InteractiveAuthFlowCatalog.descriptors.map(\.providerID).filter { $0 == "openai" }.count == 2)
    }

    @Test
    func catalogRefreshSettingsResolveFromConfig() throws {
        let enabled = try ModelCatalogRefreshConfiguration(config: ModelCatalogRefreshConfig(enabled: true, url: "https://catalog.example.com/v1.json"))
        #expect(enabled.isEnabled)
        #expect(enabled.url.absoluteString == "https://catalog.example.com/v1.json")
        #expect(try ModelCatalogRefreshConfiguration(config: ModelCatalogRefreshConfig()).isEnabled == false)
        #expect(throws: OpenClawCoreError.self) {
            _ = try ModelCatalogRefreshConfiguration(config: ModelCatalogRefreshConfig(enabled: true, url: "http://example.com/catalog.json"))
        }
        let document = try Self.document(#"{"models": {"catalogRefresh": {"enabled": true}}}"#)
        #expect(try ModelCatalogRefreshConfiguration.resolve(from: document)?.url.absoluteString == ModelCatalogRefreshConfiguration.defaultURL)
        #expect(try ModelCatalogRefreshConfiguration.resolve(from: OpenClawConfigDocument()) == nil)
    }

    @Test
    func appleProviderConfigCarriesTimeoutAndJSONSchemaSupport() {
        let facts = AppleFoundationModelFacts(available: true, modelName: "AFM", contextWindow: 8_192)
        let config = FoundationModelsProvider.buildProviderConfig(facts: facts)
        #expect(config.timeoutSeconds == FoundationModelsProvider.defaultTimeoutSeconds)
        #expect(config.models.first?.compat?.supportsJSONSchemaResponseFormat == true)
    }

    @Test
    func subagentsEmitSpawnedAndEndedHooks() async throws {
        let hooks = HookRegistry()
        let log = HookEventLog()
        for hook in [HookName.subagentSpawned, .subagentEnded] {
            await hooks.register(hook) { context in
                await log.record(hook, context)
                return nil
            }
        }
        let provider = ScriptedToolProvider(turns: [], fallback: ScriptedToolProvider.text("child done"))
        let runtime = EmbeddedAgentRuntime(
            toolRegistry: AgentToolRegistry(),
            modelRouter: ModelRouter(defaultProviderID: provider.id, providers: [provider]),
            transcriptStore: InMemorySessionTranscriptStore(),
            hookRegistry: hooks,
            mediaUnderstandingServices: .none
        )
        let manager = SubagentManager(runtime: runtime)
        let record = try await manager.spawn(SubagentSpawnParams(task: "summarize", label: "Summary"), parentSessionKey: "agent:main:main")
        for _ in 0..<300 where await !log.names.contains("subagent_ended") {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await log.names == ["subagent_spawned", "subagent_ended"])
        let spawned = try #require(await log.first(.subagentSpawned))
        #expect(spawned["childSessionKey"]?.stringValue == record.childSessionKey)
        #expect(spawned["label"]?.stringValue == "Summary")
        #expect(await log.first(.subagentEnded)?["outcome"]?.stringValue == "ok")
    }

    // MARK: Foundation Models sessions

    @Test
    func foundationModelsSessionPlanCarriesPromptSectionsAndPolicyTools() async throws {
        let runtime = EmbeddedAgentRuntime(
            toolRegistry: AgentToolRegistry(tools: [EchoArgumentTool(), TerminatingTool()]),
            toolsConfiguration: AgentToolsConfiguration(policy: ToolPolicy(deny: ["finish"])),
            loopConfiguration: AgentLoopConfiguration(baseSystemPrompt: "You are Clawd."),
            mediaUnderstandingServices: .none
        )
        await runtime.addPromptContributor { context in
            "Model: \(context.providerID ?? "")/\(context.modelID ?? ""); tools: \(context.availableToolNames.sorted().joined(separator: ","))"
        }
        let plan = try await runtime.foundationModelsSessionPlan(agentID: nil, sessionKey: "fm", workspaceRootPath: nil, modelID: "system")
        #expect(plan.toolNames == ["echo"])
        #expect(plan.systemPrompt == "You are Clawd.\n\nModel: apple-fm/system; tools: echo")
    }
}
