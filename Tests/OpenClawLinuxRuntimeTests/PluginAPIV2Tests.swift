import Foundation
import Testing
import OpenClawAgents
import OpenClawCore
import OpenClawGateway
import OpenClawMCP
import OpenClawMemory
import OpenClawProtocol
import OpenClawSkills
@testable import OpenClawPlugins

@Suite("Plugin API v2")
struct PluginAPIV2Tests {
    struct GreetTool: AgentTool {
        let name = "plugin_greet"
        var descriptor: AgentToolDescriptor {
            AgentToolDescriptor(name: self.name, description: "Greets.", source: .core)
        }
        func invoke(_ invocation: AgentToolInvocation, update _: AgentToolUpdateHandler?) async throws -> AgentToolOutput {
            .text("hello \(invocation.arguments["who"]?.stringValue ?? "world")")
        }
    }

    struct Embeddings: MemoryEmbeddingProvider {
        let id = "plugin-embeddings"
        let model = "m"
        let dimensions = 1
        func embed(_ texts: [String], inputType _: MemoryEmbeddingInputType) async throws -> [[Float]] {
            texts.map { _ in [1] }
        }
    }

    struct FullPlugin: OpenClawPlugin {
        let id = "acme"
        let skillRoot: URL
        var manifest: PluginManifest? {
            PluginManifest(id: self.id, name: "Acme", description: "Test plugin", version: "1.2.3", categories: ["tools"], contracts: ["tools": ["plugin_greet"]])
        }

        func register(api: PluginAPI) async throws {
            try await api.registerTool(GreetTool())
            await api.registerHook(.beforeToolCall, priority: 5, event: BeforeToolCallEvent.self) { event, _ in
                event.toolName == "exec" ? BeforeToolCallDecision(block: true, blockReason: "acme blocks exec") : nil
            }
            await api.registerGatewayMethod("acme.echo", scope: GatewayConnectionContext.operatorReadScope) { request in
                AnyCodable(["echo": request.params["value"] ?? AnyCodable.nullValue])
            }
            await api.registerMCPServer(name: "acme-mcp", config: MCPServerConfig(url: "https://mcp.acme.test/mcp", transport: "streamable-http"))
            await api.registerContextEngine(id: "acme-context", engine: "engine-token")
            await api.registerMemoryEmbeddingProvider(Embeddings())
            await api.registerSkillRoot(self.skillRoot)
        }
    }

    @Test
    func registrationsAreOwnedAndUnloadRemovesThem() async throws {
        let root = try RuntimeExtTestSupport.temporaryDirectory("plugins")
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = AgentToolRegistry()
        let skills = SkillRegistry(workspaceRoot: root, managedSkillsRoot: root.appendingPathComponent("managed"), includePersonalAgentsRoot: false)
        let manager = MCPClientManager(config: MCPConfig(), transportFactory: { _, _, _ in throw MCPTransportError.closed("offline") })
        let registry = PluginRegistry(toolRegistry: tools, skillRegistry: skills, mcpManager: manager)
        let skillRoot = root.appendingPathComponent("acme-skills")
        try await registry.load(plugin: FullPlugin(skillRoot: skillRoot))

        let descriptor = try #require(await tools.descriptors().first { $0.name == "plugin_greet" })
        #expect(descriptor.source == .plugin(id: "acme"))
        #expect(await tools.ownerPluginID(forTool: "plugin_greet") == "acme")
        let call = try await tools.invoke(AgentToolCall(name: "plugin_greet", arguments: ["who": AnyCodable("swift")]))
        #expect(call.output.text == "hello swift")

        let decision = await registry.hookRegistry.runBeforeToolCall(BeforeToolCallEvent(toolName: "exec"))
        #expect(decision?.block == true)
        #expect(await registry.mcpServerConfigs().map(\.name) == ["acme-mcp"])
        #expect(await manager.probe("acme-mcp").error?.contains("not configured") == false)
        #expect(await registry.contextEngine(id: "acme-context") as? String == "engine-token")
        #expect(await registry.memoryEmbeddingProviders().map(\.id) == ["plugin-embeddings"])
        #expect(await skills.orderedRoots().contains(SkillRoot(source: .plugin, url: skillRoot.standardizedFileURL)))
        #expect(await registry.toolNames(pluginID: "acme") == ["plugin_greet"])

        await registry.unload(pluginID: "acme")
        #expect(await tools.hasTool(named: "plugin_greet") == false)
        #expect(await registry.hookRegistry.runBeforeToolCall(BeforeToolCallEvent(toolName: "exec")) == nil)
        #expect(await registry.mcpServerConfigs().isEmpty)
        #expect(await manager.probe("acme-mcp").error?.contains("not configured") == true)
        #expect(await registry.contextEngineIDs().isEmpty)
        #expect(await registry.memoryEmbeddingProviders().isEmpty)
        #expect(await !skills.orderedRoots().contains { $0.source == .plugin })
        #expect(await registry.contains(id: "acme") == false)
    }

