import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OpenClawChannels
import OpenClawCore

/// Scripted HTTP transport shared by the 2026.3.0 adapter refresh tests.
///
/// Responses are matched by the first registered path suffix (optionally per method); queued
/// responses are consumed in order and the last one repeats.
actor ScriptedChannelHTTP: TelegramHTTPTransport, DiscordHTTPTransport, SlackHTTPTransport, SignalHTTPTransport,
    MicrosoftTeamsHTTPTransport, GoogleChatHTTPTransport, ChannelHTTPTransport
{
    struct Record: Sendable {
        let method: String
        let url: String
        let path: String
        let query: String?
        let headers: [String: String]
        let body: String
        let timeout: TimeInterval
    }

    struct Rule {
        let method: String?
        let suffix: String
        var responses: [Result<HTTPResponseData, Error>]
    }

    private var rules: [Rule] = []
    private(set) var records: [Record] = []
    private let fallback: HTTPResponseData

    init(fallback: HTTPResponseData = HTTPResponseData(statusCode: 404, headers: [:], body: Data())) {
        self.fallback = fallback
    }

    func on(_ suffix: String, method: String? = nil, status: Int = 200, json: String, headers: [String: String] = [:]) {
        self.on(suffix, method: method, response: HTTPResponseData(statusCode: status, headers: headers, body: Data(json.utf8)))
    }

    func on(_ suffix: String, method: String? = nil, response: HTTPResponseData) {
        if let index = self.rules.firstIndex(where: { $0.suffix == suffix && $0.method == method }) {
            self.rules[index].responses.append(.success(response))
        } else {
            self.rules.append(Rule(method: method, suffix: suffix, responses: [.success(response)]))
        }
    }

    func fail(_ suffix: String, method: String? = nil, error: Error) {
        if let index = self.rules.firstIndex(where: { $0.suffix == suffix && $0.method == method }) {
            self.rules[index].responses.append(.failure(error))
        } else {
            self.rules.append(Rule(method: method, suffix: suffix, responses: [.failure(error)]))
        }
    }

    func data(for request: URLRequest) async throws -> HTTPResponseData {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        self.records.append(
            Record(
                method: method,
                url: request.url?.absoluteString ?? "",
                path: path,
                query: request.url?.query,
                headers: request.allHTTPHeaderFields ?? [:],
                body: String(decoding: request.httpBody ?? Data(), as: UTF8.self),
                timeout: request.timeoutInterval
            )
        )
        guard let index = self.rules.firstIndex(where: { path.hasSuffix($0.suffix) && ($0.method == nil || $0.method == method) }) else {
            return self.fallback
        }
        let result: Result<HTTPResponseData, Error>
        if self.rules[index].responses.count > 1 {
            result = self.rules[index].responses.removeFirst()
        } else {
            result = self.rules[index].responses[0]
        }
        return try result.get()
    }

    func requests(_ suffix: String, method: String? = nil) -> [Record] {
        self.records.filter { $0.path.hasSuffix(suffix) && (method == nil || $0.method == method) }
    }

    func count(_ suffix: String, method: String? = nil) -> Int {
        self.requests(suffix, method: method).count
    }
}

/// One-shot gate: ``wait()`` suspends until ``open()``.
actor ChannelTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var waitCount = 0

    func wait() async {
        self.waitCount += 1
        guard !self.isOpen else { return }
        await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }

    func open() {
        self.isOpen = true
        let pending = self.waiters
        self.waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

/// Collects inbound messages and join events.
actor ChannelEventCollector {
    private(set) var messages: [InboundMessage] = []
    private(set) var joins: [ChannelJoinEvent] = []

    func append(_ message: InboundMessage) {
        self.messages.append(message)
    }

    func appendJoin(_ event: ChannelJoinEvent) {
        self.joins.append(event)
    }
}

/// Fake WebSocket connector: each `connect` hands out the next scripted connection.
actor FakeWebSocketConnector: ChannelWebSocketConnecting {
    private var connections: [FakeWebSocket] = []
    private(set) var requests: [URLRequest] = []

    init(_ connections: [FakeWebSocket]) {
        self.connections = connections
    }

    func connect(_ request: URLRequest, maximumMessageSize _: Int?) async throws -> any ChannelWebSocketConnection {
        self.requests.append(request)
        guard !self.connections.isEmpty else {
            throw URLError(.cannotConnectToHost)
        }
        return self.connections.removeFirst()
    }

    func connectCount() -> Int {
        self.requests.count
    }
}

/// Fake socket: `receive()` yields scripted frames, then waits until closed or fed more frames.
actor FakeWebSocket: ChannelWebSocketConnection {
    private var inbound: [String]
    private(set) var sent: [String] = []
    private var closed = false
    private var waiters: [CheckedContinuation<String, Error>] = []
    private let peerCloseCode: Int?

    init(frames: [String], closeCode: Int? = nil) {
        self.inbound = frames
        self.peerCloseCode = closeCode
    }

    func send(text: String) async throws {
        guard !self.closed else { throw URLError(.networkConnectionLost) }
        self.sent.append(text)
    }

    func receive() async throws -> String {
        if !self.inbound.isEmpty {
            return self.inbound.removeFirst()
        }
        if self.closed || self.peerCloseCode != nil {
            throw URLError(.networkConnectionLost)
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.waiters.append(continuation)
        }
    }

    func feed(_ frame: String) {
        if !self.waiters.isEmpty {
            self.waiters.removeFirst().resume(returning: frame)
        } else {
            self.inbound.append(frame)
        }
    }

    func close() async {
        self.closed = true
        let pending = self.waiters
        self.waiters.removeAll()
        for waiter in pending {
            waiter.resume(throwing: URLError(.networkConnectionLost))
        }
    }

    func closeCode() async -> Int? {
        self.peerCloseCode
    }

    func sentFrames() -> [String] {
        self.sent
    }

    func isClosed() -> Bool {
        self.closed
    }
}

func jsonObject(_ text: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
}
