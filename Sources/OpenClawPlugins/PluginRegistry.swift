import Foundation
import OpenClawAgents
import OpenClawCore
import OpenClawGateway
import OpenClawMCP
import OpenClawMemory
import OpenClawProtocol
import OpenClawSkills

/// Plugin contract for static Swift plugin registration.
public protocol OpenClawPlugin: Sendable {
    /// Stable plugin identifier.
    var id: String { get }
    /// Optional package metadata (`openclaw.plugin.json`), shown in `plugins.list`.
    var manifest: PluginManifest? { get }
    /// Registers plugin components through the provided API.
    /// - Parameter api: Mutable registration surface.
    func register(api: PluginAPI) async throws
}

public extension OpenClawPlugin {
    /// Default: no manifest.
    var manifest: PluginManifest? {
        nil
    }
}

/// Supported plugin hook names (the shared ``HookName`` vocabulary).
public typealias PluginHookName = HookName
/// Payload passed to plugin hook handlers (the shared ``HookContext``).
public typealias PluginHookPayload = HookContext
/// Result returned from a plugin hook handler (the shared ``HookResult``).
public typealias PluginHookResult = HookResult
/// Plugin hook handler signature.
public typealias PluginHookHandler = HookHandler
/// Legacy plugin gateway method handler signature (params in, payload out).
public typealias PluginGatewayMethodHandler = @Sendable ([String: AnyCodable]) async throws -> AnyCodable

/// Service contract managed by the plugin registry lifecycle.
public protocol PluginService: Sendable {
    /// Service identifier.
    var id: String { get }
    /// Starts service resources.
    func start() async throws
    /// Stops service resources.
    func stop() async
}

/// Runtime state of a loaded plugin (upstream `PluginRuntimeStatus.state`).
public enum PluginRuntimeState: String, Codable, Sendable, Equatable {
    /// Registered and serving.
    case active
    /// Disabled; its registrations were removed.
    case disabled
    /// Registration or a service start failed.
    case serviceFailed = "service-failed"
}

/// Wraps a plugin tool so its descriptor reports `.plugin(id:)` as its source.
struct PluginOwnedAgentTool: AgentTool {
    let base: any AgentTool
    let pluginID: String

    var name: String {
        self.base.name
    }

    var descriptor: AgentToolDescriptor {
        var descriptor = self.base.descriptor
        descriptor.source = .plugin(id: self.pluginID)
        return descriptor
    }

    func invoke(_ invocation: AgentToolInvocation, update: AgentToolUpdateHandler?) async throws -> AgentToolOutput {
        try await self.base.invoke(invocation, update: update)
    }
}

