import Foundation
import OpenClawCore
import OpenClawProtocol

/// Per-request operator scope policy for gateway methods (port of upstream `method-scopes.ts`,
/// `session-method-scopes*.ts`, `node-commands.ts` and `node-pairing-authz.ts`).
///
/// Catalog methods whose scope is ``dynamicScope`` derive their required scopes from the request
/// params and fail closed: a dynamic method without a rule requires `operator.write`, and
/// `sessions.delete` requires `operator.admin` unless it only deletes an archived session.
/// ``GatewayServer`` applies this policy before any handler runs.
public enum GatewayMethodScopePolicy {
    /// Descriptor scope marking methods whose required scopes depend on the request params.
    public static let dynamicScope = "dynamic"
    /// Upstream narrow session read scope (alternative to `operator.read` for session reads).
    public static let sessionsReadScope = "operator.sessions.read"
    /// Upstream narrow session write scope (alternative to `operator.write` for session mutations).
    public static let sessionsWriteScope = "operator.sessions.write"
    /// Upstream pairing scope.
    public static let pairingScope = "operator.pairing"
    /// Upstream talk secrets scope.
    public static let talkSecretsScope = "operator.talk.secrets"
    /// Upstream questions scope.
    public static let questionsScope = "operator.questions"

    /// Node commands that cross an admin-only host boundary (upstream `NODE_ADMIN_ONLY_INVOKE_COMMANDS`).
    public static let adminOnlyNodeInvokeCommands: Set<String> = [
        "browser.proxy", "browser.proxy.upload.v1", "fs.listDir", "terminal.upload",
    ]
    /// Node `system.run` family commands (upstream `NODE_SYSTEM_RUN_COMMANDS`).
    public static let systemRunNodeCommands: Set<String> = ["system.run.prepare", "system.run", "system.which"]
    /// Node exec-approval commands (upstream `NODE_EXEC_APPROVALS_COMMANDS`).
    public static let execApprovalsNodeCommands: Set<String> = ["system.execApprovals.get", "system.execApprovals.set"]

    /// Methods a connection holding only `operator.sessions.read` may call (upstream `SESSION_READ_METHODS`).
    static let sessionReadMethods: Set<String> = [
        "sessions.list", "sessions.subscribe", "sessions.messages.subscribe", "sessions.messages.unsubscribe",
        "sessions.viewers.set", "sessions.preview", "sessions.describe", "sessions.branches.list", "sessions.get",
        "sessions.resolve", "sessions.search", "sessions.files.list", "sessions.files.get", "sessions.setInvolvement",
        "chat.history", "chat.startup", "chat.metadata", "chat.message.get", "session.members.list",
        "session.members.listEvidence",
    ]

    /// Methods a connection holding only `operator.sessions.write` may call (upstream `SESSION_WRITE_METHODS`).
    static let sessionWriteMethods: Set<String> = [
        "question.request", "question.waitAnswer", "question.resolve", "question.get", "question.list",
        "chat.send", "chat.abort", "sessions.create", "sessions.patch", "sessions.patchMany", "sessions.delete",
        "sessions.fork", "sessions.recover", "sessions.send", "sessions.steer", "sessions.abort",
        "sessions.goal.update", "sessions.goal.clear",
    ]

    /// `sessions.patch` fields a write-scoped operator may change (upstream
    /// `SESSIONS_PATCH_WRITE_SCOPE_MUTATIONS`, plus the SDK's legacy `modelOverride` alias of `model`).
    static let patchWriteScopeMutations: Set<String> = [
        "label", "autoLabel", "icon", "color", "category", "boardFace", "boardPresentation", "pinned", "archived",
        "unread", "model", "agentRuntime", "thinkingLevel", "fastMode", "permissionMode", "modelOverride",
    ]

