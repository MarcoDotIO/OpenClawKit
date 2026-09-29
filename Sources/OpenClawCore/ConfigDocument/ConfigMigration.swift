import Foundation
import OpenClawProtocol

/// One change applied (or proposed) by ``OpenClawConfigMigrator``.
public struct ConfigMigrationChange: Codable, Sendable, Equatable {
    /// Migration identifier; mirrors the upstream doctor migration id where one exists.
    public var id: String
    /// Human-readable description of the change.
    public var message: String

    /// Creates a migration change.
    /// - Parameters:
    ///   - id: Migration identifier.
    ///   - message: Description.
    public init(id: String, message: String) {
        self.id = id
        self.message = message
    }
}

/// Static description of one ported migration (for parity diffs against upstream docs).
public struct ConfigMigrationDescriptor: Sendable, Equatable {
    /// Migration identifier (upstream id where one exists).
    public var id: String
    /// Short description.
    public var summary: String
    /// Whether the SDK applies the migration (`false` means it only reports an issue).
    public var isApplied: Bool
}

/// Swift port of the deterministic upstream doctor config migrations
/// (`docs/gateway/doctor/config-migrations.md`, `src/commands/doctor/shared/legacy-config-migrations*.ts`).
///
/// The migrator operates on the raw `openclaw.json` tree before typed decoding. It follows upstream's
/// universal rule: when the canonical key already has a value it wins and the legacy key is deleted.
/// Running it twice produces no further changes. Migrations that need plugin runtimes, the state
/// database or operator choices (account-binding repair, system-agent owner seeding, voice-call
/// migrations, QMD path import, tool-policy conflict merges) are reported through
/// ``unportedIssues(in:)`` instead of being applied.
public enum OpenClawConfigMigrator {
    /// Ported migrations in application order.
    public static let migrations: [ConfigMigrationDescriptor] = ConfigMigrationRules.all.map {
        ConfigMigrationDescriptor(id: $0.id, summary: $0.summary, isApplied: true)
    } + ConfigMigrationRules.unported.map {
        ConfigMigrationDescriptor(id: $0.id, summary: $0.summary, isApplied: false)
    }

    /// Applies every ported migration in place.
    /// - Parameters:
    ///   - root: Raw config object.
    ///   - environment: Environment for migrations that resolve default paths (the legacy first-agent
    ///     workspace pin uses `OPENCLAW_WORKSPACE_DIR`, `OPENCLAW_STATE_DIR`, `OPENCLAW_PROFILE`, `HOME`).
    /// - Returns: Applied changes (empty when the tree is already canonical).
    @discardableResult
    public static func migrate(
        _ root: inout [String: AnyCodable],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [ConfigMigrationChange] {
        var keyOrder = ConfigKeyOrder()
        return self.migrate(&root, keyOrder: &keyOrder, environment: environment)
    }

    /// Applies every ported migration in place and keeps the authored key order up to date.
    /// - Parameters:
    ///   - root: Raw config object.
    ///   - keyOrder: Authored key order; updated for moved and created objects.
    ///   - environment: Environment for migrations that resolve default paths.
    /// - Returns: Applied changes.
    @discardableResult
    public static func migrate(
        _ root: inout [String: AnyCodable],
        keyOrder: inout ConfigKeyOrder,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [ConfigMigrationChange] {
        let tree = MigrationObject(root, keyOrder: keyOrder)
        var changes: [ConfigMigrationChange] = []
        ConfigMigrationContext.$environment.withValue(environment) {
            for rule in ConfigMigrationRules.all {
                var messages: [String] = []
                rule.apply(tree, &messages)
                changes.append(contentsOf: messages.map { ConfigMigrationChange(id: rule.id, message: $0) })
            }
        }
        guard !changes.isEmpty else {
            return []
        }
        root = tree.dictionary
        var updatedOrder = ConfigKeyOrder()
        MigrationValue.object(tree).recordKeyOrder(into: &updatedOrder, path: [])
        keyOrder = updatedOrder
        return changes
    }

    /// Returns the changes a migration pass would apply, without mutating `root`.
    /// - Parameters:
    ///   - root: Raw config object.
    ///   - environment: Environment for migrations that resolve default paths.
    /// - Returns: Proposed changes.
    public static func proposedChanges(
        for root: [String: AnyCodable],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [ConfigMigrationChange] {
        var copy = root
        return self.migrate(&copy, environment: environment)
    }

    /// Legacy shapes the SDK does not migrate automatically (upstream rejects or migrates them elsewhere).
    /// - Parameter root: Raw config object.
    /// - Returns: Issues describing each unported legacy shape.
    public static func unportedIssues(in root: [String: AnyCodable]) -> [ConfigDecodeIssue] {
        let tree = MigrationObject(root)
        return ConfigMigrationRules.unported.flatMap { $0.detect(tree) }
    }

    /// Converts migration changes into decode issues (`legacyKey` for moves, `retiredKey` for removals).
    /// - Parameter changes: Migration changes.
    /// - Returns: One issue per change.
    public static func issues(for changes: [ConfigMigrationChange]) -> [ConfigDecodeIssue] {
        changes.map { change in
            let kind: ConfigDecodeIssue.Kind = change.message.hasPrefix("Removed") ? .retiredKey : .legacyKey
            return ConfigDecodeIssue(path: Self.path(fromMessage: change.message), message: change.message, kind: kind)
        }
    }

    private static func path(fromMessage message: String) -> String {
        // Messages start with "Moved <path> → ..." / "Removed <path> ..."; fall back to the root.
        let words = message.split(separator: " ", maxSplits: 2)
        guard words.count >= 2 else {
            return ""
        }
        let candidate = words[1].trimmingCharacters(in: CharacterSet(charactersIn: ".,;:()\""))
        return candidate.contains(where: { $0 == " " }) ? "" : candidate
    }
}

/// Per-pass inputs for migration rules (the rules keep the upstream `(raw, changes)` shape).
enum ConfigMigrationContext {
    /// Environment of the current migration pass.
    @TaskLocal static var environment: [String: String] = ProcessInfo.processInfo.environment
}

/// One migration rule applied to a mutable tree.
struct ConfigMigrationRule {
    let id: String
    let summary: String
    let apply: (MigrationObject, inout [String]) -> Void
}

/// A legacy shape that is detected and reported but not migrated.
struct ConfigUnportedMigration {
    let id: String
    let summary: String
    let detect: (MigrationObject) -> [ConfigDecodeIssue]
}
