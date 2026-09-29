import Foundation

/// Approved pairing metadata for a remote device.
public struct PairingRecord: Sendable, Equatable {
    /// Device identifier.
    public let deviceID: String
    /// Device role or trust class.
    public let role: String
    /// Pairing token associated with the device.
    public let token: String
    /// Approval timestamp in milliseconds since epoch (`Int64`, safe on 32-bit watchOS).
    public let approvedAtMs: Int64

    /// Creates a pairing record.
    /// - Parameters:
    ///   - deviceID: Device identifier.
    ///   - role: Device role.
    ///   - token: Pairing token.
    ///   - approvedAtMs: Approval timestamp in milliseconds.
    public init(deviceID: String, role: String, token: String, approvedAtMs: Int64) {
        self.deviceID = deviceID
        self.role = role
        self.token = token
        self.approvedAtMs = approvedAtMs
    }
}

/// Persistence seam for per-agent exec allowlists.
///
/// OpenClawCore keeps allowlists in memory by default. Apple hosts can persist them in the shared
/// exec-approvals document (`state/openclaw.sqlite#exec_approvals_config`, the same store
/// `system.execApprovals.set` writes) with the OpenClawKit bridge
/// `ExecApprovalsSQLiteAllowlistStore`; other hosts can plug in their own store.
public protocol ExecAllowlistPersisting: Sendable {
    /// Loads an agent's allowlist.
    /// - Parameter agentID: Agent id (`main` by default).
    /// - Returns: Rules in stored order.
    func loadAllowlist(agentID: String) throws -> [ExecAllowlistEntry]

    /// Replaces an agent's allowlist.
    /// - Parameters:
    ///   - entries: Rules to store.
    ///   - agentID: Agent id.
    func saveAllowlist(_ entries: [ExecAllowlistEntry], agentID: String) throws
}

/// Snapshot evaluator for exec allowlists (usable as an `ExecApprovalGate` allowlist hook).
public struct ExecAllowlistEvaluator: Sendable, Equatable {
    /// Rules to match.
    public var entries: [ExecAllowlistEntry]
    /// Working directory of the commands.
    public var cwd: String?
    /// Environment whose `PATH` is searched.
    public var environment: [String: String]

    /// Creates an evaluator.
    /// - Parameters:
    ///   - entries: Rules to match.
    ///   - cwd: Working directory of the commands.
    ///   - environment: Environment whose `PATH` is searched.
    public init(entries: [ExecAllowlistEntry], cwd: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.entries = entries
        self.cwd = cwd
        self.environment = environment
    }

    /// Rules matching every command of a shell command line (empty when any segment misses or the
    /// line cannot be analyzed safely).
    /// - Parameter commandText: Shell command text.
    /// - Returns: One rule per segment, or `[]`.
    public func matches(commandText: String) -> [ExecAllowlistEntry] {
        guard let resolutions = ExecCommandResolution.resolve(commandText: commandText, cwd: self.cwd, environment: self.environment) else {
            return []
        }
        return ExecAllowlistMatcher.matchAll(entries: self.entries, resolutions: resolutions)
    }

    /// The rule matching an argv command.
    /// - Parameter argv: Command argv.
    /// - Returns: The rule, or `nil`.
    public func match(argv: [String]) -> ExecAllowlistEntry? {
        ExecAllowlistMatcher.match(
            entries: self.entries,
            resolution: ExecCommandResolution.resolve(argv: argv, cwd: self.cwd, environment: self.environment)
        )
    }

    /// Whether every command of a shell command line is allowlisted.
    /// - Parameter commandText: Shell command text.
    /// - Returns: `true` when allowed.
    public func allows(commandText: String) -> Bool {
        !self.matches(commandText: commandText).isEmpty
    }
}

