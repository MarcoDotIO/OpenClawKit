import Foundation
import OpenClawChannels
import OpenClawCore

// Glue between the upstream-shaped config (OpenClawCore) and the SDK runtime pieces that live in
// other modules: config health reporting (StateReporting), auto-reply group-chat options and
// channel access policy (OpenClawChannels), and exec allowlist persistence (native state).

// MARK: - Config health reporting

extension OpenClawConfigHealthSnapshot {
    /// Builds the health snapshot for a config document store event.
    ///
    /// - `loaded`: `future-version-blocked` for files written by a newer OpenClaw, `invalid` when the
    ///   document fails upstream validation, otherwise `migrated` or `loaded`.
    /// - `loadFailed`: `invalid`.
    /// - `saved`: `migrated` when the write migrated legacy keys, otherwise `loaded`.
    /// - `writeRefused`: `write-conflict` for hash conflicts, `future-version-blocked` for newer files,
    ///   `invalid` for other refused writes.
    /// - Parameters:
    ///   - event: Store event.
    ///   - pathKind: Default or override config path.
    public init(event: OpenClawConfigDocumentStore.Event, pathKind: OpenClawConfigPathKind) {
        let parity = OpenClawConfigDocument.upstreamParityVersion
        switch event {
        case .loaded(let loaded):
            let issues = loaded.issues + loaded.legacyIssues
            let validation = loaded.document.validationIssues()
            let state: OpenClawConfigStateLabel?
            if let touched = loaded.touchedVersion, OpenClawVersionComparison.shouldWarnOnTouchedVersion(current: parity, touched: touched) {
                state = .futureVersionBlocked
            } else if !validation.isEmpty {
                state = .invalid
            } else {
                state = nil
            }
            self.init(
                state: state,
                issues: issues + validation,
                upstreamParityVersion: parity,
                pathKind: pathKind,
                lastTouchedVersion: loaded.touchedVersion,
                revisionHash: loaded.hash,
                migrationCount: loaded.migrationChanges.count
            )
        case .loadFailed:
            self.init(state: .invalid, upstreamParityVersion: parity, pathKind: pathKind, issueCount: 1)
        case .saved(let saved, let applied):
            self.init(
                state: applied.isEmpty ? .loaded : .migrated,
                issues: saved.issues,
                upstreamParityVersion: parity,
                pathKind: pathKind,
                lastTouchedVersion: saved.touchedVersion,
                revisionHash: saved.hash,
                migrationCount: applied.count
            )
        case .writeRefused(let error, let document):
            let state: OpenClawConfigStateLabel
            switch error {
            case .conflict:
                state = .writeConflict
            case .futureVersion:
                state = .futureVersionBlocked
            case .includesNotWritable, .notAnObject, .gatewayAuthRemoval:
                state = .invalid
            }
            var revision: String?
            if case .conflict(_, let actual) = error {
                revision = actual
            }
            self.init(
                state: state,
                upstreamParityVersion: parity,
                pathKind: pathKind,
                lastTouchedVersion: document.meta?.lastTouchedVersion,
                revisionHash: revision,
                issueCount: 1
            )
        }
    }
}

extension OpenClawConfigStateReporter {
    /// Reports a config document store event (suppressed when the document sets `diagnostics.enabled: false`).
    /// - Parameters:
    ///   - event: Store event.
    ///   - pathKind: Default or override config path.
    public func report(_ event: OpenClawConfigDocumentStore.Event, pathKind: OpenClawConfigPathKind) {
        var reporter = self
        switch event {
        case .loaded(let loaded):
            reporter.isEnabled = self.isEnabled && loaded.document.diagnostics?.enabled != false
        case .saved(let saved, _):
            reporter.isEnabled = self.isEnabled && saved.document.diagnostics?.enabled != false
        case .writeRefused(_, let document):
            reporter.isEnabled = self.isEnabled && document.diagnostics?.enabled != false
        case .loadFailed:
            break
        }
        reporter.report(OpenClawConfigHealthSnapshot(event: event, pathKind: pathKind))
    }
}

