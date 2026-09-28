import Foundation
import OpenClawProtocol

/// Server identity from the `initialize` result.
public struct MCPServerInfo: Codable, Sendable, Equatable {
    /// Server name.
    public let name: String
    /// Server version.
    public let version: String?
    /// Human-readable title.
    public let title: String?

    /// Creates server info.
    /// - Parameters:
    ///   - name: Name.
    ///   - version: Version.
    ///   - title: Title.
    public init(name: String, version: String? = nil, title: String? = nil) {
        self.name = name
        self.version = version
        self.title = title
    }
}

/// Result of the `initialize` handshake.
public struct MCPInitializeResult: Sendable, Equatable {
    /// Negotiated protocol version.
    public let protocolVersion: String
    /// Server capabilities.
    public let capabilities: [String: AnyCodable]
    /// Server identity.
    public let serverInfo: MCPServerInfo
    /// Optional server instructions (untrusted).
    public let instructions: String?

    /// Creates an initialize result.
    /// - Parameters:
    ///   - protocolVersion: Protocol version.
    ///   - capabilities: Capabilities.
    ///   - serverInfo: Server info.
    ///   - instructions: Instructions.
    public init(protocolVersion: String, capabilities: [String: AnyCodable], serverInfo: MCPServerInfo, instructions: String? = nil) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.serverInfo = serverInfo
        self.instructions = instructions
    }
}

/// One tool advertised by `tools/list`.
public struct MCPToolDefinition: Sendable, Equatable {
    /// Wire name.
    public let name: String
    /// Optional title.
    public let title: String?
    /// Description (untrusted).
    public let description: String?
    /// JSON Schema of the arguments.
    public let inputSchema: [String: AnyCodable]
    /// JSON Schema of `structuredContent`, when declared.
    public let outputSchema: [String: AnyCodable]?
    /// Tool annotations.
    public let annotations: [String: AnyCodable]?
    /// `execution.taskSupport` (`forbidden`, `optional`, `required`).
    public let taskSupport: String?

    /// Creates a tool definition.
    /// - Parameters:
    ///   - name: Name.
    ///   - title: Title.
    ///   - description: Description.
    ///   - inputSchema: Input schema.
    ///   - outputSchema: Output schema.
    ///   - annotations: Annotations.
    ///   - taskSupport: Task support.
    public init(
        name: String,
        title: String? = nil,
        description: String? = nil,
        inputSchema: [String: AnyCodable] = ["type": AnyCodable("object")],
        outputSchema: [String: AnyCodable]? = nil,
        annotations: [String: AnyCodable]? = nil,
        taskSupport: String? = nil
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.annotations = annotations
        self.taskSupport = taskSupport
    }

    /// Parses one `tools/list` entry.
    /// - Parameter value: JSON value.
    /// - Returns: The definition, or `nil` without a string name.
    public static func parse(_ value: AnyCodable) -> MCPToolDefinition? {
        guard let object = value.dictionaryValue, let name = object["name"]?.stringValue else { return nil }
        return MCPToolDefinition(
            name: name,
            title: object["title"]?.stringValue,
            description: object["description"]?.stringValue,
            inputSchema: object["inputSchema"]?.dictionaryValue ?? ["type": AnyCodable("object")],
            outputSchema: object["outputSchema"]?.dictionaryValue,
            annotations: object["annotations"]?.dictionaryValue,
            taskSupport: object["execution"]?.dictionaryValue?["taskSupport"]?.stringValue
        )
    }
}

/// Result of `tools/call`.
public struct MCPCallToolResult: Sendable, Equatable {
    /// Content blocks (`text`, `image`, `audio`, `resource`, `resource_link`).
    public let content: [AnyCodable]
    /// Structured result.
    public let structuredContent: AnyCodable?
    /// Whether the tool reported an error.
    public let isError: Bool

