import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - URLSession streaming client

/// ``MCPHTTPStreaming`` backed by a delegate-based `URLSession` (works on Apple platforms and Linux).
///
/// `allowInsecureTLS` (`sslVerify: false`) trusts any server certificate on Apple platforms; use it for
/// development only. It has no effect on Linux.
public final class URLSessionMCPHTTPStreaming: NSObject, MCPHTTPStreaming, URLSessionDataDelegate, @unchecked Sendable {
    private final class TaskState {
        var head: CheckedContinuation<HTTPURLResponse, Error>?
        let body: AsyncThrowingStream<Data, Error>.Continuation
        init(head: CheckedContinuation<HTTPURLResponse, Error>, body: AsyncThrowingStream<Data, Error>.Continuation) {
            self.head = head
            self.body = body
        }
    }

    private let lock = NSLock()
    private var states: [Int: TaskState] = [:]
    private let allowInsecureTLS: Bool
    private var session: URLSession!

    /// Creates a streaming client.
    /// - Parameters:
    ///   - configuration: Session configuration (inject `protocolClasses` for tests).
    ///   - allowInsecureTLS: Trust any TLS certificate (Apple platforms only).
    public init(configuration: URLSessionConfiguration = .default, allowInsecureTLS: Bool = false) {
        self.allowInsecureTLS = allowInsecureTLS
        super.init()
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    deinit {
        self.session?.invalidateAndCancel()
    }

    /// Performs a request and streams the response body.
    public func stream(_ request: URLRequest) async throws -> (response: HTTPURLResponse, body: AsyncThrowingStream<Data, Error>) {
        let (body, bodyContinuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let task = self.session.dataTask(with: request)
        let identifier = task.taskIdentifier
        bodyContinuation.onTermination = { [weak task] termination in
            if case .cancelled = termination { task?.cancel() }
        }
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPURLResponse, Error>) in
                self.lock.lock()
                self.states[identifier] = TaskState(head: continuation, body: bodyContinuation)
                self.lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        return (response, body)
    }

    private func state(for task: URLSessionTask) -> TaskState? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.states[task.taskIdentifier]
    }

    private func takeHead(for task: URLSessionTask) -> CheckedContinuation<HTTPURLResponse, Error>? {
        self.lock.lock()
        defer { self.lock.unlock() }
        let head = self.states[task.taskIdentifier]?.head
        self.states[task.taskIdentifier]?.head = nil
        return head
    }

    /// Delivers the response head.
    public func urlSession(
        _: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse {
            self.takeHead(for: dataTask)?.resume(returning: http)
        } else {
            self.takeHead(for: dataTask)?.resume(throwing: MCPTransportError.protocolViolation("non-HTTP response"))
        }
        completionHandler(.allow)
    }