    /// `sessions.patch` envelope fields (upstream `SESSIONS_PATCH_WRITE_SCOPE_ENVELOPE_FIELDS`, plus the
    /// SDK's legacy `agentID` alias of `agentId`).
    static let patchWriteScopeEnvelopeFields: Set<String> = [
        "key", "agentId", "expectedSessionId", "expectedLifecycleRevision", "expectedPermissionMode",
        "expectedMarkedUnreadAt", "agentID",
    ]

    /// `sessions.delete` fields allowed for a write-scoped archived-only delete.
    static let deleteWriteScopeFields: Set<String> = ["key", "agentId", "deleteTranscript", "expectedSessionId", "archivedOnly"]

    /// `sessions.create` fields that configure session state a write-scoped operator may set at
    /// creation (upstream `SessionsCreateParams`, minus the admin-only `execNode`/`toolOverrides`).
    static let createWriteScopeStateFields: Set<String> = ["contextWindow"]

    // MARK: - Resolution

    /// Required operator scopes of a dynamic method for one request (upstream
    /// `resolveDynamicLeastPrivilegeOperatorScopesForMethod`).
    ///
    /// Every listed scope must be satisfied. Methods without a rule require `operator.write`.
    /// - Parameters:
    ///   - method: Wire method name.
    ///   - params: Raw request params.
    /// - Returns: Required scopes (never empty).
    public static func requiredOperatorScopes(forDynamicMethod method: String, params: AnyCodable?) -> [String] {
        let object = params?.dictionaryValue
        let write = GatewayConnectionContext.operatorWriteScope
        let admin = GatewayConnectionContext.operatorAdminScope
        let read = GatewayConnectionContext.operatorReadScope
        switch method {
        case "agent":
            let isReset = [object?["message"], object?["prompt"]].contains { Self.isAgentSessionResetCommand($0?.stringValue) }
            return [isReset ? admin : write]
        case "node.invoke":
            let command = object?["command"]?.stringValue
            return [command.map(Self.adminOnlyNodeInvokeCommands.contains) == true ? admin : write]
        case "talk.config":
            return object?["includeSecrets"]?.boolValue == true ? [read, Self.talkSecretsScope] : [read]
        case "environments.list":
            let runtimeID = object?["runtimeId"]?.stringValue
            return [runtimeID?.isEmpty == false ? write : read]
        case "channels.pairing.approve":
            return object?["bootstrapCommandOwner"]?.boolValue == true ? [Self.pairingScope, admin] : [Self.pairingScope]
        case "fs.listDir":
            return [object?["nodeId"] != nil ? admin : write]
        case "sessions.dispatch":
            // Paired-device selection stays write-scoped; profiles and configured defaults can
            // allocate infrastructure and therefore need an administrator.
            guard let object else { return [write] }
            return [object["deviceId"] != nil || object["autoDevice"]?.boolValue == true ? write : admin]
        case "sessions.move":
            let targetKind = object?["target"]?.dictionaryValue?["kind"]?.stringValue
            return [targetKind == "profile" ? admin : write]
        case "sessions.patch", "sessions.patchMany", "sessions.create", "sessions.delete":
            return [Self.sessionMutationRequiredScope(method: method, params: object) ?? write]
        default:
            return [write]
        }
    }