/// Actor-backed registry for static Swift plugins: tools, hooks, gateway methods, services, MCP
/// servers, context engines, memory embedding providers, and skill roots.
///
/// Every registration records its owning plugin so ``unload(pluginID:)`` and
/// ``setEnabled(_:for:)`` can remove it. Hooks go into the shared ``hookRegistry`` (pass the
/// runtime's registry so plugin and app hooks observe the same events); tools go into the
/// ``AgentToolRegistry`` when one is attached.
public actor PluginRegistry {
    private struct Registrations {
        var toolNames: Set<String> = []
        var hookIDs: [HookRegistrationID] = []
        var gatewayMethods: Set<String> = []
        var serviceIDs: Set<String> = []
        var mcpServers: Set<String> = []
        var contextEngines: Set<String> = []
        var embeddingProviders: Set<String> = []
        var skillRoots: [URL] = []
    }

    private struct Record {
        var plugin: (any OpenClawPlugin)?
        var manifest: PluginManifest?
        var enabled = true
        var state: PluginRuntimeState = .active
        var error: String?
        var registrations = Registrations()
    }

    private struct GatewayMethod {
        let pluginID: String?
        let descriptor: GatewayMethodDescriptor
        let handler: GatewayMethodHandler
    }

    /// Hook registry plugin hooks are registered into.
    nonisolated public let hookRegistry: HookRegistry
    private let toolRegistry: AgentToolRegistry?
    private let skillRegistry: SkillRegistry?
    private let mcpManager: MCPClientManager?
    private var records: [String: Record] = [:]
    private var order: [String] = []
    private var legacyToolNames: [String: Set<String>] = [:]
    private var gatewayMethods: [String: GatewayMethod] = [:]
    private var services: [String: (pluginID: String?, service: any PluginService)] = [:]
    private var tools: [String: (pluginID: String, tool: any AgentTool)] = [:]
    private var mcpServers: [String: (pluginID: String, config: MCPServerConfig)] = [:]
    private var contextEngines: [String: (pluginID: String, engine: any Sendable)] = [:]
    private var embeddingProviders: [String: (pluginID: String, provider: any MemoryEmbeddingProvider)] = [:]
    private var skillRoots: [(pluginID: String, url: URL)] = []
    private var generation = 0

    /// Creates a plugin registry.
    /// - Parameters:
    ///   - hookRegistry: Shared hook registry (defaults to a new one).
    ///   - toolRegistry: Tool registry plugin tools are installed into.
    ///   - skillRegistry: Skill registry plugin skill roots are added to.
    ///   - mcpManager: MCP manager plugin MCP servers are added to.
    public init(
        hookRegistry: HookRegistry = HookRegistry(),
        toolRegistry: AgentToolRegistry? = nil,
        skillRegistry: SkillRegistry? = nil,
        mcpManager: MCPClientManager? = nil
    ) {
        self.hookRegistry = hookRegistry
        self.toolRegistry = toolRegistry
        self.skillRegistry = skillRegistry
        self.mcpManager = mcpManager
    }

    // MARK: - Loading

    /// Loads a plugin and executes its registration callback.
    ///
    /// A registration failure marks the plugin `service-failed`, removes whatever it registered, and
    /// rethrows.
    /// - Parameter plugin: Plugin implementation.
    public func load(plugin: any OpenClawPlugin) async throws {
        let id = plugin.id
        if self.records[id] != nil {
            await self.removeRegistrations(of: id)
        } else {
            self.order.append(id)
        }
        self.records[id] = Record(plugin: plugin, manifest: plugin.manifest)
        do {
            try await plugin.register(api: PluginAPI(pluginID: id, registry: self))
        } catch {
            await self.removeRegistrations(of: id)
            self.records[id]?.state = .serviceFailed
            self.records[id]?.error = error.localizedDescription
            throw error
        }
        self.generation += 1
    }

    /// Unloads a plugin: removes its tools, hooks, gateway methods, services (stopped), MCP servers,
    /// context engines, embedding providers and skill roots, then forgets it.
    /// - Parameter pluginID: Plugin identifier.
    public func unload(pluginID: String) async {
        await self.removeRegistrations(of: pluginID)
        self.records.removeValue(forKey: pluginID)
        self.order.removeAll { $0 == pluginID }
        self.legacyToolNames.removeValue(forKey: pluginID)
        self.generation += 1
    }

    /// Enables or disables a plugin; disabling removes its registrations, enabling re-runs `register(api:)`.
    /// - Parameters:
    ///   - enabled: New state.
    ///   - pluginID: Plugin identifier.
    public func setEnabled(_ enabled: Bool, for pluginID: String) async throws {
        guard var record = self.records[pluginID] else {
            throw OpenClawCoreError.invalidConfiguration("Unknown plugin: \(pluginID)")
        }
        guard record.enabled != enabled else { return }
        if enabled {
            record.enabled = true
            record.state = .active
            record.error = nil
            self.records[pluginID] = record
            if let plugin = record.plugin {
                do {
                    try await plugin.register(api: PluginAPI(pluginID: pluginID, registry: self))
                } catch {
                    await self.removeRegistrations(of: pluginID)
                    self.records[pluginID]?.state = .serviceFailed
                    self.records[pluginID]?.error = error.localizedDescription
                    throw error
                }
            }
        } else {
            await self.removeRegistrations(of: pluginID)
            record = self.records[pluginID] ?? record
            record.enabled = false
            record.state = .disabled
            self.records[pluginID] = record
        }
        self.generation += 1
    }

    /// Registers a plugin identifier without a plugin instance (legacy).
    /// - Parameter id: Plugin ID.
    public func register(id: String) {
        if self.records[id] == nil {
            self.records[id] = Record()
            self.order.append(id)
        }
    }

    /// Returns whether a plugin ID is registered.
    /// - Parameter id: Plugin ID.
    /// - Returns: `true` when registered.
    public func contains(id: String) -> Bool {
        self.records[id] != nil
    }

    /// Returns all plugin IDs sorted alphabetically.
    public func allIDs() -> [String] {
        self.records.keys.sorted()
    }

    /// Whether a plugin is enabled.
    /// - Parameter pluginID: Plugin identifier.
    /// - Returns: `true` when enabled.
    public func isEnabled(_ pluginID: String) -> Bool {
        self.records[pluginID]?.enabled ?? false
    }

    // MARK: - Tools

    /// Associates a tool name with a plugin ID (legacy bookkeeping; prefer ``PluginAPI/registerTool(_:)``).
    /// - Parameters:
    ///   - pluginID: Plugin identifier.
    ///   - toolName: Registered tool name.
    public func registerToolName(pluginID: String, toolName: String) {
        var current = self.legacyToolNames[pluginID] ?? []
        current.insert(toolName)
        self.legacyToolNames[pluginID] = current
    }

    /// Returns tool names registered by a plugin (real tools and legacy names).
    /// - Parameter pluginID: Plugin identifier.
    /// - Returns: Sorted tool names.
    public func toolNames(pluginID: String) -> [String] {
        let real = self.records[pluginID]?.registrations.toolNames ?? []
        return Array(real.union(self.legacyToolNames[pluginID] ?? [])).sorted()
    }

    /// Every plugin tool (with `.plugin(id:)` descriptors), sorted by name.
    public func pluginTools() -> [any AgentTool] {
        self.tools.keys.sorted().compactMap { self.tools[$0]?.tool }
    }

    /// Installs every plugin tool into a tool registry (for registries attached after loading).
    /// - Parameter registry: Tool registry.
    public func installTools(into registry: AgentToolRegistry) async throws {
        for name in self.tools.keys.sorted() {
            guard let entry = self.tools[name] else { continue }
            try await registry.register(entry.tool, ownerPluginID: entry.pluginID, replacing: true)
        }
    }

    func addTool(_ tool: any AgentTool, pluginID: String) async throws {
        let owned = PluginOwnedAgentTool(base: tool, pluginID: pluginID)
        if let existing = self.tools[owned.name], existing.pluginID != pluginID {
            throw OpenClawCoreError.invalidConfiguration("Tool '\(owned.name)' is already registered by plugin '\(existing.pluginID)'")
        }
        if let toolRegistry {
            try await toolRegistry.register(owned, ownerPluginID: pluginID, replacing: self.tools[owned.name] != nil)
        } else if !AgentToolDescriptor.isValidName(owned.name) {
            throw OpenClawCoreError.invalidConfiguration("Tool name '\(owned.name)' must match ^[A-Za-z][A-Za-z0-9_-]{0,63}$")
        }
        self.tools[owned.name] = (pluginID, owned)
        self.records[pluginID]?.registrations.toolNames.insert(owned.name)
    }

    // MARK: - Hooks

    /// Registers a hook handler (legacy entry point, no plugin ownership).
    /// - Parameters:
    ///   - hookName: Hook name.
    ///   - handler: Hook handler closure.
    public func registerHook(_ hookName: PluginHookName, handler: @escaping PluginHookHandler) async {
        await self.hookRegistry.register(hookName, handler: handler)
    }

    /// Emits a hook through the shared registry and collects non-nil results.
    /// - Parameters:
    ///   - hookName: Hook to invoke.
    ///   - payload: Hook payload.
    /// - Returns: Collected hook results.
    public func emitHook(_ hookName: PluginHookName, payload: PluginHookPayload) async throws -> [PluginHookResult] {
        try await self.hookRegistry.emit(hookName, context: payload)
    }

    func recordHook(_ id: HookRegistrationID, pluginID: String) {
        self.records[pluginID]?.registrations.hookIDs.append(id)
    }

    /// `hooks.status`-style report: every registration with its owner, and counts per hook.
    public func hooksStatus() async -> AnyCodable {
        let registrations = await self.hookRegistry.allRegistrations()
        var counts: [String: Int] = [:]
        var byPlugin: [String: Set<String>] = [:]
        for registration in registrations {
            counts[registration.hook.rawValue, default: 0] += 1
            if let plugin = registration.pluginID {
                byPlugin[plugin, default: []].insert(registration.hook.rawValue)
            }
        }
        let hooks = registrations.map { registration in
            AnyCodable([
                "name": AnyCodable(registration.hook.rawValue),
                "pluginId": registration.pluginID.map { AnyCodable($0) } ?? AnyCodable.nullValue,
                "priority": AnyCodable(registration.priority),
                "source": AnyCodable(registration.pluginID == nil ? "sdk" : "plugin"),
                "deprecated": AnyCodable(registration.hook.isDeprecatedAlias),
            ])
        }
        return AnyCodable([
            "hooks": AnyCodable(hooks),
            "counts": AnyCodable(counts.mapValues { AnyCodable($0) }),
            "plugins": AnyCodable(byPlugin.mapValues { AnyCodable($0.sorted().map { AnyCodable($0) }) }),
        ])
    }

    // MARK: - Gateway methods

    /// Registers a legacy gateway method handler (params dictionary in, payload out).
    /// - Parameters:
    ///   - method: Gateway method name.
    ///   - handler: Method handler.
    public func registerGatewayMethod(_ method: String, handler: @escaping PluginGatewayMethodHandler) {
        self.addGatewayMethod(
            method,
            descriptor: GatewayMethodDescriptor(name: method, family: "plugin", scope: GatewayConnectionContext.operatorWriteScope, since: "plugin"),
            pluginID: nil
        ) { request in
            try await handler(request.params)
        }
    }

    func addGatewayMethod(_ method: String, descriptor: GatewayMethodDescriptor, pluginID: String?, handler: @escaping GatewayMethodHandler) {
        let name = method.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        self.gatewayMethods[name] = GatewayMethod(pluginID: pluginID, descriptor: descriptor, handler: handler)
        if let pluginID {
            self.records[pluginID]?.registrations.gatewayMethods.insert(name)
        }
    }

    /// Invokes a previously registered gateway method.
    /// - Parameters:
    ///   - method: Method name.
    ///   - params: Method parameter payload.
    /// - Returns: Method result payload.
    public func invokeGatewayMethod(_ method: String, params: [String: AnyCodable]) async throws -> AnyCodable {
        guard let entry = self.gatewayMethods[method] else {
            throw OpenClawCoreError.unavailable("Plugin gateway method not found: \(method)")
        }
        return try await entry.handler(GatewayMethodRequest(
            method: method,
            rawParams: AnyCodable(params),
            descriptor: entry.descriptor
        )) ?? AnyCodable.nullValue
    }

    /// Handler for a plugin gateway method, enforcing the registered role and scope.
    /// - Parameter method: Method name.
    /// - Returns: Handler, or `nil` when no plugin serves the method.
    public func gatewayHandler(for method: String) -> GatewayMethodHandler? {
        guard let entry = self.gatewayMethods[method] else { return nil }
        let descriptor = entry.descriptor
        let handler = entry.handler
        return { request in
            let scope = descriptor.scope
            let role = request.connection.role
            if scope == "node" ? role != "node" : role != "operator" {
                throw GatewayMethodError.invalidRequest("unauthorized role: \(role)")
            }
            if scope != "node", !request.connection.allows(scope: scope) {
                throw GatewayMethodError.missingScope(scope)
            }
            return try await handler(request)
        }
    }

    /// Resolver for ``GatewayServer/addMethodResolver(_:)`` (upstream dispatch order: core, plugin, unknown).
    nonisolated public func gatewayMethodResolver() -> GatewayMethodResolver {
        { [weak self] method in
            await self?.gatewayHandler(for: method)
        }
    }

    /// Names of plugin gateway methods.
    public func gatewayMethodNames() -> [String] {
        self.gatewayMethods.keys.sorted()
    }

    // MARK: - Services

    /// Registers a managed plugin service instance.
    /// - Parameter service: Service implementation.
    public func registerService(_ service: any PluginService) {
        self.services[service.id] = (nil, service)
    }

    func addService(_ service: any PluginService, pluginID: String) {
        self.services[service.id] = (pluginID, service)
        self.records[pluginID]?.registrations.serviceIDs.insert(service.id)
    }

    /// Starts all registered services; a failing service marks its plugin `service-failed`.
    public func startServices() async throws {
        for id in self.services.keys.sorted() {
            guard let entry = self.services[id] else { continue }
            do {
                try await entry.service.start()
            } catch {
                if let pluginID = entry.pluginID {
                    self.records[pluginID]?.state = .serviceFailed
                    self.records[pluginID]?.error = error.localizedDescription
                }
                throw error
            }
        }
    }

    /// Stops all registered services.
    public func stopServices() async {
        for id in self.services.keys.sorted() {
            await self.services[id]?.service.stop()
        }
    }

    // MARK: - MCP, context engines, embeddings, skills

    func addMCPServer(name: String, config: MCPServerConfig, pluginID: String) async {
        self.mcpServers[name] = (pluginID, config)
        self.records[pluginID]?.registrations.mcpServers.insert(name)
        await self.mcpManager?.addServer(name: name, config: config)
    }

    /// Plugin-declared MCP servers, sorted by name.
    public func mcpServerConfigs() -> [(name: String, config: MCPServerConfig)] {
        self.mcpServers.keys.sorted().compactMap { name in self.mcpServers[name].map { (name, $0.config) } }
    }

    func addContextEngine(id: String, engine: any Sendable, pluginID: String) {
        self.contextEngines[id] = (pluginID, engine)
        self.records[pluginID]?.registrations.contextEngines.insert(id)
    }

    /// A registered context engine (cast it to the runtime's context-engine type).
    /// - Parameter id: Engine identifier.
    /// - Returns: The engine, if registered.
    public func contextEngine(id: String) -> (any Sendable)? {
        self.contextEngines[id]?.engine
    }

    /// Registered context engine identifiers.
    public func contextEngineIDs() -> [String] {
        self.contextEngines.keys.sorted()
    }

    func addEmbeddingProvider(_ provider: any MemoryEmbeddingProvider, pluginID: String) {
        self.embeddingProviders[provider.id] = (pluginID, provider)
        self.records[pluginID]?.registrations.embeddingProviders.insert(provider.id)
    }

    /// Plugin-provided memory embedding providers, sorted by id.
    public func memoryEmbeddingProviders() -> [any MemoryEmbeddingProvider] {
        self.embeddingProviders.keys.sorted().compactMap { self.embeddingProviders[$0]?.provider }
    }

    func addSkillRoot(_ url: URL, pluginID: String) async {
        self.skillRoots.append((pluginID, url))
        self.records[pluginID]?.registrations.skillRoots.append(url)
        await self.skillRegistry?.addPluginSkillRoot(url)
    }

    /// Plugin skill roots in registration order.
    public func pluginSkillRoots() -> [URL] {
        self.skillRoots.map(\.url)
    }

    // MARK: - Catalog

    /// Catalog generation (bumped on every load, unload and enable change).
    public var catalogGeneration: Int {
        self.generation
    }

    /// `plugins.list` entries for every known plugin (upstream `PluginCatalogEntry`, `origin: swift`).
    public func catalogEntries() -> [PluginCatalogEntry] {
        self.order.compactMap { id -> PluginCatalogEntry? in
            guard let record = self.records[id] else { return nil }
            let manifest = record.manifest
            let state: String
            switch record.state {
            case .active: state = "enabled"
            case .disabled: state = "disabled"
            case .serviceFailed: state = "error"
            }
            return PluginCatalogEntry(
                id: id,
                name: manifest?.name ?? id,
                description: manifest?.description,
                version: manifest?.version,
                kind: manifest?.contracts.map { Array($0.keys).sorted() },
                origin: "swift",
                installed: true,
                enabled: record.enabled,
                state: AnyCodable(state),
                error: record.error,
                runtime: PluginRuntimeStatus(state: AnyCodable(record.state.rawValue), error: record.error),
                categories: manifest?.categories,
                removable: false
            )
        }
    }

    // MARK: - Internals

    private func removeRegistrations(of pluginID: String) async {
        guard let registrations = self.records[pluginID]?.registrations else { return }
        for name in registrations.toolNames {
            self.tools.removeValue(forKey: name)
            if let toolRegistry, await toolRegistry.ownerPluginID(forTool: name) == pluginID {
                await toolRegistry.unregister(named: name)
            }
        }
        for id in registrations.hookIDs {
            await self.hookRegistry.unregister(id)
        }
        for method in registrations.gatewayMethods where self.gatewayMethods[method]?.pluginID == pluginID {
            self.gatewayMethods.removeValue(forKey: method)
        }
        for id in registrations.serviceIDs {
            if let entry = self.services.removeValue(forKey: id) {
                await entry.service.stop()
            }
        }
        for name in registrations.mcpServers {
            self.mcpServers.removeValue(forKey: name)
            await self.mcpManager?.removeServer(name: name)
        }
        for id in registrations.contextEngines {
            self.contextEngines.removeValue(forKey: id)
        }
        for id in registrations.embeddingProviders {
            self.embeddingProviders.removeValue(forKey: id)
        }
        for url in registrations.skillRoots {
            await self.skillRegistry?.removePluginSkillRoot(url)
        }
        self.skillRoots.removeAll { $0.pluginID == pluginID }
        self.records[pluginID]?.registrations = Registrations()
    }
}