    /// Streams body bytes.
    public func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        self.state(for: dataTask)?.body.yield(data)
    }

    /// Finishes the body stream.
    public func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        self.lock.lock()
        let state = self.states.removeValue(forKey: task.taskIdentifier)
        self.lock.unlock()
        if let head = state?.head {
            head.resume(throwing: error ?? MCPTransportError.protocolViolation("request finished without a response"))
        }
        if let error {
            state?.body.finish(throwing: error)
        } else {
            state?.body.finish()
        }
    }

    #if canImport(Security)
    /// Trusts any server certificate when `allowInsecureTLS` is set.
    public func urlSession(
        _: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if self.allowInsecureTLS,
           challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust
        {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
    #endif
}

// MARK: - Shared HTTP helpers

enum MCPHTTPSupport {
    static func header(_ response: HTTPURLResponse, _ name: String) -> String? {
        for (key, value) in response.allHeaderFields {
            if String(describing: key).caseInsensitiveCompare(name) == .orderedSame {
                return String(describing: value)
            }
        }
        return nil
    }

    static func collect(_ body: AsyncThrowingStream<Data, Error>, limit: Int) async throws -> Data {
        var data = Data()
        for try await chunk in body {
            data.append(chunk)
            if data.count > limit {
                throw MCPTransportError.eventTooLarge(limit: limit)
            }
        }
        return data
    }

    static func isEventStream(_ response: HTTPURLResponse) -> Bool {
        (self.header(response, "Content-Type") ?? "").lowercased().contains("text/event-stream")
    }
}

// MARK: - Streamable HTTP

/// MCP Streamable HTTP transport (protocol 2025-03-26 and later).
///
/// Every message is POSTed with `Accept: application/json, text/event-stream`; the response is a JSON
/// message (or batch) or an SSE stream of messages. The `Mcp-Session-Id` returned by `initialize` is
/// resent on later requests together with `MCP-Protocol-Version`. After initialization an optional
/// GET stream receives server-initiated messages (servers answering 405 simply do not offer one). The
/// session is DELETEd on close.
public actor MCPStreamableHTTPTransport: MCPTransport {
    /// Messages and close events from the server.
    nonisolated public let events: AsyncStream<MCPTransportEvent>
    private let continuation: AsyncStream<MCPTransportEvent>.Continuation
    private let url: URL
    private let headers: [String: String]
    private let http: any MCPHTTPStreaming
    private let maxEventBytes: Int
    private let openServerStream: Bool
    private let authorization: (any MCPAuthorizationProvider)?
    private var sessionID: String?
    private var protocolVersion: String?
    private var readers: [UUID: Task<Void, Never>] = [:]
    private var serverStreamStarted = false
    private var isClosed = false

    /// Creates a Streamable HTTP transport.
    /// - Parameters:
    ///   - url: Server URL.
    ///   - headers: Extra headers (for example `Authorization`).
    ///   - http: Streaming HTTP client.
    ///   - maxEventBytes: Size cap for one message or SSE event.
    ///   - openServerStream: Open the optional GET stream for server-initiated messages.
    ///   - authorization: OAuth provider (`auth: "oauth"`); a 401 is retried once after it handles the challenge.
    public init(
        url: URL,
        headers: [String: String] = [:],
        http: any MCPHTTPStreaming = URLSessionMCPHTTPStreaming(),
        maxEventBytes: Int = OpenClawMCP.defaultMaxMessageBytes,
        openServerStream: Bool = true,
        authorization: (any MCPAuthorizationProvider)? = nil
    ) {
        self.url = url
        self.headers = headers
        self.http = http
        self.maxEventBytes = maxEventBytes
        self.openServerStream = openServerStream
        self.authorization = authorization
        (self.events, self.continuation) = AsyncStream<MCPTransportEvent>.makeStream()
    }

    /// Session identifier assigned by the server, if any.
    public var currentSessionID: String? {
        self.sessionID
    }

    /// No-op: the session starts with the `initialize` POST.
    public func start() async throws {}

    /// Records the negotiated protocol version and opens the optional server stream.
    public func setProtocolVersion(_ version: String) async {
        self.protocolVersion = version
    }

    /// POSTs one message and routes the response messages to ``events``.
    public func send(_ message: MCPJSONRPCMessage) async throws {
        guard !self.isClosed else { throw MCPTransportError.closed("transport closed") }
        var request = try await self.authorizedRequest(method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try message.encoded()
        var (response, body) = try await self.http.stream(request)
        if response.statusCode == 401, let authorization = self.authorization,
           try await authorization.handleUnauthorized(wwwAuthenticate: MCPHTTPSupport.header(response, "WWW-Authenticate")) {
            _ = try? await MCPHTTPSupport.collect(body, limit: 64 * 1024)
            if let header = try await authorization.authorizationHeader() {
                request.setValue(header, forHTTPHeaderField: "Authorization")
            }
            (response, body) = try await self.http.stream(request)
        }
        if let session = MCPHTTPSupport.header(response, "Mcp-Session-Id"), !session.isEmpty {
            self.sessionID = session
        }
        switch response.statusCode {
        case 202, 204:
            _ = try? await MCPHTTPSupport.collect(body, limit: self.maxEventBytes)
        case 200..<300:
            if MCPHTTPSupport.isEventStream(response) {
                self.startReader(body)
            } else {
                let data = try await MCPHTTPSupport.collect(body, limit: self.maxEventBytes)
                if !data.isEmpty {
                    for decoded in try MCPJSONRPCMessage.decode(data) {
                        self.continuation.yield(.message(decoded))
                    }
                }
            }
            if case .notification(let method, _) = message, method == "notifications/initialized" {
                self.startServerStreamIfNeeded()
            }
        case 401:
            let data = (try? await MCPHTTPSupport.collect(body, limit: 64 * 1024)) ?? Data()
            throw MCPTransportError.unauthorized(MCPHTTPSupport.header(response, "WWW-Authenticate") ?? String(decoding: data, as: UTF8.self))
        case 404 where self.sessionID != nil:
            throw MCPTransportError.closed("MCP session expired (404)")
        default:
            let data = (try? await MCPHTTPSupport.collect(body, limit: 64 * 1024)) ?? Data()
            throw MCPTransportError.http(status: response.statusCode, message: String(decoding: data.prefix(512), as: UTF8.self))
        }
    }

    /// Cancels readers, DELETEs the session, and finishes ``events``.
    public func close() async {
        guard !self.isClosed else { return }
        self.isClosed = true
        for reader in self.readers.values { reader.cancel() }
        self.readers.removeAll()
        if self.sessionID != nil {
            let request = self.makeRequest(method: "DELETE")
            if let (_, body) = try? await self.http.stream(request) {
                _ = try? await MCPHTTPSupport.collect(body, limit: 64 * 1024)
            }
        }
        self.continuation.yield(.closed(nil))
        self.continuation.finish()
    }

    private func authorizedRequest(method: String) async throws -> URLRequest {
        var request = self.makeRequest(method: method)
        if let header = try await self.authorization?.authorizationHeader() {
            request.setValue(header, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func makeRequest(method: String) -> URLRequest {
        var request = URLRequest(url: self.url)
        request.httpMethod = method
        for (key, value) in self.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if let protocolVersion { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        return request
    }

    private func startReader(_ body: AsyncThrowingStream<Data, Error>) {
        let id = UUID()
        let continuation = self.continuation
        let limit = self.maxEventBytes
        self.readers[id] = Task.detached { [weak self] in
            var parser = MCPSSEParser(maxEventBytes: limit)
            do {
                for try await chunk in body {
                    for event in try parser.feed(chunk) where event.event == "message" {
                        for message in (try? MCPJSONRPCMessage.decode(Data(event.data.utf8))) ?? [] {
                            continuation.yield(.message(message))
                        }
                    }
                }
                if let event = parser.finish(), event.event == "message" {
                    for message in (try? MCPJSONRPCMessage.decode(Data(event.data.utf8))) ?? [] {
                        continuation.yield(.message(message))
                    }
                }
            } catch let error as MCPTransportError {
                continuation.yield(.closed(error))
            } catch {}
            await self?.removeReader(id)
        }
    }

    private func removeReader(_ id: UUID) {
        self.readers.removeValue(forKey: id)
    }

    private func startServerStreamIfNeeded() {
        guard self.openServerStream, !self.serverStreamStarted, !self.isClosed else { return }
        self.serverStreamStarted = true
        var request = self.makeRequest(method: "GET")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let http = self.http
        let authorization = self.authorization
        let id = UUID()
        self.readers[id] = Task.detached { [weak self] in
            if let header = try? await authorization?.authorizationHeader() {
                request.setValue(header, forHTTPHeaderField: "Authorization")
            }
            guard let (response, body) = try? await http.stream(request) else { return }
            guard (200..<300).contains(response.statusCode), MCPHTTPSupport.isEventStream(response) else {
                _ = try? await MCPHTTPSupport.collect(body, limit: 64 * 1024)
                return
            }
            await self?.startReader(body)
        }
    }
}

// MARK: - Legacy SSE

/// Legacy MCP HTTP+SSE transport (protocol 2024-11-05).
///
/// Opens `GET url` with `Accept: text/event-stream`, waits for the `endpoint` event (a URL relative to
/// the SSE URL), then POSTs every message to that endpoint; responses arrive as `message` events on
/// the SSE stream.
public actor MCPLegacySSETransport: MCPTransport {
    /// Messages and close events from the server.
    nonisolated public let events: AsyncStream<MCPTransportEvent>
    private let continuation: AsyncStream<MCPTransportEvent>.Continuation
    private let url: URL
    private let headers: [String: String]
    private let http: any MCPHTTPStreaming
    private let maxEventBytes: Int
    private let authorization: (any MCPAuthorizationProvider)?
    private var endpoint: URL?
    private var endpointWaiters: [CheckedContinuation<URL, Error>] = []
    private var reader: Task<Void, Never>?
    private var isClosed = false
    private var protocolVersion: String?

    /// Creates a legacy SSE transport.
    /// - Parameters:
    ///   - url: SSE URL.
    ///   - headers: Extra headers.
    ///   - http: Streaming HTTP client.
    ///   - maxEventBytes: Size cap for one SSE event.
    ///   - authorization: OAuth provider (`auth: "oauth"`); a 401 is retried once after it handles the challenge.
    public init(
        url: URL,
        headers: [String: String] = [:],
        http: any MCPHTTPStreaming = URLSessionMCPHTTPStreaming(),
        maxEventBytes: Int = OpenClawMCP.defaultMaxMessageBytes,
        authorization: (any MCPAuthorizationProvider)? = nil
    ) {
        self.url = url
        self.headers = headers
        self.http = http
        self.maxEventBytes = maxEventBytes
        self.authorization = authorization
        (self.events, self.continuation) = AsyncStream<MCPTransportEvent>.makeStream()
    }

    /// POST endpoint announced by the server, once known.
    public var messageEndpoint: URL? {
        self.endpoint
    }

    /// Opens the SSE stream and waits for the `endpoint` event.
    public func start() async throws {
        guard self.reader == nil else {
            _ = try await self.waitForEndpoint()
            return
        }
        var request = URLRequest(url: self.url)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        for (key, value) in self.headers { request.setValue(value, forHTTPHeaderField: key) }
        let (response, body) = try await self.performAuthorized(request)
        if response.statusCode == 401 {
            throw MCPTransportError.unauthorized(MCPHTTPSupport.header(response, "WWW-Authenticate") ?? "401")
        }
        guard (200..<300).contains(response.statusCode) else {
            let data = (try? await MCPHTTPSupport.collect(body, limit: 64 * 1024)) ?? Data()
            throw MCPTransportError.http(status: response.statusCode, message: String(decoding: data.prefix(512), as: UTF8.self))
        }
        let continuation = self.continuation
        let limit = self.maxEventBytes
        self.reader = Task.detached { [weak self] in
            var parser = MCPSSEParser(maxEventBytes: limit)
            var failure: MCPTransportError?
            do {
                for try await chunk in body {
                    for event in try parser.feed(chunk) {
                        await self?.handle(event, continuation: continuation)
                    }
                }
                if let event = parser.finish() {
                    await self?.handle(event, continuation: continuation)
                }
            } catch let error as MCPTransportError {
                failure = error
            } catch {
                failure = .closed(String(describing: error))
            }
            await self?.streamEnded(failure)
        }
        _ = try await self.waitForEndpoint()
    }

    /// Records the negotiated protocol version (sent as `MCP-Protocol-Version`).
    public func setProtocolVersion(_ version: String) async {
        self.protocolVersion = version
    }

    /// POSTs one message to the announced endpoint.
    public func send(_ message: MCPJSONRPCMessage) async throws {
        guard !self.isClosed else { throw MCPTransportError.closed("transport closed") }
        let endpoint = try await self.waitForEndpoint()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in self.headers { request.setValue(value, forHTTPHeaderField: key) }
        if let protocolVersion { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        request.httpBody = try message.encoded()
        let (response, body) = try await self.performAuthorized(request)
        let data = (try? await MCPHTTPSupport.collect(body, limit: 64 * 1024)) ?? Data()
        if response.statusCode == 401 {
            throw MCPTransportError.unauthorized(MCPHTTPSupport.header(response, "WWW-Authenticate") ?? "401")
        }
        guard (200..<300).contains(response.statusCode) else {
            throw MCPTransportError.http(status: response.statusCode, message: String(decoding: data.prefix(512), as: UTF8.self))
        }
    }

    /// Stops reading and finishes ``events``.
    public func close() async {
        guard !self.isClosed else { return }
        self.isClosed = true
        self.reader?.cancel()
        self.failWaiters(MCPTransportError.closed("transport closed"))
        self.continuation.yield(.closed(nil))
        self.continuation.finish()
    }

    private func performAuthorized(_ request: URLRequest) async throws -> (response: HTTPURLResponse, body: AsyncThrowingStream<Data, Error>) {
        var request = request
        guard let authorization = self.authorization else { return try await self.http.stream(request) }
        if let header = try await authorization.authorizationHeader() {
            request.setValue(header, forHTTPHeaderField: "Authorization")
        }
        let first = try await self.http.stream(request)
        guard first.response.statusCode == 401,
              try await authorization.handleUnauthorized(wwwAuthenticate: MCPHTTPSupport.header(first.response, "WWW-Authenticate"))
        else {
            return first
        }
        _ = try? await MCPHTTPSupport.collect(first.body, limit: 64 * 1024)
        if let header = try await authorization.authorizationHeader() {
            request.setValue(header, forHTTPHeaderField: "Authorization")
        }
        return try await self.http.stream(request)
    }

    private func waitForEndpoint() async throws -> URL {
        if let endpoint { return endpoint }
        if self.isClosed { throw MCPTransportError.closed("transport closed") }
        return try await withCheckedThrowingContinuation { continuation in
            self.endpointWaiters.append(continuation)
        }
    }

    private func handle(_ event: MCPSSEParser.Event, continuation: AsyncStream<MCPTransportEvent>.Continuation) {
        switch event.event {
        case "endpoint":
            let trimmed = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let resolved = URL(string: trimmed, relativeTo: self.url)?.absoluteURL,
                  resolved.scheme == self.url.scheme, resolved.host == self.url.host, resolved.port == self.url.port
            else {
                self.failWaiters(MCPTransportError.protocolViolation("endpoint origin does not match the SSE URL"))
                return
            }
            self.endpoint = resolved
            let waiters = self.endpointWaiters
            self.endpointWaiters.removeAll()
            for waiter in waiters { waiter.resume(returning: resolved) }
        case "message":
            for message in (try? MCPJSONRPCMessage.decode(Data(event.data.utf8))) ?? [] {
                continuation.yield(.message(message))
            }
        default:
            break
        }
    }

    private func streamEnded(_ failure: MCPTransportError?) {
        let reason = failure ?? .closed("SSE stream ended")
        self.failWaiters(reason)
        guard !self.isClosed else { return }
        self.isClosed = true
        self.continuation.yield(.closed(reason))
        self.continuation.finish()
    }

    private func failWaiters(_ error: MCPTransportError) {
        let waiters = self.endpointWaiters
        self.endpointWaiters.removeAll()
        for waiter in waiters { waiter.resume(throwing: error) }
    }
}