extension OpenClawConfigDocumentStore {
    /// Creates a store that reports config health on every load, save and refused write.
    /// - Parameters:
    ///   - fileURL: Config file; `nil` uses ``defaultConfigURL(environment:)``.
    ///   - environment: Environment used for path resolution.
    ///   - stateReporter: Destination reporter (`nil` uses `OpenClawSystemState.shared`, which is
    ///     gated by `OpenClawSystemState.isEnabled`).
    /// - Returns: The reporting store.
    public static func reportingHealth(
        fileURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        stateReporter: (any OpenClawSystemStateReporting)? = nil
    ) -> OpenClawConfigDocumentStore {
        let reporter = OpenClawConfigStateReporter(reporter: stateReporter)
        let defaultURL = Self.defaultConfigURL(environment: environment)
        let isDefault = fileURL == nil || fileURL?.standardizedFileURL.path == defaultURL.standardizedFileURL.path
        let pathKind: OpenClawConfigPathKind = isDefault ? .default : .override
        return OpenClawConfigDocumentStore(fileURL: fileURL, environment: environment) { event in
            reporter.report(event, pathKind: pathKind)
        }
    }
}

// MARK: - Runtime pieces

extension AutoReplyGroupChatOptions {
    /// Group-chat options from `messages.groupChat` (upstream `GroupChatSchema`).
    ///
    /// `unmentionedInbound` defaults to `user_request`; `visibleReplies` uses
    /// `messages.groupChat.visibleReplies`, then `messages.visibleReplies`, then `automatic`.
    /// Unknown values fall back to the defaults.
    /// - Parameter messages: The document's `messages` section.
    public init(messages: OpenClawConfigDocument.Messages?) {
        let inbound = messages?.groupChat?.effectiveUnmentionedInbound
        let visible = messages?.groupVisibleRepliesMode
        self.init(
            unmentionedInbound: inbound.flatMap(UnmentionedInbound.init(rawValue:)) ?? .userRequest,
            visibleReplies: visible.flatMap(VisibleReplies.init(rawValue:)) ?? .automatic
        )
    }
}

/// SDK runtime inputs derived from one upstream `openclaw.json`.
public struct OpenClawConfigRuntime: Sendable {
    /// The loaded file (authored document, hash, issues and migrations).
    public var loaded: OpenClawConfigDocumentStore.LoadedConfigDocument
    /// The document with `${VAR}` references resolved for runtime use (never write it back).
    public var runtimeDocument: OpenClawConfigDocument
    /// SDK-native config imported from ``runtimeDocument`` onto the caller's base config.
    public var config: OpenClawConfig
    /// Group-chat options for `AutoReplyEngine(groupChat:)`.
    public var groupChat: AutoReplyGroupChatOptions
    /// Decode, legacy-key, validation, env-substitution and mapping issues.
    public var issues: [ConfigDecodeIssue]
    /// Config health summary (also reported through the store when reporting is enabled).
    public var health: OpenClawConfigHealthSnapshot
    /// Store used to load the file; save through it to keep write guards and health reporting.
    public var store: OpenClawConfigDocumentStore

    /// Resolved messaging (access) policy for one channel account, with `channels.defaults` applied;
    /// pass it to `ChannelAccessPolicyEvaluator`.
    /// - Parameters:
    ///   - channelID: Upstream channel id (for example `telegram`).
    ///   - accountID: Account id (`nil` uses the channel's default account).
    /// - Returns: The policy.
    public func messagingPolicy(for channelID: String, accountID: String? = nil) -> ChannelMessagingPolicyConfig {
        self.config.channels.messagingPolicy(for: channelID, accountID: accountID)
    }
}

