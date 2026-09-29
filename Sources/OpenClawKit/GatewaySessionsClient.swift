import Foundation
import OpenClawAgents
import OpenClawProtocol

/// Result of a `sessions.patch` permission-mode change.
public struct GatewaySessionPermissionModeOutcome: Sendable {
    /// Session key the gateway patched (`key`), when reported.
    public let key: String?
    /// Permission mode the gateway reports after the patch (`entry.permissionMode` or
    /// `permissionMode`), when reported.
    public let permissionMode: SessionPermissionMode?
    /// Raw response payload.
    public let raw: AnyCodable

    /// Parses a `sessions.patch` response.
    /// - Parameter raw: Response payload.
    public init(raw: AnyCodable) {
        let object = raw.dictionaryValue ?? [:]
        let entry = object["entry"]?.dictionaryValue ?? [:]
        self.raw = raw
        self.key = object["key"]?.stringValue ?? entry["key"]?.stringValue
        self.permissionMode = (entry["permissionMode"]?.stringValue ?? object["permissionMode"]?.stringValue)
            .flatMap(SessionPermissionMode.init(rawValue:))
    }
}

/// Typed helpers for operator session RPCs.
///
/// Session permissions use the 2026.8 `permissionMode` vocabulary (`read-only`, `guarded`,
/// `workspace`, `full`). The retired `execSecurity`/`execAsk` fields are never sent: current gateways
/// reject them with `INVALID_REQUEST`.
public struct GatewaySessionsClient: Sendable {
    /// Underlying request sender (for example a connected `GatewayChannelActor`).
    public let sender: any GatewayRequestSending
    /// Timeout applied to every request, in milliseconds (`nil` uses the channel default).
    public var timeoutMs: Double?

    /// Creates a client over a request sender.
    /// - Parameters:
    ///   - sender: Request sender.
    ///   - timeoutMs: Request timeout.
    public init(sender: any GatewayRequestSending, timeoutMs: Double? = nil) {
        self.sender = sender
        self.timeoutMs = timeoutMs
    }

    /// Changes a session's permission mode through `sessions.patch` (`operator.write`; `full` also
    /// needs `operator.admin`).
    ///
    /// Changing the mode cancels the session's pending approvals on the gateway.
    /// - Parameters:
    ///   - sessionKey: Session key.
    ///   - mode: New mode, or `nil` to clear the override (sent as JSON `null`).
    ///   - expectedMode: When set, the gateway applies the change only if the current mode still
    ///     matches (`expectedPermissionMode`; pass `.some(nil)` to require "no override").
    /// - Returns: The patch outcome.
    public func setPermissionMode(
        sessionKey: String,
        mode: SessionPermissionMode?,
        expectedMode: SessionPermissionMode?? = nil) async throws -> GatewaySessionPermissionModeOutcome
    {
        let data = try await self.sender.request(
            method: "sessions.patch",
            params: Self.permissionModePatch(sessionKey: sessionKey, mode: mode, expectedMode: expectedMode),
            timeoutMs: self.timeoutMs)
        let raw = try GatewayRPCCoding.decode(AnyCodable.self, from: data, method: "sessions.patch")
        return GatewaySessionPermissionModeOutcome(raw: raw)
    }

    /// `sessions.patch` params for a permission-mode change (never `execSecurity`/`execAsk`).
    static func permissionModePatch(
        sessionKey: String,
        mode: SessionPermissionMode?,
        expectedMode: SessionPermissionMode??) -> [String: AnyCodable]
    {
        var params: [String: AnyCodable] = [
            "key": AnyCodable(sessionKey),
            "permissionMode": mode.map { AnyCodable($0.rawValue) } ?? AnyCodable.nullValue,
        ]
        if let expectedMode {
            params["expectedPermissionMode"] = expectedMode.map { AnyCodable($0.rawValue) } ?? AnyCodable.nullValue
        }
        return params
    }
}

/// Operator approval backfill that reconciles `exec.approval.list` / `plugin.approval.list` with live
/// `*.approval.requested` / `*.approval.resolved` events (upstream approval backfill).
///
/// Start forwarding gateway events to ``ingest(_:)`` right after hello-ok, then call
/// ``backfill(using:timeoutMs:)``. Requests that race the list are not lost, and approvals resolved
/// while the list was in flight are not resurrected (``ApprovalBackfillReconciler``).
public actor GatewayApprovalBackfill {
    /// Approval family.
    public enum Kind: String, Sendable, CaseIterable {
        /// Exec approvals (`exec.approval.*`).
        case exec
        /// Plugin approvals (`plugin.approval.*`).
        case plugin

        /// Backfill method.
        public var listMethod: String {
            "\(self.rawValue).approval.list"
        }

        /// Live request event.
        public var requestedEvent: String {
            "\(self.rawValue).approval.requested"
        }

        /// Live resolution event.
        public var resolvedEvent: String {
            "\(self.rawValue).approval.resolved"
        }
    }

    /// Approval family this backfill tracks.
    public let kind: Kind
    private var reconciler = ApprovalBackfillReconciler()

    /// Creates a backfill for one approval family.
    /// - Parameter kind: Approval family.
    public init(kind: Kind) {
        self.kind = kind
    }

    /// Applies a gateway event; other events are ignored.
    /// - Parameter event: Gateway event frame.
    /// - Returns: `true` when the event changed the tracked approvals.
    @discardableResult
    public func ingest(_ event: EventFrame) -> Bool {
        guard event.event == self.kind.requestedEvent || event.event == self.kind.resolvedEvent,
              let payload = event.payload?.dictionaryValue,
              let id = payload["id"]?.stringValue, !id.isEmpty
        else { return false }
        if event.event == self.kind.requestedEvent {
            self.reconciler.applyRequested(id: id, payload: payload)
        } else {
            self.reconciler.applyResolved(id: id)
        }
        return true
    }

    /// Lists pending approvals and merges them with the events seen so far.
    /// - Parameters:
    ///   - sender: Request sender (the connected operator channel, `operator.approvals`).
    ///   - timeoutMs: Request timeout.
    public func backfill(using sender: any GatewayRequestSending, timeoutMs: Double? = nil) async throws {
        let data = try await sender.request(method: self.kind.listMethod, params: [:], timeoutMs: timeoutMs)
        let raw = try GatewayRPCCoding.decode(AnyCodable.self, from: data, method: self.kind.listMethod)
        self.reconciler.applyList(Self.rows(raw))
    }

    /// Pending approvals (raw wire rows keyed by id), sorted by id.
    public var pendingApprovals: [[String: AnyCodable]] {
        self.reconciler.pendingIDs.compactMap { self.reconciler.pending[$0] }
    }

    /// Pending approval ids, sorted.
    public var pendingIDs: [String] {
        self.reconciler.pendingIDs
    }

    /// Pending exec approvals decoded as ``GatewayPendingExecApproval`` (rows that do not decode are skipped).
    public var pendingExecApprovals: [GatewayPendingExecApproval] {
        self.pendingApprovals.compactMap { row in
            guard let data = try? JSONEncoder().encode(AnyCodable(row)) else { return nil }
            return try? JSONDecoder().decode(GatewayPendingExecApproval.self, from: data)
        }
    }

    /// Accepts a bare array or an `{approvals|items: [...]}` envelope.
    private static func rows(_ raw: AnyCodable) -> [[String: AnyCodable]] {
        let list = raw.arrayValue
            ?? raw.dictionaryValue?["approvals"]?.arrayValue
            ?? raw.dictionaryValue?["items"]?.arrayValue
            ?? []
        return list.compactMap(\.dictionaryValue)
    }
}
