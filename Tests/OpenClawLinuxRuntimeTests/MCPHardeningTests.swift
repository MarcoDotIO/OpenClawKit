import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import OpenClawAgents
import OpenClawCore
import OpenClawProtocol
@testable import OpenClawMCP

/// Scripted in-process MCP server transport that records what the client sent.
actor ScriptedMCPTransport: MCPTransport {
    /// What the fake server does with one request.
    enum Action: Sendable {
        /// Answer with a result.
        case reply([String: AnyCodable])
        /// Answer with a JSON-RPC error.
        case error(Int)
        /// The server ran the request, then its stream ended (process exit, dropped session).
        case closeStream
        /// The POST failed with an HTTP status after reaching the server.
        case http(Int)
    }

    nonisolated let events: AsyncStream<MCPTransportEvent>
    private let continuation: AsyncStream<MCPTransportEvent>.Continuation
    private let startDelayNanoseconds: UInt64
    private let script: @Sendable (_ method: String, _ params: [String: AnyCodable]) -> Action
    private(set) var starts = 0
    private(set) var closes = 0
    private(set) var methods: [String] = []

    init(startDelayNanoseconds: UInt64 = 0, script: @escaping @Sendable (_ method: String, _ params: [String: AnyCodable]) -> Action) {
        self.startDelayNanoseconds = startDelayNanoseconds
        self.script = script
        (self.events, self.continuation) = AsyncStream<MCPTransportEvent>.makeStream()
    }

    func start() async throws {
        self.starts += 1
        if self.startDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: self.startDelayNanoseconds)
        }
    }

    func send(_ message: MCPJSONRPCMessage) async throws {
        guard case .request(let id, let method, let params) = message else { return }
        self.methods.append(method)
        switch self.script(method, params?.dictionaryValue ?? [:]) {
        case .reply(let result):
            self.continuation.yield(.message(.response(id: id, result: AnyCodable(result))))
        case .error(let code):
            self.continuation.yield(.message(.error(id: id, error: MCPJSONRPCError(code: code, message: "scripted"))))
        case .closeStream:
            self.continuation.yield(.closed(.closed("server exited")))
            self.continuation.finish()
        case .http(let status):
            throw MCPTransportError.http(status: status, message: "scripted")
        }
    }

    func close() async {
        self.closes += 1
        self.continuation.yield(.closed(nil))
        self.continuation.finish()
    }

    static let initializeResult: [String: AnyCodable] = [
        "protocolVersion": AnyCodable("2025-06-18"),
        "capabilities": AnyCodable(["tools": AnyCodable([String: AnyCodable]())]),
        "serverInfo": AnyCodable(["name": AnyCodable("scripted")]),
    ]

    static let toolsResult: [String: AnyCodable] = ["tools": AnyCodable([AnyCodable(["name": AnyCodable("create_issue")])])]
}

/// Collects the transports a manager created.
final class TransportLog: @unchecked Sendable {
    private let lock = NSLock()
    private var created: [ScriptedMCPTransport] = []

    var transports: [ScriptedMCPTransport] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.created
    }

    func add(_ transport: ScriptedMCPTransport) {
        self.lock.lock()
        self.created.append(transport)
        self.lock.unlock()
    }

    func totalMethods(_ method: String) async -> Int {
        var total = 0
        for transport in self.transports {
            total += await transport.methods.filter { $0 == method }.count
        }
        return total
    }
}

@Suite("MCP hardening", .timeLimit(.minutes(1)))
struct MCPHardeningTests {
    static func manager(
        log: TransportLog,
        requestTimeoutMs: Int? = nil,
        startDelayNanoseconds: UInt64 = 0,
        script: @escaping @Sendable (_ method: String, _ params: [String: AnyCodable]) -> ScriptedMCPTransport.Action
    ) -> MCPClientManager {
        let config = MCPConfig(servers: [
            (name: "tracker", config: MCPServerConfig(url: "https://mcp.example.com/mcp", transport: "streamable-http", requestTimeoutMs: requestTimeoutMs)),
        ])
        return MCPClientManager(config: config, transportFactory: { _, _, _ in
            let transport = ScriptedMCPTransport(startDelayNanoseconds: startDelayNanoseconds, script: script)
            log.add(transport)
            return transport
        })
    }

