import Foundation
import OpenClawAgents
import OpenClawCore

/// Mailbox cursor (UIDVALIDITY + last seen UID).
public struct IMAPCursor: Codable, Sendable, Equatable {
    /// UIDVALIDITY.
    public var uidValidity: String
    /// Last processed UID.
    public var lastSeenUID: UInt32
    /// Last update.
    public var updatedAt: Date

    /// Creates a cursor.
    /// - Parameters:
    ///   - uidValidity: UIDVALIDITY.
    ///   - lastSeenUID: Last UID.
    ///   - updatedAt: Timestamp.
    public init(uidValidity: String, lastSeenUID: UInt32, updatedAt: Date = Date()) {
        self.uidValidity = uidValidity
        self.lastSeenUID = lastSeenUID
        self.updatedAt = updatedAt
    }
}

/// Persistence for watcher cursors and recently dispatched Message-IDs.
public protocol IMAPCursorStore: Sendable {
    /// Cursor for an account.
    /// - Parameter accountID: Account id.
    /// - Returns: Cursor.
    func cursor(accountID: String) async -> IMAPCursor?
    /// Stores a cursor.
    /// - Parameters:
    ///   - cursor: Cursor.
    ///   - accountID: Account id.
    func setCursor(_ cursor: IMAPCursor, accountID: String) async
    /// Records a Message-ID; returns `false` when it was already recorded (last 100 kept).
    /// - Parameters:
    ///   - messageID: Message-ID.
    ///   - accountID: Account id.
    /// - Returns: Whether the id was new.
    func rememberMessageID(_ messageID: String, accountID: String) async -> Bool
    /// Whether a Message-ID was recorded.
    /// - Parameters:
    ///   - messageID: Message-ID.
    ///   - accountID: Account id.
    /// - Returns: `true` when recorded.
    func containsMessageID(_ messageID: String, accountID: String) async -> Bool
}

