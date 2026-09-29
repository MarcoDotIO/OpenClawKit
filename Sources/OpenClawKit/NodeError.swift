import Foundation

/// Stable error codes returned by node command handlers.
public enum OpenClawNodeErrorCode: String, Codable, Sendable {
    case notPaired = "NOT_PAIRED"
    case unauthorized = "UNAUTHORIZED"
    case backgroundUnavailable = "NODE_BACKGROUND_UNAVAILABLE"
    case invalidRequest = "INVALID_REQUEST"
    case unavailable = "UNAVAILABLE"
    /// Rejected before a command handler or progress frame; safe for bounded admission recovery.
    case notReady = "NODE_NOT_READY"
    /// The node's exec policy denied a `system.run` request.
    case systemRunDenied = "SYSTEM_RUN_DENIED"
}

/// Structured node command error returned in `node.invoke.result`.
public struct OpenClawNodeError: Error, Codable, Sendable, Equatable {
    /// Stable error code.
    public var code: OpenClawNodeErrorCode
    /// Human-readable message, conventionally prefixed with the code (for example `INVALID_REQUEST: …`).
    public var message: String
    /// Whether the caller may retry.
    public var retryable: Bool?
    /// Suggested retry delay in milliseconds.
    public var retryAfterMs: Int?

    /// Creates a node error.
    public init(
        code: OpenClawNodeErrorCode,
        message: String,
        retryable: Bool? = nil,
        retryAfterMs: Int? = nil)
    {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.retryAfterMs = retryAfterMs
    }
}

/// Privacy-gated node domains that report `<DOMAIN>_PERMISSION_REQUIRED` errors.
public enum OpenClawPermissionDomain: String, Sendable, CaseIterable {
    /// Calendar (EventKit events).
    case calendar = "CALENDAR"
    /// Reminders (EventKit reminders).
    case reminders = "REMINDERS"
    /// Contacts.
    case contacts = "CONTACTS"
    /// Photos library (limited access counts as authorized).
    case photos = "PHOTOS"
    /// Camera capture.
    case camera = "CAMERA"
    /// Microphone capture.
    case microphone = "MICROPHONE"
    /// Motion and fitness.
    case motion = "MOTION"
    /// Location.
    case location = "LOCATION"
    /// Screen recording.
    case screen = "SCREEN"
    /// Health data.
    case health = "HEALTH"
}

extension OpenClawNodeError {
    /// Error for a remote invoke that needs an OS permission the user has not granted.
    ///
    /// Privacy-gated handlers must never show an OS permission prompt in response to a remote invoke;
    /// they return this immediately (code `UNAVAILABLE`, message `<DOMAIN>_PERMISSION_REQUIRED: <hint>`)
    /// so the agent gets a deterministic tool error, matching the upstream iOS app.
    public static func permissionRequired(_ domain: OpenClawPermissionDomain, hint: String? = nil) -> OpenClawNodeError {
        let trimmed = hint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let detail = trimmed.isEmpty ? "grant access in the OpenClaw app settings on this device" : trimmed
        return OpenClawNodeError(code: .unavailable, message: "\(domain.rawValue)_PERMISSION_REQUIRED: \(detail)")
    }

    /// Error for an invoke received before the node finished starting (safe to retry).
    public static func notReady(retryAfterMs: Int? = nil) -> OpenClawNodeError {
        OpenClawNodeError(
            code: .notReady,
            message: "NODE_NOT_READY: node is still starting",
            retryable: true,
            retryAfterMs: retryAfterMs)
    }
}