    /// Required scope of a params-aware session mutation (upstream `resolveBaseSessionMutationRequiredScope`).
    /// - Parameters:
    ///   - method: Wire method name.
    ///   - params: Request params object.
    /// - Returns: `operator.write` or `operator.admin`, or `nil` for methods without a rule.
    static func sessionMutationRequiredScope(method: String, params: [String: AnyCodable]?) -> String? {
        let write = GatewayConnectionContext.operatorWriteScope
        let admin = GatewayConnectionContext.operatorAdminScope
        switch method {
        case "sessions.recover":
            return write
        case "sessions.patch":
            guard let params else { return write }
            return Self.patchRequiresAdmin(params, allowed: Self.patchWriteScopeEnvelopeFields) ? admin : write
        case "sessions.patchMany":
            guard let patch = params?["patch"]?.dictionaryValue else { return write }
            return Self.patchRequiresAdmin(patch, allowed: []) ? admin : write
        case "sessions.create":
            guard let params else { return write }
            if params["incognito"]?.boolValue == true
                || Self.isIncognitoSessionKey(params["key"]?.stringValue)
                || Self.isIncognitoSessionKey(params["parentSessionKey"]?.stringValue)
                || params["execNode"] != nil
                || params["toolOverrides"] != nil
                || Self.isFullPermissionMode(params["permissionMode"])
            {
                return admin
            }
            // The SDK applies the remaining create params as a session patch, so they follow the
            // patch whitelist (upstream rejects them through its closed params schema).
            let patchFields = params.filter { !GatewayServer.sessionCreateNonPatchFields.contains($0.key) }
            let allowed = Self.patchWriteScopeEnvelopeFields.union(Self.createWriteScopeStateFields)
            return Self.patchRequiresAdmin(patchFields, allowed: allowed) ? admin : write
        case "sessions.delete":
            guard let params, params["archivedOnly"]?.boolValue == true else { return admin }
            return params.keys.allSatisfy(Self.deleteWriteScopeFields.contains) ? write : admin
        default:
            return nil
        }
    }

    /// Narrow session scope a connection may present instead of `operator.read`/`operator.write`
    /// (upstream `resolveSessionMethodScope`).
    /// - Parameters:
    ///   - method: Wire method name.
    ///   - params: Raw request params.
    /// - Returns: `operator.sessions.read`, `operator.sessions.write`, or `nil`.
    static func sessionScope(method: String, params: AnyCodable?) -> String? {
        if Self.sessionReadMethods.contains(method) {
            return Self.sessionsReadScope
        }
        if Self.sessionWriteMethods.contains(method),
           Self.sessionMutationRequiredScope(method: method, params: params?.dictionaryValue) != GatewayConnectionContext.operatorAdminScope
        {
            return Self.sessionsWriteScope
        }
        return nil
    }

    /// Operator scopes needed to approve a pending node pairing that declares `commands` (upstream
    /// `resolveNodePairApprovalScopes`).
    ///
    /// Admin-only, `system.run` and exec-approval commands need `operator.admin`; any other command
    /// needs `operator.write`; a request without commands needs only `operator.pairing`.
    /// - Parameter commands: Commands declared by the pending request.
    /// - Returns: Required scopes, starting with `operator.pairing`.
    public static func nodePairApprovalScopes(commands: [String]?) -> [String] {
        let commands = commands ?? []
        let isAdminCommand: (String) -> Bool = { command in
            Self.adminOnlyNodeInvokeCommands.contains(command)
                || Self.systemRunNodeCommands.contains(command)
                || Self.execApprovalsNodeCommands.contains(command)
        }
        if commands.contains(where: isAdminCommand) {
            return [Self.pairingScope, GatewayConnectionContext.operatorAdminScope]
        }
        if !commands.isEmpty {
            return [Self.pairingScope, GatewayConnectionContext.operatorWriteScope]
        }
        return [Self.pairingScope]
    }

    // MARK: - Authorization

