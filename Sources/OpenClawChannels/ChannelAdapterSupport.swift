import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore

// MARK: - Configuration status

/// Whether an adapter has the credentials and settings it needs to start.
public enum ChannelConfigurationStatus: Sendable, Equatable {
    /// Credentials are present.
    case configured
    /// Credentials are missing; the reason is shown in `channels.status` (upstream `unconfigured`).
    case unconfigured(reason: String)

    /// Whether the adapter is configured.
    public var isConfigured: Bool {
        if case .configured = self { return true }
        return false
    }

    /// Reason for ``unconfigured(reason:)``.
    public var reason: String? {
        if case .unconfigured(let reason) = self { return reason }
        return nil
    }
}

/// Adapter capability: reports whether credentials are configured without starting the transport.
///
/// ``ChannelRegistry/start(id:)`` does not start an unconfigured adapter and does not throw; it
/// records the reason in ``ChannelRuntimeState/unconfiguredReason`` so `channels.status` reports
/// `configured: false` with the reason instead of a start failure.
public protocol ChannelConfigurationReporting: ChannelAdapter {
    /// Current configuration status (declare it `nonisolated` on actors).
    var configurationStatus: ChannelConfigurationStatus { get }
}

// MARK: - Transport health

/// Inbound transport health reported by long-running adapters (polling loops, sockets).
public struct ChannelTransportHealth: Sendable, Equatable {
    /// Transport state.
    public enum State: String, Sendable, Equatable, CaseIterable {
        /// Not started.
        case stopped
        /// Receiving normally.
        case healthy
        /// Recovering from errors (conflicts, rate limits, disconnects); still retrying.
        case degraded
        /// Stopped by a terminal error (revoked or invalid credentials).
        case blocked
    }

    /// Transport state.
    public var state: State
    /// Last error detail.
    public var lastError: String?
    /// Last state change.
    public var updatedAt: Date

    /// Creates a health snapshot.
    /// - Parameters:
    ///   - state: Transport state.
    ///   - lastError: Last error detail.
    ///   - updatedAt: Last state change.
    public init(state: State = .stopped, lastError: String? = nil, updatedAt: Date = Date()) {
        self.state = state
        self.lastError = lastError
        self.updatedAt = updatedAt
    }
}

/// Adapter capability: reports inbound transport health (for example Telegram `getUpdates` 409s).
public protocol ChannelTransportHealthReporting: ChannelAdapter {
    /// Current inbound transport health.
    /// - Returns: Health snapshot.
    func transportHealth() async -> ChannelTransportHealth
}

// MARK: - Join events

/// Async callback invoked when the bot joins a room.
public typealias ChannelJoinEventHandler = @Sendable (ChannelJoinEvent) async -> Void

/// Adapter capability: emits ``ChannelJoinEvent`` values when the bot is added to a room
/// (Telegram `my_chat_member`, Slack `member_joined_channel`, Discord `GUILD_CREATE`, LINE `join`).
public protocol JoinEventChannelAdapter: ChannelAdapter {
    /// Registers or clears the join-event callback.
    /// - Parameter handler: Callback invoked for bot joins.
    func setJoinEventHandler(_ handler: ChannelJoinEventHandler?) async
}

public extension AutoReplyEngine {
    /// Routes an adapter's join events into ``handleJoin(_:)`` (one-time room introductions).
    /// - Parameter adapter: Adapter that emits join events.
    func attachJoinEvents(from adapter: some JoinEventChannelAdapter) async {
        await adapter.setJoinEventHandler { [weak self] event in
            _ = try? await self?.handleJoin(event)
        }
    }
}

// MARK: - HTTP helpers

/// Generic HTTP transport used by the SMS, LINE, A2A and Teams token adapters; inject a fake in tests.
public protocol ChannelHTTPTransport: Sendable {
    /// Executes an HTTP request and returns normalized response data.
    /// - Parameter request: Configured URL request.
    /// - Returns: Normalized response payload.
    func data(for request: URLRequest) async throws -> HTTPResponseData
}

extension HTTPClient: ChannelHTTPTransport {}


