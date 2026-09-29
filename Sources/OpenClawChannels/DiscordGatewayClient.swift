import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore
import OpenClawProtocol

/// Discord gateway intent bits (upstream `extensions/discord/src/monitor/gateway-plugin.ts`).
public enum DiscordGatewayIntent {
    /// `GUILDS` (1 << 0).
    public static let guilds = 1 << 0
    /// `GUILD_MEMBERS` (1 << 1, privileged).
    public static let guildMembers = 1 << 1
    /// `GUILD_EXPRESSIONS` (1 << 3).
    public static let guildExpressions = 1 << 3
    /// `GUILD_PRESENCES` (1 << 8, privileged).
    public static let guildPresences = 1 << 8
    /// `GUILD_MESSAGES` (1 << 9).
    public static let guildMessages = 1 << 9
    /// `GUILD_MESSAGE_REACTIONS` (1 << 10).
    public static let guildMessageReactions = 1 << 10
    /// `DIRECT_MESSAGES` (1 << 12).
    public static let directMessages = 1 << 12
    /// `DIRECT_MESSAGE_REACTIONS` (1 << 13).
    public static let directMessageReactions = 1 << 13
    /// `MESSAGE_CONTENT` (1 << 15, privileged).
    public static let messageContent = 1 << 15

    /// Intents requested for a config: the upstream base set, plus Message Content unless
    /// `intents.messageContent == false`, plus Presences/Members only when enabled.
    /// - Parameter intents: Intent switches.
    /// - Returns: Intent bit field.
    public static func resolve(_ intents: DiscordIntentsConfig) -> Int {
        var value = self.guilds | self.guildExpressions | self.guildMessages | self.guildMessageReactions
            | self.directMessages | self.directMessageReactions
        if intents.messageContent ?? true {
            value |= self.messageContent
        }
        if intents.presence == true {
            value |= self.guildPresences
        }
        if intents.guildMembers == true {
            value |= self.guildMembers
        }
        return value
    }
}

/// Bot presence sent with `IDENTIFY` and presence updates.
public struct DiscordPresence: Sendable, Equatable {
    /// Status (`online`, `dnd`, `idle`, `invisible`).
    public var status: DiscordPresenceStatus
    /// Activity text.
    public var activity: String?
    /// Activity type 0-5 (defaults to 4, Custom, when ``activity`` is set).
    public var activityType: Int?
    /// Streaming URL for activity type 1.
    public var activityURL: String?

    /// Creates a presence.
    /// - Parameters:
    ///   - status: Status.
    ///   - activity: Activity text.
    ///   - activityType: Activity type.
    ///   - activityURL: Streaming URL.
    public init(status: DiscordPresenceStatus = .online, activity: String? = nil, activityType: Int? = nil, activityURL: String? = nil) {
        self.status = status
        self.activity = activity
        self.activityType = activityType
        self.activityURL = activityURL
    }

    /// Presence from channel config (`status`, `activity`, `activityType`, `activityUrl`).
    /// - Parameter config: Discord config.
    /// - Returns: Presence.
    public static func from(_ config: DiscordChannelConfig) -> DiscordPresence {
        DiscordPresence(
            status: config.status ?? .online,
            activity: config.activity?.channelTrimmedNonEmpty,
            activityType: config.activityType,
            activityURL: config.activityURL
        )
    }

    var payload: [String: Any] {
        var activities: [[String: Any]] = []
        if let activity {
            let type = self.activityType ?? 4
            var entry: [String: Any] = ["type": type, "name": type == 4 ? "Custom Status" : activity]
            if type == 4 {
                entry["state"] = activity
            }
            if type == 1, let activityURL {
                entry["url"] = activityURL
            }
            activities.append(entry)
        }
        return ["since": NSNull(), "activities": activities, "status": self.status.rawValue, "afk": false]
    }
}

/// Handler for gateway dispatch events: event name (`MESSAGE_CREATE`, ...) and the raw frame JSON.
public typealias DiscordGatewayDispatchHandler = @Sendable (_ event: String, _ frame: Data) async -> Void

private struct DiscordGatewayDispatch: Sendable {
    let type: String
    let frame: Data
}

private struct DiscordGatewayFrame: Decodable {
    let op: Int
    let s: Int?
    let t: String?
    let d: AnyCodable?
}