    /// Authorizes one request against its method descriptor (upstream `authorizeGatewayMethod`).
    ///
    /// `health` is always reachable. Node-scoped methods require the node role and every other
    /// method the operator role (`INVALID_REQUEST "unauthorized role: …"`). Static scopes, and the
    /// per-request scopes of ``dynamicScope`` methods, are checked against the connection grants;
    /// session methods also accept the narrow `operator.sessions.read`/`operator.sessions.write`
    /// grants. A method registered without any descriptor requires `operator.admin` (upstream
    /// default-deny for unclassified methods).
    /// - Parameters:
    ///   - method: Wire method name.
    ///   - descriptor: Method descriptor, or `nil` for an unclassified method.
    ///   - params: Raw request params.
    ///   - connection: Connection the request arrived on.
    /// - Returns: The denial, or `nil` when the request is authorized.
    public static func authorizationError(
        method: String,
        descriptor: GatewayMethodDescriptor?,
        params: AnyCodable?,
        connection: GatewayConnectionContext
    ) -> GatewayMethodError? {
        if method == "health" {
            return nil
        }
        let scope = descriptor?.scope.trimmingCharacters(in: .whitespacesAndNewlines) ?? GatewayConnectionContext.operatorAdminScope
        let role = connection.role.trimmingCharacters(in: .whitespacesAndNewlines)
        let requiresNodeRole = scope == "node"
        guard role == (requiresNodeRole ? "node" : "operator") else {
            return .invalidRequest("unauthorized role: \(role)")
        }
        if requiresNodeRole || connection.allows(scope: GatewayConnectionContext.operatorAdminScope) {
            return nil
        }
        let required = scope == Self.dynamicScope
            ? Self.requiredOperatorScopes(forDynamicMethod: method, params: params)
            : [scope]
        let sessionScope = Self.sessionScope(method: method, params: params)
        for requiredScope in required where !Self.isSatisfied(requiredScope, method: method, sessionScope: sessionScope, connection: connection) {
            return .missingScope(requiredScope, requiredScopes: required)
        }
        return nil
    }

    /// Upstream `authorizeOperatorScopesForRequiredScope`: the scope itself, or the narrow session
    /// alternative for session reads (`operator.read`) and session writes (`operator.write`, and
    /// `operator.questions` for `question.*`).
    static func isSatisfied(_ scope: String, method: String, sessionScope: String?, connection: GatewayConnectionContext) -> Bool {
        if connection.allows(scope: scope) {
            return true
        }
        guard let sessionScope else { return false }
        let readAlternative = scope == GatewayConnectionContext.operatorReadScope && sessionScope == Self.sessionsReadScope
        let writeAlternative = (scope == GatewayConnectionContext.operatorWriteScope
            || (scope == Self.questionsScope && method.hasPrefix("question.")))
            && sessionScope == Self.sessionsWriteScope
        return (readAlternative || writeAlternative) && connection.allows(scope: sessionScope)
    }

    // MARK: - Helpers

    /// Whether an `agent` message is a session reset command (upstream `AGENT_SESSION_RESET_COMMAND_RE`,
    /// `^/(new|reset)(\s…)?$`, case-insensitive).
    /// - Parameter message: Message text.
    /// - Returns: `true` for `/new` and `/reset` commands.
    public static func isAgentSessionResetCommand(_ message: String?) -> Bool {
        guard let message, message.first == "/" else { return false }
        let body = message.dropFirst()
        for command in ["new", "reset"] {
            guard body.lowercased().hasPrefix(command) else { continue }
            let rest = body.dropFirst(command.count)
            if rest.isEmpty || rest.first?.isWhitespace == true {
                return true
            }
        }
        return false
    }

    /// Whether a key is a process-only incognito session key (upstream `isIncognitoSessionKey`:
    /// `agent:<id>:(dashboard|subagent|internal-session-effects):incognito-<suffix>`).
    static func isIncognitoSessionKey(_ key: String?) -> Bool {
        guard let raw = key?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else { return false }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "agent", !parts[1].isEmpty,
              ["dashboard", "subagent", "internal-session-effects"].contains(String(parts[2]))
        else {
            return false
        }
        return parts[3].hasPrefix("incognito-") && parts[3].count > "incognito-".count
    }

    private static func isFullPermissionMode(_ value: AnyCodable?) -> Bool {
        value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "full"
    }

    /// Upstream `resolveSessionsPatchRequiredScope`: `permissionMode: full`, any `sandboxMode`, or any
    /// field outside the write whitelist (plus `allowed`) needs `operator.admin`.
    private static func patchRequiresAdmin(_ patch: [String: AnyCodable], allowed: Set<String>) -> Bool {
        if Self.isFullPermissionMode(patch["permissionMode"]) || patch["sandboxMode"] != nil {
            return true
        }
        return !patch.keys.allSatisfy { Self.patchWriteScopeMutations.contains($0) || allowed.contains($0) }
    }
}
