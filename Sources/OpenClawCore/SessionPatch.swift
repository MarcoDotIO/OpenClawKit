import Foundation
import OpenClawProtocol

/// Error raised by ``SessionStore/applyPatch(_:defaultAgentID:grantedScopes:)``.
public enum SessionPatchError: Error, LocalizedError, Sendable, Equatable {
    /// The patch is malformed or not allowed (`INVALID_REQUEST` on the wire).
    case invalid(String)
    /// The caller lacks the scope a field requires (`FORBIDDEN` / `MISSING_SCOPE` on the wire).
    case missingScope(scope: String, message: String)

    /// Human-readable message.
    public var errorDescription: String? {
        switch self {
        case .invalid(let message):
            return message
        case .missingScope(_, let message):
            return message
        }
    }
}

/// Result of an upstream-shaped session patch.
public struct SessionPatchOutcome: Sendable, Equatable {
    /// Record after the patch.
    public let record: SessionRecord
    /// Record before the patch (`nil` when the patch created the session).
    public let previous: SessionRecord?

    /// Whether the permission mode changed (pending approvals of the old mode must be cancelled).
    public var permissionModeChanged: Bool {
        self.previous?.permissionMode != self.record.permissionMode
    }

    /// Whether the patch created the session.
    public var created: Bool {
        self.previous == nil
    }
}

extension SessionStore {
    /// Message returned when a patch carries the retired `execSecurity`/`execAsk` fields.
    public static let retiredExecPolicyMessage =
        "execSecurity/execAsk are retired; set permissionMode (read-only|guarded|workspace|full) instead, or use /exec for this run only."

    /// Applies an upstream-shaped `sessions.patch` payload (raw params), creating the session when missing.
    ///
    /// Mirrors upstream `projectSessionsPatchEntry` for the fields the embedded runtime stores:
    /// - Requests containing `execSecurity` or `execAsk` (including `null`) are rejected with
    ///   ``SessionStore/retiredExecPolicyMessage``.
    /// - `permissionMode` accepts `read-only|guarded|workspace|full`; `full` requires `operator.admin`,
    ///   the other modes `operator.write`. `expectedPermissionMode`/`expectedSessionId` fence stale writers.
    /// - Explicit JSON `null` clears a field; omitted fields are unchanged.
    /// - `archived`, `pinned` and `unread` follow upstream (archiving unpins; child and archived sessions
    ///   cannot be pinned; `unread:false` records a read).
    /// - Legacy SDK fields (`agentID`, `modelOverride`, legacy aliases) keep their lenient semantics: an
    ///   unknown value clears the field instead of failing the patch.
    /// - Parameters:
    ///   - raw: Patch params (`key` required).
    ///   - defaultAgentID: Agent id for sessions created by the patch.
    ///   - grantedScopes: Operator scopes of the caller; `nil` means trusted in-process (all scopes).
    /// - Returns: The patch outcome.
    /// - Throws: ``SessionPatchError``.
    @discardableResult
    public func applyPatch(
        _ raw: [String: AnyCodable],
        defaultAgentID: String,
        grantedScopes: Set<String>? = nil
    ) throws -> SessionPatchOutcome {
        if raw.keys.contains("execSecurity") || raw.keys.contains("execAsk") {
            throw SessionPatchError.invalid(Self.retiredExecPolicyMessage)
        }
        guard let key = raw["key"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw SessionPatchError.invalid("Session key must not be empty")
        }
        let previous = self.records[key]
        let now = sessionStoreNowMs()
        let agentID = SessionRecord.normalizedText(raw["agentId"]?.stringValue ?? raw["agentID"]?.stringValue)
        var record = previous ?? SessionRecord(
            key: key,
            agentID: agentID ?? defaultAgentID,
            updatedAtMs: now
        )
        if previous == nil {
            record.createdAtMs = now
        }
        if record.sessionID == nil {
            record.sessionID = Self.makeSessionID()
        }
        record.updatedAtMs = max(record.updatedAtMs, now)
        if let agentID {
            record.agentID = agentID
        }

        try Self.checkFences(raw, record: previous)
        try Self.applyDisplayFields(raw, to: &record)
        try Self.applyLifecycleFields(raw, to: &record, existed: previous != nil, now: now)
        try Self.applyLevelFields(raw, to: &record)
        try Self.applyExecutionFields(raw, to: &record, grantedScopes: grantedScopes)
        try Self.applyModelFields(raw, to: &record)

        self.records[key] = record
        return SessionPatchOutcome(record: record, previous: previous)
    }

    // MARK: - Field groups

