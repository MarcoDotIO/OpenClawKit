import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore

/// Presence lifecycle contract used by Discord channel integrations.
public protocol DiscordPresenceClient: Sendable {
    /// Starts presence signaling.
    func start() async throws
    /// Stops presence signaling and tears down resources.
    func stop() async
}

protocol DiscordGatewaySocket: Sendable {
    func connect(url: URL) async throws
    func send(text: String) async throws
    func receive() async throws -> String
    func close() async
}

actor URLSessionDiscordGatewaySocket: DiscordGatewaySocket {
    private let session: URLSession
    private var task: URLSessionWebSocketTask?

    init(session: URLSession = .shared) {
        self.session = session
    }

    func connect(url: URL) async throws {
        let task = self.session.webSocketTask(with: url)
        task.resume()
        self.task = task
    }

    func send(text: String) async throws {
        guard let task = self.task else {
            throw OpenClawCoreError.unavailable("Discord gateway socket is not connected")
        }
        try await task.send(.string(text))
    }

    func receive() async throws -> String {
        guard let task = self.task else {
            throw OpenClawCoreError.unavailable("Discord gateway socket is not connected")
        }
        let message = try await task.receive()
        switch message {
        case .string(let text):
            return text
        case .data(let data):
            return String(decoding: data, as: UTF8.self)
        @unknown default:
            throw OpenClawCoreError.unavailable("Unsupported Discord gateway frame")
        }
    }

    func close() async {
        self.task?.cancel(with: .goingAway, reason: nil)
        self.task = nil
    }
}

/// Minimal Discord gateway client that keeps bot presence online while deployed.
public actor DiscordGatewayPresenceClient: DiscordPresenceClient {
    typealias SocketFactory = @Sendable () -> any DiscordGatewaySocket

    private let token: String
    private let gatewayURL: URL
    private let socketFactory: SocketFactory
    private var socket: (any DiscordGatewaySocket)?
    private var heartbeatTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var sequence: Int?
    private var heartbeatIntervalMs: Int = 45_000
    private var started = false

    /// Creates a gateway presence client.
    /// - Parameters:
    ///   - token: Discord bot token.
    ///   - gatewayURL: Discord gateway URL.
    public init(
        token: String,
        gatewayURL: URL = URL(string: "wss://gateway.discord.gg/?v=10&encoding=json")!
    ) {
        self.token = token
        self.gatewayURL = gatewayURL
        self.socketFactory = { URLSessionDiscordGatewaySocket() }
    }

    init(
        token: String,
        gatewayURL: URL,
        socketFactory: @escaping SocketFactory
    ) {
        self.token = token
        self.gatewayURL = gatewayURL
        self.socketFactory = socketFactory
    }

    /// Connects to Discord gateway and starts heartbeat/receive loops.
    public func start() async throws {
        guard !self.started else { return }
        let trimmed = self.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("Discord gateway token is required")
        }

        let socket = self.socketFactory()
        try await socket.connect(url: self.gatewayURL)
        self.socket = socket

        let helloPayload = try await socket.receive()
        try self.handleHelloPayload(helloPayload)
        try await self.sendIdentify(token: trimmed)
        self.started = true
        self.startReceiveLoop()
        self.startHeartbeatLoop()
    }

    /// Stops heartbeat/receive loops and closes gateway transport.
    public func stop() async {
        _ = await self.sendPresenceUpdate(status: "invisible")
        self.started = false
        self.heartbeatTask?.cancel()
        self.heartbeatTask = nil
        self.receiveTask?.cancel()
        self.receiveTask = nil
        if let socket = self.socket {
            await socket.close()
        }
        self.socket = nil
        self.sequence = nil
    }

    private func handleHelloPayload(_ raw: String) throws {
        guard let data = raw.data(using: .utf8) else {
            throw OpenClawCoreError.unavailable("Discord gateway hello frame was not UTF-8")
        }
        guard
            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let op = payload["op"] as? Int,
            op == 10,
            let details = payload["d"] as? [String: Any],
            let heartbeatInterval = details["heartbeat_interval"] as? Int
        else {
            throw OpenClawCoreError.unavailable("Discord gateway hello payload was invalid")
        }
        self.heartbeatIntervalMs = max(10_000, heartbeatInterval)
    }

    private func sendIdentify(token: String) async throws {
        guard let socket = self.socket else {
            throw OpenClawCoreError.unavailable("Discord gateway socket is not connected")
        }

        let payload: [String: Any] = [
            "op": 2,
            "d": [
                "token": token,
                "intents": 0,
                "properties": [
                    "os": "openclawkit",
                    "browser": "openclawkit",
                    "device": "openclawkit",
                ],
                "presence": [
                    "status": "online",
                    "since": NSNull(),
                    "activities": [],
                    "afk": false,
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let raw = String(decoding: data, as: UTF8.self)
        try await socket.send(text: raw)
    }

    private func sendPresenceUpdate(status: String) async -> Bool {
        guard let socket = self.socket else {
            return false
        }
        let payload: [String: Any] = [
            "op": 3,
            "d": [
                "since": NSNull(),
                "activities": [],
                "status": status,
                "afk": false,
            ],
        ]
        guard
            let data = try? JSONSerialization.data(withJSONObject: payload),
            let raw = String(data: data, encoding: .utf8)
        else {
            return false
        }
        do {
            try await socket.send(text: raw)
            return true
        } catch {
            return false
        }
    }

    private func startHeartbeatLoop() {
        self.heartbeatTask?.cancel()
        self.heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sendHeartbeat()
                let interval = await self.currentHeartbeatIntervalMs()
                let delayNs = ChannelAsync.nanoseconds(milliseconds: max(1_000, interval))
                try? await Task.sleep(nanoseconds: delayNs)
            }
        }
    }

    private func currentHeartbeatIntervalMs() -> Int {
        self.heartbeatIntervalMs
    }

    private func sendHeartbeat() {
        guard let socket = self.socket else { return }
        let payload: [String: Any] = [
            "op": 1,
            "d": self.sequence.map { $0 as Any } ?? NSNull(),
        ]
        guard
            let data = try? JSONSerialization.data(withJSONObject: payload),
            let raw = String(data: data, encoding: .utf8)
        else {
            return
        }
        Task {
            try? await socket.send(text: raw)
        }
    }

    private func startReceiveLoop() {
        self.receiveTask?.cancel()
        self.receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let socket = await self.socket else {
                    return
                }
                do {
                    let raw = try await socket.receive()
                    await self.handleEventPayload(raw)
                } catch {
                    return
                }
            }
        }
    }

    private func handleEventPayload(_ raw: String) {
        guard let data = raw.data(using: .utf8) else { return }
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        if let seq = payload["s"] as? Int {
            self.sequence = seq
        }
        if let op = payload["op"] as? Int, op == 10,
           let details = payload["d"] as? [String: Any],
           let interval = details["heartbeat_interval"] as? Int
        {
            self.heartbeatIntervalMs = max(10_000, interval)
        }
    }
}
