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
/// runs; concurrent callers share one connection attempt per server, and a failed attempt closes its
/// client (no orphaned stdio processes or HTTP sessions). Sessions idle longer than
/// `sessionIdleTtlMs` are closed by ``evictIdle(now:)``. A `tools/call` is never replayed once it may
/// have reached the server: a transport failure recycles the session (the next call reconnects) and
/// rethrows; only a call whose cached client was already closed is retried on a fresh connection.
/// ``reload(config:)`` retires servers whose definition changed and keeps the rest.
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
    private var connecting: [String: Task<MCPClient, Error>] = [:]
    private var shutdownGeneration = 0
    private var refreshing: Set<String> = []
    private var refreshPending: Set<String> = []
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
        for name in self.connecting.keys where servers.first(where: { $0.name == name }) == nil {
            // In-flight connects re-check the definition before storing their session.
            self.connecting.removeValue(forKey: name)
        }
        for (name, session) in self.sessions {
            let next = servers.first { $0.name == name }?.config
            if next != session.config {
                self.connecting.removeValue(forKey: name)
                if self.sessions[name]?.client === session.client {
                    self.sessions.removeValue(forKey: name)
                }
                await session.client.close()
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
            self.connecting.removeValue(forKey: name)
            self.sessions.removeValue(forKey: name)
            await session.client.close()
        }
    }

    /// Removes a server added with ``addServer(name:config:)``.
    /// - Parameter name: Server name.
    public func removeServer(name: String) async {
        self.extraServers.removeAll { $0.name == name }
        self.connecting.removeValue(forKey: name)
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

    /// Calls a server tool.
    ///
    /// The call is never replayed once it may have reached the server (upstream "never replay a possibly
    /// mutating call"): on a transport failure (process exit, HTTP 5xx, expired session, …) the session
    /// is recycled so the next call reconnects, and the error is rethrown. Only a call whose cached
    /// client turned out to be closed before the request was sent is retried once on a fresh connection.
    /// Timeouts keep the session.
    /// - Parameters:
    ///   - server: Declared server name.
    ///   - tool: Wire tool name.
    ///   - arguments: Arguments.
    /// - Returns: The call result.
    public func call(server: String, tool: String, arguments: [String: AnyCodable]) async throws -> MCPCallToolResult {
        guard let definition = self.allServers().first(where: { $0.name == server })?.config else {
            throw MCPTransportError.closed("MCP server \(server) is not configured")
        }
        let timeoutMs = definition.effectiveRequestTimeoutMs
        let client = try await self.connectedClient(name: server, server: definition)
        do {
            let result = try await client.callToolIfOpen(name: tool, arguments: arguments, timeoutMs: timeoutMs)
            self.touch(server)
            return result
        } catch is MCPRequestNotSentError {
            // The cached client closed before the request left it, so nothing reached the server.
            await self.drop(server, ifClient: client)
            let retry = try await self.connectedClient(name: server, server: definition)
            do {
                let result = try await retry.callTool(name: tool, arguments: arguments, timeoutMs: timeoutMs)
                self.touch(server)
                return result
            } catch let error as MCPTransportError {
                if case .timeout = error { throw error }
                await self.drop(server, ifClient: retry)
                throw error
            }
        } catch let error as MCPTransportError {
            if case .timeout = error { throw error }
            await self.drop(server, ifClient: client)
            throw error
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
            let tools = MCPToolCatalogNormalizer.normalize(try await Self.listTools(client), filter: server.toolFilter)
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
            if self.sessions[name]?.client === session.client {
                self.sessions.removeValue(forKey: name)
            }
            await session.client.close()
            evicted.append(name)
        }
        return evicted.sorted()
    }

    /// Names of servers with an open session.
    public func connectedServers() -> [String] {
        self.sessions.keys.sorted()
    }

    /// Closes every session (connections still being established are closed when they finish).
    public func shutdown() async {
        self.shutdownGeneration += 1
        self.connecting.removeAll()
        let sessions = self.sessions.values
        self.sessions.removeAll()
        for session in sessions {
            await session.client.close()
        }
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
        if let inFlight = self.connecting[name] {
            return try await inFlight.value
        }
        let generation = self.shutdownGeneration
        let task = Task { () throws -> MCPClient in
            try await self.establish(name: name, server: server, generation: generation)
        }
        self.connecting[name] = task
        defer {
            if self.connecting[name] == task { self.connecting.removeValue(forKey: name) }
        }
        return try await task.value
    }

    /// Connects a new client and stores its session; a failed attempt, or one that finishes after the
    /// server was reconfigured, removed or the manager shut down, closes its client.
    private func establish(name: String, server: MCPServerConfig, generation: Int) async throws -> MCPClient {
        let client = try self.makeClient(name: name, server: server)
        let tools: [MCPToolDefinition]
        do {
            try await client.connect()
            tools = MCPToolCatalogNormalizer.normalize(try await Self.listTools(client), filter: server.toolFilter)
        } catch {
            await client.close()
            throw error
        }
        guard generation == self.shutdownGeneration, self.allServers().first(where: { $0.name == name })?.config == server else {
            await client.close()
            throw MCPTransportError.closed("MCP server \(name) was reconfigured or shut down while connecting")
        }
        let displaced = self.sessions[name]
        self.sessions[name] = Session(client: client, tools: tools, lastUsed: self.now(), config: server)
        await client.onToolsListChanged { [weak self, weak client] in
            guard let client else { return }
            await self?.refreshCatalog(name, client: client)
        }
        if let displaced, displaced.client !== client {
            await displaced.client.close()
        }
        return client
    }

    /// `tools/list`, treating `-32601` as an empty catalog for servers that advertise resources or
    /// prompts but no tools (upstream parity).
    static func listTools(_ client: MCPClient) async throws -> [MCPToolDefinition] {
        do {
            return try await client.listTools()
        } catch let error as MCPJSONRPCError where error.code == -32601 {
            let capabilities = await client.serverInitializeResult?.capabilities ?? [:]
            if capabilities["tools"] == nil, capabilities["resources"] != nil || capabilities["prompts"] != nil {
                return []
            }
            throw error
        }
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

    /// Re-lists a server's tools after `notifications/tools/list_changed`; bursts of notifications
    /// coalesce into at most one follow-up `tools/list`, and results for a replaced session are dropped.
    private func refreshCatalog(_ name: String, client: MCPClient) async {
        guard self.sessions[name]?.client === client else { return }
        guard !self.refreshing.contains(name) else {
            self.refreshPending.insert(name)
            return
        }
        self.refreshing.insert(name)
        defer { self.refreshing.remove(name) }
        repeat {
            self.refreshPending.remove(name)
            guard let tools = try? await client.listTools() else { return }
            guard var session = self.sessions[name], session.client === client else { return }
            session.tools = MCPToolCatalogNormalizer.normalize(tools, filter: session.config.toolFilter)
            self.sessions[name] = session
        } while self.refreshPending.contains(name)
    }

    private func touch(_ name: String) {
        self.sessions[name]?.lastUsed = self.now()
    }

    /// Closes and forgets the session, unless a concurrent caller already replaced its client.
    private func drop(_ name: String, ifClient client: MCPClient) async {
        if let session = self.sessions[name], session.client === client {
            self.sessions.removeValue(forKey: name)
        }
        await client.close()
    }
}