    static func handshake(_ method: String) -> ScriptedMCPTransport.Action? {
        switch method {
        case "initialize": return .reply(ScriptedMCPTransport.initializeResult)
        case "tools/list": return .reply(ScriptedMCPTransport.toolsResult)
        default: return nil
        }
    }

    // MARK: - JSON-RPC ids and OAuth expiry (no traps on hostile numbers)

    @Test(arguments: ["1e300", "-1e300", "9223372036854775808", "1e19", "3.5"])
    func unrepresentableJSONRPCIDsNeverTrap(rawID: String) throws {
        #expect(throws: MCPJSONRPCError.self) {
            _ = try MCPJSONRPCMessage.decode(Data(#"{"jsonrpc":"2.0","id":\#(rawID),"result":{}}"#.utf8))
        }
        let request = try MCPJSONRPCMessage.decode(Data(#"{"jsonrpc":"2.0","id":\#(rawID),"method":"ping"}"#.utf8))
        #expect(request == [.notification(method: "ping", params: nil)])
        let error = try MCPJSONRPCMessage.decode(Data(#"{"jsonrpc":"2.0","id":\#(rawID),"error":{"code":-1,"message":"x"}}"#.utf8))
        #expect(error == [.error(id: nil, error: MCPJSONRPCError(code: -1, message: "x"))])
        let integral = try MCPJSONRPCMessage.decode(Data(#"{"jsonrpc":"2.0","id":7.0,"result":{}}"#.utf8))
        #expect(integral == [.response(id: .int(7), result: AnyCodable([String: AnyCodable]()))])
    }

    @Test
    func tokenExpiryIsClampedAndNeverTraps() {
        let now: Int64 = 1_800_000_000_000
        #expect(MCPOAuthClient.expiresAtMs(expiresIn: 3_600, nowMs: now) == now + 3_600_000)
        #expect(MCPOAuthClient.expiresAtMs(expiresIn: 1e19, nowMs: now) == now + 315_360_000_000)
        #expect(MCPOAuthClient.expiresAtMs(expiresIn: 1e300, nowMs: now) == now + 315_360_000_000)
        #expect(MCPOAuthClient.expiresAtMs(expiresIn: -5, nowMs: now) == nil)
        #expect(MCPOAuthClient.expiresAtMs(expiresIn: 0, nowMs: now) == nil)
        #expect(MCPOAuthClient.expiresAtMs(expiresIn: .infinity, nowMs: now) == nil)
        #expect(MCPOAuthClient.expiresAtMs(expiresIn: nil, nowMs: now) == nil)
        #expect(MCPOAuthClient.expiresAtMs(expiresIn: 10, nowMs: Int64.max - 5) == nil)
        #expect(MCPTimeoutRace.nanoseconds(milliseconds: Int.max) == UInt64(Int32.max) * 1_000_000)
        #expect(MCPTimeoutRace.nanoseconds(milliseconds: -5) == 1_000_000)
    }

    @Test(arguments: [1e19, -5.0])
    func hostileExpiresInFromTheTokenEndpointDoesNotCrash(expiresIn: Double) async throws {
        let clock = OAuthTestClock()
        let http = FakeMCPHTTP { request, _ in
            guard request.url?.absoluteString == "https://auth.example.com/token" else {
                return FakeMCPHTTP.json(["error": AnyCodable("not_found")], status: 404)
            }
            return FakeMCPHTTP.json(["access_token": AnyCodable("access-2"), "refresh_token": AnyCodable("r2"), "expires_in": AnyCodable(expiresIn)])
        }
        let store = InMemoryOAuthStore()
        var state = MCPOAuthState()
        state.clientID = "client-1"
        state.tokenEndpoint = "https://auth.example.com/token"
        state.tokens = MCPOAuthTokens(accessToken: "access-1", refreshToken: "r1", expiresAtMs: 0)
        try await store.save(state, server: "docs", identity: "shared")
        let client = try MCPOAuthClient(serverName: "docs", serverURL: URL(string: "https://mcp.example.com/mcp")!, store: store, http: http, now: { clock.now })
        #expect(try await client.authorizationHeader() == "Bearer access-2")
        let expected: Int64? = expiresIn > 0 ? 1_800_000_000_000 + 315_360_000_000 : nil
        #expect(await client.status() == .signedIn(expiresAtMs: expected))
    }

    // MARK: - OAuth single flight

    /// Token endpoint that rotates refresh tokens and rejects reuse (OAuth 2.1 public clients).
    static func rotatingTokenServer(counter: ManagedCounter, used: LockedSet) -> FakeMCPHTTP {
        FakeMCPHTTP { request, _ in
            let fields = MCPOAuthTests.formFields(request)
            let presented = fields["refresh_token"] ?? ""
            let (stream, feed) = AsyncThrowingStream<Data, Error>.makeStream()
            let body: [String: AnyCodable]
            let status: Int
            if used.insert(presented) {
                let count = counter.increment() + 1
                body = ["access_token": AnyCodable("access-\(count)"), "refresh_token": AnyCodable("R\(count)"), "expires_in": AnyCodable(3_600)]
                status = 200
            } else {
                body = ["error": AnyCodable("invalid_grant")]
                status = 400
            }
            let data = (try? JSONEncoder().encode(AnyCodable(body))) ?? Data()
            Task {
                // Slow token endpoint, so concurrent callers overlap.
                try? await Task.sleep(nanoseconds: 50_000_000)
                feed.yield(data)
                feed.finish()
            }
            return FakeMCPHTTP.Reply(status: status, headers: ["Content-Type": "application/json"], chunks: [], stream: stream)
        }
    }

    static func signedInClient(http: FakeMCPHTTP, clock: OAuthTestClock, expiresAtMs: Int64) async throws -> MCPOAuthClient {
        let store = InMemoryOAuthStore()
        var state = MCPOAuthState()
        state.clientID = "client-1"
        state.tokenEndpoint = "https://auth.example.com/token"
        state.tokens = MCPOAuthTokens(accessToken: "access-1", refreshToken: "R1", expiresAtMs: expiresAtMs)
        try await store.save(state, server: "docs", identity: "shared")
        return try MCPOAuthClient(serverName: "docs", serverURL: URL(string: "https://mcp.example.com/mcp")!, store: store, http: http, now: { clock.now })
    }

    @Test
    func concurrentRefreshesShareOneTokenRequest() async throws {
        let clock = OAuthTestClock()
        let http = Self.rotatingTokenServer(counter: ManagedCounter(), used: LockedSet())
        let client = try await Self.signedInClient(http: http, clock: clock, expiresAtMs: 0)
        async let first = client.authorizationHeader()
        async let second = client.authorizationHeader()
        async let third = client.authorizationHeader()
        let headers = try await [first, second, third]
        #expect(headers == ["Bearer access-2", "Bearer access-2", "Bearer access-2"])
        #expect(http.requests.count == 1)
        #expect(await client.status() == .signedIn(expiresAtMs: 1_800_000_000_000 + 3_600_000))
    }

    @Test
    func concurrentUnauthorizedResponsesRefreshOnceAndSkipReplacedCredentials() async throws {
        let clock = OAuthTestClock()
        let http = Self.rotatingTokenServer(counter: ManagedCounter(), used: LockedSet())
        let client = try await Self.signedInClient(http: http, clock: clock, expiresAtMs: 1_900_000_000_000)
        async let first = client.handleUnauthorized(wwwAuthenticate: nil, rejectedAuthorization: "Bearer access-1")
        async let second = client.handleUnauthorized(wwwAuthenticate: nil, rejectedAuthorization: "Bearer access-1")
        #expect(try await [first, second] == [true, true])
        #expect(http.requests.count == 1)
        #expect(try await client.authorizationHeader() == "Bearer access-2")
        // A late 401 for the credential that was already replaced retries without refreshing again.
        #expect(try await client.handleUnauthorized(wwwAuthenticate: nil, rejectedAuthorization: "Bearer access-1"))
        #expect(http.requests.count == 1)
        #expect(await client.status() == .signedIn(expiresAtMs: 1_800_000_000_000 + 3_600_000))
    }

    // MARK: - No replay of possibly-delivered tools/call

    @Test
    func toolCallIsNotReplayedWhenTheServerDiesMidCall() async throws {
        let log = TransportLog()
        let calls = ManagedCounter()
        let manager = Self.manager(log: log) { method, _ in
            if let handshake = Self.handshake(method) { return handshake }
            return calls.increment() == 1 ? .closeStream : .reply(["content": AnyCodable([AnyCodable]())])
        }
        await #expect(throws: MCPTransportError.self) {
            _ = try await manager.call(server: "tracker", tool: "create_issue", arguments: [:])
        }
        #expect(await log.totalMethods("tools/call") == 1, "the possibly-executed call must not be replayed")
        #expect(await manager.connectedServers().isEmpty, "the failed session is recycled")
        #expect(await log.transports.first?.closes == 1)

        let result = try await manager.call(server: "tracker", tool: "create_issue", arguments: [:])
        #expect(result.isError == false)
        #expect(log.transports.count == 2, "the next call opens a fresh session")
        #expect(await log.totalMethods("tools/call") == 2)
        await manager.shutdown()
    }

    @Test
    func toolCallIsNotReplayedAfterAnHTTPServerError() async throws {
        let log = TransportLog()
        let manager = Self.manager(log: log) { method, _ in
            Self.handshake(method) ?? .http(502)
        }
        await #expect(throws: MCPTransportError.http(status: 502, message: "scripted")) {
            _ = try await manager.call(server: "tracker", tool: "create_issue", arguments: [:])
        }
        #expect(await log.totalMethods("tools/call") == 1)
        #expect(log.transports.count == 1)
        await manager.shutdown()
    }

    @Test
    func closedClientReportsRequestsAsNotSent() async throws {
        let transport = ScriptedMCPTransport { method, _ in Self.handshake(method) ?? .reply([:]) }
        let client = MCPClient(serverName: "scripted", transport: transport)
        try await client.connect()
        await client.close()
        await #expect(throws: MCPRequestNotSentError.self) {
            _ = try await client.callToolIfOpen(name: "create_issue", arguments: [:])
        }
        await #expect(throws: MCPTransportError.self) {
            _ = try await client.callTool(name: "create_issue", arguments: [:])
        }
        #expect(await transport.methods.filter { $0 == "tools/call" }.isEmpty)
    }

    // MARK: - Connect coalescing and cleanup

    @Test
    func concurrentDiscoverySharesOneConnection() async throws {
        let log = TransportLog()
        let manager = Self.manager(log: log, startDelayNanoseconds: 100_000_000) { method, _ in
            Self.handshake(method) ?? .reply([:])
        }
        async let first = manager.tools()
        async let second = manager.tools()
        async let third = manager.call(server: "tracker", tool: "create_issue", arguments: [:])
        let (a, b) = await (first, second)
        _ = try await third
        #expect(a.map(\.name) == ["tracker__create_issue"])
        #expect(b.map(\.name) == ["tracker__create_issue"])
        #expect(log.transports.count == 1, "one server process for concurrent callers")
        #expect(await log.transports.first?.starts == 1)
        #expect(await log.transports.first?.closes == 0)
        await manager.shutdown()
        #expect(await log.transports.first?.closes == 1)
    }

    @Test
    func failedDiscoveryClosesTheClient() async throws {
        let log = TransportLog()
        let manager = Self.manager(log: log) { method, _ in
            method == "initialize" ? .reply(ScriptedMCPTransport.initializeResult) : .error(-32603)
        }
        let tools = await manager.tools()
        #expect(tools.isEmpty)
        #expect(await manager.currentNotices().count == 1)
        #expect(await manager.connectedServers().isEmpty)
        #expect(await log.transports.first?.closes == 1, "no orphaned server process")
    }

    @Test
    func resourceOnlyServersListAnEmptyCatalog() async throws {
        let log = TransportLog()
        let manager = Self.manager(log: log) { method, _ in
            switch method {
            case "initialize":
                return .reply([
                    "protocolVersion": AnyCodable("2025-06-18"),
                    "capabilities": AnyCodable(["resources": AnyCodable([String: AnyCodable]())]),
                    "serverInfo": AnyCodable(["name": AnyCodable("docs")]),
                ])
            default:
                return .error(-32601)
            }
        }
        #expect(await manager.tools().isEmpty)
        #expect(await manager.currentNotices().isEmpty)
        #expect(await manager.connectedServers() == ["tracker"])
        await manager.shutdown()
    }

    // MARK: - Legacy SSE connect timeout

    @Test
    func legacySSEConnectTimesOutWithoutAnEndpointEvent() async throws {
        let (stream, feed) = AsyncThrowingStream<Data, Error>.makeStream()
        let http = FakeMCPHTTP { request, _ in
            if request.httpMethod == "GET" {
                // A Streamable-HTTP-only server: 200 text/event-stream with keep-alives, never `endpoint`.
                return FakeMCPHTTP.Reply(status: 200, headers: ["Content-Type": "text/event-stream"], chunks: [], stream: stream)
            }
            return FakeMCPHTTP.Reply(status: 202, headers: [:], chunks: [])
        }
        feed.yield(Data(": ping\n\n".utf8))
        let transport = MCPLegacySSETransport(url: URL(string: "https://mcp.example.com/mcp")!, http: http)
        let client = MCPClient(serverName: "legacy", transport: transport, connectionTimeoutMs: 100)
        let started = Date()
        await #expect(throws: MCPTransportError.timeout(method: "connect", milliseconds: 100)) {
            try await client.connect()
        }
        #expect(Date().timeIntervalSince(started) < 2)
        await #expect(throws: MCPTransportError.closed("transport closed")) {
            try await transport.send(.notification(method: "ping", params: nil))
        }
        #expect(await client.isConnected == false)
        feed.finish()
    }

    @Test
    func timeoutRaceHonoursCallerCancellation() async {
        let task = Task {
            try await MCPTimeoutRace.run(milliseconds: 60_000, method: "slow") {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
    }

    // MARK: - Server stream and list_changed

    @Test
    func toolsListChangedOnTheServerStreamRefreshesTheCatalog() async throws {
        let (serverStream, serverFeed) = AsyncThrowingStream<Data, Error>.makeStream()
        let version = ManagedCounter()
        let changed = LockedSet()
        let http = FakeMCPHTTP { request, json in
            switch request.httpMethod {
            case "GET":
                return FakeMCPHTTP.Reply(status: 200, headers: ["Content-Type": "text/event-stream"], chunks: [], stream: serverStream)
            case "DELETE":
                return FakeMCPHTTP.Reply(status: 200, headers: [:], chunks: [])
            default:
                break
            }
            let id = json?["id"]
            switch json?["method"]?.stringValue {
            case "initialize":
                return FakeMCPHTTP.json(FakeMCPHTTP.result(id, ScriptedMCPTransport.initializeResult), headers: ["Mcp-Session-Id": "s-1"])
            case "tools/list":
                _ = version.increment()
                let names = changed.contains("yes") ? ["create_issue", "close_issue"] : ["create_issue"]
                return FakeMCPHTTP.json(FakeMCPHTTP.result(id, ["tools": AnyCodable(names.map { AnyCodable(["name": AnyCodable($0)]) })]))
            case "tools/call":
                return FakeMCPHTTP.json(FakeMCPHTTP.result(id, ["content": AnyCodable([AnyCodable]())]))
            default:
                // Spec-compliant: notifications are answered with 202 Accepted.
                return FakeMCPHTTP.Reply(status: 202, headers: [:], chunks: [])
            }
        }
        // The request timeout is past the suite's time limit, so a call or refresh that stalls behind
        // another request fails as a hang instead of recovering when that request times out.
        let config = MCPConfig(servers: [
            (name: "tracker", config: MCPServerConfig(url: "https://mcp.example.com/mcp", transport: "streamable-http", requestTimeoutMs: 3_600_000)),
        ])
        let manager = MCPClientManager(config: config, transportFactory: { _, server, _ in
            MCPStreamableHTTPTransport(url: URL(string: server.url!)!, http: http)
        })
        #expect(await manager.tools().map(\.name) == ["tracker__create_issue"])

        // The GET stream opens after the 202 to notifications/initialized.
        try await waitUntil("server stream GET opened") { http.requests.contains { $0.httpMethod == "GET" } }
        let get = try #require(http.requests.first { $0.httpMethod == "GET" })
        #expect(get.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(get.value(forHTTPHeaderField: "Mcp-Session-Id") == "s-1")
        #expect(get.value(forHTTPHeaderField: "MCP-Protocol-Version") == "2025-06-18")

        _ = changed.insert("yes")
        serverFeed.yield(Data("event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}\n\n".utf8))
        // A call right after the notification must not stall behind the refresh.
        _ = try await manager.call(server: "tracker", tool: "create_issue", arguments: [:])
        try await waitUntil("catalog refreshed after list_changed") { await manager.tools().count >= 2 }
        #expect(await manager.tools().map(\.name) == ["tracker__create_issue", "tracker__close_issue"])
        serverFeed.finish()
        await manager.shutdown()
    }
}

/// Thread-safe string set (`insert` reports whether the value was new).
final class LockedSet: @unchecked Sendable {
    private let lock = NSLock()
    private var values: Set<String> = []

    func insert(_ value: String) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.values.insert(value).inserted
    }

    func contains(_ value: String) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.values.contains(value)
    }
}