    private static func checkFences(_ raw: [String: AnyCodable], record: SessionRecord?) throws {
        if let expected = raw["expectedSessionId"]?.stringValue, expected != record?.sessionID {
            throw SessionPatchError.invalid("session changed before the patch committed (expectedSessionId mismatch)")
        }
        if let expected = raw["expectedPermissionMode"] {
            let expectedMode = expected.isNull ? nil : SessionPermissionMode.normalize(expected.stringValue)
            if expected.isNull == false, expectedMode == nil {
                throw SessionPatchError.invalid(Self.invalidPermissionModeMessage)
            }
            if expectedMode != record?.permissionMode {
                throw SessionPatchError.invalid("permissionMode changed before the patch committed (expectedPermissionMode mismatch)")
            }
        }
        if let expected = raw["expectedToolOverrides"] {
            let expectedOverrides = expected.isNull ? nil : try Self.decodeToolOverrides(expected)
            if expectedOverrides?.normalized() != record?.toolOverrides?.normalized() {
                throw SessionPatchError.invalid("toolOverrides changed before the patch committed (expectedToolOverrides mismatch)")
            }
        }
    }

    private static func applyDisplayFields(_ raw: [String: AnyCodable], to record: inout SessionRecord) throws {
        if let value = raw["label"] {
            record.label = value.isNull ? nil : SessionRecord.normalizedText(value.stringValue)
        }
        for (field, keyPath) in [
            ("autoLabel", \SessionRecord.autoLabel),
            ("icon", \SessionRecord.icon),
            ("color", \SessionRecord.color),
            ("category", \SessionRecord.category),
        ] {
            guard let value = raw[field] else { continue }
            if value.isNull {
                record[keyPath: keyPath] = nil
            } else if let text = value.stringValue {
                record[keyPath: keyPath] = SessionRecord.normalizedText(text)
            } else {
                throw SessionPatchError.invalid("invalid \(field): expected a string or null")
            }
        }
    }

    private static func applyLifecycleFields(
        _ raw: [String: AnyCodable],
        to record: inout SessionRecord,
        existed: Bool,
        now: Int64
    ) throws {
        if let value = raw["archived"] {
            guard let archived = value.boolValue else {
                throw SessionPatchError.invalid("invalid archived: expected a boolean")
            }
            guard existed else {
                throw SessionPatchError.invalid("session not found: \(record.key)")
            }
            if archived {
                record.archivedAtMs = record.archivedAtMs ?? now
                record.pinnedAtMs = nil
            } else {
                record.archivedAtMs = nil
            }
        }
        if record.isChildSession {
            record.pinnedAtMs = nil
        }
        if let value = raw["pinned"] {
            guard let pinned = value.boolValue else {
                throw SessionPatchError.invalid("invalid pinned: expected a boolean")
            }
            if pinned {
                if record.archived {
                    throw SessionPatchError.invalid("cannot pin an archived session; restore it first")
                }
                if record.isChildSession {
                    throw SessionPatchError.invalid("cannot pin a child session; pin its parent session instead")
                }
                record.pinnedAtMs = record.pinnedAtMs ?? now
            } else {
                record.pinnedAtMs = nil
            }
        }
        if let value = raw["unread"] {
            guard let unread = value.boolValue else {
                throw SessionPatchError.invalid("invalid unread: expected a boolean")
            }
            if unread {
                // The marker doubles as a conditional-ack revision, so repeated writes stay distinct.
                record.markedUnreadAtMs = max(now, (record.markedUnreadAtMs ?? 0) + 1)
            } else {
                record.lastReadAtMs = now
                record.markedUnreadAtMs = nil
            }
        }
    }

    private static func applyLevelFields(_ raw: [String: AnyCodable], to record: inout SessionRecord) throws {
        if let value = raw["thinkingLevel"] {
            record.thinkingLevel = value.isNull ? nil : ThinkLevel.normalize(value.stringValue)
        }
        if let value = raw["fastMode"] {
            if value.isNull {
                record.fastModeSetting = nil
            } else if let flag = value.boolValue {
                record.fastModeSetting = FastModeSetting(flag)
            } else if let setting = FastModeSetting.normalize(value.stringValue) {
                record.fastModeSetting = setting
            } else {
                throw SessionPatchError.invalid("invalid fastMode (use true, false, or \"auto\")")
            }
        }
        if let value = raw["verboseLevel"] {
            record.verboseLevel = value.isNull ? nil : VerboseLevel.normalize(value.stringValue)
        }
        if let value = raw["traceLevel"] {
            if value.isNull {
                record.traceLevel = nil
            } else if let level = TraceLevel.normalize(value.stringValue) {
                record.traceLevel = level
            } else {
                throw SessionPatchError.invalid("invalid traceLevel (use \"on\"|\"off\"|\"raw\")")
            }
        }
        if let value = raw["reasoningLevel"] {
            record.reasoningLevel = value.isNull ? nil : ReasoningLevel.normalize(value.stringValue)
        }
        if let value = raw["responseUsage"] {
            record.responseUsage = value.isNull ? nil : UsageDisplayLevel.normalize(value.stringValue)
        }
        if let value = raw["elevatedLevel"] {
            record.elevatedLevel = value.isNull ? nil : ElevatedLevel.normalize(value.stringValue)
        }
        if let value = raw["groupActivation"] {
            record.groupActivation = value.isNull ? nil : Self.normalizeGroupActivationAlias(value.stringValue)
        }
        if let value = raw["sendPolicy"] {
            record.sendPolicy = value.isNull ? nil : Self.normalizeSendPolicyAlias(value.stringValue)
        }
    }

