import Foundation
import OpenClawProtocol

/// Result of `gateway.identity.get`: the gateway's device identity, used to scope relay push grants.
public struct GatewayRelayIdentity: Codable, Sendable, Equatable {
    /// Gateway device identifier.
    public let deviceId: String
    /// Gateway public key (raw, base64url).
    public let publicKey: String

    /// Creates an identity.
    public init(deviceId: String, publicKey: String) {
        self.deviceId = deviceId
        self.publicKey = publicKey
    }
}

/// Outcome of `plugins.sessionAction` (the gateway answers with `ok: true` or `ok: false` shapes).
public enum PluginsSessionActionOutcome: Sendable {
    /// The plugin handled the action.
    case success(PluginsSessionActionSuccessResult)
    /// The plugin rejected or failed the action.
    case failure(PluginsSessionActionFailureResult)
}

/// Where an artifact download can be read from.
public enum GatewayArtifactDownload: Sendable, Equatable {
    /// Bytes delivered inline over the WebSocket (base64-decoded).
    case inline(Data)
    /// A short-lived URL to fetch over HTTPS (only when `transport: "http"` was requested).
    case url(URL, expiresAt: String?)
}

/// Transport for `artifacts.download`.
public enum GatewayArtifactDownloadTransport: String, Sendable {
    /// Base64 bytes in the WebSocket response (the default).
    case websocket = "ws"
    /// A URL on the gateway's HTTP surface; request it only when the gateway origin is reachable over HTTPS.
    case http
}

/// Operator decision for a pending exec approval.
public enum ExecApprovalDecision: String, Codable, Sendable, CaseIterable {
    /// Allow this one run.
    case allowOnce = "allow-once"
    /// Allow and persist an allowlist rule.
    case allowAlways = "allow-always"
    /// Deny the run.
    case deny
}

/// One pending exec approval from `exec.approval.list`.
public struct GatewayPendingExecApproval: Codable, Sendable, Equatable {
    /// Approval identifier for `exec.approval.resolve`.
    public let id: String
    /// Raw approval request payload (`ExecApprovalRequestParams` shape).
    public let request: AnyCodable
    /// Creation time in milliseconds since the Unix epoch.
    public let createdAtMs: Int64
    /// Expiry time in milliseconds since the Unix epoch.
    public let expiresAtMs: Int64
    /// Approval kind (`exec`), when reported.
    public let approvalKind: String?

    /// Creates a pending approval record.
    public init(id: String, request: AnyCodable, createdAtMs: Int64, expiresAtMs: Int64, approvalKind: String? = nil) {
        self.id = id
        self.request = request
        self.createdAtMs = createdAtMs
        self.expiresAtMs = expiresAtMs
        self.approvalKind = approvalKind
    }

    private var requestObject: [String: AnyCodable] {
        self.request.dictionaryValue ?? [:]
    }

    /// Command text to show the reviewer.
    public var commandText: String? {
        self.requestObject["command"]?.stringValue
    }

    /// Optional warning to show next to the command.
    public var warningText: String? {
        self.requestObject["warningText"]?.stringValue
    }

    /// Decisions the reviewer must not be offered (for example `allow-always`).
    public var unavailableDecisions: Set<ExecApprovalDecision> {
        let raw = self.requestObject["unavailableDecisions"]?.arrayValue?.compactMap(\.stringValue) ?? []
        return Set(raw.compactMap(ExecApprovalDecision.init(rawValue:)))
    }

    /// Decisions to offer, in display order.
    public var availableDecisions: [ExecApprovalDecision] {
        ExecApprovalDecision.allCases.filter { !self.unavailableDecisions.contains($0) }
    }

    /// UTF-16 `[start, end)` ranges of ``commandText`` to highlight.
    public var commandSpans: [Range<Int>] {
        (self.requestObject["commandSpans"]?.arrayValue ?? []).compactMap { span in
            guard let object = span.dictionaryValue,
                  let start = object["startIndex"]?.intValue,
                  let end = object["endIndex"]?.intValue,
                  start >= 0, end > start
            else { return nil }
            return start..<end
        }
    }

    /// Devices the gateway targets for review; empty means any approver.
    public var approvalReviewerDeviceIds: [String] {
        self.requestObject["approvalReviewerDeviceIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    /// Agent that requested the run.
    public var agentId: String? {
        self.requestObject["agentId"]?.stringValue
    }

    /// Session that requested the run.
    public var sessionKey: String? {
        self.requestObject["sessionKey"]?.stringValue
    }

    /// Best-effort typed view of ``request``.
    public var requestParams: ExecApprovalRequestParams? {
        guard let data = try? JSONEncoder().encode(self.request) else { return nil }
        return try? JSONDecoder().decode(ExecApprovalRequestParams.self, from: data)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case request
        case createdAtMs
        case expiresAtMs
        case approvalKind
    }

    /// Decodes a record; millisecond timestamps are read as `Int64` (or whole doubles).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.request = try container.decodeIfPresent(AnyCodable.self, forKey: .request) ?? AnyCodable.nullValue
        self.createdAtMs = try Self.decodeMilliseconds(container, key: .createdAtMs)
        self.expiresAtMs = try Self.decodeMilliseconds(container, key: .expiresAtMs)
        self.approvalKind = try container.decodeIfPresent(String.self, forKey: .approvalKind)
    }

    private static func decodeMilliseconds(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys) throws -> Int64
    {
        if let value = try? container.decode(Int64.self, forKey: key) {
            return value
        }
        let value = try container.decode(Double.self, forKey: key)
        guard value.isFinite, let whole = Int64(exactly: value.rounded()) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "invalid timestamp")
        }
        return whole
    }
}

/// Typed failures of `exec.approval.resolve`.
public enum ExecApprovalResolveError: Error, Equatable, LocalizedError, Sendable {
    /// Someone already resolved the approval with a different decision (`APPROVAL_ALREADY_RESOLVED`).
    /// Repeating the same decision is treated as success by the gateway.
    case alreadyResolved(id: String)

    /// Human-readable description.
    public var errorDescription: String? {
        switch self {
        case let .alreadyResolved(id):
            "Approval \(id) was already resolved with a different decision."
        }
    }
}
