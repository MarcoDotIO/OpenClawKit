import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawAgents
import OpenClawCore
import OpenClawProtocol

/// Per-session MCP overrides (maps upstream `SessionToolOverrides.mcpServers` / `mcpToolsDeny`).
public struct MCPSessionToolOverrides: Sendable, Equatable {
    /// Servers switched off for the session.
    public var disabledServers: Set<String>
    /// Denied server tool names, keyed by declared server name (`*` globs allowed).
    public var deniedTools: [String: [String]]

    /// Creates overrides.
    /// - Parameters:
    ///   - disabledServers: Disabled servers.
    ///   - deniedTools: Denied tools per server.
    public init(disabledServers: Set<String> = [], deniedTools: [String: [String]] = [:]) {
        self.disabledServers = disabledServers
        self.deniedTools = deniedTools
    }
}

/// Diagnostic notice about an MCP server (surfaced by `tools.effective`-style UIs).
public struct MCPServerNotice: Sendable, Equatable {
    /// Declared server name.
    public let server: String
    /// Message.
    public let message: String

    /// Creates a notice.
    /// - Parameters:
    ///   - server: Server name.
    ///   - message: Message.
    public init(server: String, message: String) {
        self.server = server
        self.message = message
    }
}

/// Result of ``MCPClientManager/probe(_:)`` (the `openclaw mcp doctor --probe` equivalent).
public struct MCPServerProbe: Sendable, Equatable {
    /// Whether the server connected and listed tools.
    public let ok: Bool
    /// Negotiated protocol version.
    public let protocolVersion: String?
    /// Server identity.
    public let serverInfo: MCPServerInfo?
    /// Server capabilities.
    public let capabilities: [String: AnyCodable]
    /// Tool names after normalization and filtering.
    public let tools: [String]
    /// Failure description.
    public let error: String?

    /// Creates a probe result.
    /// - Parameters:
    ///   - ok: Success flag.
    ///   - protocolVersion: Protocol version.
    ///   - serverInfo: Server info.
    ///   - capabilities: Capabilities.
    ///   - tools: Tool names.
    ///   - error: Error description.
    public init(
        ok: Bool,
        protocolVersion: String? = nil,
        serverInfo: MCPServerInfo? = nil,
        capabilities: [String: AnyCodable] = [:],
        tools: [String] = [],
        error: String? = nil
    ) {
        self.ok = ok
        self.protocolVersion = protocolVersion
        self.serverInfo = serverInfo
        self.capabilities = capabilities
        self.tools = tools
        self.error = error
    }
}

