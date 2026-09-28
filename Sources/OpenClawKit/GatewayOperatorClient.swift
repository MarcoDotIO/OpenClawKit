import Foundation
import OpenClawProtocol

/// Typed helpers for the SDK-facing operator RPCs added upstream since 2026.4.
///
/// Each method is a thin wrapper that encodes the generated `OpenClawProtocol` params, calls the
/// gateway through ``GatewayRequestSending`` and decodes the generated result. Scopes are enforced by
/// the gateway; the required operator scope is noted per method.
public struct GatewayOperatorClient: Sendable {
    /// Underlying request sender (for example a connected `GatewayChannelActor`).
    public let sender: any GatewayRequestSending
    /// Timeout applied to every request, in milliseconds (`nil` uses the channel default).
    public var timeoutMs: Double?

    /// Creates a client over a request sender.
    public init(sender: any GatewayRequestSending, timeoutMs: Double? = nil) {
        self.sender = sender
        self.timeoutMs = timeoutMs
    }

    // MARK: - Tools

    /// `tools.invoke`: runs one tool through the gateway's shared HTTP tool policy.
    ///
    /// A result with `requiresApproval == true` carries an `approvalid`; resolve it through the exec or
    /// plugin approval flow before retrying.
    public func invokeTool(_ params: ToolsInvokeParams) async throws -> ToolsInvokeResult {
        try await self.sender.request(method: "tools.invoke", params: params, timeoutMs: self.timeoutMs)
    }

    // MARK: - Artifacts

    /// `artifacts.list` (operator.read).
    public func listArtifacts(_ params: ArtifactsListParams = ArtifactsListParams()) async throws -> ArtifactsListResult {
        try await self.sender.request(method: "artifacts.list", params: params, timeoutMs: self.timeoutMs)
    }

    /// `artifacts.get` (operator.read).
    public func getArtifact(_ params: ArtifactsGetParams) async throws -> ArtifactsGetResult {
        try await self.sender.request(method: "artifacts.get", params: params, timeoutMs: self.timeoutMs)
    }

    /// `artifacts.download` (operator.read). The default transport returns base64 bytes over the
    /// WebSocket; pass `transport: "http"` in `params` only when the gateway origin is reachable over HTTPS.
    public func downloadArtifact(_ params: ArtifactsDownloadParams) async throws -> ArtifactsDownloadResult {
        try await self.sender.request(method: "artifacts.download", params: params, timeoutMs: self.timeoutMs)
    }

    /// `artifacts.download` resolved into inline bytes or a fetch URL.
    public func downloadArtifactContent(_ params: ArtifactsDownloadParams) async throws -> GatewayArtifactDownload {
        let result = try await self.downloadArtifact(params)
        return try Self.content(of: result)
    }

    /// Resolves a download result into inline bytes or a URL.
    public static func content(of result: ArtifactsDownloadResult) throws -> GatewayArtifactDownload {
        if let data = result.data {
            let encoding = result.encoding?.lowercased() ?? "base64"
            switch encoding {
            case "base64":
                guard let bytes = Data(base64Encoded: data) else {
                    throw GatewayRPCClientError.invalidResponse(method: "artifacts.download", reason: "invalid base64 data")
                }
                return .inline(bytes)
            case "utf8", "utf-8", "text":
                return .inline(Data(data.utf8))
            default:
                throw GatewayRPCClientError.invalidResponse(
                    method: "artifacts.download",
                    reason: "unsupported encoding \(encoding)")
            }
        }
        if let raw = result.url, let url = URL(string: raw) {
            return .url(url, expiresAt: result.expiresat)
        }
        throw GatewayRPCClientError.invalidResponse(method: "artifacts.download", reason: "neither data nor url")
    }

    // MARK: - Environments

    /// `environments.list` (operator.read).
    public func listEnvironments(_ params: EnvironmentsListParams = EnvironmentsListParams()) async throws
        -> EnvironmentsListResult
    {
        try await self.sender.request(method: "environments.list", params: params, timeoutMs: self.timeoutMs)
    }

    /// `environments.status` (operator.read).
    public func environmentStatus(environmentId: String) async throws -> EnvironmentsStatusResult {
        try await self.sender.request(
            method: "environments.status",
            params: EnvironmentsStatusParams(environmentid: environmentId),
            timeoutMs: self.timeoutMs)
    }

    // MARK: - Tasks

    /// `tasks.list` (operator.read).
    public func listTasks(_ params: TasksListParams = TasksListParams()) async throws -> TasksListResult {
        try await self.sender.request(method: "tasks.list", params: params, timeoutMs: self.timeoutMs)
    }

    /// `tasks.get` (operator.read).
    public func getTask(taskId: String) async throws -> TaskSummary {
        let result: TasksGetResult = try await self.sender.request(
            method: "tasks.get",
            params: TasksGetParams(taskid: taskId),
            timeoutMs: self.timeoutMs)
        return result.task
    }

