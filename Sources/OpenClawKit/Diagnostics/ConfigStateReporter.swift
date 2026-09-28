import CryptoKit
import Foundation
import OpenClawCore

/// Configuration health states reported on ``OpenClawStateDomain/config``.
public enum OpenClawConfigStateLabel: String, Sendable, CaseIterable {
    /// The config loaded cleanly (possibly with tolerated issues).
    case loaded
    /// The config failed validation and the previous or default config is in use.
    case invalid
    /// Legacy keys were migrated on load or save.
    case migrated
    /// A save was rejected because the file changed underneath (revision conflict).
    case writeConflict = "write-conflict"
    /// The file was written by a newer OpenClaw and is read-only for this SDK.
    case futureVersionBlocked = "future-version-blocked"
}

/// Where the active config file lives, reported instead of its path.
public enum OpenClawConfigPathKind: String, Sendable, CaseIterable {
    /// The SDK default location.
    case `default`
    /// A host-supplied override location.
    case override
}

/// Privacy-safe summary of a config load, save, or conflict.
///
/// Never carries paths, secrets, or config values: only versions, a revision-hash prefix and counts.
public struct OpenClawConfigHealthSnapshot: Sendable, Equatable {
    /// Health state.
    public var state: OpenClawConfigStateLabel
    /// Upstream OpenClaw version the config schema tracks (for example `2026.9.6`).
    public var upstreamParityVersion: String
    /// Default or override path.
    public var pathKind: OpenClawConfigPathKind
    /// `meta.lastTouchedVersion` from the file, when present.
    public var lastTouchedVersion: String?
    /// Config revision identifier (only its first 8 characters are reported).
    public var revisionHash: String?
    /// Total decode issues.
    public var issueCount: Int
    /// Decode issues caused by legacy keys.
    public var legacyIssueCount: Int
    /// Migrations applied.
    public var migrationCount: Int

    /// Creates a config health snapshot.
    /// - Parameters:
    ///   - state: Health state.
    ///   - upstreamParityVersion: Upstream schema version.
    ///   - pathKind: Default or override path.
    ///   - lastTouchedVersion: `meta.lastTouchedVersion`.
    ///   - revisionHash: Revision identifier; truncated to 8 characters when reported.
    ///   - issueCount: Total decode issues.
    ///   - legacyIssueCount: Legacy-key issues.
    ///   - migrationCount: Applied migrations.
    public init(
        state: OpenClawConfigStateLabel,
        upstreamParityVersion: String,
        pathKind: OpenClawConfigPathKind = .default,
        lastTouchedVersion: String? = nil,
        revisionHash: String? = nil,
        issueCount: Int = 0,
        legacyIssueCount: Int = 0,
        migrationCount: Int = 0)
    {
        self.state = state
        self.upstreamParityVersion = upstreamParityVersion
        self.pathKind = pathKind
        self.lastTouchedVersion = lastTouchedVersion
        self.revisionHash = revisionHash
        self.issueCount = max(0, issueCount)
        self.legacyIssueCount = max(0, legacyIssueCount)
        self.migrationCount = max(0, migrationCount)
    }

    /// Creates a snapshot from decode issues collected while loading.
    /// - Parameters:
    ///   - state: Health state; `nil` derives `migrated` when migrations ran, otherwise `loaded`.
    ///   - issues: Decode issues from `ConfigDecodeIssueCollector`.
    ///   - upstreamParityVersion: Upstream schema version.
    ///   - pathKind: Default or override path.
    ///   - lastTouchedVersion: `meta.lastTouchedVersion`.
    ///   - revisionHash: Revision identifier.
    ///   - migrationCount: Applied migrations.
    public init(
        state: OpenClawConfigStateLabel? = nil,
        issues: [ConfigDecodeIssue],
        upstreamParityVersion: String,
        pathKind: OpenClawConfigPathKind = .default,
        lastTouchedVersion: String? = nil,
        revisionHash: String? = nil,
        migrationCount: Int = 0)
    {
        self.init(
            state: state ?? (migrationCount > 0 ? .migrated : .loaded),
            upstreamParityVersion: upstreamParityVersion,
            pathKind: pathKind,
            lastTouchedVersion: lastTouchedVersion,
            revisionHash: revisionHash,
            issueCount: issues.count,
            legacyIssueCount: issues.filter { $0.kind == .legacyKey }.count,
            migrationCount: migrationCount)
    }

    /// Stable metadata (schema identity).
    public var stableMetadata: OpenClawStateMetadata {
        [
            "upstreamParityVersion": .string(self.upstreamParityVersion),
            "configPathKind": .string(self.pathKind.rawValue),
        ]
    }

    /// Volatile metadata (versions, revision prefix, counts).
    public var volatileMetadata: OpenClawStateMetadata {
        var metadata: OpenClawStateMetadata = [
            "issueCount": .int(self.issueCount),
            "legacyIssueCount": .int(self.legacyIssueCount),
            "migrationCount": .int(self.migrationCount),
        ]
        if let lastTouchedVersion, !lastTouchedVersion.isEmpty {
            metadata["lastTouchedVersion"] = .string(lastTouchedVersion)
        }
        if let revisionHash = Self.revisionPrefix(self.revisionHash) {
            metadata["configRevisionHash"] = .string(revisionHash)
        }
        return metadata
    }

    /// Returns the first 8 characters of a revision identifier.
    /// - Parameter revision: Revision identifier (hash, etag, ...).
    /// - Returns: Prefix, or `nil` when empty.
    public static func revisionPrefix(_ revision: String?) -> String? {
        let trimmed = revision?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(8))
    }

    /// Computes a revision hash (SHA-256 hex) for raw config bytes.
    /// - Parameter data: Config file contents.
    /// - Returns: Lowercase hex digest.
    public static func revisionHash(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Reports configuration health on ``OpenClawStateDomain/config``.
///
/// Config stores call ``report(_:)`` on load, save and conflict. Reporting is skipped when
/// `isEnabled` is false (pass `diagnostics.enabled != false` from the config document).
public struct OpenClawConfigStateReporter: Sendable {
    /// Destination reporter.
    public let reporter: any OpenClawSystemStateReporting
    /// Whether config diagnostics are enabled.
    public var isEnabled: Bool

    /// Creates a config state reporter.
    /// - Parameters:
    ///   - reporter: Destination reporter; `nil` uses ``OpenClawSystemState/shared``.
    ///   - isEnabled: Whether to report (mirrors `diagnostics.enabled != false`).
    public init(reporter: (any OpenClawSystemStateReporting)? = nil, isEnabled: Bool = true) {
        self.reporter = OpenClawSystemState.resolve(reporter)
        self.isEnabled = isEnabled
    }

    /// Reports a config health snapshot.
    /// - Parameter snapshot: Health summary.
    public func report(_ snapshot: OpenClawConfigHealthSnapshot) {
        guard self.isEnabled else { return }
        self.reporter.reportTransition(
            .config,
            to: snapshot.state.rawValue,
            stable: snapshot.stableMetadata,
            volatile: snapshot.volatileMetadata)
    }

    /// Clears the config state (for example when the store is torn down).
    public func clear() {
        guard self.isEnabled else { return }
        self.reporter.reportTransition(.config, to: nil, stable: [:], volatile: [:])
    }
}