    private static func applyExecutionFields(
        _ raw: [String: AnyCodable],
        to record: inout SessionRecord,
        grantedScopes: Set<String>?
    ) throws {
        if let value = raw["execHost"] {
            record.execHost = value.isNull ? nil : Self.normalizeExecHostAlias(value.stringValue)
        }
        if let value = raw["execNode"] {
            if value.isNull {
                record.execNode = nil
                if record.execHost == .node {
                    record.execHost = nil
                }
            } else {
                record.execNode = SessionRecord.normalizedText(value.stringValue)
            }
        }
        if let value = raw["sandboxMode"] {
            if value.isNull {
                record.sandboxMode = nil
            } else if value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "off" {
                record.sandboxMode = "off"
            } else {
                throw SessionPatchError.invalid("invalid sandboxMode (use \"off\" or null)")
            }
        }
        if let value = raw["permissionMode"] {
            if value.isNull {
                record.permissionMode = nil
            } else if let mode = SessionPermissionMode.normalize(value.stringValue) {
                if let grantedScopes, !Self.scopes(grantedScopes, allow: mode.requiredScope) {
                    throw SessionPatchError.missingScope(
                        scope: mode.requiredScope,
                        message: "permissionMode \(mode.rawValue) requires \(mode.requiredScope)"
                    )
                }
                record.permissionMode = mode
            } else {
                throw SessionPatchError.invalid(Self.invalidPermissionModeMessage)
            }
        }
        if let value = raw["toolOverrides"] {
            record.toolOverrides = value.isNull ? nil : try Self.decodeToolOverrides(value).normalized()
        }
    }

    private static func applyModelFields(_ raw: [String: AnyCodable], to record: inout SessionRecord) throws {
        let modelValue = raw["model"] ?? raw["modelOverride"]
        if let value = raw["agentRuntime"] {
            if value.isNull {
                record.agentRuntime = nil
            } else if let runtime = SessionRecord.normalizedText(value.stringValue) {
                guard modelValue?.stringValue != nil else {
                    throw SessionPatchError.invalid("agentRuntime requires an explicit canonical provider/model selection")
                }
                record.agentRuntime = runtime
            } else {
                throw SessionPatchError.invalid("invalid agentRuntime: expected a string or null")
            }
        }
        if let value = modelValue {
            record.modelOverride = value.isNull ? nil : SessionRecord.normalizedText(value.stringValue)
        }
        if let value = raw["contextWindow"] {
            record.contextWindow = value.isNull ? nil : SessionRecord.normalizedText(value.stringValue)
        }
    }

    // MARK: - Helpers

    static let invalidPermissionModeMessage = "invalid permissionMode (use \"read-only\"|\"guarded\"|\"workspace\"|\"full\")"

    private static func scopes(_ granted: Set<String>, allow required: String) -> Bool {
        if granted.contains("operator.admin") || granted.contains(required) {
            return true
        }
        return false
    }

    private static func decodeToolOverrides(_ value: AnyCodable) throws -> SessionToolOverrides {
        guard value.dictionaryValue != nil else {
            throw SessionPatchError.invalid("invalid toolOverrides: expected an object or null")
        }
        do {
            return try GatewayPayloadCodecLite.decode(SessionToolOverrides.self, from: value)
        } catch {
            throw SessionPatchError.invalid("invalid toolOverrides: \(error.localizedDescription)")
        }
    }

    static func normalizeExecHostAlias(_ raw: String?) -> ExecHost? {
        guard let raw else { return nil }
        return ExecHost(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static func normalizeSendPolicyAlias(_ raw: String?) -> SendPolicy? {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "allow", "on", "true", "yes":
            return .allow
        case "deny", "off", "false", "no":
            return .deny
        default:
            return nil
        }
    }

    static func normalizeGroupActivationAlias(_ raw: String?) -> GroupActivation? {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "always":
            return .always
        case "mention", "mentions":
            return .mention
        default:
            return nil
        }
    }
}