/// HTTP helpers shared by the native adapters.
enum ChannelHTTP {
    /// Throws the classified ``ChannelSendError`` for a non-2xx response.
    static func check(_ response: HTTPResponseData) throws {
        if let error = ChannelSendError.classify(statusCode: response.statusCode, headers: response.headers, body: response.body) {
            throw error
        }
    }

    /// Encodes `application/x-www-form-urlencoded` pairs (spaces as `+`, RFC 3986 unreserved kept).
    static func formEncoded(_ pairs: [(String, String)]) -> Data {
        let body = pairs.map { "\(self.formEscape($0.0))=\(self.formEscape($0.1))" }.joined(separator: "&")
        return Data(body.utf8)
    }

    static func formEscape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        let escaped = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return escaped.replacingOccurrences(of: "%20", with: "+")
    }

    /// Parses an `application/x-www-form-urlencoded` body, keeping the first value per key.
    static func parseForm(_ body: Data) -> [String: String] {
        let text = String(decoding: body, as: UTF8.self)
        var result: [String: String] = [:]
        for pair in text.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = self.formUnescape(String(parts[0]))
            let value = parts.count > 1 ? self.formUnescape(String(parts[1])) : ""
            if result[key] == nil {
                result[key] = value
            }
        }
        return result
    }

    static func formUnescape(_ value: String) -> String {
        let spaced = value.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }

    /// Case-insensitive header lookup.
    static func header(_ name: String, in headers: [String: String]) -> String? {
        let lowered = name.lowercased()
        return headers.first { $0.key.lowercased() == lowered }?.value
    }

    /// Returns a JSON request.
    static func jsonRequest(
        url: URL,
        method: String = "POST",
        body: Data?,
        headers: [String: String] = [:],
        timeout: TimeInterval? = nil
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let timeout {
            request.timeoutInterval = timeout
        }
        return request
    }

    /// Serializes a JSON object built from Sendable-free Foundation values.
    static func jsonBody(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Parses a JSON object response.
    static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

// MARK: - Async helpers

/// Timeout helper shared by adapters.
enum ChannelAsync {
    struct TimeoutError: Error, LocalizedError {
        let milliseconds: Int

        var errorDescription: String? {
            "Timed out after \(self.milliseconds) ms"
        }
    }

    /// Runs `operation`, throwing ``TimeoutError`` when it does not finish in time.
    static func withTimeout<T: Sendable>(
        milliseconds: Int,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(1, milliseconds)) * 1_000_000)
                throw TimeoutError(milliseconds: milliseconds)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw TimeoutError(milliseconds: milliseconds)
            }
            return first
        }
    }

    /// Runs a probe with a timeout and measures latency.
    static func probe(
        timeoutMs: Int,
        _ operation: @escaping @Sendable () async throws -> String?
    ) async -> ChannelProbeResult {
        let started = Date()
        do {
            let detail = try await self.withTimeout(milliseconds: timeoutMs, operation)
            return ChannelProbeResult(ok: true, detail: detail, latencyMs: Int(Date().timeIntervalSince(started) * 1_000))
        } catch {
            return ChannelProbeResult(
                ok: false,
                detail: (error as? LocalizedError)?.errorDescription ?? String(describing: error),
                latencyMs: Int(Date().timeIntervalSince(started) * 1_000)
            )
        }
    }

    /// Exponential backoff with jitter (Slack reconnect policy defaults).
    static func backoffMs(attempt: Int, initialMs: Int = 2_000, maxMs: Int = 30_000, factor: Double = 1.8, jitter: Double = 0.25) -> Int {
        let base = Double(initialMs) * pow(factor, Double(max(0, attempt)))
        let capped = min(Double(maxMs), base)
        let spread = capped * jitter
        let jittered = capped + Double.random(in: -spread...spread)
        return max(1, Int(jittered))
    }

    /// Sleeps without throwing (returns early when cancelled).
    static func sleep(milliseconds: Int) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, milliseconds)) * 1_000_000)
    }
}

// MARK: - WebSocket abstraction