    /// Creates a call result.
    /// - Parameters:
    ///   - content: Content blocks.
    ///   - structuredContent: Structured result.
    ///   - isError: Error flag.
    public init(content: [AnyCodable], structuredContent: AnyCodable? = nil, isError: Bool = false) {
        self.content = content
        self.structuredContent = structuredContent
        self.isError = isError
    }
}

/// JSON-RPC 2.0 MCP client over any ``MCPTransport``.
///
/// ``connect()`` performs `initialize` (offering ``latestProtocolVersion`` and accepting any of
/// ``supportedProtocolVersions``) and `notifications/initialized`. Requests time out after the
/// request timeout and send `notifications/cancelled`, as does task cancellation. Server `ping`
/// requests are answered; other server requests get `-32601`. `notifications/tools/list_changed`
/// invokes ``onToolsListChanged(_:)`` handlers.
public actor MCPClient {
    /// Protocol version offered in `initialize`.
    public static let latestProtocolVersion = "2025-06-18"
    /// Negotiated versions the client accepts.
    public static let supportedProtocolVersions: Set<String> = ["2025-06-18", "2025-03-26", "2024-11-05"]
    /// Client name sent in `clientInfo`.
    public static let clientName = "openclawkit"

    /// Server name the client was created for (diagnostics).
    public nonisolated let serverName: String
    private let transport: any MCPTransport
    private let requestTimeoutMs: Int
    private let connectionTimeoutMs: Int
    private var nextID = 1
    private var pending: [MCPRequestID: CheckedContinuation<AnyCodable, Error>] = [:]
    private var timeouts: [MCPRequestID: Task<Void, Never>] = [:]
    private var reader: Task<Void, Never>?
    private var toolsChangedHandlers: [@Sendable () async -> Void] = []
    private var initializeResult: MCPInitializeResult?
    private var closedError: MCPTransportError?

    /// Creates a client.
    /// - Parameters:
    ///   - serverName: Server name (diagnostics).
    ///   - transport: Transport.
    ///   - requestTimeoutMs: Per-request timeout (default 60000).
    ///   - connectionTimeoutMs: Connect/initialize timeout (default 30000).
    public init(
        serverName: String,
        transport: any MCPTransport,
        requestTimeoutMs: Int = MCPServerConfig.defaultRequestTimeoutMs,
        connectionTimeoutMs: Int = MCPServerConfig.defaultConnectionTimeoutMs
    ) {
        self.serverName = serverName
        self.transport = transport
        self.requestTimeoutMs = max(1, requestTimeoutMs)
        self.connectionTimeoutMs = max(1, connectionTimeoutMs)
    }

    /// The `initialize` result once connected.
    public var serverInitializeResult: MCPInitializeResult? {
        self.initializeResult
    }

    /// Whether the client is connected and the transport is open.
    public var isConnected: Bool {
        self.initializeResult != nil && self.closedError == nil
    }

    /// Registers a handler for `notifications/tools/list_changed`.
    /// - Parameter handler: Handler.
    public func onToolsListChanged(_ handler: @escaping @Sendable () async -> Void) {
        self.toolsChangedHandlers.append(handler)
    }

    /// Starts the transport and performs the initialize handshake.
    /// - Returns: The initialize result.
    @discardableResult
    public func connect() async throws -> MCPInitializeResult {
        if let initializeResult { return initializeResult }
        self.startReaderIfNeeded()
        let transport = self.transport
        let timeoutMs = self.connectionTimeoutMs
        try await Self.withTimeout(milliseconds: timeoutMs, method: "connect") {
            try await transport.start()
        }
        let params: [String: AnyCodable] = [
            "protocolVersion": AnyCodable(Self.latestProtocolVersion),
            "capabilities": AnyCodable([String: AnyCodable]()),
            "clientInfo": AnyCodable(["name": AnyCodable(Self.clientName), "version": AnyCodable(OpenClawMCP.moduleVersion)]),
        ]
        let raw = try await self.request(method: "initialize", params: AnyCodable(params), timeoutMs: timeoutMs)
        guard let object = raw.dictionaryValue, let version = object["protocolVersion"]?.stringValue else {
            throw MCPTransportError.protocolViolation("initialize result without protocolVersion")
        }
        guard Self.supportedProtocolVersions.contains(version) else {
            await self.close()
            throw MCPTransportError.unsupportedProtocolVersion(version)
        }
        let info = object["serverInfo"]?.dictionaryValue ?? [:]
        let result = MCPInitializeResult(
            protocolVersion: version,
            capabilities: object["capabilities"]?.dictionaryValue ?? [:],
            serverInfo: MCPServerInfo(
                name: info["name"]?.stringValue ?? self.serverName,
                version: info["version"]?.stringValue,
                title: info["title"]?.stringValue
            ),
            instructions: object["instructions"]?.stringValue
        )
        await transport.setProtocolVersion(version)
        try await self.notify(method: "notifications/initialized")
        self.initializeResult = result
        return result
    }

    /// Sends a request and waits for its result.
    /// - Parameters:
    ///   - method: Method.
    ///   - params: Params.
    ///   - timeoutMs: Timeout override.
    /// - Returns: The result.
    public func request(method: String, params: AnyCodable? = nil, timeoutMs: Int? = nil) async throws -> AnyCodable {
        if let closedError { throw closedError }
        self.startReaderIfNeeded()
        let id = MCPRequestID.int(self.nextID)
        self.nextID += 1
        let timeout = max(1, timeoutMs ?? self.requestTimeoutMs)
        let message = MCPJSONRPCMessage.request(id: id, method: method, params: params)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AnyCodable, Error>) in
                self.pending[id] = continuation
                self.timeouts[id] = Task.detached { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000)
                    guard !Task.isCancelled else { return }
                    await self?.expire(id, method: method, timeoutMs: timeout)
                }
                let transport = self.transport
                Task.detached { [weak self] in
                    do {
                        try await transport.send(message)
                    } catch {
                        await self?.fail(id, error: error)
                    }
                }
            }
        } onCancel: {
            Task { [weak self] in await self?.cancelRequest(id, reason: "cancelled") }
        }
    }

    /// Sends a notification.
    /// - Parameters:
    ///   - method: Method.
    ///   - params: Params.
    public func notify(method: String, params: AnyCodable? = nil) async throws {
        if let closedError { throw closedError }
        try await self.transport.send(.notification(method: method, params: params))
    }

    /// Lists every tool, following `nextCursor`.
    /// - Returns: Tool definitions.
    public func listTools() async throws -> [MCPToolDefinition] {
        var tools: [MCPToolDefinition] = []
        var cursor: String?
        var pages = 0
        repeat {
            let params: AnyCodable? = cursor.map { AnyCodable(["cursor": AnyCodable($0)]) }
            let result = try await self.request(method: "tools/list", params: params)
            let object = result.dictionaryValue ?? [:]
            tools.append(contentsOf: (object["tools"]?.arrayValue ?? []).compactMap(MCPToolDefinition.parse))
            cursor = object["nextCursor"]?.stringValue
            pages += 1
        } while cursor?.isEmpty == false && pages < 1_000
        return tools
    }

    /// Calls a tool.
    /// - Parameters:
    ///   - name: Tool wire name.
    ///   - arguments: Arguments.
    ///   - timeoutMs: Timeout override.
    /// - Returns: The result.
    public func callTool(name: String, arguments: [String: AnyCodable], timeoutMs: Int? = nil) async throws -> MCPCallToolResult {
        let params = AnyCodable(["name": AnyCodable(name), "arguments": AnyCodable(arguments)])
        let result = try await self.request(method: "tools/call", params: params, timeoutMs: timeoutMs)
        let object = result.dictionaryValue ?? [:]
        return MCPCallToolResult(
            content: object["content"]?.arrayValue ?? [],
            structuredContent: object["structuredContent"],
            isError: object["isError"]?.boolValue ?? false
        )
    }

    /// Lists resources (`resources/list`, first page).
    /// - Returns: Raw resource entries.
    public func listResources() async throws -> [AnyCodable] {
        let result = try await self.request(method: "resources/list")
        return result.dictionaryValue?["resources"]?.arrayValue ?? []
    }

    /// Reads a resource (`resources/read`).
    /// - Parameter uri: Resource URI.
    /// - Returns: Raw contents.
    public func readResource(uri: String) async throws -> [AnyCodable] {
        let result = try await self.request(method: "resources/read", params: AnyCodable(["uri": AnyCodable(uri)]))
        return result.dictionaryValue?["contents"]?.arrayValue ?? []
    }

    /// Lists prompts (`prompts/list`, first page).
    /// - Returns: Raw prompt entries.
    public func listPrompts() async throws -> [AnyCodable] {
        let result = try await self.request(method: "prompts/list")
        return result.dictionaryValue?["prompts"]?.arrayValue ?? []
    }

    /// Pings the server.
    public func ping() async throws {
        _ = try await self.request(method: "ping")
    }

    /// Closes the transport and fails pending requests.
    public func close() async {
        await self.transport.close()
        self.shutdown(.closed("client closed"))
        self.reader?.cancel()
        self.reader = nil
    }

    // MARK: - Internals

    private func startReaderIfNeeded() {
        guard self.reader == nil else { return }
        let events = self.transport.events
        self.reader = Task.detached { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
            await self?.shutdown(.closed("transport ended"))
        }
    }

    private func handle(_ event: MCPTransportEvent) async {
        switch event {
        case .message(let message):
            switch message {
            case .response(let id, let result):
                self.resolve(id, with: .success(result))
            case .error(let id, let error):
                if let id { self.resolve(id, with: .failure(error)) }
            case .request(let id, let method, _):
                let reply: MCPJSONRPCMessage = method == "ping"
                    ? .response(id: id, result: AnyCodable([String: AnyCodable]()))
                    : .error(id: id, error: MCPJSONRPCError(code: -32601, message: "Method not found: \(method)"))
                try? await self.transport.send(reply)
            case .notification(let method, _):
                if method == "notifications/tools/list_changed" {
                    for handler in self.toolsChangedHandlers {
                        await handler()
                    }
                }
            }
        case .closed(let error):
            self.shutdown(error ?? .closed("transport closed"))
        }
    }

    private func resolve(_ id: MCPRequestID, with result: Result<AnyCodable, Error>) {
        self.timeouts.removeValue(forKey: id)?.cancel()
        guard let continuation = self.pending.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    private func fail(_ id: MCPRequestID, error: Error) {
        self.resolve(id, with: .failure(error))
    }

    private func expire(_ id: MCPRequestID, method: String, timeoutMs: Int) async {
        guard self.pending[id] != nil else { return }
        self.resolve(id, with: .failure(MCPTransportError.timeout(method: method, milliseconds: timeoutMs)))
        try? await self.transport.send(
            .notification(method: "notifications/cancelled", params: AnyCodable(["requestId": id.anyCodable, "reason": AnyCodable("timeout")]))
        )
    }

    private func cancelRequest(_ id: MCPRequestID, reason: String) async {
        guard self.pending[id] != nil else { return }
        self.resolve(id, with: .failure(CancellationError()))
        try? await self.transport.send(
            .notification(method: "notifications/cancelled", params: AnyCodable(["requestId": id.anyCodable, "reason": AnyCodable(reason)]))
        )
    }

    private func shutdown(_ error: MCPTransportError) {
        if self.closedError == nil {
            self.closedError = error
        }
        let pending = self.pending
        self.pending.removeAll()
        for task in self.timeouts.values { task.cancel() }
        self.timeouts.removeAll()
        for continuation in pending.values {
            continuation.resume(throwing: error)
        }
    }

    static func withTimeout(milliseconds: Int, method: String, _ operation: @escaping @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(1, milliseconds)) * 1_000_000)
                throw MCPTransportError.timeout(method: method, milliseconds: milliseconds)
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }
}
