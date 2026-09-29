import CryptoKit
import Foundation

/// Params for `system.execApprovals.get`.
public struct OpenClawSystemExecApprovalsGetParams: Codable, Sendable, Equatable {
    /// Also return the effective defaults (`resolvedDefaults`).
    public var includeResolvedDefaults: Bool?

    /// Creates get params.
    public init(includeResolvedDefaults: Bool? = nil) {
        self.includeResolvedDefaults = includeResolvedDefaults
    }
}

/// Params for `system.execApprovals.set` (upstream `SystemExecApprovalsSetParams`).
public struct OpenClawSystemExecApprovalsSetParams: Codable, Sendable, Equatable {
    /// Replacement document.
    public var file: ExecApprovalsDocument
    /// Hash of the snapshot the editor started from; required once a document exists.
    public var baseHash: String?

    /// Creates set params.
    public init(file: ExecApprovalsDocument, baseHash: String? = nil) {
        self.file = file
        self.baseHash = baseHash
    }
}

/// Effective exec defaults (the document defaults filled with upstream fallbacks).
public struct OpenClawExecApprovalsResolvedDefaults: Codable, Sendable, Equatable {
    /// Security policy (upstream default `full`).
    public var security: ExecApprovalsSecurity
    /// Ask mode (upstream default `off`).
    public var ask: ExecApprovalsAsk
    /// Fallback when no prompt can be shown (upstream default `deny`).
    public var askFallback: ExecApprovalsSecurity
    /// Whether skill commands are allowed automatically (upstream default `false`).
    public var autoAllowSkills: Bool

    /// Resolves defaults from a document.
    /// - Parameter document: Exec-approvals document, or `nil` for none.
    public init(document: ExecApprovalsDocument?) {
        let defaults = document?.defaults
        self.security = defaults?.security ?? .full
        self.ask = defaults?.ask ?? .off
        self.askFallback = defaults?.askFallback ?? .deny
        self.autoAllowSkills = defaults?.autoAllowSkills ?? false
    }
}

/// Redacted exec-approvals snapshot returned by `system.execApprovals.get`/`set`.
///
/// The socket token never leaves the node: only `socket.path` is reported.
public struct OpenClawExecApprovalsSnapshot: Codable, Sendable, Equatable {
    /// Storage location (the SQLite database path).
    public var path: String
    /// Whether a document is stored.
    public var exists: Bool
    /// SHA-256 hex of the stored raw JSON (`missing:<sha256("")>` when absent); pass it back as
    /// ``OpenClawSystemExecApprovalsSetParams/baseHash``.
    public var hash: String
    /// Redacted document.
    public var file: ExecApprovalsDocument
    /// Effective defaults, when requested.
    public var resolvedDefaults: OpenClawExecApprovalsResolvedDefaults?

    /// Creates a snapshot.
    public init(
        path: String,
        exists: Bool,
        hash: String,
        file: ExecApprovalsDocument,
        resolvedDefaults: OpenClawExecApprovalsResolvedDefaults? = nil)
    {
        self.path = path
        self.exists = exists
        self.hash = hash
        self.file = file
        self.resolvedDefaults = resolvedDefaults
    }
}

/// Node-side handler for `system.execApprovals.get` / `system.execApprovals.set` backed by
/// ``ExecApprovalsSQLiteStore`` (upstream `src/node-host/invoke.ts`).
///
/// The state directory is always explicit: pass ``OpenClawStateDirectory/resolved()`` (the SDK
/// default) or, on a macOS exec host that shares approvals with the CLI,
/// `OpenClawStateDirectory.cliShared()`. `set` is optimistic: a stale `baseHash` is rejected with
/// `INVALID_REQUEST: exec approvals changed; reload and retry`, re-checked inside the write
/// transaction. The socket path and token are preserved (or generated) as upstream does, and
/// never reported.
public struct OpenClawSystemExecApprovalsHandler: Sendable {
    /// State directory holding `state/openclaw.sqlite`.
    public let stateDirectoryURL: URL

    /// Creates a handler.
    /// - Parameter stateDirectoryURL: Explicit state directory.
    public init(stateDirectoryURL: URL) {
        self.stateDirectoryURL = stateDirectoryURL
    }

    /// Reads the redacted snapshot.
    /// - Parameter includeResolvedDefaults: Also resolve the effective defaults.
    /// - Returns: The snapshot.
    /// - Throws: ``ExecApprovalsLegacyMigrationRequiredError`` or a storage error.
    public func snapshot(includeResolvedDefaults: Bool = false) throws -> OpenClawExecApprovalsSnapshot {
        let record = try ExecApprovalsSQLiteStore.read(stateDirectoryURL: self.stateDirectoryURL)
        return self.snapshot(record: record, includeResolvedDefaults: includeResolvedDefaults)
    }