/// Registration API passed to plugins during load.
public struct PluginAPI: Sendable {
    /// Plugin being registered (empty for APIs built with the legacy closure initializer).
    public let pluginID: String
    private let registry: PluginRegistry?
    private let registerToolNameFn: @Sendable (_ pluginID: String, _ toolName: String) async -> Void
    private let registerHookFn: @Sendable (_ hookName: PluginHookName, _ handler: @escaping PluginHookHandler) async -> Void
    private let registerGatewayMethodFn: @Sendable (_ method: String, _ handler: @escaping PluginGatewayMethodHandler) async -> Void
    private let registerServiceFn: @Sendable (_ service: any PluginService) async -> Void

    /// Creates a plugin registration API from callback closures (legacy; v2 registrations are no-ops).
    /// - Parameters:
    ///   - registerToolName: Tool-name registration callback.
    ///   - registerHook: Hook registration callback.
    ///   - registerGatewayMethod: Gateway-method registration callback.
    ///   - registerService: Service registration callback.
    public init(
        registerToolName: @escaping @Sendable (_ pluginID: String, _ toolName: String) async -> Void,
        registerHook: @escaping @Sendable (_ hookName: PluginHookName, _ handler: @escaping PluginHookHandler) async -> Void,
        registerGatewayMethod: @escaping @Sendable (_ method: String, _ handler: @escaping PluginGatewayMethodHandler) async -> Void,
        registerService: @escaping @Sendable (_ service: any PluginService) async -> Void
    ) {
        self.pluginID = ""
        self.registry = nil
        self.registerToolNameFn = registerToolName
        self.registerHookFn = registerHook
        self.registerGatewayMethodFn = registerGatewayMethod
        self.registerServiceFn = registerService
    }