    /// `tasks.cancel` (operator.write).
    public func cancelTask(taskId: String, reason: String? = nil) async throws -> TasksCancelResult {
        try await self.sender.request(
            method: "tasks.cancel",
            params: TasksCancelParams(taskid: taskId, reason: reason),
            timeoutMs: self.timeoutMs)
    }

    // MARK: - Plugins, chat, sessions

    /// `plugins.sessionAction`: dispatches a scoped plugin action for a session.
    public func sessionAction(_ params: PluginsSessionActionParams) async throws -> PluginsSessionActionOutcome {
        let data = try await self.sender.request(
            method: "plugins.sessionAction",
            params: GatewayRPCCoding.encodeParams(params, method: "plugins.sessionAction"),
            timeoutMs: self.timeoutMs)
        let probe = try GatewayRPCCoding.decode(AnyCodable.self, from: data, method: "plugins.sessionAction")
        if probe.dictionaryValue?["ok"]?.boolValue == false {
            return try .failure(GatewayRPCCoding.decode(
                PluginsSessionActionFailureResult.self,
                from: data,
                method: "plugins.sessionAction"))
        }
        return try .success(GatewayRPCCoding.decode(
            PluginsSessionActionSuccessResult.self,
            from: data,
            method: "plugins.sessionAction"))
    }

    /// `chat.message.get` (operator.read): one transcript message by id.
    public func getChatMessage(_ params: ChatMessageGetParams) async throws -> ChatMessageGetResult {
        try await self.sender.request(method: "chat.message.get", params: params, timeoutMs: self.timeoutMs)
    }

    /// `sessions.compact` (operator.write); throws the gateway's reason when compaction fails.
    public func compactSession(_ params: SessionsCompactParams) async throws {
        let data = try await self.sender.request(
            method: "sessions.compact",
            params: GatewayRPCCoding.encodeParams(params, method: "sessions.compact"),
            timeoutMs: self.timeoutMs)
        try OpenClawSessionsCompactResponse.requireSuccess(from: data)
    }

    /// `skills.status` (operator.read).
    public func skillsStatus(_ params: SkillsStatusParams = SkillsStatusParams()) async throws -> SkillsStatusReport {
        try await self.sender.request(method: "skills.status", params: params, timeoutMs: self.timeoutMs)
    }

    /// `users.prefs.get` for the profile accent color (normalized `#rrggbb`), or `nil`.
    public func profileAccentHex() async throws -> String? {
        let data = try await self.sender.request(
            method: "users.prefs.get",
            params: GatewayUserPreferences.accentRequestParams,
            timeoutMs: self.timeoutMs)
        return try GatewayUserPreferences.decodeProfileAccentHex(data)
    }

    // MARK: - Nodes, update, identity

    /// `node.pair.remove`: removes a paired node (needs operator admin or pairing scope).
    public func removePairedNode(nodeId: String) async throws {
        _ = try await self.sender.request(
            method: "node.pair.remove",
            params: GatewayRPCCoding.encodeParams(NodePairRemoveParams(nodeid: nodeId), method: "node.pair.remove"),
            timeoutMs: self.timeoutMs)
    }

    /// `update.status` (operator.read).
    public func updateStatus(refreshCheckout: Bool? = nil) async throws -> UpdateStatusResult {
        try await self.sender.request(
            method: "update.status",
            params: UpdateStatusParams(refreshcheckout: refreshCheckout),
            timeoutMs: self.timeoutMs)
    }

    /// `gateway.identity.get` (operator.read): the gateway device identity used for relay push grants.
    public func gatewayIdentity() async throws -> GatewayRelayIdentity {
        try await self.sender.request(method: "gateway.identity.get", timeoutMs: self.timeoutMs)
    }

    // MARK: - Exec approvals

    /// `exec.approval.list` (operator.approvals), optionally keeping only approvals whose
    /// `approvalReviewerDeviceIds` target `reviewerDeviceId` (the device that started the request).
    public func listPendingExecApprovals(targetingDeviceId reviewerDeviceId: String? = nil) async throws
        -> [GatewayPendingExecApproval]
    {
        let approvals: [GatewayPendingExecApproval] = try await self.sender.request(
            method: "exec.approval.list",
            timeoutMs: self.timeoutMs)
        guard let reviewerDeviceId else { return approvals }
        return approvals.filter { $0.approvalReviewerDeviceIds.contains(reviewerDeviceId) }
    }

    /// `exec.approval.resolve` (operator.approvals). Repeating the same decision succeeds; a conflicting
    /// repeat throws ``ExecApprovalResolveError/alreadyResolved(id:)``.
    public func resolveExecApproval(id: String, decision: ExecApprovalDecision) async throws {
        do {
            _ = try await self.sender.request(
                method: "exec.approval.resolve",
                params: GatewayRPCCoding.encodeParams(
                    ExecApprovalResolveParams(id: id, decision: decision.rawValue),
                    method: "exec.approval.resolve"),
                timeoutMs: self.timeoutMs)
        } catch let error as GatewayResponseError
            where error.details["reason"]?.stringValue == "APPROVAL_ALREADY_RESOLVED"
        {
            throw ExecApprovalResolveError.alreadyResolved(id: id)
        }
    }
}
