import Foundation
import OpenClawCore
import OpenClawProtocol

/// Selects which events a ``GatewayServer/events(filter:bufferingNewest:)`` subscriber receives.
///
/// - ``eventNames``: `nil` delivers every event name; otherwise only the listed names.
/// - ``connectionID``: binds the subscription to a client connection registered with
///   ``GatewayServer/connectionOpened(_:)``. Events then follow that connection's role and scopes
///   (``hasEventScope(_:event:)``, upstream `EVENT_SCOPE_GUARDS`); an unregistered connection
///   receives nothing. `sessions.changed` reaches it only after `sessions.subscribe`, and
///   session-scoped events (``sessionScopedEvents``: `session.message`, `session.tool`) only for
///   sessions it subscribed to with `sessions.messages.subscribe`. Unbound subscribers (trusted
///   in-process observers) receive every event.
public struct GatewayEventFilter: Sendable, Equatable {
    /// Events delivered only to connections subscribed to the event's `sessionKey`.
    public static let sessionScopedEvents: Set<String> = [
        GatewayEventName.sessionMessage.rawValue,
        GatewayEventName.sessionTool.rawValue,
    ]

    /// Event names to deliver (`nil` = all).
    public var eventNames: Set<String>?
    /// Connection the subscription belongs to (`nil` = in-process observer).
    public var connectionID: String?

    /// Creates a filter.
    /// - Parameters:
    ///   - eventNames: Event names to deliver (`nil` = all).
    ///   - connectionID: Connection the subscription belongs to.
    public init(eventNames: Set<String>? = nil, connectionID: String? = nil) {
        self.eventNames = eventNames
        self.connectionID = connectionID
    }

    /// Every event, unbound to a connection.
    public static let all = GatewayEventFilter()

    /// Only the given event names.
    /// - Parameter names: Event names.
    /// - Returns: The filter.
    public static func only(_ names: Set<String>) -> GatewayEventFilter {
        GatewayEventFilter(eventNames: names)
    }

    /// Only the given upstream events.
    /// - Parameter names: Upstream event names.
    /// - Returns: The filter.
    public static func only(_ names: GatewayEventName...) -> GatewayEventFilter {
        GatewayEventFilter(eventNames: Set(names.map(\.rawValue)))
    }

    /// Every event the connection may receive, bound to a client connection registered with
    /// ``GatewayServer/connectionOpened(_:)`` (role and scope guards apply; `sessions.changed` and
    /// session-scoped events follow its subscriptions).
    /// - Parameter connectionID: Connection identifier (``GatewayConnectionContext/connectionID``).
    /// - Returns: The filter.
    public static func connection(_ connectionID: String) -> GatewayEventFilter {
        GatewayEventFilter(connectionID: connectionID)
    }

    /// Whether the filter admits an event name (scopes and session subscriptions are checked separately).
    /// - Parameter event: Event name.
    public func admits(_ event: String) -> Bool {
        self.eventNames?.contains(event) ?? true
    }