    init(pluginID: String, registry: PluginRegistry) {
        self.pluginID = pluginID
        self.registry = registry
        self.registerToolNameFn = { owner, toolName in await registry.registerToolName(pluginID: owner, toolName: toolName) }
        self.registerHookFn = { hook, handler in
            let id = await registry.hookRegistry.register(hook, pluginID: pluginID, handler: handler)
            await registry.recordHook(id, pluginID: pluginID)
        }
        self.registerGatewayMethodFn = { method, handler in
            await registry.addGatewayMethod(
                method,
                descriptor: GatewayMethodDescriptor(name: method, family: "plugin", scope: GatewayConnectionContext.operatorWriteScope, since: "plugin"),
                pluginID: pluginID
            ) { request in
                try await handler(request.params)
            }
        }
        self.registerServiceFn = { service in await registry.addService(service, pluginID: pluginID) }
    }

    /// Records a tool name for a plugin (deprecated bookkeeping-only API; use ``registerTool(_:)``).
    /// - Parameters:
    ///   - pluginID: Plugin identifier.
    ///   - toolName: Tool name.
    public func registerToolName(pluginID: String, toolName: String) async {
        await self.registerToolNameFn(pluginID, toolName)
    }

    /// Registers a real agent tool owned by the plugin (its descriptor source becomes `.plugin(id:)`).
    /// - Parameter tool: Tool implementation.
    /// - Throws: For invalid names or names owned by another plugin.
    public func registerTool(_ tool: any AgentTool) async throws {
        try await self.registry?.addTool(tool, pluginID: self.pluginID)
    }