/// Discord gateway client: HELLO, IDENTIFY with intents, heartbeats with ACK tracking,
/// dispatch forwarding, and RESUME/reconnect on `op 7`, `op 9` and dropped sockets with backoff.
///
/// Dispatch events are handed to the handler in order from a separate task, so a slow handler
/// never stalls the receive loop: heartbeat ACKs, reconnect requests and later events keep
/// flowing while an agent turn runs.
///
/// Terminal close codes (4004 authentication failed, 4010-4014 invalid shard/version/intents)
/// stop reconnecting and are reported through ``lastError()``.
public actor DiscordGatewayClient {
    /// Terminal close codes (no reconnect).
    public static let terminalCloseCodes: Set<Int> = [4004, 4010, 4011, 4012, 4013, 4014]

    private let token: String
    private let intents: Int
    private var presence: DiscordPresence?
    private let gatewayURL: URL
    private let connector: any ChannelWebSocketConnecting
    private let maxBackoffMs: Int

    private var socket: (any ChannelWebSocketConnection)?
    private var runTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var dispatchTask: Task<Void, Never>?
    private var dispatchContinuation: AsyncStream<DiscordGatewayDispatch>.Continuation?
    private var sequence: Int?
    private var sessionID: String?
    private var resumeURL: URL?
    private var heartbeatIntervalMs = 45_000
    private var awaitingAck = false
    private var running = false
    private var readyUserID: String?
    private var error: String?
    private var readyContinuation: CheckedContinuation<Void, Error>?

    /// Creates a gateway client.
    /// - Parameters:
    ///   - token: Bot token.
    ///   - intents: Intent bit field (see ``DiscordGatewayIntent/resolve(_:)``).
    ///   - presence: Presence sent with IDENTIFY (`nil` = default online).
    ///   - gatewayURL: Gateway URL.
    ///   - connector: WebSocket connector.
    ///   - maxBackoffMs: Reconnect backoff cap.
    public init(
        token: String,
        intents: Int,
        presence: DiscordPresence? = nil,
        gatewayURL: URL = URL(string: "wss://gateway.discord.gg/?v=10&encoding=json")!,
        connector: any ChannelWebSocketConnecting = URLSessionChannelWebSocketConnector(),
        maxBackoffMs: Int = 30_000
    ) {
        self.token = token
        self.intents = intents
        self.presence = presence
        self.gatewayURL = gatewayURL
        self.connector = connector
        self.maxBackoffMs = max(1, maxBackoffMs)
    }

    /// Connects, identifies and forwards dispatch events until ``stop()``.
    ///
    /// Returns once the first `READY` arrives (or throws when the first connection fails).
    /// - Parameter handler: Dispatch handler.
    public func start(handler: @escaping DiscordGatewayDispatchHandler) async throws {
        guard !self.running else { return }
        guard !self.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("Discord gateway token is required")
        }
        let (dispatches, continuation) = AsyncStream<DiscordGatewayDispatch>.makeStream()
        self.dispatchContinuation = continuation
        self.dispatchTask = Task {
            for await dispatch in dispatches {
                await handler(dispatch.type, dispatch.frame)
            }
        }
        self.running = true
        self.error = nil
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.readyContinuation = continuation
            self.runTask = Task { [weak self] in
                await self?.runLoop()
            }
        }
    }

    /// Stops the client and closes the socket (sets presence invisible first).
    public func stop() async {
        guard self.running else { return }
        self.running = false
        if let socket, let text = try? Self.text(["op": 3, "d": DiscordPresence(status: .invisible).payload]) {
            try? await socket.send(text: text)
        }
        self.runTask?.cancel()
        self.runTask = nil
        self.heartbeatTask?.cancel()
        self.heartbeatTask = nil
        self.finishDispatch()
        self.dispatchTask?.cancel()
        self.dispatchTask = nil
        await self.socket?.close()
        self.socket = nil
        self.sequence = nil
        self.sessionID = nil
        self.resumeURL = nil
        self.failReady(OpenClawCoreError.unavailable("Discord gateway stopped"))
    }

    /// Updates bot presence (`op 3`).
    /// - Parameter presence: New presence.
    public func updatePresence(_ presence: DiscordPresence) async {
        self.presence = presence
        guard let socket, let text = try? Self.text(["op": 3, "d": presence.payload]) else { return }
        try? await socket.send(text: text)
    }

    /// Bot user id from the last `READY`.
    /// - Returns: User id.
    public func botUserID() -> String? {
        self.readyUserID
    }

    /// Last terminal or connection error.
    /// - Returns: Error detail.
    public func lastError() -> String? {
        self.error
    }

    // MARK: Loop

    private func runLoop() async {
        var attempt = 0
        while self.running, !Task.isCancelled {
            do {
                try await self.runConnection()
                attempt = 0
            } catch {
                self.error = ChannelErrorText.describe(error)
                if self.readyContinuation != nil {
                    // The first connection failed before READY: fail start() instead of retrying forever.
                    self.running = false
                    self.heartbeatTask?.cancel()
                    self.heartbeatTask = nil
                    self.finishDispatch()
                    await self.socket?.close()
                    self.socket = nil
                    self.failReady(error)
                    return
                }
            }
            guard self.running, !Task.isCancelled else { return }
            if let code = await self.socket?.closeCode(), Self.terminalCloseCodes.contains(code) {
                self.error = "Discord gateway closed with terminal code \(code)"
                self.running = false
                self.heartbeatTask?.cancel()
                self.heartbeatTask = nil
                self.finishDispatch()
                self.failReady(OpenClawCoreError.unavailable(self.error ?? "Discord gateway closed"))
                return
            }
            self.heartbeatTask?.cancel()
            self.heartbeatTask = nil
            await self.socket?.close()
            self.socket = nil
            attempt += 1
            let delay = min(self.maxBackoffMs, 1_000 * (1 << min(attempt - 1, 5)))
            await ChannelAsync.sleep(milliseconds: delay)
        }
    }

    private func runConnection() async throws {
        var request = URLRequest(url: self.resumeURL ?? self.gatewayURL)
        request.timeoutInterval = 30
        let socket = try await self.connector.connect(request, maximumMessageSize: 8 * 1_024 * 1_024)
        self.socket = socket
        let helloRaw = try await socket.receive()
        let hello = try JSONDecoder().decode(DiscordGatewayFrame.self, from: Data(helloRaw.utf8))
        guard hello.op == 10, let interval = hello.d?.dictionaryValue?["heartbeat_interval"]?.intValue else {
            throw OpenClawCoreError.unavailable("Discord gateway hello payload was invalid")
        }
        self.heartbeatIntervalMs = max(1_000, interval)
        if let sessionID, let sequence {
            try await socket.send(text: Self.text(["op": 6, "d": ["token": self.token, "session_id": sessionID, "seq": sequence]]))
        } else {
            try await self.identify(on: socket)
        }
        self.startHeartbeat(on: socket)
        while self.running, !Task.isCancelled {
            let raw = try await socket.receive()
            guard let frame = try? JSONDecoder().decode(DiscordGatewayFrame.self, from: Data(raw.utf8)) else { continue }
            if let seq = frame.s {
                self.sequence = seq
            }
            switch frame.op {
            case 0:
                self.handleDispatch(frame, raw: raw)
            case 1:
                try await socket.send(text: Self.text(["op": 1, "d": self.sequenceJSON]))
            case 7:
                // Reconnect requested; resume on the next connection.
                return
            case 9:
                if frame.d?.boolValue != true {
                    self.sessionID = nil
                    self.sequence = nil
                    self.resumeURL = nil
                }
                await ChannelAsync.sleep(milliseconds: Int.random(in: 1_000...5_000))
                return
            case 11:
                self.awaitingAck = false
            default:
                continue
            }
        }
    }

    private func identify(on socket: any ChannelWebSocketConnection) async throws {
        var data: [String: Any] = [
            "token": self.token,
            "intents": self.intents,
            "properties": ["os": "openclawkit", "browser": "openclawkit", "device": "openclawkit"],
        ]
        data["presence"] = (self.presence ?? DiscordPresence()).payload
        try await socket.send(text: Self.text(["op": 2, "d": data]))
    }

    /// Session bookkeeping runs inline; the handler runs on the dispatch task.
    private func handleDispatch(_ frame: DiscordGatewayFrame, raw: String) {
        guard let type = frame.t else { return }
        if type == "RESUMED" {
            self.error = nil
        }
        if type == "READY" {
            let payload = frame.d?.dictionaryValue
            self.sessionID = payload?["session_id"]?.stringValue
            self.readyUserID = payload?["user"]?.dictionaryValue?["id"]?.stringValue
            if let resume = payload?["resume_gateway_url"]?.stringValue,
               var components = URLComponents(string: resume)
            {
                components.queryItems = [URLQueryItem(name: "v", value: "10"), URLQueryItem(name: "encoding", value: "json")]
                self.resumeURL = components.url
            }
            self.error = nil
            self.readyContinuation?.resume()
            self.readyContinuation = nil
        }
        self.dispatchContinuation?.yield(DiscordGatewayDispatch(type: type, frame: Data(raw.utf8)))
    }

    private func startHeartbeat(on socket: any ChannelWebSocketConnection) {
        self.heartbeatTask?.cancel()
        self.awaitingAck = false
        let interval = self.heartbeatIntervalMs
        self.heartbeatTask = Task { [weak self] in
            // First beat is jittered per the gateway docs.
            await ChannelAsync.sleep(milliseconds: Int(Double(interval) * Double.random(in: 0.1...1.0)))
            while !Task.isCancelled {
                guard let self else { return }
                guard await self.beat(on: socket) else {
                    // Missed ACK: zombied connection; closing forces a resume.
                    await socket.close()
                    return
                }
                await ChannelAsync.sleep(milliseconds: interval)
            }
        }
    }

    private func beat(on socket: any ChannelWebSocketConnection) async -> Bool {
        if self.awaitingAck {
            return false
        }
        self.awaitingAck = true
        guard let text = try? Self.text(["op": 1, "d": self.sequenceJSON]) else { return true }
        try? await socket.send(text: text)
        return true
    }

    private var sequenceJSON: Any {
        self.sequence.map { $0 as Any } ?? NSNull()
    }

    /// Ends the dispatch stream; events already queued are still delivered unless the task is cancelled.
    private func finishDispatch() {
        self.dispatchContinuation?.finish()
        self.dispatchContinuation = nil
    }

    private func failReady(_ error: Error) {
        self.readyContinuation?.resume(throwing: error)
        self.readyContinuation = nil
    }

    private static func text(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}
