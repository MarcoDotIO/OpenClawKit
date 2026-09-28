import Foundation

/// Why an iPhone host cannot relay `watch.status`/`watch.notify` work to its Apple Watch.
///
/// Every reason maps to a node error with code `UNAVAILABLE` and a message prefixed with
/// ``messagePrefix``, matching the upstream iPhone node, so agents get a deterministic tool error.
public enum OpenClawWatchUnavailableReason: Sendable, Equatable {
    /// WatchConnectivity is not supported on this device (for example iPad).
    case unsupported
    /// No Apple Watch is paired.
    case notPaired
    /// The companion Watch app is not installed.
    case watchAppNotInstalled
    /// The iPhone's Watch chat journal is not ready to admit messages.
    case admissionUnavailable
    /// `WCSession` activation failed with the given reason.
    case activationFailed(String)
    /// `WCSession` activation did not finish in time.
    case activationTimedOut

    /// Prefix of every Watch-unavailable node error message.
    public static let messagePrefix = "WATCH_UNAVAILABLE:"

    /// Node error message, for example `WATCH_UNAVAILABLE: no paired Apple Watch`.
    public var message: String {
        switch self {
        case .unsupported:
            "\(Self.messagePrefix) WatchConnectivity is not supported on this device"
        case .notPaired:
            "\(Self.messagePrefix) no paired Apple Watch"
        case .watchAppNotInstalled:
            "\(Self.messagePrefix) OpenClaw watch companion app is not installed"
        case .admissionUnavailable:
            "\(Self.messagePrefix) Watch chat storage is not ready"
        case let .activationFailed(reason):
            "\(Self.messagePrefix) Apple Watch session activation failed (\(reason))"
        case .activationTimedOut:
            "\(Self.messagePrefix) Apple Watch session activation timed out"
        }
    }

    /// `UNAVAILABLE` node error carrying ``message``.
    public var nodeError: OpenClawNodeError {
        OpenClawNodeError(code: .unavailable, message: self.message)
    }

    /// The first reason that blocks relaying for a `watch.status` snapshot, or nil when it is usable.
    public static func blocking(_ status: OpenClawWatchStatusPayload) -> OpenClawWatchUnavailableReason? {
        if !status.supported { return .unsupported }
        if !status.paired { return .notPaired }
        if !status.appInstalled { return .watchAppNotInstalled }
        return nil
    }
}

extension OpenClawWatchNotifyParams {
    /// Maximum quick actions a Watch prompt shows.
    public static let maximumActionCount = 4

    /// Normalizes params before relaying, as the upstream iPhone node does.
    ///
    /// Trims text fields (blank optionals become nil), derives a missing priority from the risk and a
    /// missing risk from the priority, keeps at most ``maximumActionCount`` non-blank actions, and for
    /// prompts (a non-empty `promptId`) without actions inserts default quick actions: approve/decline
    /// for approval kinds, otherwise done/snooze. An empty title and body stay empty; callers reject them.
    public func normalized() -> OpenClawWatchNotifyParams {
        var normalized = self
        normalized.title = self.title.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.body = self.body.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.promptId = Self.trimmedOrNil(self.promptId)
        normalized.sessionKey = Self.trimmedOrNil(self.sessionKey)
        normalized.gatewayStableID = Self.trimmedOrNil(self.gatewayStableID)
        normalized.kind = Self.trimmedOrNil(self.kind)
        normalized.details = Self.trimmedOrNil(self.details)
        normalized.priority = Self.normalizedPriority(self.priority, risk: self.risk)
        normalized.risk = Self.normalizedRisk(self.risk, priority: normalized.priority)
        let actions = Self.normalizedActions(self.actions, kind: normalized.kind, promptId: normalized.promptId)
        normalized.actions = actions.isEmpty ? nil : actions
        return normalized
    }

    static func normalizedActions(
        _ actions: [OpenClawWatchAction]?,
        kind: String?,
        promptId: String?) -> [OpenClawWatchAction]
    {
        let provided = (actions ?? []).compactMap { action -> OpenClawWatchAction? in
            let id = action.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = action.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !label.isEmpty else { return nil }
            return OpenClawWatchAction(id: id, label: label, style: self.trimmedOrNil(action.style))
        }
        if !provided.isEmpty {
            return Array(provided.prefix(self.maximumActionCount))
        }
        // Only auto-insert quick actions when this is a prompt/decision flow.
        guard promptId?.isEmpty == false else { return [] }
        let normalizedKind = kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if normalizedKind.contains("approval") || normalizedKind.contains("approve") {
            return [
                OpenClawWatchAction(id: "approve", label: "Approve"),
                OpenClawWatchAction(id: "decline", label: "Decline", style: "destructive"),
                OpenClawWatchAction(id: "open_phone", label: "Open iPhone"),
                OpenClawWatchAction(id: "escalate", label: "Escalate"),
            ]
        }
        return [
            OpenClawWatchAction(id: "done", label: "Done"),
            OpenClawWatchAction(id: "snooze_10m", label: "Snooze 10m"),
            OpenClawWatchAction(id: "open_phone", label: "Open iPhone"),
            OpenClawWatchAction(id: "escalate", label: "Escalate"),
        ]
    }

    static func normalizedRisk(
        _ risk: OpenClawWatchRisk?,
        priority: OpenClawNotificationPriority?) -> OpenClawWatchRisk?
    {
        if let risk { return risk }
        switch priority {
        case .passive: return .low
        case .active: return .medium
        case .timeSensitive: return .high
        case nil: return nil
        }
    }

    static func normalizedPriority(
        _ priority: OpenClawNotificationPriority?,
        risk: OpenClawWatchRisk?) -> OpenClawNotificationPriority?
    {
        if let priority { return priority }
        switch risk {
        case .low: return .passive
        case .medium: return .active
        case .high: return .timeSensitive
        case nil: return nil
        }
    }

    private static func trimmedOrNil(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