    /// Registers a hook handler in the shared hook registry.
    /// - Parameters:
    ///   - hookName: Hook name.
    ///   - priority: Priority (higher runs first).
    ///   - handler: Hook handler closure.
    public func registerHook(_ hookName: PluginHookName, priority: Int = 0, handler: @escaping PluginHookHandler) async {
        guard let registry else {
            await self.registerHookFn(hookName, handler)
            return
        }
        let id = await registry.hookRegistry.register(hookName, priority: priority, pluginID: self.pluginID, handler: handler)
        await registry.recordHook(id, pluginID: self.pluginID)
    }

    /// Registers a typed hook handler.
    /// - Parameters:
    ///   - hookName: Hook name.
    ///   - priority: Priority.
    ///   - event: Event type.
    ///   - handler: Typed handler.
    public func registerHook<Event: Decodable & Sendable, Result: Encodable & Sendable>(
        _ hookName: PluginHookName,
        priority: Int = 0,
        event: Event.Type,
        handler: @escaping @Sendable (Event, HookContext) async throws -> Result?
    ) async {
        guard let registry else { return }
        let id = await registry.hookRegistry.register(hookName, priority: priority, pluginID: self.pluginID, event: event, handler: handler)
        await registry.recordHook(id, pluginID: self.pluginID)
    }