extension OpenClawSDK {
    /// Loads an upstream `openclaw.json` and derives the SDK runtime inputs: the imported
    /// ``OpenClawConfig`` (channels, auth profiles, models, `mcp`/`skills`/`memory`/`plugins`, …),
    /// auto-reply group-chat options, channel access policy and a config health snapshot.
    ///
    /// The store reports config health (`OpenClawConfigStateReporter`) on this load and on later saves
    /// through ``OpenClawConfigRuntime/store``.
    /// - Parameters:
    ///   - url: Config file; `nil` uses `OPENCLAW_CONFIG_PATH` or `~/.openclaw/openclaw.json`.
    ///   - base: SDK-native values used where the document has no equivalent.
    ///   - environment: Environment for path resolution and `${VAR}` substitution.
    ///   - stateReporter: Health reporter (`nil` uses `OpenClawSystemState.shared`).
    /// - Returns: The runtime inputs.
    /// - Throws: Parse errors for malformed files.
    public func loadConfigRuntime(
        fromOpenClawJSON url: URL? = nil,
        base: OpenClawConfig = OpenClawConfig(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        stateReporter: (any OpenClawSystemStateReporting)? = nil
    ) async throws -> OpenClawConfigRuntime {
        let store = OpenClawConfigDocumentStore.reportingHealth(fileURL: url, environment: environment, stateReporter: stateReporter)
        let loaded = try await store.load()
        let resolved = loaded.document.resolvedForRuntime(environment: environment)
        let collector = ConfigDecodeIssueCollector()
        let config = OpenClawConfig(document: resolved.document, base: base, issues: collector)
        let pathKind: OpenClawConfigPathKind = store.usesDefaultLocation ? .default : .override
        return OpenClawConfigRuntime(
            loaded: loaded,
            runtimeDocument: resolved.document,
            config: config,
            groupChat: AutoReplyGroupChatOptions(messages: resolved.document.messages),
            issues: loaded.issues + loaded.legacyIssues + loaded.document.validationIssues() + resolved.issues + collector.issues,
            health: OpenClawConfigHealthSnapshot(event: .loaded(loaded), pathKind: pathKind),
            store: store
        )
    }
}

// MARK: - Exec allowlist persistence

/// Persists ``SecurityRuntime`` exec allowlists in the shared exec-approvals document
/// (`<stateDir>/state/openclaw.sqlite#exec_approvals_config`), the store `system.execApprovals.set`
/// and the Node gateway use.
///
/// Rules map to `agents.<agentId>.allowlist`. The legacy `default` agent is folded into `main` the
/// way upstream normalizes the document (union of both allowlists, deduplicated by pattern and
/// `argPattern`; `main`'s policy fields win): reads return the merged list upstream enforces, and
/// every write stores the merged `main` and removes `default`, so a rule revoked through the SDK is
/// revoked everywhere. Writes are read-modify-write inside one immediate transaction.
/// `commandText` is display-only and is not persisted in the shared document (upstream behavior).
/// Calls are synchronous and may block on SQLite locks; they throw
/// ``ExecApprovalsLegacyMigrationRequiredError`` while a legacy `exec-approvals.json` awaits Doctor.
public struct ExecApprovalsSQLiteAllowlistStore: ExecAllowlistPersisting {
    /// Legacy agent key folded into ``SecurityRuntime/defaultAgentID``.
    static let legacyDefaultAgentID = "default"

    /// OpenClaw state directory.
    public let stateDirectoryURL: URL

    /// Creates a store.
    /// - Parameter stateDirectoryURL: OpenClaw state directory (for example `OpenClawStateDirectory.cliShared()`).
    public init(stateDirectoryURL: URL) {
        self.stateDirectoryURL = stateDirectoryURL
    }

    /// Loads an agent's allowlist (for `main`, merged with the legacy `default` agent).
    /// - Parameter agentID: Agent id.
    /// - Returns: Rules in stored order.
    public func loadAllowlist(agentID: String) throws -> [ExecAllowlistEntry] {
        guard let record = try ExecApprovalsSQLiteStore.read(stateDirectoryURL: self.stateDirectoryURL) else {
            return []
        }
        let agents = Self.foldingLegacyDefaultAgent(record.document).agents ?? [:]
        return (agents[Self.storedAgentID(agentID)]?.allowlist ?? []).map(Self.entry(from:))
    }

    /// Replaces an agent's allowlist inside one immediate transaction.
    /// - Parameters:
    ///   - entries: Rules to store.
    ///   - agentID: Agent id.
    public func saveAllowlist(_ entries: [ExecAllowlistEntry], agentID: String) throws {
        _ = try self.updateAllowlist(agentID: agentID) { _ in entries }
    }

