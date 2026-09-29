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
///
/// The store is authoritative: ``SecurityRuntime`` re-reads it before every evaluation and changes
/// it only through ``updateAllowlist(agentID:_:)``, so rules added or revoked by other writers (the
/// Node gateway, `system.execApprovals.set`) take effect immediately and are never overwritten.
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

    /// Reads, transforms and writes an agent's allowlist as one atomic step (a transaction for
    /// shared stores).
    ///
    /// The default implementation loads, transforms and saves without isolation; stores shared with
    /// other processes should implement it transactionally.
    /// - Parameters:
    ///   - agentID: Agent id.
    ///   - transform: Receives the current rules; returns the replacement, or `nil` to leave the
    ///     store unchanged.
    /// - Returns: The rules stored afterwards.
    func updateAllowlist(
        agentID: String,
        _ transform: ([ExecAllowlistEntry]) throws -> [ExecAllowlistEntry]?
    ) throws -> [ExecAllowlistEntry]
}

extension ExecAllowlistPersisting {
    /// Loads, transforms and saves an agent's allowlist (not isolated from other writers).
    /// - Parameters:
    ///   - agentID: Agent id.
    ///   - transform: Receives the current rules; returns the replacement, or `nil` to leave the
    ///     store unchanged.
    /// - Returns: The rules stored afterwards.
    public func updateAllowlist(
        agentID: String,
        _ transform: ([ExecAllowlistEntry]) throws -> [ExecAllowlistEntry]?
    ) throws -> [ExecAllowlistEntry] {
        let current = try self.loadAllowlist(agentID: agentID)
        guard let next = try transform(current) else { return current }
        try self.saveAllowlist(next, agentID: agentID)
        return next
    }
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
    ///
    /// A `<shell> -c <payload>` segment that no rule authorizes directly is matched through the
    /// payload's commands (see ``ExecAllowlistMatcher/matchIncludingShellPayload(entries:resolution:environment:)``).
    /// - Parameter commandText: Shell command text.
    /// - Returns: One rule per authorized command, or `[]`.
    public func matches(commandText: String) -> [ExecAllowlistEntry] {
        guard !self.entries.isEmpty,
              let resolutions = ExecCommandResolution.resolve(commandText: commandText, cwd: self.cwd, environment: self.environment)
        else {
            return []
        }
        var matches: [ExecAllowlistEntry] = []
        for resolution in resolutions {
            let segmentMatches = ExecAllowlistMatcher.matchIncludingShellPayload(
                entries: self.entries,
                resolution: resolution,
                environment: self.environment
            )
            guard !segmentMatches.isEmpty else { return [] }
            matches.append(contentsOf: segmentMatches)
        }
        return matches
    }

    /// Rules authorizing an argv command (empty on a miss); a `<shell> -c <payload>` command is
    /// matched through its payload when no rule authorizes the shell itself.
    /// - Parameter argv: Command argv.
    /// - Returns: One rule per authorized command, or `[]`.
    public func matches(argv: [String]) -> [ExecAllowlistEntry] {
        guard let resolution = ExecCommandResolution.resolve(argv: argv, cwd: self.cwd, environment: self.environment) else {
            return []
        }
        return ExecAllowlistMatcher.matchIncludingShellPayload(entries: self.entries, resolution: resolution, environment: self.environment)
    }