/// One open text WebSocket used by channel transports (Slack Socket Mode and relay, Signal
/// container receive, Discord gateway).
public protocol ChannelWebSocketConnection: Sendable {
    /// Sends a text frame.
    /// - Parameter text: Frame text.
    func send(text: String) async throws
    /// Receives the next text frame (binary frames are decoded as UTF-8).
    /// - Returns: Frame text.
    func receive() async throws -> String
    /// Closes the socket.
    func close() async
    /// Close code received from the peer, when the socket was closed by the server.
    /// - Returns: WebSocket close code, or `nil`.
    func closeCode() async -> Int?
}

public extension ChannelWebSocketConnection {
    /// Default: close codes are not reported.
    func closeCode() async -> Int? {
        nil
    }
}

/// Opens WebSockets for channel transports; inject a fake in tests.
public protocol ChannelWebSocketConnecting: Sendable {
    /// Opens a WebSocket.
    /// - Parameters:
    ///   - request: Upgrade request (URL and headers).
    ///   - maximumMessageSize: Maximum frame size in bytes, when limited.
    /// - Returns: Open connection.
    func connect(_ request: URLRequest, maximumMessageSize: Int?) async throws -> any ChannelWebSocketConnection
}

/// `URLSessionWebSocketTask`-backed connector (Apple platforms and Linux FoundationNetworking).
public struct URLSessionChannelWebSocketConnector: ChannelWebSocketConnecting {
    private let session: URLSession

    /// Creates a connector.
    /// - Parameter session: URL session (default `.shared`).
    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Opens a WebSocket task and resumes it.
    /// - Parameters:
    ///   - request: Upgrade request.
    ///   - maximumMessageSize: Maximum frame size.
    /// - Returns: Open connection.
    public func connect(_ request: URLRequest, maximumMessageSize: Int?) async throws -> any ChannelWebSocketConnection {
        let task = self.session.webSocketTask(with: request)
        #if canImport(Darwin)
        if let maximumMessageSize {
            task.maximumMessageSize = maximumMessageSize
        }
        #endif
        task.resume()
        return URLSessionChannelWebSocket(task: task, maximumMessageSize: maximumMessageSize)
    }
}

actor URLSessionChannelWebSocket: ChannelWebSocketConnection {
    private let task: URLSessionWebSocketTask
    private let maximumMessageSize: Int?

    init(task: URLSessionWebSocketTask, maximumMessageSize: Int?) {
        self.task = task
        self.maximumMessageSize = maximumMessageSize
    }

    func send(text: String) async throws {
        try await self.task.send(.string(text))
    }

    func receive() async throws -> String {
        let message = try await self.task.receive()
        let text: String
        switch message {
        case .string(let value):
            text = value
        case .data(let data):
            text = String(decoding: data, as: UTF8.self)
        @unknown default:
            throw OpenClawCoreError.unavailable("Unsupported WebSocket frame")
        }
        if let maximumMessageSize, text.utf8.count > maximumMessageSize {
            throw OpenClawCoreError.unavailable("WebSocket frame exceeds \(maximumMessageSize) bytes")
        }
        return text
    }

    func close() async {
        self.task.cancel(with: .goingAway, reason: nil)
    }

    func closeCode() async -> Int? {
        let code = self.task.closeCode
        return code == .invalid ? nil : code.rawValue
    }
}

// MARK: - Small utilities

/// Bounded recently-seen id set used for inbound dedupe.
struct ChannelRecentIDs {
    private var order: [String] = []
    private var members: Set<String> = []
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    /// Inserts an id; returns `false` when it was already present.
    mutating func insert(_ id: String) -> Bool {
        guard !self.members.contains(id) else { return false }
        self.members.insert(id)
        self.order.append(id)
        if self.order.count > self.capacity {
            let evicted = self.order.removeFirst()
            self.members.remove(evicted)
        }
        return true
    }

    func contains(_ id: String) -> Bool {
        self.members.contains(id)
    }

    mutating func removeAll() {
        self.order.removeAll()
        self.members.removeAll()
    }
}

extension String {
    /// Trimmed value, or `nil` when blank.
    var channelTrimmedNonEmpty: String? {
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension Optional where Wrapped == String {
    /// Trimmed value, or `nil` when blank or `nil`.
    var channelTrimmedNonEmpty: String? {
        self?.channelTrimmedNonEmpty
    }
}
