import Foundation
import OpenClawCore
import OpenClawProtocol

/// Plugin contract for static Swift plugin registration.
public protocol OpenClawPlugin: Sendable {
    /// Stable plugin identifier.
    var id: String { get }
    /// Registers plugin components through the provided API.
    /// - Parameter api: Mutable registration surface.
    func register(api: PluginAPI) async throws
}

/// Actor-backed registry for plugins, hooks, methods, and services.
public actor PluginRegistry {
    private var pluginIDs: Set<String> = []
    private var toolNamesByPlugin: [String: Set<String>] = [:]
    private var hooks: [PluginHookName: [PluginHookHandler]] = [:]
    private var gatewayMethods: [String: PluginGatewayMethodHandler] = [:]
    private var services: [String: any PluginService] = [:]

    /// Creates an empty plugin registry.
    public init() {}

    /// Loads a plugin and executes its registration callback.
    /// - Parameter plugin: Plugin implementation.
    public func load(plugin: any OpenClawPlugin) async throws {
        self.register(id: plugin.id)
        let api = PluginAPI(
            registerToolName: { [weak self] pluginID, toolName in
                await self?.registerToolName(pluginID: pluginID, toolName: toolName)
            },
            registerHook: { [weak self] hookName, handler in
                await self?.registerHook(hookName, handler: handler)
            },
            registerGatewayMethod: { [weak self] method, handler in
                await self?.registerGatewayMethod(method, handler: handler)
            },
            registerService: { [weak self] service in
                await self?.registerService(service)
            }
        )
        try await plugin.register(api: api)
    }

    /// Registers a plugin identifier.
    /// - Parameter id: Plugin ID.
    public func register(id: String) {
        self.pluginIDs.insert(id)
    }

    /// Returns whether a plugin ID is registered.
    /// - Parameter id: Plugin ID.
    /// - Returns: `true` when registered.
    public func contains(id: String) -> Bool {
        self.pluginIDs.contains(id)
    }

    /// Returns all plugin IDs sorted alphabetically.
    public func allIDs() -> [String] {
        self.pluginIDs.sorted()
    }

    /// Associates a tool name with a plugin ID.
    /// - Parameters:
    ///   - pluginID: Plugin identifier.
    ///   - toolName: Registered tool name.
    public func registerToolName(pluginID: String, toolName: String) {
        var current = self.toolNamesByPlugin[pluginID] ?? []
        current.insert(toolName)
        self.toolNamesByPlugin[pluginID] = current
    }

    /// Returns tool names registered by a plugin.
    /// - Parameter pluginID: Plugin identifier.
    /// - Returns: Sorted tool names.
    public func toolNames(pluginID: String) -> [String] {
        Array(self.toolNamesByPlugin[pluginID] ?? []).sorted()
    }

    /// Registers a hook handler.
    /// - Parameters:
    ///   - hookName: Hook name.
    ///   - handler: Hook handler closure.
    public func registerHook(_ hookName: PluginHookName, handler: @escaping PluginHookHandler) {
        var current = self.hooks[hookName] ?? []
        current.append(handler)
        self.hooks[hookName] = current
    }

    /// Emits a plugin hook and collects non-nil results.
    /// - Parameters:
    ///   - hookName: Hook to invoke.
    ///   - payload: Hook payload.
    /// - Returns: Collected hook results.
    public func emitHook(
        _ hookName: PluginHookName,
        payload: PluginHookPayload
    ) async throws -> [PluginHookResult] {
        let handlers = self.hooks[hookName] ?? []
        var results: [PluginHookResult] = []
        for handler in handlers {
            if let result = try await handler(payload) {
                results.append(result)
            }
        }
        return results
    }

    /// Registers a callable gateway method.
    /// - Parameters:
    ///   - method: Gateway method name.
    ///   - handler: Method handler.
    public func registerGatewayMethod(
        _ method: String,
        handler: @escaping PluginGatewayMethodHandler
    ) {
        self.gatewayMethods[method] = handler
    }

    /// Invokes a previously registered gateway method.
    /// - Parameters:
    ///   - method: Method name.
    ///   - params: Method parameter payload.
    /// - Returns: Method result payload.
    public func invokeGatewayMethod(
        _ method: String,
        params: [String: AnyCodable]
    ) async throws -> AnyCodable {
        guard let handler = self.gatewayMethods[method] else {
            throw OpenClawCoreError.unavailable("Plugin gateway method not found: \(method)")
        }
        return try await handler(params)
    }

    /// Registers a managed plugin service instance.
    /// - Parameter service: Service implementation.
    public func registerService(_ service: any PluginService) {
        self.services[service.id] = service
    }

    /// Starts all registered services.
    public func startServices() async throws {
        for service in self.services.values {
            try await service.start()
        }
    }

    /// Stops all registered services.
    public func stopServices() async {
        for service in self.services.values {
            await service.stop()
        }
    }
}