/// Actor that tracks pairing and command-approval state.
public actor SecurityRuntime {
    /// Default agent id for allowlists.
    public static let defaultAgentID = "main"

    private var pairedDevices: [String: PairingRecord] = [:]
    private var execApprovals: [String: Bool] = [:]
    private var allowlists: [String: [ExecAllowlistEntry]] = [:]
    private let allowlistStore: (any ExecAllowlistPersisting)?

    /// Creates an empty security runtime state container.
    public init() {
        self.allowlistStore = nil
    }

    /// Creates a security runtime whose exec allowlists persist through `allowlistStore`.
    /// - Parameter allowlistStore: Allowlist persistence (`nil` keeps allowlists in memory).
    public init(allowlistStore: (any ExecAllowlistPersisting)?) {
        self.allowlistStore = allowlistStore
    }

    /// Approves or updates a paired device entry.
    /// - Parameters:
    ///   - deviceID: Device identifier.
    ///   - role: Device role.
    ///   - token: Pairing token.
    public func approveDevice(deviceID: String, role: String, token: String) {
        self.pairedDevices[deviceID] = PairingRecord(
            deviceID: deviceID,
            role: role,
            token: token,
            approvedAtMs: OpenClawClock.nowMs()
        )
    }

    /// Returns pairing metadata for a device.
    /// - Parameter deviceID: Device identifier.
    /// - Returns: Pairing record when present.
    public func pairedDevice(_ deviceID: String) -> PairingRecord? {
        self.pairedDevices[deviceID]
    }

    /// Returns all paired devices sorted by device identifier.
    public func listPairedDevices() -> [PairingRecord] {
        self.pairedDevices.values.sorted { $0.deviceID < $1.deviceID }
    }

    /// Sets approval state for a command signature.
    /// - Parameters:
    ///   - command: Command identifier/signature.
    ///   - approved: Approval decision.
    public func setExecApproval(command: String, approved: Bool) {
        self.execApprovals[command] = approved
    }

    /// Returns whether a command has an approved execution record.
    /// - Parameter command: Command identifier/signature.
    /// - Returns: `true` if approved.
    public func isExecApproved(command: String) -> Bool {
        self.execApprovals[command] == true
    }

    // MARK: Exec allowlists

    /// An agent's allowlist (loaded from the store on first use).
    /// - Parameter agentID: Agent id.
    /// - Returns: Rules in stored order.
    public func execAllowlist(agentID: String = SecurityRuntime.defaultAgentID) throws -> [ExecAllowlistEntry] {
        try self.loadedAllowlist(agentID)
    }

    /// Replaces an agent's allowlist (and persists it).
    /// - Parameters:
    ///   - entries: Rules.
    ///   - agentID: Agent id.
    public func setExecAllowlist(_ entries: [ExecAllowlistEntry], agentID: String = SecurityRuntime.defaultAgentID) throws {
        try self.allowlistStore?.saveAllowlist(entries, agentID: agentID)
        self.allowlists[agentID] = entries
    }

    /// Adds (or replaces, by id) one rule.
    /// - Parameters:
    ///   - entry: Rule.
    ///   - agentID: Agent id.
    public func addExecAllowlistEntry(_ entry: ExecAllowlistEntry, agentID: String = SecurityRuntime.defaultAgentID) throws {
        var entries = try self.loadedAllowlist(agentID)
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        try self.setExecAllowlist(entries, agentID: agentID)
    }

    /// Records an "always allow" decision for an approved argv command: stores a generated grant
    /// (trust path plus cwd-bound argv hash, source `allow-always`, the command text) unless an
    /// equivalent grant exists.
    /// - Parameters:
    ///   - argv: Approved command argv.
    ///   - cwd: Working directory.
    ///   - commandText: Display text (defaults to the argv joined with spaces).
    ///   - agentID: Agent id.
    ///   - environment: Environment whose `PATH` is searched.
    /// - Returns: The stored grant, or `nil` when no durable grant is allowed (blocked wrappers,
    ///   interpreter-like targets, unresolved executables).
    @discardableResult
    public func recordAllowAlways(
        argv: [String],
        cwd: String? = nil,
        commandText: String? = nil,
        agentID: String = SecurityRuntime.defaultAgentID,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ExecAllowlistEntry? {
        let effectiveCwd = ExecCommandResolution.canonicalApprovalCwd(cwd)
        guard let resolution = ExecCommandResolution.resolve(argv: argv, cwd: effectiveCwd, environment: environment),
              let grant = ExecAllowlistMatcher.allowAlwaysEntry(for: resolution, commandText: commandText ?? argv.joined(separator: " "))
        else {
            return nil
        }
        var entries = try self.loadedAllowlist(agentID)
        if let existing = entries.first(where: { $0.pattern == grant.pattern && $0.argPattern == grant.argPattern }) {
            return existing
        }
        entries.append(grant)
        try self.setExecAllowlist(entries, agentID: agentID)
        return grant
    }

    /// Matches an argv command against an agent's allowlist and records the use on the rule.
    /// - Parameters:
    ///   - argv: Command argv.
    ///   - cwd: Working directory.
    ///   - agentID: Agent id.
    ///   - environment: Environment whose `PATH` is searched.
    /// - Returns: The matching rule (with updated usage), or `nil`.
    public func evaluateExec(
        argv: [String],
        cwd: String? = nil,
        agentID: String = SecurityRuntime.defaultAgentID,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ExecAllowlistEntry? {
        var entries = try self.loadedAllowlist(agentID)
        let resolution = ExecCommandResolution.resolve(argv: argv, cwd: cwd ?? ExecCommandResolution.canonicalApprovalCwd(nil), environment: environment)
        guard var match = ExecAllowlistMatcher.match(entries: entries, resolution: resolution) else {
            return nil
        }
        match.lastUsedAt = OpenClawClock.nowMs()
        match.lastUsedCommand = argv.joined(separator: " ")
        match.lastResolvedPath = resolution?.resolvedRealPath ?? resolution?.resolvedPath
        if let index = entries.firstIndex(where: { $0.id == match.id }) {
            entries[index] = match
            // Usage metadata is best effort; a failed write never blocks an allowed command.
            try? self.setExecAllowlist(entries, agentID: agentID)
        }
        return match
    }

    /// A snapshot evaluator for an agent's allowlist.
    /// - Parameters:
    ///   - agentID: Agent id.
    ///   - cwd: Working directory.
    ///   - environment: Environment whose `PATH` is searched.
    /// - Returns: The evaluator.
    public func allowlistEvaluator(
        agentID: String = SecurityRuntime.defaultAgentID,
        cwd: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ExecAllowlistEvaluator {
        ExecAllowlistEvaluator(entries: try self.loadedAllowlist(agentID), cwd: cwd, environment: environment)
    }

    private func loadedAllowlist(_ agentID: String) throws -> [ExecAllowlistEntry] {
        if let cached = self.allowlists[agentID] {
            return cached
        }
        let loaded = try self.allowlistStore?.loadAllowlist(agentID: agentID) ?? []
        self.allowlists[agentID] = loaded
        return loaded
    }
}