    @Test
    func gatewayMethodsListEnableAndHookStatus() async throws {
        let root = try RuntimeExtTestSupport.temporaryDirectory("plugins-gateway")
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = AgentToolRegistry()
        let registry = PluginRegistry(toolRegistry: tools)
        try await registry.load(plugin: FullPlugin(skillRoot: root.appendingPathComponent("s")))
        let server = RuntimeExtTestSupport.makeGatewayServer(root: root)
        await attachPluginRegistry(registry, to: server)

        let echo = await RuntimeExtTestSupport.call(server, "acme.echo", params: ["value": AnyCodable(42)])
        #expect(echo.ok)
        #expect(echo.payload?.dictionaryValue?["echo"]?.intValue == 42)
        let noScope = GatewayConnectionContext(connectionID: "c", role: "operator", scopes: [])
        let denied = await RuntimeExtTestSupport.call(server, "acme.echo", params: [:], connection: noScope)
        #expect(denied.error?.code == ErrorCode.forbidden.rawValue)

        let list = await RuntimeExtTestSupport.call(server, "plugins.list", params: [:])
        let listed = try RuntimeExtTestSupport.decode(PluginsListResult.self, from: list.payload)
        #expect(listed.mutationallowed == false)
        let entry = try #require(listed.plugins.first)
        #expect(entry.id == "acme" && entry.name == "Acme" && entry.version == "1.2.3" && entry.origin == "swift")
        #expect(entry.enabled && entry.state.stringValue == "enabled" && entry.removable == false)
        #expect(entry.runtime?.state.stringValue == "active")

        let disable = await RuntimeExtTestSupport.call(server, "plugins.setEnabled", params: ["pluginId": AnyCodable("acme"), "enabled": AnyCodable(false)])
        #expect(disable.ok)
        #expect(await tools.hasTool(named: "plugin_greet") == false)
        let gone = await RuntimeExtTestSupport.call(server, "acme.echo", params: [:])
        #expect(gone.ok == false)
        let enable = await RuntimeExtTestSupport.call(server, "plugins.setEnabled", params: ["pluginId": AnyCodable("acme"), "enabled": AnyCodable(true)])
        #expect(enable.ok)
        #expect(await tools.hasTool(named: "plugin_greet"))
        let unknown = await RuntimeExtTestSupport.call(server, "plugins.setEnabled", params: ["pluginId": AnyCodable("nope"), "enabled": AnyCodable(true)])
        #expect(unknown.error?.code == ErrorCode.invalidRequest.rawValue)

        await registry.hookRegistry.register(.gatewayStart) { _ in nil }
        let status = await RuntimeExtTestSupport.call(server, "hooks.status", params: [:])
        let counts = status.payload?.dictionaryValue?["counts"]?.dictionaryValue
        #expect(counts?["before_tool_call"]?.intValue == 1)
        #expect(counts?["gateway_start"]?.intValue == 1)
        #expect(status.payload?.dictionaryValue?["plugins"]?.dictionaryValue?["acme"]?.arrayValue?.first?.stringValue == "before_tool_call")

        let install = await RuntimeExtTestSupport.call(server, "plugins.install", params: [:])
        #expect(install.error?.code == ErrorCode.unavailable.rawValue)
    }

    @Test
    func manifestDecodesUpstreamExampleAndValidatesConfig() throws {
        let json = """
        {
          "id": "code-mode-quickjs",
          "name": "QuickJS Code Mode",
          "description": "Hardened JavaScript execution for Code Mode using QuickJS in WebAssembly.",
          "categories": ["infrastructure"],
          "activation": { "onStartup": false },
          "contracts": { "codeModeExecutors": ["quickjs"] },
          "configSchema": { "type": "object", "additionalProperties": false, "properties": {} },
          "mcpServers": { "local": { "command": "server", "args": ["--stdio"] } },
          "uiHints": { "color": "blue" }
        }
        """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        #expect(manifest.id == "code-mode-quickjs")
        #expect(manifest.activation?.onStartup == false)
        #expect(manifest.contracts?["codeModeExecutors"] == ["quickjs"])
        #expect(manifest.mcpServers?["local"]?.args == ["--stdio"])
        #expect(manifest.extra["uiHints"] != nil)
        try manifest.validateConfig(AnyCodable([String: AnyCodable]()))
        #expect(throws: MCPJSONSchemaValidator.Failure.self) {
            try manifest.validateConfig(AnyCodable(["unexpected": AnyCodable(true)]))
        }
        let roundTrip = try JSONDecoder().decode(PluginManifest.self, from: JSONEncoder().encode(manifest))
        #expect(roundTrip == manifest)
    }

    @Test
    func failingRegistrationMarksPluginAndCleansUp() async {
        struct Broken: OpenClawPlugin {
            let id = "broken"
            func register(api: PluginAPI) async throws {
                try await api.registerTool(GreetTool())
                throw OpenClawCoreError.unavailable("boom")
            }
        }
        let tools = AgentToolRegistry()
        let registry = PluginRegistry(toolRegistry: tools)
        await #expect(throws: OpenClawCoreError.self) {
            try await registry.load(plugin: Broken())
        }
        #expect(await tools.hasTool(named: "plugin_greet") == false)
        #expect(await registry.catalogEntries().first?.state.stringValue == "error")
    }
}