    /// Replaces the stored document after checking `baseHash`.
    /// - Parameter params: Set params.
    /// - Returns: The redacted snapshot of the stored document.
    /// - Throws: ``OpenClawNodeError`` (`INVALID_REQUEST`) for a missing or stale base hash or an
    ///   unsupported version; storage errors otherwise.
    public func apply(_ params: OpenClawSystemExecApprovalsSetParams) throws -> OpenClawExecApprovalsSnapshot {
        guard params.file.version == 1 else {
            throw OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: exec approvals version must be 1")
        }
        let baseHash = params.baseHash?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stored = try ExecApprovalsSQLiteStore.withImmediateTransaction(
            stateDirectoryURL: self.stateDirectoryURL)
        { current -> ExecApprovalsSQLiteMutation<ExecApprovalsDocument> in
            try Self.requireBaseHash(baseHash, current: current)
            let next = self.mergingSocketDefaults(params.file, current: current?.document)
            return ExecApprovalsSQLiteMutation(value: next, documentToWrite: next)
        }
        let rawJSON = try ExecApprovalsSQLiteStore.serialize(stored)
        return self.snapshot(
            record: ExecApprovalsSQLiteRecord(rawJSON: rawJSON, document: stored),
            includeResolvedDefaults: false)
    }

    /// Handles `system.execApprovals.get` / `set`; returns `nil` for any other command.
    /// - Parameter request: Node invoke request.
    /// - Returns: The invoke response, or `nil` when the command is not an exec-approvals command.
    public func handle(_ request: BridgeInvokeRequest) -> BridgeInvokeResponse? {
        switch OpenClawSystemCommand(rawValue: request.command) {
        case .execApprovalsGet?:
            return self.respond(to: request) {
                let params = try Self.decode(OpenClawSystemExecApprovalsGetParams.self, request.paramsJSON)
                return try self.snapshot(includeResolvedDefaults: params?.includeResolvedDefaults == true)
            }
        case .execApprovalsSet?:
            return self.respond(to: request) {
                guard let params = try Self.decode(OpenClawSystemExecApprovalsSetParams.self, request.paramsJSON) else {
                    throw OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: exec approvals file required")
                }
                return try self.apply(params)
            }
        default:
            return nil
        }
    }

    /// Hash reported for a stored raw JSON value (upstream `hashExecApprovalsRaw`).
    /// - Parameter rawJSON: Stored raw JSON, or `nil` when absent.
    /// - Returns: SHA-256 hex, or `missing:<sha256("")>`.
    public static func hash(rawJSON: String?) -> String {
        guard let rawJSON else { return "missing:\(Self.sha256Hex(Data()))" }
        return Self.sha256Hex(Data(rawJSON.utf8))
    }

    private func snapshot(
        record: ExecApprovalsSQLiteRecord?,
        includeResolvedDefaults: Bool) -> OpenClawExecApprovalsSnapshot
    {
        var file = record?.document ?? ExecApprovalsDocument(version: 1, agents: [:])
        let socketPath = file.socket?.path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        file.socket = socketPath.isEmpty ? nil : ExecApprovalsSocketDocument(path: socketPath)
        return OpenClawExecApprovalsSnapshot(
            path: ExecApprovalsSQLiteStore.databaseURL(stateDirectoryURL: self.stateDirectoryURL).path,
            exists: record != nil,
            hash: Self.hash(rawJSON: record?.rawJSON),
            file: file,
            resolvedDefaults: includeResolvedDefaults
                ? OpenClawExecApprovalsResolvedDefaults(document: record?.document)
                : nil)
    }

    private static func requireBaseHash(_ baseHash: String, current: ExecApprovalsSQLiteRecord?) throws {
        let currentHash = Self.hash(rawJSON: current?.rawJSON)
        guard current != nil else {
            if !baseHash.isEmpty, baseHash != currentHash { throw Self.changedError() }
            return
        }
        guard !baseHash.isEmpty else {
            throw OpenClawNodeError(
                code: .invalidRequest,
                message: "INVALID_REQUEST: exec approvals base hash required; reload and retry")
        }
        guard baseHash == currentHash else { throw Self.changedError() }
    }

    private static func changedError() -> OpenClawNodeError {
        OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: exec approvals changed; reload and retry")
    }

    /// Upstream `mergeExecApprovalsSocketDefaults`: keep the submitted socket values, else the stored
    /// ones, else the default path and a fresh 24-byte token.
    private func mergingSocketDefaults(
        _ document: ExecApprovalsDocument,
        current: ExecApprovalsDocument?) -> ExecApprovalsDocument
    {
        func trimmed(_ value: String?) -> String? {
            let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }
        var next = document
        let path = trimmed(document.socket?.path)
            ?? trimmed(current?.socket?.path)
            ?? self.stateDirectoryURL.appendingPathComponent("exec-approvals.sock").path
        let token = trimmed(document.socket?.token) ?? trimmed(current?.socket?.token) ?? Self.generateToken()
        next.socket = ExecApprovalsSocketDocument(path: path, token: token)
        return next
    }