    /// Operator scopes a connection needs to receive each event (upstream `EVENT_SCOPE_GUARDS`).
    ///
    /// Any listed scope suffices; an empty list admits every connection, node-role ones included.
    public static let scopeGuards: [String: [String]] = {
        let read = GatewayConnectionContext.operatorReadScope
        let admin = GatewayConnectionContext.operatorAdminScope
        let approvals = "operator.approvals"
        let questions = GatewayMethodScopePolicy.questionsScope
        let pairing = GatewayMethodScopePolicy.pairingScope
        let talk = "operator.talk"
        var guards: [String: [String]] = [
            "chat.metadata.changed": [read, GatewayMethodScopePolicy.sessionsReadScope],
            "exec.approval.requested": [approvals], "exec.approval.resolved": [approvals],
            "plugin.approval.requested": [approvals], "plugin.approval.resolved": [approvals],
            "openclaw.approval.requested": [approvals], "openclaw.approval.resolved": [approvals],
            "session.approval": [approvals],
            "question.requested": [questions], "question.resolved": [questions],
            "talk.mode": [talk], "talk.voice.change": [talk],
            "update.run.changed": [admin], "plugins.install.progress": [admin],
            "terminal.data": [admin], "terminal.exit": [admin],
            "device.pair.changed": [pairing], "device.pair.requested": [pairing], "device.pair.resolved": [pairing],
            "device.pair.setup.completed": [pairing], "device.pair.setup.deliveryUncertain": [pairing],
            "node.pair.requested": [pairing], "node.pair.resolved": [pairing],
        ]
        for event in ["health", "heartbeat", "shutdown", "gateway.suspension", "tick", "update.available"] {
            guards[event] = []
        }
        let readEvents = [
            "agent", "chat", "board.changed", "board.command", "progressCard.changed", "ui.command", "chat.send_timing",
            "chat.side_result", "cron", "presence", "talk.event", "task", "task.suggestion", "config.changed",
            "users.prefs.changed", "mentions.changed", "skills.changed", "plugins.changed", "voicewake.changed",
            "voicewake.routing.changed", "node.presence", "node.hostStats", "node.runnerInventory.changed",
            "sessions.catalog.host", "sessions.changed", "controlUi.sessionPullRequests.changed",
            "plugins.controlUi.changed", "session.message", "session.observer", "session.operation", "session.sharing",
            "session.sharing.evidence", "session.suggestion", "session.typing", "session.tool", "portal.changed",
        ]
        for event in readEvents {
            guards[event] = [read]
        }
        return guards
    }()

    /// Whether a client connection may receive an event (upstream `hasEventScope`).
    ///
    /// Guarded events need the operator role and one of their ``scopeGuards`` (an empty guard admits
    /// everyone); unguarded `plugin.*` events need `operator.write`; any other unguarded event (for
    /// example an SDK-defined one) needs `operator.admin`. An unknown connection (`nil`) receives nothing.
    /// - Parameters:
    ///   - connection: Connection context, or `nil` when the connection is not registered.
    ///   - event: Event name.
    /// - Returns: `true` when the event may be delivered.
    public static func hasEventScope(_ connection: GatewayConnectionContext?, event: String) -> Bool {
        guard let connection else { return false }
        let isOperator = connection.role.trimmingCharacters(in: .whitespacesAndNewlines) == "operator"
        if let required = Self.scopeGuards[event] {
            return required.isEmpty || (isOperator && required.contains { connection.allows(scope: $0) })
        }
        if event.hasPrefix("plugin.") {
            return isOperator && connection.allows(scope: GatewayConnectionContext.operatorWriteScope)
        }
        return isOperator && connection.allows(scope: GatewayConnectionContext.operatorAdminScope)
    }
}

extension GatewayServer {
    // MARK: - Subscribing