    /// The rule matching an argv command (for a shell payload, the rule of its first command).
    /// - Parameter argv: Command argv.
    /// - Returns: The rule, or `nil`.
    public func match(argv: [String]) -> ExecAllowlistEntry? {
        self.matches(argv: argv).first
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

    /// An agent's allowlist (re-read from the store on every call when one is configured).
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

    /// Adds (or replaces, by id) one rule; with a store, inside one read-modify-write.
    /// - Parameters:
    ///   - entry: Rule.
    ///   - agentID: Agent id.
    public func addExecAllowlistEntry(_ entry: ExecAllowlistEntry, agentID: String = SecurityRuntime.defaultAgentID) throws {
        try self.updateAllowlist(agentID) { entries in
            var next = entries
            next.removeAll { $0.id == entry.id }
            next.append(entry)
            return next
        }
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
    ///   shells, carriers, interpreter-like targets, unresolved executables).
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
        var stored = grant
        try self.updateAllowlist(agentID) { entries in
            if let existing = entries.first(where: { $0.pattern == grant.pattern && $0.argPattern == grant.argPattern }) {
                stored = existing
                return nil
            }
            return entries + [grant]
        }
        return stored
    }

    /// Matches an argv command against an agent's current allowlist and records the use on the
    /// matching rules.
    ///
    /// With a store, the allowlist is re-read first (a rule revoked elsewhere never matches), and the
    /// usage write only patches `lastUsed*` on stored rules with the same pattern and `argPattern`
    /// inside one read-modify-write; it never re-adds a rule revoked in the meantime. A
    /// `<shell> -c <payload>` command is matched through its payload when no rule authorizes the
    /// shell itself.
    /// - Parameters:
    ///   - argv: Command argv.
    ///   - cwd: Working directory.
    ///   - agentID: Agent id.
    ///   - environment: Environment whose `PATH` is searched.
    /// - Returns: The (first) matching rule with updated usage, or `nil`.
    public func evaluateExec(
        argv: [String],
        cwd: String? = nil,
        agentID: String = SecurityRuntime.defaultAgentID,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ExecAllowlistEntry? {
        let entries = try self.loadedAllowlist(agentID)
        guard let resolution = ExecCommandResolution.resolve(
            argv: argv,
            cwd: cwd ?? ExecCommandResolution.canonicalApprovalCwd(nil),
            environment: environment
        ) else {
            return nil
        }
        let matches = ExecAllowlistMatcher.matchIncludingShellPayload(entries: entries, resolution: resolution, environment: environment)
        guard var first = matches.first else {
            return nil
        }
        let usedAt = OpenClawClock.nowMs()
        let command = argv.joined(separator: " ")
        let resolvedPath = resolution.resolvedRealPath ?? resolution.resolvedPath
        let keys = Set(matches.map(Self.matchKey))
        func recordingUse(_ entry: ExecAllowlistEntry) -> ExecAllowlistEntry {
            var updated = entry
            updated.lastUsedAt = usedAt
            updated.lastUsedCommand = command
            updated.lastResolvedPath = resolvedPath
            return updated
        }
        // Usage metadata is best effort; a failed write never blocks an allowed command.
        _ = try? self.updateAllowlist(agentID) { stored in
            guard stored.contains(where: { keys.contains(Self.matchKey($0)) }) else { return nil }
            return stored.map { keys.contains(Self.matchKey($0)) ? recordingUse($0) : $0 }
        }
        first = recordingUse(first)
        return first
    }

    /// A snapshot evaluator for an agent's current allowlist.
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

    /// Rule identity for usage recording (upstream `buildAllowlistEntryMatchKey`): ids are not
    /// stable for stored entries without one.
    private static func matchKey(_ entry: ExecAllowlistEntry) -> String {
        "\(entry.pattern.utf8.count)\u{0}\(entry.pattern)\u{0}\(entry.argPattern.map { "1\($0)" } ?? "0")"
    }

    private func loadedAllowlist(_ agentID: String) throws -> [ExecAllowlistEntry] {
        guard let store = self.allowlistStore else {
            return self.allowlists[agentID] ?? []
        }
        // The store is shared with other writers: never serve a stale copy.
        let loaded = try store.loadAllowlist(agentID: agentID)
        self.allowlists[agentID] = loaded
        return loaded
    }

    @discardableResult
    private func updateAllowlist(
        _ agentID: String,
        _ transform: ([ExecAllowlistEntry]) throws -> [ExecAllowlistEntry]?
    ) throws -> [ExecAllowlistEntry] {
        guard let store = self.allowlistStore else {
            let current = self.allowlists[agentID] ?? []
            guard let next = try transform(current) else { return current }
            self.allowlists[agentID] = next
            return next
        }
        let stored = try store.updateAllowlist(agentID: agentID, transform)
        self.allowlists[agentID] = stored
        return stored
    }
}