    private static func generateToken() -> String {
        let bytes = SymmetricKey(size: SymmetricKeySize(bitCount: 192)).withUnsafeBytes { Data($0) }
        return bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ paramsJSON: String?) throws -> T? {
        guard let paramsJSON, !paramsJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            return try JSONDecoder().decode(type, from: Data(paramsJSON.utf8))
        } catch {
            throw OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: \(error.localizedDescription)")
        }
    }

    private func respond(
        to request: BridgeInvokeRequest,
        _ body: () throws -> OpenClawExecApprovalsSnapshot) -> BridgeInvokeResponse
    {
        do {
            let snapshot = try body()
            let payload = try JSONEncoder().encode(snapshot)
            return BridgeInvokeResponse(
                id: request.id,
                ok: true,
                payloadJSON: String(decoding: payload, as: UTF8.self))
        } catch let error as OpenClawNodeError {
            return BridgeInvokeResponse(id: request.id, ok: false, error: error)
        } catch let error as ExecApprovalsLegacyMigrationRequiredError {
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(code: .unavailable, message: "UNAVAILABLE: \(error.localizedDescription)"))
        } catch {
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(
                    code: .unavailable,
                    message: "UNAVAILABLE: exec approvals storage failed: \(error.localizedDescription)"))
        }
    }
}

extension OpenClawSystemRunApprovalPolicySnapshot {
    /// Captures the effective persisted policy of one agent (upstream `createExecApprovalPolicySnapshot`).
    ///
    /// Agent values win over the `*` wildcard entry, which wins over the document defaults (upstream
    /// fallbacks `full` / `off` / `deny` / `false`). Allowlist rules merge the wildcard and agent
    /// lists, keeping only the pattern, argument pattern and `allow-always` source.
    /// - Parameters:
    ///   - document: Stored exec-approvals document, or `nil` when none is stored.
    ///   - agentId: Agent id; blank means `main`.
    public init(document: ExecApprovalsDocument?, agentId: String?) {
        let defaults = OpenClawExecApprovalsResolvedDefaults(document: document)
        let key = agentId?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyExecAgentKey ?? "main"
        let agent = document?.agents?[key] ?? (key == "main" ? document?.agents?["default"] : nil)
        let wildcard = document?.agents?["*"]
        let entries = (wildcard?.allowlist ?? []) + (agent?.allowlist ?? [])
        self.init(
            security: Security(agent?.security ?? wildcard?.security ?? defaults.security),
            ask: Ask(agent?.ask ?? wildcard?.ask ?? defaults.ask),
            askFallback: Security(agent?.askFallback ?? wildcard?.askFallback ?? defaults.askFallback),
            autoAllowSkills: agent?.autoAllowSkills ?? wildcard?.autoAllowSkills ?? defaults.autoAllowSkills,
            allowlistRules: entries.compactMap { entry in
                let pattern = entry.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !pattern.isEmpty else { return nil }
                return Rule(
                    pattern: pattern,
                    argPattern: entry.argPattern,
                    source: entry.source == RuleSource.allowAlways.rawValue ? .allowAlways : nil)
            })
    }

    /// Whether `current` still grants everything this snapshot granted (upstream
    /// `isExecApprovalPolicySnapshotCurrent`): scalar policy must match, every expected rule must
    /// still exist (an in-place upgrade to `allow-always` counts), and added rules are fine.
    /// - Parameter current: Policy re-read right before execution.
    /// - Returns: `true` when the delayed authority is still valid.
    public func isCurrent(_ current: OpenClawSystemRunApprovalPolicySnapshot) -> Bool {
        guard self.security == current.security,
              self.ask == current.ask,
              self.askFallback == current.askFallback,
              self.autoAllowSkills == current.autoAllowSkills
        else { return false }
        let currentRules = Set(current.allowlistRules)
        return self.allowlistRules.allSatisfy { rule in
            if currentRules.contains(rule) { return true }
            guard rule.source == nil else { return false }
            return currentRules.contains(Rule(pattern: rule.pattern, argPattern: rule.argPattern, source: .allowAlways))
        }
    }
}

extension OpenClawSystemRunApprovalPolicySnapshot.Security {
    fileprivate init(_ security: ExecApprovalsSecurity) {
        switch security {
        case .deny: self = .deny
        case .allowlist: self = .allowlist
        case .full: self = .full
        }
    }
}

extension OpenClawSystemRunApprovalPolicySnapshot.Ask {
    fileprivate init(_ ask: ExecApprovalsAsk) {
        switch ask {
        case .off: self = .off
        case .onMiss: self = .onMiss
        case .always: self = .always
        }
    }
}

extension String {
    fileprivate var nonEmptyExecAgentKey: String? {
        self.isEmpty ? nil : self
    }
}