    /// Reads, transforms and writes an agent's allowlist inside one immediate transaction, starting
    /// from the stored document (so concurrent changes by other writers are preserved).
    /// - Parameters:
    ///   - agentID: Agent id.
    ///   - transform: Receives the stored rules; returns the replacement, or `nil` to leave the
    ///     document unchanged.
    /// - Returns: The rules stored afterwards.
    public func updateAllowlist(
        agentID: String,
        _ transform: ([ExecAllowlistEntry]) throws -> [ExecAllowlistEntry]?
    ) throws -> [ExecAllowlistEntry] {
        let key = Self.storedAgentID(agentID)
        return try ExecApprovalsSQLiteStore.withImmediateTransaction(
            stateDirectoryURL: self.stateDirectoryURL,
            updatedAtMilliseconds: OpenClawClock.nowMs()
        ) { current in
            var document = Self.foldingLegacyDefaultAgent(current?.document ?? ExecApprovalsDocument(version: 1))
            var agents = document.agents ?? [:]
            let stored = (agents[key]?.allowlist ?? []).map(Self.entry(from:))
            guard let entries = try transform(stored) else {
                return ExecApprovalsSQLiteMutation(value: stored, documentToWrite: nil)
            }
            var agent = agents[key] ?? ExecApprovalsAgentDocument()
            agent.allowlist = entries.isEmpty ? nil : entries.map(Self.sharedEntry(from:))
            agents[key] = agent.isEmpty ? nil : agent
            document.agents = agents.isEmpty ? nil : agents
            return ExecApprovalsSQLiteMutation(value: entries, documentToWrite: document)
        }
    }

    /// Agent key in the shared document (`default` is the legacy spelling of `main`).
    static func storedAgentID(_ agentID: String) -> String {
        agentID == Self.legacyDefaultAgentID ? SecurityRuntime.defaultAgentID : agentID
    }

    /// Folds the legacy `default` agent into `main` (upstream `normalizeExecApprovals`): the
    /// allowlists are concatenated (`main` first) and deduplicated by lowercased trimmed pattern plus
    /// trimmed `argPattern`, entries with an empty pattern are dropped, and each policy field takes
    /// `main`'s value when set.
    static func foldingLegacyDefaultAgent(_ document: ExecApprovalsDocument) -> ExecApprovalsDocument {
        guard var agents = document.agents, let legacy = agents.removeValue(forKey: Self.legacyDefaultAgentID) else {
            return document
        }
        let main = agents[SecurityRuntime.defaultAgentID] ?? ExecApprovalsAgentDocument()
        var seen = Set<String>()
        let allowlist = ((main.allowlist ?? []) + (legacy.allowlist ?? [])).filter { entry in
            let pattern = entry.pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !pattern.isEmpty else { return false }
            let argPattern = entry.argPattern?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return seen.insert("\(pattern)\u{0}\(argPattern)").inserted
        }
        let merged = ExecApprovalsAgentDocument(
            security: main.security ?? legacy.security,
            ask: main.ask ?? legacy.ask,
            askFallback: main.askFallback ?? legacy.askFallback,
            autoAllowSkills: main.autoAllowSkills ?? legacy.autoAllowSkills,
            allowlist: allowlist.isEmpty ? nil : allowlist
        )
        agents[SecurityRuntime.defaultAgentID] = merged.isEmpty ? nil : merged
        var folded = document
        folded.agents = agents.isEmpty ? nil : agents
        return folded
    }

    static func entry(from shared: ExecApprovalsAllowlistEntry) -> ExecAllowlistEntry {
        ExecAllowlistEntry(
            id: shared.id,
            pattern: shared.pattern,
            source: shared.source,
            commandText: shared.commandText,
            argPattern: shared.argPattern,
            lastUsedAt: shared.lastUsedAt.flatMap { $0.isFinite && abs($0) < 9.0e18 ? Int64($0.rounded()) : nil },
            lastUsedCommand: shared.lastUsedCommand,
            lastResolvedPath: shared.lastResolvedPath
        )
    }

    static func sharedEntry(from entry: ExecAllowlistEntry) -> ExecApprovalsAllowlistEntry {
        ExecApprovalsAllowlistEntry(
            id: entry.id,
            pattern: entry.pattern,
            source: entry.source,
            commandText: entry.commandText,
            argPattern: entry.argPattern,
            lastUsedAt: entry.lastUsedAt.map(Double.init),
            lastUsedCommand: entry.lastUsedCommand,
            lastResolvedPath: entry.lastResolvedPath
        )
    }
}