    /// Subscribes to server events.
    ///
    /// Each subscriber has its own buffer of `limit` undelivered frames; when a slow subscriber falls
    /// behind, the oldest frames are dropped, which shows as a gap in the server-global `seq`.
    /// - Parameters:
    ///   - filter: Which events to deliver.
    ///   - limit: Undelivered frames buffered for this subscriber.
    /// - Returns: Stream of event frames; cancel iteration to unsubscribe.
    public func events(filter: GatewayEventFilter = .all, bufferingNewest limit: Int = 1024) -> AsyncStream<EventFrame> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<EventFrame>.makeStream(bufferingPolicy: .bufferingNewest(max(1, limit)))
        self.eventSubscribers[id] = EventSubscriber(continuation: continuation, filter: filter)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeEventSubscriber(id) }
        }
        return stream
    }

    func removeEventSubscriber(_ id: UUID) {
        self.eventSubscribers.removeValue(forKey: id)
    }

    /// Number of active event subscribers (diagnostics).
    public func eventSubscriberCount() -> Int {
        self.eventSubscribers.count
    }

    // MARK: - Emitting

    /// Emits an event to every matching subscriber with the next sequence number.
    ///
    /// Connection-bound subscribers receive the event only when their connection's role and scopes
    /// allow it (``GatewayEventFilter/hasEventScope(_:event:)``); `sessions.changed` additionally
    /// needs `sessions.subscribe`, and `session.message`/`session.tool` a matching
    /// `sessions.messages.subscribe`.
    /// - Parameters:
    ///   - event: Event name (see ``GatewayEventName``).
    ///   - payload: Optional event payload.
    /// - Returns: The emitted frame.
    @discardableResult
    public func broadcast(event: String, payload: AnyCodable? = nil) -> EventFrame {
        self.eventSequence += 1
        let frame = EventFrame(type: "event", event: event, payload: payload, seq: self.eventSequence)
        let sessionScoped = GatewayEventFilter.sessionScopedEvents.contains(event)
        let sessionKey = sessionScoped ? payload?.dictionaryValue?["sessionKey"]?.stringValue.map(Self.subscriptionKey) : nil
        let sessionsChanged = event == GatewayEventName.sessionsChanged.rawValue
        for subscriber in self.eventSubscribers.values where subscriber.filter.admits(event) {
            if let connectionID = subscriber.filter.connectionID {
                guard GatewayEventFilter.hasEventScope(self.connections[connectionID]?.context, event: event) else {
                    continue
                }
                if sessionsChanged, !self.sessionEventConnections.contains(connectionID) {
                    continue
                }
                if sessionScoped {
                    guard let sessionKey, self.messageSubscriptions[connectionID]?.contains(sessionKey) == true else {
                        continue
                    }
                }
            }
            subscriber.continuation.yield(frame)
        }
        return frame
    }

    /// Emits an upstream event.
    /// - Parameters:
    ///   - event: Upstream event name.
    ///   - payload: Optional event payload.
    /// - Returns: The emitted frame.
    @discardableResult
    public func emit(_ event: GatewayEventName, payload: AnyCodable? = nil) -> EventFrame {
        self.broadcast(event: event.rawValue, payload: payload)
    }

    /// Emits an event with a typed payload (JSON-encoded into the frame).
    /// - Parameters:
    ///   - event: Event name.
    ///   - payload: Encodable payload.
    /// - Returns: The emitted frame.
    /// - Throws: Encoding errors for the payload.
    @discardableResult
    public func emit(event: String, encoding payload: some Encodable) throws -> EventFrame {
        self.broadcast(event: event, payload: try AnyCodable(encoding: payload))
    }

    /// Emits `sessions.changed` (`{sessionKey, sessionId?, agentId?, reason, session?, …extra}`).
    /// - Parameters:
    ///   - sessionKey: Changed session (`nil` for catalog-only changes such as `groups`).
    ///   - reason: Change reason (`patch`, `create`, `delete`, `reset`, `groups`, `rewind`, `fork`,
    ///     `branch-switch`, `run`, …).
    ///   - extra: Additional payload fields.
    /// - Returns: The emitted frame.
    @discardableResult
    public func emitSessionsChanged(sessionKey: String?, reason: String, extra: [String: AnyCodable] = [:]) async -> EventFrame {
        var record: SessionRecord?
        if let sessionKey {
            record = await self.sessionStore.recordForKey(sessionKey)
        }
        let payload = Self.sessionsChangedPayload(sessionKey: sessionKey, record: record, reason: reason, extra: extra)
        return self.broadcast(event: GatewayEventName.sessionsChanged.rawValue, payload: payload)
    }

    /// Builds a `sessions.changed` payload: `{sessionKey?, sessionId?, agentId?, reason, session?, …extra}`,
    /// where `session` is the row in both the legacy and the upstream `SessionRow` shape.
    /// - Parameters:
    ///   - sessionKey: Changed session.
    ///   - record: Current record (`nil` after a delete).
    ///   - reason: Change reason.
    ///   - extra: Additional fields (win over the derived ones).
    /// - Returns: The payload.
    public static func sessionsChangedPayload(
        sessionKey: String?,
        record: SessionRecord?,
        reason: String,
        extra: [String: AnyCodable] = [:]
    ) -> AnyCodable {
        var payload: [String: AnyCodable] = ["reason": AnyCodable(reason)]
        if let sessionKey {
            payload["sessionKey"] = AnyCodable(sessionKey)
        }
        if let record {
            payload["agentId"] = AnyCodable(record.agentID)
            if let sessionID = record.sessionID {
                payload["sessionId"] = AnyCodable(sessionID)
            }
            if let row = try? GatewayPayloadCodec.encode(Self.sessionInfo(from: record)) {
                payload["session"] = row
            }
        }
        payload.merge(extra) { _, new in new }
        return AnyCodable(payload)
    }

    // MARK: - Session subscriptions

    /// Whether any connection subscribed to a session's messages, or an in-process observer asked
    /// for `session.message` explicitly (bridges use this to skip transcript reads nobody receives).
    /// - Parameter sessionKey: Session key.
    public func wantsSessionEvents(sessionKey: String) -> Bool {
        let key = Self.subscriptionKey(sessionKey)
        if self.messageSubscriptions.values.contains(where: { $0.contains(key) }) {
            return true
        }
        return self.eventSubscribers.values.contains { subscriber in
            subscriber.filter.connectionID == nil
                && subscriber.filter.eventNames?.contains(GatewayEventName.sessionMessage.rawValue) == true
        }
    }

    /// Subscribes a connection to one session's `session.message` / `session.tool` events.
    /// - Parameters:
    ///   - sessionKey: Session key.
    ///   - connectionID: Connection identifier.
    public func subscribeSessionMessages(sessionKey: String, connectionID: String) {
        self.messageSubscriptions[connectionID, default: []].insert(Self.subscriptionKey(sessionKey))
    }

    /// Removes a connection's subscription to one session's messages.
    /// - Parameters:
    ///   - sessionKey: Session key.
    ///   - connectionID: Connection identifier.
    public func unsubscribeSessionMessages(sessionKey: String, connectionID: String) {
        self.messageSubscriptions[connectionID]?.remove(Self.subscriptionKey(sessionKey))
        if self.messageSubscriptions[connectionID]?.isEmpty == true {
            self.messageSubscriptions[connectionID] = nil
        }
    }

    /// Session keys a connection subscribed to.
    /// - Parameter connectionID: Connection identifier.
    public func sessionMessageSubscriptions(connectionID: String) -> Set<String> {
        self.messageSubscriptions[connectionID] ?? []
    }

    /// Whether a connection called `sessions.subscribe`.
    /// - Parameter connectionID: Connection identifier.
    public func isSubscribedToSessionEvents(connectionID: String) -> Bool {
        self.sessionEventConnections.contains(connectionID)
    }

    static func subscriptionKey(_ sessionKey: String) -> String {
        sessionKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func handleSessionsSubscribe(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        let connectionID = request.connection.connectionID
        self.sessionEventConnections.insert(connectionID)
        guard !request.params.isEmpty else {
            return AnyCodable(["subscribed": AnyCodable(true)])
        }
        var payload = try await self.handleSessionsList(request)?.dictionaryValue ?? [:]
        payload["subscribed"] = AnyCodable(true)
        return AnyCodable(payload)
    }

    func handleMessagesSubscribe(_ request: GatewayMethodRequest, subscribe: Bool) throws -> AnyCodable? {
        guard let key = request.stringParam("key", "sessionKey") else {
            throw GatewayMethodError.invalidRequest("\(request.method) requires key")
        }
        if subscribe {
            self.subscribeSessionMessages(sessionKey: key, connectionID: request.connection.connectionID)
        } else {
            self.unsubscribeSessionMessages(sessionKey: key, connectionID: request.connection.connectionID)
        }
        return AnyCodable(["subscribed": AnyCodable(subscribe), "key": AnyCodable(key)])
    }
}