/// JSON-file (or in-memory when `fileURL` is `nil`) cursor store.
public actor FileIMAPCursorStore: IMAPCursorStore {
    private struct State: Codable {
        var cursors: [String: IMAPCursor] = [:]
        var messageIDs: [String: [String]] = [:]
    }

    private let fileURL: URL?
    private var state: State

    /// Creates a store.
    /// - Parameter fileURL: JSON file (`nil` keeps state in memory).
    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder().decode(State.self, from: data) {
            self.state = decoded
        } else {
            self.state = State()
        }
    }

    /// Cursor for an account.
    /// - Parameter accountID: Account id.
    /// - Returns: Cursor.
    public func cursor(accountID: String) -> IMAPCursor? {
        self.state.cursors[accountID]
    }

    /// Stores a cursor.
    /// - Parameters:
    ///   - cursor: Cursor.
    ///   - accountID: Account id.
    public func setCursor(_ cursor: IMAPCursor, accountID: String) {
        self.state.cursors[accountID] = cursor
        self.persist()
    }

    /// Records a Message-ID.
    /// - Parameters:
    ///   - messageID: Message-ID.
    ///   - accountID: Account id.
    /// - Returns: Whether the id was new.
    public func rememberMessageID(_ messageID: String, accountID: String) -> Bool {
        var ring = self.state.messageIDs[accountID] ?? []
        guard !ring.contains(messageID) else { return false }
        ring.append(messageID)
        self.state.messageIDs[accountID] = Array(ring.suffix(100))
        self.persist()
        return true
    }

    /// Whether a Message-ID was recorded.
    /// - Parameters:
    ///   - messageID: Message-ID.
    ///   - accountID: Account id.
    /// - Returns: `true` when recorded.
    public func containsMessageID(_ messageID: String, accountID: String) -> Bool {
        self.state.messageIDs[accountID]?.contains(messageID) == true
    }

    private func persist() {
        guard let fileURL, let data = try? JSONEncoder().encode(self.state) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Isolated hook agent turn for one admitted email (upstream `dispatchHookAgentTurn`).
public struct IMAPHookTurn: Sendable, Equatable {
    /// Display name (`IMAP <account>`).
    public var name: String
    /// Target agent.
    public var agentID: String
    /// Session key `hook:imap:<account>:<uidvalidity>:<uid>` (also the idempotency key).
    public var sessionKey: String
    /// Untrusted-email prompt.
    public var message: String
    /// Whether the reply is delivered to a channel.
    public var deliver: Bool
    /// Model override.
    public var model: String?
    /// Thinking override.
    public var thinking: String?
    /// Timeout in seconds.
    public var timeoutSeconds: Int?
    /// Sender address.
    public var sender: String
    /// Gate reason (`token` or the authentication evidence).
    public var gateReason: String

    /// External content source marker.
    public var externalContentSource: String {
        "email"
    }

    /// Idempotency key (same as the session key).
    public var idempotencyKey: String {
        self.sessionKey
    }
}

/// IMAP inbox watcher: a hook source (not a channel) that turns authenticated email into
/// isolated agent turns (port of upstream `extensions/imap`).
///
/// Per account it logs in (implicit TLS by default), opens the mailbox read-only, keeps a
/// `(UIDVALIDITY, lastSeenUid)` cursor (a new mailbox starts at the current `UIDNEXT - 1`),
/// fetches `UID last+1:*` capped at 1 MiB per message and waits with IDLE (re-issued at least
/// every 4 minutes) when the server supports it and `watch.mode` is not `interval`, otherwise
/// polls every `pollSeconds`. Each message passes ``IMAPSenderGate``; admitted mail is
/// dispatched once as ``IMAPHookTurn`` (Message-IDs deduped). Rejected transient verdicts and
/// dispatch failures retry up to three times before the message is skipped. Three
/// authentication failures stop the watcher (``ChannelTransportHealth/State/blocked``).
///
/// Uses Network.framework on Apple platforms; on Linux supply an ``IMAPTransport``.
public actor IMAPMailboxWatcher {
    /// Dispatches a hook turn; return `true` when it was admitted.
    public typealias Dispatcher = @Sendable (IMAPHookTurn) async throws -> Bool
    /// Creates a transport for the account.
    public typealias TransportFactory = @Sendable (IMAPAccountConfig) throws -> any IMAPTransport

    /// Maximum fetched source bytes per message.
    public static let maxSourceBytes = 1_048_576
    /// Maximum attempts before a message is skipped.
    public static let maxAttempts = 3
    /// Maximum IDLE duration before it is re-issued.
    public static let maxIdleSeconds: TimeInterval = 240
    /// Maximum reconnect delay.
    public static let maxReconnectDelay: TimeInterval = 60

    private let accountID: String
    private let account: IMAPAccountConfig
    private let store: any IMAPCursorStore
    private let transportFactory: TransportFactory
    private let dispatcher: Dispatcher
    private let diagnosticsSink: RuntimeDiagnosticSink?
    private let now: @Sendable () -> Date
    private let reconnectBase: TimeInterval

    private var loopTask: Task<Void, Never>?
    private var client: IMAPClient?
    private var attempts: [String: Int] = [:]
    private var authFailures = 0
    private var failures = 0
    private var health = ChannelTransportHealth()
    private var dispatchedKeys: Set<String> = []

    /// Creates a watcher.
    /// - Parameters:
    ///   - accountID: Account id (session-safe).
    ///   - account: Account settings.
    ///   - store: Cursor store.
    ///   - transportFactory: Transport factory (default: Network.framework TLS on Apple platforms).
    ///   - reconnectBaseSeconds: Initial reconnect backoff.
    ///   - diagnosticsSink: Diagnostics (`imap.*` events).
    ///   - now: Clock.
    ///   - dispatcher: Hook-turn dispatcher.
    public init(
        accountID: String,
        account: IMAPAccountConfig,
        store: any IMAPCursorStore = FileIMAPCursorStore(),
        transportFactory: TransportFactory? = nil,
        reconnectBaseSeconds: TimeInterval = 1,
        diagnosticsSink: RuntimeDiagnosticSink? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        dispatcher: @escaping Dispatcher
    ) {
        self.accountID = accountID
        self.account = account
        self.store = store
        self.transportFactory = transportFactory ?? { account in try Self.defaultTransport(for: account) }
        self.reconnectBase = reconnectBaseSeconds
        self.diagnosticsSink = diagnosticsSink
        self.now = now
        self.dispatcher = dispatcher
    }

    /// Current connection health.
    /// - Returns: Health snapshot.
    public func transportHealth() -> ChannelTransportHealth {
        self.health
    }

    /// Starts watching (no-op when already running or the sender allowlist is empty).
    public func start() {
        guard self.loopTask == nil else { return }
        guard !self.account.allowedSenders.isEmpty else {
            self.health = ChannelTransportHealth(state: .blocked, lastError: "allowedSenders is empty; the account is disabled")
            return
        }
        self.loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Stops watching and logs out.
    public func stop() async {
        self.loopTask?.cancel()
        self.loopTask = nil
        await self.client?.close()
        self.client = nil
        self.health = ChannelTransportHealth(state: .stopped)
    }

    private func runLoop() async {
        while !Task.isCancelled {
            do {
                try await self.runConnection()
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                await self.client?.close()
                self.client = nil
                if case IMAPError.authenticationFailed = error {
                    self.authFailures += 1
                    if self.authFailures >= Self.maxAttempts {
                        let message = "account \(self.accountID) needs reauthentication after \(Self.maxAttempts) authentication failures"
                        self.health = ChannelTransportHealth(state: .blocked, lastError: message)
                        await self.emit("imap.auth_blocked", ["account": self.accountID])
                        return
                    }
                }
                self.health = ChannelTransportHealth(state: .degraded, lastError: error.localizedDescription)
                await self.emit("imap.connection_failed", ["account": self.accountID, "error": error.localizedDescription])
                let delay = min(self.reconnectBase * pow(2, Double(self.failures)), Self.maxReconnectDelay)
                self.failures += 1
                let jitter = Double.random(in: 0...max(0.001, delay / 4))
                try? await Task.sleep(nanoseconds: UInt64((delay + jitter) * 1_000_000_000))
            }
        }
    }

    private func runConnection() async throws {
        let client = IMAPClient(transport: try self.transportFactory(self.account))
        self.client = client
        try await client.connect()
        if await client.capabilities.isEmpty {
            try await client.refreshCapabilities()
        }
        try await client.login(user: self.account.user, password: self.account.password)
        try await client.refreshCapabilities()
        let mailbox = try await client.examine(self.account.mailbox)
        let uidValidity = String(mailbox.uidValidity)
        let existing = await self.store.cursor(accountID: self.accountID)
        if existing?.uidValidity != uidValidity {
            let baseline = IMAPCursor(uidValidity: uidValidity, lastSeenUID: (mailbox.uidNext ?? 1) &- 1, updatedAt: self.now())
            await self.store.setCursor(baseline, accountID: self.accountID)
            await self.emit("imap.cursor", ["account": self.accountID, "kind": existing == nil ? "baseline" : "reset"])
        }
        self.authFailures = 0
        self.failures = 0
        let supportsIdle = await client.capabilities.contains("IDLE")
        let push = self.account.watchMode != .interval && supportsIdle
        self.health = ChannelTransportHealth(state: .healthy)
        await self.emit("imap.connected", ["account": self.accountID, "mode": push ? "push" : "poll"])
        while !Task.isCancelled {
            try await self.sweep(client: client)
            let interval = TimeInterval(self.account.pollSeconds)
            if push {
                _ = try await client.idle(timeout: min(interval, Self.maxIdleSeconds))
            } else {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                try await client.command("NOOP")
            }
        }
    }

    /// Fetches and processes new messages once (exposed for tests and manual refresh).
    func sweep(client: IMAPClient) async throws {
        guard let cursor = await self.store.cursor(accountID: self.accountID) else { return }
        let messages = try await client.fetch(after: cursor.lastSeenUID, maxBytes: Self.maxSourceBytes)
        for message in messages {
            guard !Task.isCancelled else { return }
            guard await self.process(message, uidValidity: cursor.uidValidity) else { break }
            await self.store.setCursor(IMAPCursor(uidValidity: cursor.uidValidity, lastSeenUID: message.uid, updatedAt: self.now()), accountID: self.accountID)
        }
    }

    /// Returns `false` to stop the sweep and retry this message later.
    private func process(_ message: IMAPFetchedMessage, uidValidity: String) async -> Bool {
        let key = "\(self.accountID):\(uidValidity):\(message.uid)"
        guard let source = message.source else {
            await self.skip(message.uid, sender: nil, reason: "message-source-missing")
            return true
        }
        let mail = IMAPMailMessage(raw: source)
        let verdict = IMAPSenderGate.evaluate(mail: mail, internalDate: message.internalDate ?? self.now(), account: self.account, now: self.now())
        guard verdict.accepted, let sender = verdict.sender else {
            await self.skip(message.uid, sender: verdict.sender, reason: verdict.reason)
            return true
        }
        if let messageID = mail.messageID, await self.store.containsMessageID(messageID, accountID: self.accountID) {
            await self.skip(message.uid, sender: sender, reason: "duplicate-message-id")
            return true
        }
        guard !self.dispatchedKeys.contains(key) else {
            await self.skip(message.uid, sender: sender, reason: "duplicate-uid")
            return true
        }
        let turn = IMAPHookTurn(
            name: "IMAP \(self.accountID)",
            agentID: self.account.agentId,
            sessionKey: "hook:imap:\(key)",
            message: IMAPPrompt.render(
                mail: mail,
                includeBody: self.account.includeBody,
                maxBytes: self.account.maxBytes,
                sourceTruncated: (message.size ?? 0) > Self.maxSourceBytes
            ),
            deliver: self.account.deliver,
            model: self.account.model,
            thinking: self.account.thinking,
            timeoutSeconds: self.account.timeoutSeconds,
            sender: sender,
            gateReason: verdict.reason
        )
        let admitted = (try? await self.dispatcher(turn)) ?? false
        if admitted {
            self.dispatchedKeys.insert(key)
            if let messageID = mail.messageID {
                _ = await self.store.rememberMessageID(messageID, accountID: self.accountID)
            }
            await self.emit("imap.dispatched", ["account": self.accountID, "uid": String(message.uid), "gate": verdict.reason])
            return true
        }
        let count = (self.attempts[key] ?? 0) + 1
        self.attempts[key] = count
        if count < Self.maxAttempts {
            await self.emit("imap.dispatch_retry", ["account": self.accountID, "uid": String(message.uid)])
            return false
        }
        await self.skip(message.uid, sender: sender, reason: "dispatch-rejected")
        return true
    }

    private func skip(_ uid: UInt32, sender: String?, reason: String) async {
        let domain = sender.flatMap { $0.split(separator: "@").last.map(String.init) } ?? "unknown"
        await self.emit("imap.skipped", ["account": self.accountID, "uid": String(uid), "domain": domain, "reason": reason])
    }

    private func emit(_ name: String, _ metadata: [String: String]) async {
        guard let diagnosticsSink else { return }
        await diagnosticsSink(RuntimeDiagnosticEvent(subsystem: "imap", name: name, metadata: metadata))
    }

    private static func defaultTransport(for account: IMAPAccountConfig) throws -> any IMAPTransport {
        #if canImport(Network)
        guard account.secure else {
            throw OpenClawCoreError.unavailable("IMAP without implicit TLS (STARTTLS) is not supported natively; use port 993 with secure: true")
        }
        return NetworkIMAPTransport(host: account.host, port: account.port)
        #else
        throw OpenClawCoreError.unavailable("IMAP needs Network.framework; supply an IMAPTransport on this platform")
        #endif
    }
}

public extension IMAPMailboxWatcher {
    /// Dispatcher that runs each hook turn on an embedded runtime in its own session
    /// (`hook:imap:<account>:<uidvalidity>:<uid>`) with the hidden untrusted-email prompt.
    /// - Parameters:
    ///   - runtime: Embedded agent runtime.
    ///   - defaultTimeoutSeconds: Timeout when the account sets none.
    /// - Returns: Dispatcher (admitted when the run completes).
    static func runtimeDispatcher(_ runtime: EmbeddedAgentRuntime, defaultTimeoutSeconds: Int = 300) -> Dispatcher {
        { turn in
            let request = AgentRunRequest(
                runID: turn.sessionKey,
                sessionKey: turn.sessionKey,
                prompt: turn.message,
                modelID: turn.model,
                thinkingLevel: turn.thinking.flatMap(ThinkLevel.init(rawValue:)),
                agentID: turn.agentID
            )
            _ = try await runtime.run(request, timeoutMs: (turn.timeoutSeconds ?? defaultTimeoutSeconds) * 1_000)
            return true
        }
    }
}