/// Owns MCP clients for the configured servers and exposes their tools as agent tools.
///
/// Servers connect lazily on the first ``tools(reservedNames:overrides:)`` call and are cached across
/// runs; sessions idle longer than `sessionIdleTtlMs` are closed by ``evictIdle(now:)``. A failed call
/// reconnects once. ``reload(config:)`` retires servers whose definition changed and keeps the rest.
public actor MCPClientManager {
    /// Creates a transport for a server.
    public typealias TransportFactory = @Sendable (_ serverName: String, _ config: MCPServerConfig, _ kind: MCPTransportKind) throws -> any MCPTransport
    /// Supplies the OAuth provider for an HTTP server with `auth: "oauth"` (for example an ``MCPOAuthClient``).
    public typealias AuthorizationProviderFactory = @Sendable (
        _ serverName: String,
        _ config: MCPServerConfig
    ) throws -> (any MCPAuthorizationProvider)?

    private struct Session {
        let client: MCPClient
        var tools: [MCPToolDefinition]
        var lastUsed: Date
        let config: MCPServerConfig
    }

    private var config: MCPConfig
    private var sessions: [String: Session] = [:]
    private var extraServers: [(name: String, config: MCPServerConfig)] = []
    private var notices: [MCPServerNotice] = []
    private let transportFactory: TransportFactory
    private let stdioAllowlist: ExecCommandAllowlist
    private let diagnostics: RuntimeDiagnosticSink?
    private let now: @Sendable () -> Date

    /// Creates a manager.
    /// - Parameters:
    ///   - config: MCP settings.
    ///   - transportFactory: Transport factory (defaults to the built-in stdio/SSE/Streamable HTTP transports).
    ///   - stdioAllowlist: Executables stdio servers may launch (empty by default; see
    ///     ``MCPConfig/allowUnlistedStdioCommands``).
    ///   - diagnostics: Optional diagnostics sink (stderr lines are reported as `mcp.stderr`).
    ///   - authorizationProvider: OAuth providers for `auth: "oauth"` servers (default transports only).
    ///   - now: Clock (tests).
    public init(
        config: MCPConfig,
        transportFactory: TransportFactory? = nil,
        stdioAllowlist: ExecCommandAllowlist = ExecCommandAllowlist(patterns: []),
        diagnostics: RuntimeDiagnosticSink? = nil,
        authorizationProvider: AuthorizationProviderFactory? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.stdioAllowlist = stdioAllowlist
        self.diagnostics = diagnostics
        self.now = now
        let allowUnlisted = config.allowUnlistedStdioCommands == true
        self.transportFactory = transportFactory ?? { name, server, kind in
            try MCPClientManager.defaultTransport(
                name: name,
                config: server,
                kind: kind,
                allowlist: stdioAllowlist,
                allowUnlisted: allowUnlisted,
                diagnostics: diagnostics,
                authorization: server.auth == "oauth" ? try authorizationProvider?(name, server) : nil
            )
        }
    }

    /// Builds the default transport for a server.
    /// - Parameters:
    ///   - name: Server name.
    ///   - config: Server definition.
    ///   - kind: Resolved transport.
    ///   - allowlist: Stdio exec allowlist.
    ///   - allowUnlisted: Allow stdio commands outside the allowlist.
    ///   - diagnostics: Diagnostics sink.
    ///   - authorization: OAuth provider for HTTP transports.
    /// - Returns: A transport.
    public static func defaultTransport(
        name: String,
        config: MCPServerConfig,
        kind: MCPTransportKind,
        allowlist: ExecCommandAllowlist,
        allowUnlisted: Bool,
        diagnostics: RuntimeDiagnosticSink?,
        authorization: (any MCPAuthorizationProvider)? = nil
    ) throws -> any MCPTransport {
        switch kind {
        case .stdio:
            #if os(macOS) || os(Linux)
            return try MCPStdioTransport(serverName: name, config: config, allowlist: allowlist, allowUnlistedCommands: allowUnlisted, diagnostics: diagnostics)
            #else
            throw MCPTransportError.unsupportedOnPlatform("stdio MCP servers cannot be launched on this platform")
            #endif
        case .sse, .streamableHTTP:
            guard let raw = config.url, let url = URL(string: raw) else {
                throw MCPTransportError.protocolViolation("server \(name) has no valid url")
            }
            let http = URLSessionMCPHTTPStreaming(allowInsecureTLS: config.sslVerify == false)
            let headers = config.headers ?? [:]
            if kind == .sse {
                return MCPLegacySSETransport(url: url, headers: headers, http: http, authorization: authorization)
            }
            return MCPStreamableHTTPTransport(url: url, headers: headers, http: http, authorization: authorization)
        }
    }

    // MARK: - Configuration

    /// Applies new settings: servers whose definition changed or disappeared are closed.
    /// - Parameter config: New settings.
    public func reload(config: MCPConfig) async {
        self.config = config
        let servers = self.allServers()
        for (name, session) in self.sessions {
            let next = servers.first { $0.name == name }?.config
            if next != session.config {
                await session.client.close()
                self.sessions.removeValue(forKey: name)
            }
        }
    }

    /// Adds a server declared outside the config (for example by a plugin).
    /// - Parameters:
    ///   - name: Server name.
    ///   - config: Server definition.
    public func addServer(name: String, config: MCPServerConfig) async {
        self.extraServers.removeAll { $0.name == name }
        self.extraServers.append((name, config))
        if let session = self.sessions[name], session.config != config {
            await session.client.close()
            self.sessions.removeValue(forKey: name)
        }
    }

    /// Removes a server added with ``addServer(name:config:)``.
    /// - Parameter name: Server name.
    public func removeServer(name: String) async {
        self.extraServers.removeAll { $0.name == name }
        if let session = self.sessions.removeValue(forKey: name) {
            await session.client.close()
        }
    }

    /// Notices collected while connecting (skipped servers, connection failures).
    public func currentNotices() -> [MCPServerNotice] {
        self.notices
    }

    // MARK: - Tools

    /// Connects enabled servers as needed and returns their tools.
    /// - Parameters:
    ///   - reservedNames: Names already taken (core tools win collisions).
    ///   - overrides: Session overrides.
    /// - Returns: Agent tools in server declaration order.
    public func tools(reservedNames: Set<String> = [], overrides: MCPSessionToolOverrides = MCPSessionToolOverrides()) async -> [MCPAgentTool] {
        self.notices.removeAll()
        let servers = self.allServers()
        let safeNames = MCPToolNaming.assignSafeServerNames(servers.map(\.name))
        var reserved = Set(reservedNames.map { $0.lowercased() })
        var result: [MCPAgentTool] = []
        for (name, server) in servers {
            guard server.isEnabled, !overrides.disabledServers.contains(name) else { continue }
            let definitions: [MCPToolDefinition]
            do {
                definitions = try await self.catalog(for: name, server: server)
            } catch {
                self.notices.append(MCPServerNotice(server: name, message: error.localizedDescription))
                continue
            }
            let denied = MCPToolFilter(exclude: overrides.deniedTools[name])
            let safeServer = safeNames[name] ?? name
            for definition in definitions where denied.allows(definition.name) {
                let toolName = MCPToolNaming.buildSafeToolName(serverName: safeServer, toolName: definition.name, reservedNames: reserved)
                reserved.insert(toolName.lowercased())
                result.append(
                    MCPAgentTool(
                        name: toolName,
                        serverName: name,
                        definition: definition,
                        supportsParallelToolCalls: server.supportsParallelToolCalls == true,
                        caller: { [weak self] server, tool, arguments in
                            guard let self else { throw MCPTransportError.closed("MCP manager released") }
                            return try await self.call(server: server, tool: tool, arguments: arguments)
                        }
                    )
                )
            }
        }
        return result
    }

    /// Registers the MCP tools into a tool registry (existing names are reserved and never replaced).
    /// - Parameters:
    ///   - registry: Tool registry.
    ///   - overrides: Session overrides.
    /// - Returns: Registered tool names.
    @discardableResult
    public func registerTools(into registry: AgentToolRegistry, overrides: MCPSessionToolOverrides = MCPSessionToolOverrides()) async -> [String] {
        let existing = Set(await registry.descriptors().map(\.name))
        var registered: [String] = []
        for tool in await self.tools(reservedNames: existing, overrides: overrides) {
            if (try? await registry.register(tool, ownerPluginID: nil)) != nil {
                registered.append(tool.name)
            }
        }
        return registered
    }

    /// Calls a server tool, reconnecting once when the session failed.
    /// - Parameters:
    ///   - server: Declared server name.
    ///   - tool: Wire tool name.
    ///   - arguments: Arguments.
    /// - Returns: The call result.
    public func call(server: String, tool: String, arguments: [String: AnyCodable]) async throws -> MCPCallToolResult {
        guard let definition = self.allServers().first(where: { $0.name == server })?.config else {
            throw MCPTransportError.closed("MCP server \(server) is not configured")
        }
        let client = try await self.connectedClient(name: server, server: definition)
        do {
            let result = try await client.callTool(name: tool, arguments: arguments, timeoutMs: definition.effectiveRequestTimeoutMs)
            self.touch(server)
            return result
        } catch let error as MCPTransportError {
            if case .timeout = error { throw error }
            await self.drop(server)
            let retry = try await self.connectedClient(name: server, server: definition)
            return try await retry.callTool(name: tool, arguments: arguments, timeoutMs: definition.effectiveRequestTimeoutMs)
        }
    }

    /// Connects to a server and lists its tools without caching the session.
    /// - Parameter serverName: Declared server name.
    /// - Returns: Probe result.
    public func probe(_ serverName: String) async -> MCPServerProbe {
        guard let server = self.allServers().first(where: { $0.name == serverName })?.config else {
            return MCPServerProbe(ok: false, error: "MCP server \(serverName) is not configured")
        }
        do {
            let client = try self.makeClient(name: serverName, server: server)
            defer { Task { await client.close() } }
            let initialize = try await client.connect()
            let tools = MCPToolCatalogNormalizer.normalize(try await client.listTools(), filter: server.toolFilter)
            return MCPServerProbe(
                ok: true,
                protocolVersion: initialize.protocolVersion,
                serverInfo: initialize.serverInfo,
                capabilities: initialize.capabilities,
                tools: tools.map(\.name)
            )
        } catch {
            return MCPServerProbe(ok: false, error: error.localizedDescription)
        }
    }

    /// Closes sessions idle for longer than the configured TTL.
    /// - Parameter now: Current time.
    /// - Returns: Closed server names.
    @discardableResult
    public func evictIdle(now: Date? = nil) async -> [String] {
        let reference = now ?? self.now()
        let ttl = TimeInterval(self.config.effectiveSessionIdleTtlMs) / 1_000
        var evicted: [String] = []
        for (name, session) in self.sessions where reference.timeIntervalSince(session.lastUsed) >= ttl {
            await session.client.close()
            self.sessions.removeValue(forKey: name)
            evicted.append(name)
        }
        return evicted.sorted()
    }

    /// Names of servers with an open session.
    public func connectedServers() -> [String] {
        self.sessions.keys.sorted()
    }

    /// Closes every session.
    public func shutdown() async {
        for session in self.sessions.values {
            await session.client.close()
        }
        self.sessions.removeAll()
    }

    // MARK: - Internals

    private func allServers() -> [(name: String, config: MCPServerConfig)] {
        var servers = self.config.servers
        for extra in self.extraServers where !servers.contains(where: { $0.name == extra.name }) {
            servers.append(extra)
        }
        return servers
    }

    private func catalog(for name: String, server: MCPServerConfig) async throws -> [MCPToolDefinition] {
        if let session = self.sessions[name], await session.client.isConnected {
            return session.tools
        }
        _ = try await self.connectedClient(name: name, server: server)
        return self.sessions[name]?.tools ?? []
    }

    private func connectedClient(name: String, server: MCPServerConfig) async throws -> MCPClient {
        if let session = self.sessions[name], await session.client.isConnected {
            return session.client
        }
        let client = try self.makeClient(name: name, server: server)
        try await client.connect()
        let tools = MCPToolCatalogNormalizer.normalize(try await client.listTools(), filter: server.toolFilter)
        self.sessions[name] = Session(client: client, tools: tools, lastUsed: self.now(), config: server)
        await client.onToolsListChanged { [weak self] in
            await self?.refreshCatalog(name)
        }
        return client
    }

    private func makeClient(name: String, server: MCPServerConfig) throws -> MCPClient {
        let kind: MCPTransportKind
        switch server.resolveTransport() {
        case .success(let resolved):
            kind = resolved
        case .failure(let issue):
            throw MCPTransportError.protocolViolation("skipped server \"\(name)\": \(issue.message)")
        }
        let transport = try self.transportFactory(name, server, kind)
        return MCPClient(
            serverName: name,
            transport: transport,
            requestTimeoutMs: server.effectiveRequestTimeoutMs,
            connectionTimeoutMs: server.effectiveConnectionTimeoutMs
        )
    }

    private func refreshCatalog(_ name: String) async {
        guard var session = self.sessions[name] else { return }
        if let tools = try? await session.client.listTools() {
            session.tools = MCPToolCatalogNormalizer.normalize(tools, filter: session.config.toolFilter)
            self.sessions[name] = session
        }
    }

    private func touch(_ name: String) {
        self.sessions[name]?.lastUsed = self.now()
    }

    private func drop(_ name: String) async {
        if let session = self.sessions.removeValue(forKey: name) {
            await session.client.close()
        }
    }
}
