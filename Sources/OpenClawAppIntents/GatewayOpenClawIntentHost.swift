import Foundation
import OpenClawKit

/// ``OpenClawIntentHost`` backed by an OpenClaw gateway connection.
///
/// Uses `sessions.list`, `agents.list`, `chat.send` and `chat.abort`. Run progress comes from the
/// same `chat`/`agent` push events the chat UI consumes, so forward the channel's pushes with
/// ``ingest(_:)-(GatewayPush)`` (for example from `GatewayChannelActor`'s `pushHandler`) or hand an
/// event stream to ``consume(_:)``. Events are matched to an intent's run by run id (the `chat.send`
/// idempotency key, which upstream uses as the run id, or the id the ack names), never by a shared
/// session-key suffix, so another agent's run cannot complete or stream into the intent.
///
/// `chat.abort` runs inside a cancellation shield so an intent's cancel handler still reaches the
/// gateway after the calling task was cancelled.
public actor GatewayOpenClawIntentHost: OpenClawIntentHost {
    /// Host configuration.
    public struct Configuration: Sendable, Equatable {
        /// Session used when an intent does not name one.
        public var defaultSessionKey: String
        /// Maximum run duration before the stream fails with ``OpenClawIntentError/timedOut``.
        public var runTimeout: TimeInterval
        /// Per-request RPC timeout in milliseconds.
        public var requestTimeoutMs: Double
        /// Rows fetched when resolving sessions by key.
        public var sessionLookupLimit: Int
        /// Optional `thinking` level sent with `chat.send`.
        public var thinking: String?

        /// Creates a configuration.
        /// - Parameters:
        ///   - defaultSessionKey: Default session key.
        ///   - runTimeout: Maximum run duration in seconds.
        ///   - requestTimeoutMs: RPC timeout in milliseconds.
        ///   - sessionLookupLimit: Rows fetched for key resolution.
        ///   - thinking: Optional thinking level.
        public init(
            defaultSessionKey: String = "main",
            runTimeout: TimeInterval = 300,
            requestTimeoutMs: Double = 15000,
            sessionLookupLimit: Int = 200,
            thinking: String? = nil)
        {
            self.defaultSessionKey = defaultSessionKey
            self.runTimeout = max(0.01, runTimeout)
            self.requestTimeoutMs = max(1, requestTimeoutMs)
            self.sessionLookupLimit = max(1, sessionLookupLimit)
            self.thinking = thinking
        }
    }

    /// One intent's run. Upstream uses the `chat.send` idempotency key as the run id, so events are
    /// matched by run id from the first byte; session keys never decide which run an event belongs to.
    private struct RunWatcher {
        let sessionKey: String
        let agentId: String?
        /// Run id events must carry: the idempotency key until the `chat.send` ack names the run.
        var runId: String
        /// Whether ``runId`` is confirmed (acked, adopted, or seen on an event) and may be reported.
        var runIdConfirmed = false
        /// Whether the `chat.send` ack arrived.
        var acknowledged = false
        /// Set when the ack carried no run id (a gateway that ignores the idempotency key): the first
        /// post-ack event from exactly this session names the run.
        var adoptsRunFromEvents = false
        /// Chat events from a matching session that arrived before the ack with another run id; only
        /// those whose run id equals the acked run id are replayed.
        var pendingEvents: [[String: AnyCodable]] = []
        var text: String
        let progress: OpenClawRunProgress
        let continuation: AsyncThrowingStream<OpenClawIntentRunEvent, any Error>.Continuation
    }

    /// Bound on buffered pre-ack events per run.
    private static let maxPendingEvents = 256

    private let requester: any OpenClawIntentGatewayRequesting
    /// Active configuration.
    public let configuration: Configuration
    private let talkHandler: (@Sendable (String?) async throws -> Void)?
    private var watchers: [UUID: RunWatcher] = [:]
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var activeRunBySession: [String: String] = [:]
    private var summaryCache: [String: OpenClawIntentSessionSummary] = [:]

    /// Creates a gateway intent host.
    /// - Parameters:
    ///   - requester: Gateway RPC transport (for example a `GatewayChannelActor`).
    ///   - configuration: Host configuration.
    ///   - startTalk: Optional handler that starts talk mode in the app.
    public init(
        requester: any OpenClawIntentGatewayRequesting,
        configuration: Configuration = Configuration(),
        startTalk: (@Sendable (String?) async throws -> Void)? = nil)
    {
        self.requester = requester
        self.configuration = configuration
        self.talkHandler = startTalk
    }

    // MARK: - Push events

    /// Feeds one gateway push into active runs.
    /// - Parameter push: Gateway push.
    public func ingest(_ push: GatewayPush) {
        if case let .event(frame) = push {
            self.ingest(frame)
        }
    }

    /// Feeds one gateway event frame into active runs (`chat` and `agent` events).
    /// - Parameter event: Event frame.
    public func ingest(_ event: EventFrame) {
        guard !self.watchers.isEmpty, let payload = event.payload?.dictionaryValue else { return }
        switch event.event {
        case "chat":
            self.handleChatEvent(payload)
        case "agent":
            self.handleAgentEvent(payload)
        default:
            break
        }
    }

    /// Consumes an event stream (for example `GatewayNodeSession.subscribeServerEvents()`).
    /// - Parameter events: Event frames.
    /// - Returns: The consuming task; cancel it to stop.
    @discardableResult
    nonisolated public func consume(_ events: AsyncStream<EventFrame>) -> Task<Void, Never> {
        Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.ingest(event)
            }
        }
    }

    // MARK: - OpenClawIntentHost

    /// Lists sessions through `sessions.list` (server-side `search`).
    public func sessions(matching query: String?, limit: Int) async throws -> [OpenClawIntentSessionSummary] {
        let search = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await self.listSessions(limit: max(1, limit), search: search?.isEmpty == false ? search : nil)
    }

    /// Resolves sessions by key; keys the gateway does not list resolve from the cache or as bare keys.
    public func sessions(forKeys keys: [String]) async throws -> [OpenClawIntentSessionSummary] {
        guard !keys.isEmpty else { return [] }
        let listed = try await self.listSessions(limit: self.configuration.sessionLookupLimit, search: nil)
        let byKey = Dictionary(listed.map { ($0.sessionKey, $0) }, uniquingKeysWith: { first, _ in first })
        return keys.map { key in
            byKey[key] ?? self.summaryCache[key] ?? OpenClawIntentSessionSummary(sessionKey: key, title: key)
        }
    }

    /// Returns a cached summary (for display representations without a round trip).
    /// - Parameter sessionKey: Session key.
    /// - Returns: Cached summary, if any.
    public func cachedSummary(for sessionKey: String) -> OpenClawIntentSessionSummary? {
        self.summaryCache[sessionKey]
    }

    /// Lists selectable agents through `agents.list` (system agents are hidden).
    public func agents() async throws -> [OpenClawIntentAgentSummary] {
        let data = try await self.requester.request(
            method: "agents.list",
            params: [:],
            timeoutMs: self.configuration.requestTimeoutMs)
        return Self.parseAgents(data)
    }

    /// Sends `chat.send` and streams run progress from push events.
    public func send(prompt: String, sessionKey: String?, agentId: String?) async throws
        -> AsyncThrowingStream<OpenClawIntentRunEvent, any Error>
    {
        try await self.send(prompt: prompt, sessionKey: sessionKey, agentId: agentId, attachments: [])
    }

    /// Sends `chat.send` with base64 attachments and streams run progress from push events.
    public func send(
        prompt: String,
        sessionKey: String?,
        agentId: String?,
        attachments: [OpenClawIntentAttachment]) async throws -> AsyncThrowingStream<OpenClawIntentRunEvent, any Error>
    {
        let message = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { throw OpenClawIntentError.emptyPrompt }
        let key = Self.normalized(sessionKey) ?? self.configuration.defaultSessionKey

        let (stream, continuation) = AsyncThrowingStream<OpenClawIntentRunEvent, any Error>.makeStream()
        let watcherID = UUID()
        let progress = OpenClawRunProgress()
        let idempotencyKey = UUID().uuidString
        let requestedAgentId = Self.normalized(agentId)
        self.watchers[watcherID] = RunWatcher(
            sessionKey: key,
            agentId: requestedAgentId,
            runId: idempotencyKey,
            text: "",
            progress: progress,
            continuation: continuation)
        // Upstream registers the run under the idempotency key, so an abort before the ack targets it.
        self.activeRunBySession[key] = idempotencyKey
        continuation.onTermination = { [weak self] _ in
            Task { await self?.dropWatcher(watcherID) }
        }
        self.emit(watcherID, phase: .queued)

        var params: [String: AnyCodable] = [
            "sessionKey": AnyCodable(key),
            "message": AnyCodable(message),
            "idempotencyKey": AnyCodable(idempotencyKey),
        ]
        if let requestedAgentId {
            params["agentId"] = AnyCodable(requestedAgentId)
        }
        if let thinking = Self.normalized(self.configuration.thinking) {
            params["thinking"] = AnyCodable(thinking)
        }
        // Clamp before converting: `Int` is 32-bit on watchOS (arm64_32) and a huge or non-finite
        // timeout must not trap.
        let timeoutMs = self.configuration.runTimeout * 1000
        params["timeoutMs"] = AnyCodable(timeoutMs.isFinite ? Int(min(max(0, timeoutMs), Double(Int32.max))) : 0)
        if !attachments.isEmpty {
            params["attachments"] = AnyCodable(attachments.map { AnyCodable($0.chatSendPayload) })
        }

        do {
            let data = try await self.requester.request(
                method: "chat.send",
                params: params,
                timeoutMs: self.configuration.requestTimeoutMs)
            self.acknowledge(watcherID, runId: Self.normalized(Self.decodeObject(data)?["runId"]?.stringValue))
        } catch {
            self.finish(watcherID, throwing: error, runEnded: true)
            throw error
        }
        self.scheduleTimeout(for: watcherID)
        return stream
    }

    /// Sends `chat.abort` for the session's active run (cancellation-shielded, best effort).
    public func abort(sessionKey: String) async {
        var params: [String: AnyCodable] = ["sessionKey": AnyCodable(sessionKey)]
        if let runId = self.activeRunBySession[sessionKey] {
            params["runId"] = AnyCodable(runId)
        }
        let requester = self.requester
        let timeout = self.configuration.requestTimeoutMs
        let sendable = params
        _ = try? await IntentCancellationShield.run {
            try await requester.request(method: "chat.abort", params: sendable, timeoutMs: timeout)
        }
    }

    /// Starts talk mode through the configured handler.
    public func startTalk(sessionKey: String?) async throws {
        guard let talkHandler else {
            throw OpenClawIntentError.unsupported("Live voice is not available in this app.")
        }
        try await talkHandler(sessionKey)
    }

    // MARK: - Event handling

    /// Applies the `chat.send` ack: the ack's run id (upstream: the idempotency key) becomes
    /// authoritative, and buffered pre-ack events of exactly that run are replayed.
    private func acknowledge(_ id: UUID, runId: String?) {
        guard var watcher = self.watchers[id] else { return }
        watcher.acknowledged = true
        if let runId {
            if self.activeRunBySession[watcher.sessionKey] == watcher.runId {
                self.activeRunBySession[watcher.sessionKey] = runId
            }
            watcher.runId = runId
            watcher.runIdConfirmed = true
        } else if !watcher.runIdConfirmed {
            // The gateway named no run and none of its events carried our idempotency key.
            watcher.adoptsRunFromEvents = true
            if self.activeRunBySession[watcher.sessionKey] == watcher.runId {
                self.activeRunBySession[watcher.sessionKey] = nil
            }
        }
        let pending = watcher.pendingEvents
        watcher.pendingEvents = []
        self.watchers[id] = watcher
        if !watcher.progress.isFinished {
            watcher.progress.advance(to: .running)
            self.emit(id, phase: .running)
        }
        for payload in pending where payload["runId"]?.stringValue == watcher.runId {
            guard self.watchers[id] != nil else { break }
            self.applyChatEvent(payload, to: id)
        }
    }

    private func handleChatEvent(_ payload: [String: AnyCodable]) {
        guard let sessionKey = payload["sessionKey"]?.stringValue else { return }
        let runId = payload["runId"]?.stringValue
        for id in Array(self.watchers.keys) {
            guard var watcher = self.watchers[id] else { continue }
            if let runId, runId == watcher.runId {
                self.applyChatEvent(payload, to: id)
                continue
            }
            guard Self.sessionKeysMatch(watcher.sessionKey, sessionKey, agentId: watcher.agentId) else { continue }
            if !watcher.acknowledged {
                // Never adopt a run id before the ack: another agent's run may share the key.
                if watcher.pendingEvents.count < Self.maxPendingEvents {
                    watcher.pendingEvents.append(payload)
                    self.watchers[id] = watcher
                }
            } else if watcher.adoptsRunFromEvents, let runId {
                watcher.runId = runId
                watcher.runIdConfirmed = true
                watcher.adoptsRunFromEvents = false
                self.watchers[id] = watcher
                self.activeRunBySession[watcher.sessionKey] = runId
                self.applyChatEvent(payload, to: id)
            }
        }
    }

    private func applyChatEvent(_ payload: [String: AnyCodable], to id: UUID) {
        guard var watcher = self.watchers[id] else { return }
        if !watcher.runIdConfirmed {
            // An event carrying our run id confirms it; nothing else may be adopted afterwards.
            watcher.runIdConfirmed = true
            watcher.adoptsRunFromEvents = false
            self.activeRunBySession[watcher.sessionKey] = watcher.runId
        }
        let state = payload["state"]?.stringValue ?? ""
        switch state {
        case "status":
            self.watchers[id] = watcher
            watcher.progress.advance(to: .running)
            self.emit(id, phase: .running)
        case "delta":
            let delta = payload["deltaText"]?.stringValue ?? ""
            if payload["replace"]?.boolValue == true {
                watcher.text = delta
            } else if !delta.isEmpty {
                watcher.text += delta
            } else if let text = OpenClawIntentMessageText.extract(from: payload["message"]) {
                watcher.text = text
            }
            self.watchers[id] = watcher
            watcher.progress.advance(to: .streaming)
            self.emit(id, phase: .streaming)
        case "final":
            if let text = OpenClawIntentMessageText.extract(from: payload["message"]), !text.isEmpty {
                watcher.text = text
            }
            self.watchers[id] = watcher
            watcher.progress.advance(to: .completed)
            self.emit(id, phase: .completed)
            self.finish(id, throwing: nil, runEnded: true)
        case "aborted":
            self.watchers[id] = watcher
            watcher.progress.advance(to: .aborted)
            self.emit(id, phase: .aborted)
            self.finish(id, throwing: nil, runEnded: true)
        case "error":
            self.watchers[id] = watcher
            watcher.progress.advance(to: .failed)
            self.emit(id, phase: .failed)
            let message = payload["errorMessage"]?.stringValue ?? "The OpenClaw run failed."
            self.finish(id, throwing: OpenClawIntentError.runFailed(message), runEnded: true)
        default:
            self.watchers[id] = watcher
        }
    }

    private func handleAgentEvent(_ payload: [String: AnyCodable]) {
        guard let runId = payload["runId"]?.stringValue else { return }
        let stream = payload["stream"]?.stringValue ?? ""
        let data = payload["data"]?.dictionaryValue ?? [:]
        for (id, watcher) in self.watchers where watcher.runId == runId {
            switch stream {
            case "tool":
                watcher.progress.advance(to: .toolRunning)
                self.emit(id, phase: .toolRunning)
            case "assistant":
                guard let text = data["text"]?.stringValue, !text.isEmpty else { continue }
                var updated = watcher
                updated.text = text
                self.watchers[id] = updated
                watcher.progress.advance(to: .streaming)
                self.emit(id, phase: .streaming)
            default:
                continue
            }
        }
    }

    /// Whether an event's session key is exactly our session: the same key, or its canonical
    /// `agent:<agentId>:<key>` form for the requested agent (upstream default agent `main`). Another
    /// agent's session that merely shares the suffix (for example `agent:ops:main`) never matches.
    static func sessionKeysMatch(_ watcherKey: String, _ eventKey: String, agentId: String?) -> Bool {
        let left = watcherKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let right = eventKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right { return true }
        let agent = agentId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let prefix = "agent:\(agent.isEmpty ? "main" : agent):"
        return right == prefix + left || left == prefix + right
    }

    private func emit(_ id: UUID, phase: OpenClawRunPhase) {
        guard let watcher = self.watchers[id] else { return }
        watcher.continuation.yield(OpenClawIntentRunEvent(
            phase: phase,
            fractionCompleted: watcher.progress.fractionCompleted,
            text: watcher.text.isEmpty ? nil : watcher.text,
            runId: watcher.runIdConfirmed ? watcher.runId : nil,
            sessionKey: watcher.sessionKey))
    }

    /// Ends a watcher. The session's active run id is only forgotten on terminal gateway events:
    /// a consumer that stops listening (for example a cancelled intent) must still be able to
    /// `chat.abort` the run that keeps going on the gateway.
    private func finish(_ id: UUID, throwing error: (any Error)?, runEnded: Bool = false) {
        guard let watcher = self.watchers.removeValue(forKey: id) else { return }
        self.timeoutTasks.removeValue(forKey: id)?.cancel()
        if runEnded, self.activeRunBySession[watcher.sessionKey] == watcher.runId {
            self.activeRunBySession[watcher.sessionKey] = nil
        }
        if let error {
            watcher.continuation.finish(throwing: error)
        } else {
            watcher.continuation.finish()
        }
    }

    private func dropWatcher(_ id: UUID) {
        self.finish(id, throwing: nil)
    }

    private func scheduleTimeout(for id: UUID) {
        guard self.watchers[id] != nil else { return }
        // Saturate: a huge or infinite run timeout must not trap converting to UInt64.
        let requested = self.configuration.runTimeout * 1_000_000_000
        let nanoseconds = requested >= Double(UInt64.max) ? UInt64.max : UInt64(max(0, requested))
        self.timeoutTasks[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await self?.timeOut(id)
        }
    }

    private func timeOut(_ id: UUID) {
        self.finish(id, throwing: OpenClawIntentError.timedOut)
    }

    // MARK: - Parsing

    private func listSessions(limit: Int, search: String?) async throws -> [OpenClawIntentSessionSummary] {
        var params: [String: AnyCodable] = [
            "limit": AnyCodable(limit),
            "includeDerivedTitles": AnyCodable(true),
        ]
        if let search {
            params["search"] = AnyCodable(search)
        }
        let data = try await self.requester.request(
            method: "sessions.list",
            params: params,
            timeoutMs: self.configuration.requestTimeoutMs)
        let summaries = Self.parseSessions(data)
        for summary in summaries {
            self.summaryCache[summary.sessionKey] = summary
        }
        return Array(summaries.prefix(limit))
    }

    static func decodeObject(_ data: Data) -> [String: AnyCodable]? {
        guard !data.isEmpty else { return nil }
        return (try? JSONDecoder().decode(AnyCodable.self, from: data))?.dictionaryValue
    }

    static func parseSessions(_ data: Data) -> [OpenClawIntentSessionSummary] {
        guard let rows = Self.decodeObject(data)?["sessions"]?.arrayValue else { return [] }
        return rows.compactMap { row in
            guard let object = row.dictionaryValue,
                  let key = Self.normalized(object["key"]?.stringValue)
            else {
                return nil
            }
            let title = ["label", "displayName", "derivedTitle", "autoLabel"]
                .lazy
                .compactMap { Self.normalized(object[$0]?.stringValue) }
                .first ?? key
            let updatedAt = object["updatedAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0 / 1000) }
            let kind = object["kind"]?.stringValue
            let chatType = object["chatType"]?.stringValue
            return OpenClawIntentSessionSummary(
                sessionKey: key,
                title: title,
                agentId: Self.normalized(object["agentId"]?.stringValue),
                updatedAt: updatedAt,
                isGroup: kind == "group" || chatType == "group" || chatType == "channel")
        }
    }

    static func parseAgents(_ data: Data) -> [OpenClawIntentAgentSummary] {
        guard let rows = Self.decodeObject(data)?["agents"]?.arrayValue else { return [] }
        return rows.compactMap { row in
            guard let object = row.dictionaryValue,
                  let id = Self.normalized(object["id"]?.stringValue),
                  object["kind"]?.stringValue != AgentKind.system.rawValue
            else {
                return nil
            }
            let identity = object["identity"]?.dictionaryValue
            let name = Self.normalized(object["name"]?.stringValue)
                ?? Self.normalized(identity?["name"]?.stringValue)
                ?? id
            return OpenClawIntentAgentSummary(
                agentId: id,
                displayName: name,
                emoji: Self.normalized(identity?["emoji"]?.stringValue))
        }
    }

    static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

/// Extracts plain assistant text from a gateway chat message payload.
public enum OpenClawIntentMessageText {
    /// Returns the text of a message: a string, `{ content: String | [parts] }`, `{ text }`, or an
    /// array of `{ type: "text", text }` parts (non-text parts are skipped).
    /// - Parameter message: Message payload.
    /// - Returns: Joined text, or `nil` when the message has none.
    public static func extract(from message: AnyCodable?) -> String? {
        guard let message else { return nil }
        if let text = message.stringValue {
            return text
        }
        if let parts = message.arrayValue {
            return Self.join(parts)
        }
        guard let object = message.dictionaryValue else { return nil }
        if let content = object["content"] {
            if let text = content.stringValue {
                return text
            }
            if let parts = content.arrayValue {
                return Self.join(parts)
            }
        }
        return object["text"]?.stringValue
    }

    private static func join(_ parts: [AnyCodable]) -> String? {
        let texts = parts.compactMap { part -> String? in
            if let text = part.stringValue {
                return text
            }
            guard let object = part.dictionaryValue else { return nil }
            let type = object["type"]?.stringValue ?? "text"
            guard type == "text" || type == "output_text" else { return nil }
            return object["text"]?.stringValue
        }
        return texts.isEmpty ? nil : texts.joined()
    }
}