    /// Registers a legacy gateway method handler (params dictionary in, payload out; `operator.write` scope).
    /// - Parameters:
    ///   - method: Method name.
    ///   - handler: Handler closure.
    public func registerGatewayMethod(_ method: String, handler: @escaping PluginGatewayMethodHandler) async {
        await self.registerGatewayMethodFn(method, handler)
    }

    /// Registers a gateway method served through the plugin method resolver.
    /// - Parameters:
    ///   - method: Method name.
    ///   - scope: Required scope (`operator.read`, `operator.write`, `operator.admin`, `node`, …).
    ///   - handler: Handler receiving the full request context.
    public func registerGatewayMethod(_ method: String, scope: String, handler: @escaping GatewayMethodHandler) async {
        await self.registry?.addGatewayMethod(
            method,
            descriptor: GatewayMethodDescriptor(name: method, family: "plugin", scope: scope, since: "plugin"),
            pluginID: self.pluginID,
            handler: handler
        )
    }

    /// Registers a static MCP server that exists while the plugin is enabled.
    /// - Parameters:
    ///   - name: Server name.
    ///   - config: Server definition.
    public func registerMCPServer(name: String, config: MCPServerConfig) async {
        await self.registry?.addMCPServer(name: name, config: config, pluginID: self.pluginID)
    }

    /// Registers a context engine (retrieve it with ``PluginRegistry/contextEngine(id:)``).
    /// - Parameters:
    ///   - id: Engine identifier.
    ///   - engine: Engine instance (for example a runtime `ContextEngine`).
    public func registerContextEngine(id: String, engine: any Sendable) async {
        await self.registry?.addContextEngine(id: id, engine: engine, pluginID: self.pluginID)
    }

    /// Registers a memory embedding provider.
    /// - Parameter provider: Provider.
    public func registerMemoryEmbeddingProvider(_ provider: any MemoryEmbeddingProvider) async {
        await self.registry?.addEmbeddingProvider(provider, pluginID: self.pluginID)
    }

    /// Registers a plugin skill root (loaded with the `plugin` source, reported as `openclaw-extra`).
    /// - Parameter url: Root directory.
    public func registerSkillRoot(_ url: URL) async {
        await self.registry?.addSkillRoot(url, pluginID: self.pluginID)
    }

    /// Registers a managed plugin service.
    /// - Parameter service: Service implementation.
    public func registerService(_ service: any PluginService) async {
        await self.registerServiceFn(service)
    }
}