/// Supported plugin hook names.
public enum PluginHookName: String, Sendable {
    case beforeAgentStart = "before_agent_start"
    case afterToolCall = "after_tool_call"
    case gatewayStart = "gateway_start"
    case gatewayStop = "gateway_stop"
}

/// Payload passed to plugin hook handlers.
public struct PluginHookPayload: Sendable, Equatable {
    /// Optional run identifier.
    public let runID: String?
    /// Optional session key.
    public let sessionKey: String?
    /// Arbitrary metadata payload.
    public let metadata: [String: AnyCodable]

    /// Creates a hook payload.
    /// - Parameters:
    ///   - runID: Optional run identifier.
    ///   - sessionKey: Optional session key.
    ///   - metadata: Arbitrary metadata payload.
    public init(runID: String? = nil, sessionKey: String? = nil, metadata: [String: AnyCodable] = [:]) {
        self.runID = runID
        self.sessionKey = sessionKey
        self.metadata = metadata
    }
}

/// Result returned from a plugin hook handler.
public struct PluginHookResult: Sendable, Equatable {
    /// Arbitrary metadata returned from hooks.
    public let metadata: [String: AnyCodable]

    /// Creates a hook result payload.
    /// - Parameter metadata: Arbitrary metadata payload.
    public init(metadata: [String: AnyCodable] = [:]) {
        self.metadata = metadata
    }
}

/// Plugin hook handler signature.
public typealias PluginHookHandler = @Sendable (PluginHookPayload) async throws -> PluginHookResult?
/// Plugin gateway method handler signature.
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

/// Registration API passed to plugins during load.
public struct PluginAPI: Sendable {
    private let registerToolNameFn: @Sendable (_ pluginID: String, _ toolName: String) async -> Void
    private let registerHookFn: @Sendable (_ hookName: PluginHookName, _ handler: @escaping PluginHookHandler) async -> Void
    private let registerGatewayMethodFn: @Sendable (_ method: String, _ handler: @escaping PluginGatewayMethodHandler) async -> Void
    private let registerServiceFn: @Sendable (_ service: any PluginService) async -> Void

    /// Creates a plugin registration API from callback closures.
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
        self.registerToolNameFn = registerToolName
        self.registerHookFn = registerHook
        self.registerGatewayMethodFn = registerGatewayMethod
        self.registerServiceFn = registerService
    }

    /// Registers a tool name owned by a plugin.
    /// - Parameters:
    ///   - pluginID: Plugin identifier.
    ///   - toolName: Tool name.
    public func registerToolName(pluginID: String, toolName: String) async {
        await self.registerToolNameFn(pluginID, toolName)
    }

    /// Registers a hook handler.
    /// - Parameters:
    ///   - hookName: Hook name.
    ///   - handler: Hook handler closure.
    public func registerHook(_ hookName: PluginHookName, handler: @escaping PluginHookHandler) async {
        await self.registerHookFn(hookName, handler)
    }

    /// Registers a gateway method handler.
    /// - Parameters:
    ///   - method: Method name.
    ///   - handler: Handler closure.
    public func registerGatewayMethod(
        _ method: String,
        handler: @escaping PluginGatewayMethodHandler
    ) async {
        await self.registerGatewayMethodFn(method, handler)
    }

    /// Registers a managed plugin service.
    /// - Parameter service: Service implementation.
    public func registerService(_ service: any PluginService) async {
        await self.registerServiceFn(service)
    }
}
