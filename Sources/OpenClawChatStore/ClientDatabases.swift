import CryptoKit
import Foundation
import GRDB
import OpenClawChatUI
import OSLog

// Ported from upstream OpenClaw 2026.9.6 `apps/shared/OpenClawKit/Sources/OpenClawChatUI/ClientDatabases.swift`.
// SDK additions: `defaultDirectoryURL(appGroupIdentifier:)` and private directory/file permissions
// (0700/0600 plus `completeUntilFirstUserAuthentication` where data protection exists).

private let databaseLogger = Logger(subsystem: "ai.openclaw", category: "OpenClawClientDatabases")

private struct GatewayCacheFormatMismatch: Error {}

private enum GatewayRemovalPhase: Int {
    case finalized = 0
    case staged = 1
    case committing = 2
    case scrubbing = 3
}

private struct RegisteredGatewayIDs {
    private let exactIDs: Set<Data>

    init(_ gatewayIDs: [String]) {
        self.exactIDs = Set(gatewayIDs.map { Data($0.utf8) })
    }

    func contains(_ gatewayID: String) -> Bool {
        self.exactIDs.contains(Data(gatewayID.utf8))
    }
}

/// Installation-wide storage for every paired gateway.
///
/// Gateway-derived snapshots and client-owned work deliberately live in
/// separate files. The cache may be rebuilt at any time; client state uses
/// forward migrations and is never erased as a cache-repair strategy.
///
/// Create one instance per installation (typically at app launch) and hand each
/// gateway its facade with ``store(gatewayID:)``. Every facade from one container
/// shares exactly one GRDB queue per database file.
///
/// Both databases observe GRDB's suspension notifications. A host that stores them in a shared
/// (app-group) container must call ``suspend()`` before the app is suspended and ``resume()`` when
/// it becomes active again (see ``defaultDirectoryURL(appGroupIdentifier:)``).
public final class OpenClawClientDatabases: @unchecked Sendable {
    /// File name of the disposable gateway snapshot cache.
    public static let gatewayCacheFilename = "gateway-cache.sqlite"
    /// File name of the durable client-state database (outbox, routing identity, watch journal).
    public static let clientStateFilename = "client-state.sqlite"
    static let gatewayCacheFormatVersion = 1

    /// Directory holding both database files.
    public let directoryURL: URL
    let cacheQueue: DatabaseQueue
    let stateQueue: DatabaseQueue
    let outboxChangeHub = OutboxChangeHub()
    /// The phone-side ledger for Watch-originated chat commands (shares the client-state queue).
    public let watchMessages: OpenClawWatchMessageJournal
    private let legacyDirectoryURLs: [URL]

    /// Opens (creating when needed) both databases in `directoryURL`.
    ///
    /// - Parameters:
    ///   - directoryURL: Directory for `gateway-cache.sqlite` and `client-state.sqlite`. It is
    ///     created with `0700` permissions; database files are restricted to `0600`.
    ///   - legacyDirectoryURLs: Older store locations whose per-gateway or shared
    ///     `chat-cache.sqlite` files are imported once and then removed.
    ///   - registeredGatewayIDs: The authoritative paired-gateway registry, when known. Pending
    ///     forget operations for registered gateways are cancelled; others finish erasure.
    /// - Throws: When a database cannot be opened or the client-state migrations fail.
    public init(
        directoryURL: URL,
        legacyDirectoryURLs: [URL] = [],
        registeredGatewayIDs: [String]? = nil) throws
    {
        self.directoryURL = directoryURL
        self.legacyDirectoryURLs = legacyDirectoryURLs
        try Self.securePrivateDirectory(directoryURL)

        let stateURL = directoryURL.appendingPathComponent(Self.clientStateFilename, isDirectory: false)
        let cacheURL = directoryURL.appendingPathComponent(Self.gatewayCacheFilename, isDirectory: false)
        // Another process sharing the directory (an app extension using the same app group) may
        // open and migrate the same files concurrently; coordinate first open and migration.
        let (stateQueue, cacheQueue) = try Self.coordinatingFirstOpen(of: directoryURL) {
            try (Self.openStateDatabase(at: stateURL), Self.openRepairableCacheDatabase(at: cacheURL))
        }
        self.stateQueue = stateQueue
        self.watchMessages = OpenClawWatchMessageJournal(queue: stateQueue)
        self.cacheQueue = cacheQueue
        Self.securePrivateDatabaseFiles(stateURL)
        Self.securePrivateDatabaseFiles(cacheURL)
        let exactRegisteredGatewayIDs = registeredGatewayIDs.map(RegisteredGatewayIDs.init)
        self.resolvePendingGatewayRemovals(registeredGatewayIDs: exactRegisteredGatewayIDs)
        importLegacyDatabases(registeredGatewayIDs: exactRegisteredGatewayIDs)
    }

    /// Suspends every GRDB database in this process that observes suspension notifications,
    /// including this container's two databases (GRDB's `Database.suspendNotification`).
    ///
    /// Required when the databases live in a shared app-group container: iOS terminates an app
    /// (`0xDEAD10CC`) that is suspended while holding a lock on a shared-container SQLite file.
    /// Call it when the app enters the background and before a background task expires. While
    /// suspended, reads keep working and writes fail without changing durable state, the same way
    /// an interrupted process does: queued commands stay queued and a later flush picks them up.
    public static func suspend() {
        NotificationCenter.default.post(name: Database.suspendNotification, object: nil)
    }

    /// Resumes databases suspended by ``suspend()`` (GRDB's `Database.resumeNotification`).
    ///
    /// Call it when the app becomes active and at the start of every background-mode callback
    /// (background fetch, Watch delivery, push handling) that may use the chat store.
    public static func resume() {
        NotificationCenter.default.post(name: Database.resumeNotification, object: nil)
    }

    /// Returns the gateway-scoped transcript cache and command outbox facade.
    ///
    /// Gateway identifiers are compared as exact UTF-8 bytes. The facade owns no SQLite connection.
    public func store(gatewayID: String) -> OpenClawChatSQLiteTranscriptCache {
        OpenClawChatSQLiteTranscriptCache(databases: self, gatewayID: gatewayID)
    }

    /// Retries one-time import and forgotten-gateway cleanup. iOS calls this
    /// again on foreground because old complete-protection files may have been
    /// unreadable during a locked background launch.
    public func retryLegacyImport(registeredGatewayIDs: [String]? = nil) {
        importLegacyDatabases(
            registeredGatewayIDs: registeredGatewayIDs.map(RegisteredGatewayIDs.init))
    }

    /// Reads the persisted session routing identity (`scope|mainKey|defaultAgentId`) for a gateway.
    public func loadSessionRoutingIdentity(
        gatewayID: String) -> OpenClawChatSessionRoutingIdentity?
    {
        do {
            return try self.stateQueue.read { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT scope, main_session_key, default_agent_id
                    FROM gateway_routing_identity WHERE gateway_id = ?
                    """,
                    arguments: [gatewayID])
                else { return nil }
                return OpenClawChatSessionRoutingIdentity(
                    scope: row["scope"],
                    mainSessionKey: row["main_session_key"],
                    defaultAgentID: row["default_agent_id"])
            }
        } catch {
            databaseLogger.error("client state routing read failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Removes one forgotten gateway without disturbing the other gateways in
    /// either installation-wide database.
    public func removeGatewayData(gatewayID: String) throws {
        try self.stageGatewayRemoval(gatewayID: gatewayID)
        try self.commitGatewayRemoval(gatewayID: gatewayID)
    }

    /// Stages the cross-owner forget transaction before pairing metadata is
    /// removed. No gateway payload is deleted until the registry owner commits.
    public func stageGatewayRemoval(gatewayID: String) throws {
        let gatewayHash = Self.gatewayIdentityHash(gatewayID)
        let existingPhase = try stateQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT cleanup_phase FROM forgotten_gateways WHERE gateway_hash = ?",
                arguments: [gatewayHash])
        }
        if existingPhase == GatewayRemovalPhase.committing.rawValue {
            try self.commitGatewayRemoval(gatewayID: gatewayID)
        } else if existingPhase == GatewayRemovalPhase.scrubbing.rawValue {
            try self.finishGatewayRemovalScrub(gatewayHash: gatewayHash)
        }
        try self.rejectPreservedSharedLegacyDatabase()
        try self.stateQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO forgotten_gateways(
                    gateway_hash, gateway_id, forgotten_at, cleanup_phase, restore_finalized
                ) VALUES (?, ?, ?, ?, 0)
                ON CONFLICT(gateway_hash) DO UPDATE SET
                    gateway_id = excluded.gateway_id,
                    forgotten_at = CASE
                        WHEN forgotten_gateways.cleanup_phase = 0
                            THEN forgotten_gateways.forgotten_at
                        ELSE excluded.forgotten_at
                    END,
                    cleanup_phase = excluded.cleanup_phase,
                    restore_finalized = CASE
                        WHEN forgotten_gateways.cleanup_phase = 0 THEN 1
                        ELSE forgotten_gateways.restore_finalized
                    END
                WHERE forgotten_gateways.cleanup_phase NOT IN (2, 3)
                """,
                arguments: [
                    gatewayHash,
                    gatewayID,
                    Date().timeIntervalSince1970,
                    GatewayRemovalPhase.staged.rawValue,
                ])
        }
    }

    /// Commits a staged forget after the registry owner has removed pairing
    /// metadata. A failed commit remains staged for startup reconciliation.
    public func commitGatewayRemoval(gatewayID: String) throws {
        let gatewayHash = Self.gatewayIdentityHash(gatewayID)
        let existingPhase = try stateQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT cleanup_phase FROM forgotten_gateways WHERE gateway_hash = ?",
                arguments: [gatewayHash])
        }
        if existingPhase == GatewayRemovalPhase.scrubbing.rawValue {
            try self.finishGatewayRemovalScrub(gatewayHash: gatewayHash)
            return
        }
        // Mark the irreversible phase in the same transaction that deletes
        // client state. Recovery must finish this phase even if pairing was
        // preserved (for example, a cache-only purge).
        try self.stateQueue.write { db in
            guard let phase = try Int.fetchOne(
                db,
                sql: """
                SELECT cleanup_phase FROM forgotten_gateways
                WHERE gateway_hash = ? AND gateway_id = ?
                """,
                arguments: [gatewayHash, gatewayID]),
                phase == GatewayRemovalPhase.staged.rawValue ||
                phase == GatewayRemovalPhase.committing.rawValue
            else {
                throw DatabaseError(message: "gateway removal was not staged")
            }
            if phase == GatewayRemovalPhase.staged.rawValue {
                try db.execute(
                    sql: """
                    UPDATE forgotten_gateways SET cleanup_phase = ?
                    WHERE gateway_hash = ? AND gateway_id = ? AND cleanup_phase = ?
                    """,
                    arguments: [
                        GatewayRemovalPhase.committing.rawValue,
                        gatewayHash,
                        gatewayID,
                        GatewayRemovalPhase.staged.rawValue,
                    ])
            }
            try db.execute(sql: "DELETE FROM outbox_commands WHERE gateway_id = ?", arguments: [gatewayID])
            try db.execute(sql: "DELETE FROM outbox_branch_scopes WHERE gateway_id = ?", arguments: [gatewayID])
            try db.execute(
                sql: "DELETE FROM gateway_routing_identity WHERE gateway_id = ?",
                arguments: [gatewayID])
        }
        try self.cacheQueue.write { db in
            try db.execute(
                sql: "DELETE FROM cached_agent_sessions WHERE gateway_id = ?",
                arguments: [gatewayID])
            try db.execute(
                sql: "DELETE FROM cached_session_rosters WHERE gateway_id = ?",
                arguments: [gatewayID])
            try db.execute(sql: "DELETE FROM cached_sessions WHERE gateway_id = ?", arguments: [gatewayID])
            try db.execute(sql: "DELETE FROM cached_transcripts WHERE gateway_id = ?", arguments: [gatewayID])
        }
        try self.removeLegacyGatewayDatabaseFiles(gatewayID: gatewayID)
        // secure_delete scrubs deleted cells; truncating both WALs removes
        // pre-delete frames while preserving every other gateway's rows.
        _ = try self.cacheQueue.writeWithoutTransaction { db in
            try db.checkpoint(.truncate)
        }
        _ = try self.stateQueue.writeWithoutTransaction { db in
            try db.checkpoint(.truncate)
        }
        try self.stateQueue.write { db in
            try db.execute(
                sql: """
                UPDATE forgotten_gateways
                SET gateway_id = NULL, cleanup_phase = 3, restore_finalized = 0
                WHERE gateway_hash = ? AND cleanup_phase = 2
                """,
                arguments: [gatewayHash])
        }
        try self.finishGatewayRemovalScrub(gatewayHash: gatewayHash)
    }

    /// Cancels an uncommitted forget when the registry owner could not remove
    /// the pairing. Since staging deletes no payload, the gateway stays intact.
    public func cancelGatewayRemoval(gatewayID: String) throws {
        let gatewayHash = Self.gatewayIdentityHash(gatewayID)
        try self.stateQueue.write { db in
            // A repeated forget temporarily expands a finalized hash-only
            // tombstone. Cancellation must collapse it again, not erase it.
            try db.execute(
                sql: """
                UPDATE forgotten_gateways
                SET gateway_id = NULL, cleanup_phase = 0, restore_finalized = 0
                WHERE gateway_hash = ? AND gateway_id = ?
                    AND cleanup_phase = 1 AND restore_finalized = 1
                """,
                arguments: [gatewayHash, gatewayID])
            try db.execute(
                sql: """
                DELETE FROM forgotten_gateways
                WHERE gateway_hash = ? AND gateway_id = ?
                    AND cleanup_phase = 1 AND restore_finalized = 0
                """,
                arguments: [gatewayHash, gatewayID])
        }
        _ = try self.stateQueue.writeWithoutTransaction { db in
            try db.checkpoint(.truncate)
        }
    }

    /// Resolves a crash between staging, registry removal, and commit. A still
    /// registered gateway cancels safely; an absent gateway finishes erasure.
    /// Without an authoritative registry, only irreversible commits advance;
    /// cancelable stages remain untouched.
    public func resolvePendingGatewayRemovals(registeredGatewayIDs: [String]? = nil) {
        self.resolvePendingGatewayRemovals(
            registeredGatewayIDs: registeredGatewayIDs.map(RegisteredGatewayIDs.init))
    }

    private func resolvePendingGatewayRemovals(registeredGatewayIDs: RegisteredGatewayIDs?) {
        let pending: [Row]
        do {
            pending = try self.stateQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT gateway_hash, gateway_id, cleanup_phase FROM forgotten_gateways
                    WHERE cleanup_phase IN (1, 2, 3)
                    ORDER BY gateway_hash
                    """)
            }
        } catch {
            databaseLogger.error(
                "pending gateway removal read failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        for row in pending {
            let gatewayHash: String = row["gateway_hash"]
            let gatewayID: String? = row["gateway_id"]
            let phase: Int = row["cleanup_phase"]
            do {
                if phase == GatewayRemovalPhase.scrubbing.rawValue {
                    try self.finishGatewayRemovalScrub(gatewayHash: gatewayHash)
                } else if phase == GatewayRemovalPhase.committing.rawValue, let gatewayID {
                    try self.commitGatewayRemoval(gatewayID: gatewayID)
                } else if let gatewayID, let registeredGatewayIDs {
                    if registeredGatewayIDs.contains(gatewayID) {
                        try self.cancelGatewayRemoval(gatewayID: gatewayID)
                    } else {
                        try self.commitGatewayRemoval(gatewayID: gatewayID)
                    }
                }
            } catch {
                let reason = error.localizedDescription
                databaseLogger.error(
                    "pending removal \(gatewayHash.prefix(12), privacy: .public) failed: \(reason, privacy: .public)")
            }
        }
    }

    /// Fail closed while an irreversible or cancelable removal marker still
    /// exists. Callers use this after recovery before exposing a new writable
    /// facade for the same gateway.
    public func hasPendingGatewayRemoval(gatewayID: String) -> Bool {
        do {
            let gatewayHash = Self.gatewayIdentityHash(gatewayID)
            return try self.stateQueue.read { db in
                try Int.fetchOne(
                    db,
                    sql: """
                    SELECT 1 FROM forgotten_gateways
                    WHERE gateway_hash = ? AND cleanup_phase IN (1, 2, 3)
                    """,
                    arguments: [gatewayHash]) != nil
            }
        } catch {
            let reason = error.localizedDescription
            databaseLogger.error(
                "pending gateway removal check failed: \(reason, privacy: .public)")
            return true
        }
    }

    /// A hash-only marker survives until the checkpoint that physically drops
    /// old WAL frames. If that checkpoint fails, startup can retry without
    /// retaining the raw gateway identifier.
    private func finishGatewayRemovalScrub(gatewayHash: String) throws {
        _ = try self.stateQueue.writeWithoutTransaction { db in
            try db.checkpoint(.truncate)
        }
        try self.stateQueue.write { db in
            try db.execute(
                sql: """
                UPDATE forgotten_gateways SET cleanup_phase = 0
                WHERE gateway_hash = ? AND cleanup_phase = 3
                """,
                arguments: [gatewayHash])
        }
    }

    /// Closes both installation-wide handles before a full reset removes the
    /// files. Gateway-scoped deletion keeps the shared handles open.
    public func close() throws {
        self.outboxChangeHub.finish()
        try self.cacheQueue.close()
        try self.stateQueue.close()
    }

    /// Startup-only removal after all store/container references have been
    /// released. Sidecars are named explicitly so WAL pages cannot survive a
    /// full onboarding reset.
    public static func removeDatabaseFiles(in directoryURL: URL) throws {
        for filename in [self.gatewayCacheFilename, self.clientStateFilename] {
            try self.removeDatabaseFilesChecked(
                at: directoryURL.appendingPathComponent(filename, isDirectory: false))
        }
        for legacyURL in legacyDatabaseURLs(in: directoryURL) {
            try self.removeDatabaseFilesChecked(at: legacyURL)
        }
    }

    static func removeDatabaseFiles(at databaseURL: URL) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: databaseURL)
        for suffix in ["-wal", "-shm", "-journal"] {
            try? fileManager.removeItem(at: URL(fileURLWithPath: databaseURL.path + suffix))
        }
    }

    static func legacyPerGatewayDatabaseURL(gatewayID: String, directoryURL: URL) -> URL {
        directoryURL.appendingPathComponent("\(self.gatewayIdentityHash(gatewayID)).sqlite", isDirectory: false)
    }

    static func gatewayIdentityHash(_ gatewayID: String) -> String {
        SHA256.hash(data: Data(gatewayID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func removeDatabaseFilesChecked(at databaseURL: URL) throws {
        let fileManager = FileManager.default
        for url in [databaseURL] + ["-wal", "-shm", "-journal"].map({ suffix in
            URL(fileURLWithPath: databaseURL.path + suffix)
        }) where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func removeLegacyGatewayDatabaseFiles(gatewayID: String) throws {
        let directories = Set([directoryURL] + self.legacyDirectoryURLs)
        for directoryURL in directories {
            try Self.removeDatabaseFilesChecked(at: Self.legacyPerGatewayDatabaseURL(
                gatewayID: gatewayID,
                directoryURL: directoryURL))
        }
    }

    private func rejectPreservedSharedLegacyDatabase() throws {
        let directories = Set([directoryURL] + self.legacyDirectoryURLs)
        guard directories.contains(where: { directoryURL in
            FileManager.default.fileExists(
                atPath: directoryURL.appendingPathComponent("chat-cache.sqlite").path)
        }) else { return }
        // A shared legacy file may contain several gateways. If startup could
        // not import it, targeted erasure cannot be proven without data loss.
        throw DatabaseError(message: "shared legacy database blocks targeted gateway removal")
    }
}

extension OpenClawClientDatabases {
    // MARK: - Schema ownership

    private static func configuration(label: String) -> Configuration {
        var configuration = Configuration()
        configuration.label = label
        configuration.journalMode = .wal
        configuration.busyMode = .timeout(5)
        // No effect until a host posts GRDB's suspend notification (see `suspend()`); required so
        // app-group hosts can release shared-container locks before iOS suspends the process.
        configuration.observesSuspensionNotifications = true
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA secure_delete = ON")
        }
        return configuration
    }

    private static func openStateDatabase(at url: URL) throws -> DatabaseQueue {
        let queue = try DatabaseQueue(
            path: url.path,
            configuration: self.configuration(label: "OpenClaw.client-state"))
        var migrator = DatabaseMigrator()
        self.registerClientStateMigrationsV1ThroughV5(&migrator)
        self.registerClientStateMigrationsV6ThroughV8(&migrator)
        self.registerWatchMessageJournalMigration(&migrator)
        try migrator.migrate(queue)
        return queue
    }

    /// Runs `open` under a coordinated write of `directoryURL`, so processes sharing the
    /// directory never create or migrate the same databases at the same time.
    static func coordinatingFirstOpen<T>(of directoryURL: URL, _ open: () throws -> T) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<T, Error>?
        coordinator.coordinate(
            writingItemAt: directoryURL,
            options: .forMerging,
            error: &coordinationError)
        { _ in
            result = Result { try open() }
        }
        if let result { return try result.get() }
        throw coordinationError ?? CocoaError(.fileWriteUnknown)
    }

    /// Lock contention or suspension from another connection (possibly another process sharing
    /// the directory): the cache is healthy, so it must not be deleted as a repair.
    static func isContentionError(_ error: Error) -> Bool {
        guard let error = error as? DatabaseError else { return false }
        switch error.resultCode {
        case .SQLITE_BUSY, .SQLITE_LOCKED, .SQLITE_INTERRUPT, .SQLITE_ABORT:
            return true
        default:
            return false
        }
    }

    private static func openRepairableCacheDatabase(at url: URL) throws -> DatabaseQueue {
        do {
            let queue = try DatabaseQueue(
                path: url.path,
                configuration: self.configuration(label: "OpenClaw.gateway-cache"))
            try self.prepareCacheSchema(queue)
            return queue
        } catch where self.isContentionError(error) {
            throw error
        } catch {
            // This file contains gateway snapshots only. A format mismatch or
            // corruption is repaired by rebuilding, never by migrating rows.
            self.removeDatabaseFiles(at: url)
            let queue = try DatabaseQueue(
                path: url.path,
                configuration: self.configuration(label: "OpenClaw.gateway-cache"))
            try self.prepareCacheSchema(queue)
            return queue
        }
    }

    private static func prepareCacheSchema(_ queue: DatabaseQueue) throws {
        try queue.write { db in
            let currentVersion: Int? = if try db.tableExists("cache_metadata") {
                try Int.fetchOne(db, sql: "SELECT format_version FROM cache_metadata WHERE id = 1")
            } else {
                nil
            }
            if let currentVersion, currentVersion != self.gatewayCacheFormatVersion {
                throw GatewayCacheFormatMismatch()
            }
            if currentVersion == nil,
               try db.tableExists("cached_sessions") ||
               db.tableExists("cached_transcripts") ||
               db.tableExists("cached_messages")
            {
                throw GatewayCacheFormatMismatch()
            }
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS cache_metadata(
                id INTEGER NOT NULL PRIMARY KEY CHECK(id = 1),
                format_version INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS cached_sessions(
                gateway_id TEXT NOT NULL,
                session_key TEXT NOT NULL,
                position INTEGER NOT NULL,
                updated_at REAL NOT NULL,
                payload_json TEXT NOT NULL,
                PRIMARY KEY(gateway_id, session_key)
            );
            CREATE INDEX IF NOT EXISTS cached_sessions_order
                ON cached_sessions(gateway_id, position);
            CREATE TABLE IF NOT EXISTS cached_transcripts(
                gateway_id TEXT NOT NULL,
                session_key TEXT NOT NULL,
                agent_id TEXT NOT NULL,
                updated_at REAL NOT NULL,
                PRIMARY KEY(gateway_id, session_key, agent_id)
            );
            CREATE INDEX IF NOT EXISTS cached_transcripts_recency
                ON cached_transcripts(gateway_id, updated_at DESC);
            CREATE TABLE IF NOT EXISTS cached_messages(
                gateway_id TEXT NOT NULL,
                session_key TEXT NOT NULL,
                agent_id TEXT NOT NULL,
                position INTEGER NOT NULL,
                timestamp_ms REAL,
                idempotency_key TEXT,
                payload_json TEXT NOT NULL,
                PRIMARY KEY(gateway_id, session_key, agent_id, position),
                FOREIGN KEY(gateway_id, session_key, agent_id)
                    REFERENCES cached_transcripts(gateway_id, session_key, agent_id)
                    ON DELETE CASCADE
            );
            INSERT OR REPLACE INTO cache_metadata(id, format_version)
                VALUES (1, \(self.gatewayCacheFormatVersion));
            """)
            try self.ensureAgentSessionCacheSchema(db)
        }
    }

    /// Session rosters are disposable cache state, so this additive surface is
    /// lazily ensured without advancing the cache format or erasing transcripts.
    static func ensureAgentSessionCacheSchema(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS cached_session_rosters(
            gateway_id TEXT NOT NULL,
            agent_id TEXT NOT NULL,
            last_used_at REAL NOT NULL,
            PRIMARY KEY(gateway_id, agent_id)
        );
        CREATE TABLE IF NOT EXISTS cached_agent_sessions(
            gateway_id TEXT NOT NULL,
            agent_id TEXT NOT NULL,
            session_key TEXT NOT NULL,
            position INTEGER NOT NULL,
            updated_at REAL NOT NULL,
            payload_json TEXT NOT NULL,
            PRIMARY KEY(gateway_id, agent_id, session_key),
            FOREIGN KEY(gateway_id, agent_id)
                REFERENCES cached_session_rosters(gateway_id, agent_id)
                ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS cached_agent_sessions_order
            ON cached_agent_sessions(gateway_id, agent_id, position);
        """)
    }
}

extension OpenClawClientDatabases {
    // MARK: - One-time legacy import

    private struct LegacySnapshot {
        var commands: [LegacyCommand]
        var routingIdentities: [LegacyRoutingIdentity]
    }

    private struct LegacyCommand {
        var gatewayID: String
        var id: String
        var sessionKey: String
        var deliverySessionKey: String
        var routingContract: String
        var agentID: String
        var text: String
        var attachments: [OpenClawChatOutboxAttachment]
        var thinking: String
        var createdAt: Double
        var status: String
        var retryCount: Int
        var lastError: String
    }

    private struct LegacyRoutingIdentity {
        var gatewayID: String
        var scope: String
        var mainSessionKey: String
        var defaultAgentID: String
        var updatedAt: Double
    }

    private func importLegacyDatabases(registeredGatewayIDs: RegisteredGatewayIDs?) {
        let directories = [directoryURL] + self.legacyDirectoryURLs
        let legacyURLs = Set(directories.flatMap(Self.legacyDatabaseURLs(in:)))
        for legacyURL in legacyURLs.sorted(by: { $0.path < $1.path }) {
            do {
                guard let snapshot = try Self.readLegacySnapshot(at: legacyURL) else { continue }
                let legacyGatewayIDs = Set(
                    snapshot.commands.map(\.gatewayID) + snapshot.routingIdentities.map(\.gatewayID))
                let ownedSnapshot: LegacySnapshot = if let registeredGatewayIDs {
                    LegacySnapshot(
                        commands: snapshot.commands.filter {
                            registeredGatewayIDs.contains($0.gatewayID)
                        },
                        routingIdentities: snapshot.routingIdentities.filter {
                            registeredGatewayIDs.contains($0.gatewayID)
                        })
                } else {
                    snapshot
                }
                try self.writeLegacySnapshot(ownedSnapshot)
                // Preserve bytes for unregistered gateways rather than
                // importing or destroying state whose ownership is unknown.
                let forgottenGatewayHashes = try forgottenGatewayHashesForLegacyImport()
                let allLegacyGatewaysAccountedFor = legacyGatewayIDs.allSatisfy { gatewayID in
                    registeredGatewayIDs?.contains(gatewayID) == true ||
                        forgottenGatewayHashes.contains(Self.gatewayIdentityHash(gatewayID))
                }
                if registeredGatewayIDs == nil || allLegacyGatewaysAccountedFor {
                    Self.removeDatabaseFiles(at: legacyURL)
                }
            } catch {
                // The new stores remain usable, but unknown/corrupt durable
                // bytes stay untouched for a future compatible importer.
                let filename = legacyURL.lastPathComponent
                let reason = error.localizedDescription
                databaseLogger.error(
                    "legacy import failed: \(filename, privacy: .public): \(reason, privacy: .public)")
            }
        }
    }

    private static func legacyDatabaseURLs(in directoryURL: URL) -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        else { return [] }
        return urls.filter { url in
            let name = url.lastPathComponent
            guard name.hasSuffix(".sqlite"),
                  name != self.gatewayCacheFilename,
                  name != self.clientStateFilename
            else { return false }
            if name == "chat-cache.sqlite" {
                return true
            }
            let stem = String(name.dropLast(".sqlite".count))
            return stem.count == 64 && stem.allSatisfy(\.isHexDigit)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func readLegacySnapshot(at url: URL) throws -> LegacySnapshot? {
        var configuration = Configuration()
        configuration.label = "OpenClaw.legacy-chat-import"
        configuration.readonly = true
        configuration.busyMode = .timeout(5)
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        return try queue.read { db in
            let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
            guard (1...6).contains(version) else { return nil }

            var snapshot = LegacySnapshot(commands: [], routingIdentities: [])
            if try db.tableExists("outbox_commands") {
                snapshot.commands = try self.readLegacyCommands(db)
            }
            if try db.tableExists("gateway_routing_identity") {
                let rows = try Row.fetchAll(db, sql: """
                SELECT gateway_id, scope, main_session_key, default_agent_id, updated_at
                FROM gateway_routing_identity
                """)
                snapshot.routingIdentities = rows.map { row in
                    LegacyRoutingIdentity(
                        gatewayID: row["gateway_id"],
                        scope: row["scope"],
                        mainSessionKey: row["main_session_key"],
                        defaultAgentID: row["default_agent_id"],
                        updatedAt: row["updated_at"])
                }
            }
            return snapshot
        }
    }

    private static func readLegacyCommands(_ db: Database) throws -> [LegacyCommand] {
        let columns = try Set(db.columns(in: "outbox_commands").map(\.name))
        func expression(_ name: String, fallback: String) -> String {
            columns.contains(name) ? name : fallback
        }
        let rows = try Row.fetchAll(db, sql: """
        SELECT client_uuid, gateway_id, session_key,
               \(expression("delivery_session_key", fallback: "''")) AS delivery_session_key,
               \(expression("routing_contract", fallback: "''")) AS routing_contract,
               \(expression("agent_id", fallback: "''")) AS agent_id,
               text,
               \(expression("attachments", fallback: "'[]'")) AS attachments,
               thinking, created_at, status, retry_count, last_error
        FROM outbox_commands ORDER BY created_at, id
        """)
        return try rows.map { row in
            let attachmentsJSON: String = row["attachments"]
            let attachments = try JSONDecoder().decode(
                [OpenClawChatOutboxAttachment].self,
                from: Data(attachmentsJSON.utf8))
            let originalStatus: String = row["status"]
            guard OpenClawChatOutboxCommand.Status(rawValue: originalStatus) != nil else {
                throw DatabaseError(message: "unknown legacy outbox status")
            }
            let routingContract: String = row["routing_contract"]
            let originalError: String = row["last_error"]
            let lacksVerifiedTarget = routingContract.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let status = lacksVerifiedTarget ? OpenClawChatOutboxCommand.Status.failed.rawValue : originalStatus
            let lastError: String = if lacksVerifiedTarget {
                if originalStatus == OpenClawChatOutboxCommand.Status.sending.rawValue ||
                    originalStatus == OpenClawChatOutboxCommand.Status.awaitingConfirmation.rawValue ||
                    originalError == OpenClawChatOutboxErrorCode.unconfirmed
                {
                    OpenClawChatOutboxErrorCode.unconfirmed
                } else {
                    OpenClawChatOutboxErrorCode.unknownTarget
                }
            } else {
                originalError
            }
            return LegacyCommand(
                gatewayID: row["gateway_id"],
                id: row["client_uuid"],
                sessionKey: row["session_key"],
                deliverySessionKey: lacksVerifiedTarget ? "" : row["delivery_session_key"],
                routingContract: lacksVerifiedTarget ? "" : routingContract,
                agentID: lacksVerifiedTarget ? "" : row["agent_id"],
                text: row["text"],
                attachments: attachments,
                thinking: row["thinking"],
                createdAt: row["created_at"],
                status: status,
                retryCount: row["retry_count"],
                lastError: lastError)
        }
    }

    private func writeLegacySnapshot(_ snapshot: LegacySnapshot) throws {
        try self.stateQueue.write { db in
            let forgottenGatewayHashes = try Set(String.fetchAll(
                db,
                sql: """
                SELECT gateway_hash FROM forgotten_gateways
                WHERE cleanup_phase IN (0, 2, 3) OR restore_finalized = 1
                """))
            for identity in snapshot.routingIdentities
                where !forgottenGatewayHashes.contains(Self.gatewayIdentityHash(identity.gatewayID))
            {
                try db.execute(
                    sql: """
                    INSERT INTO gateway_routing_identity(
                        gateway_id, scope, main_session_key, default_agent_id, updated_at
                    ) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(gateway_id) DO UPDATE SET
                        scope = excluded.scope,
                        main_session_key = excluded.main_session_key,
                        default_agent_id = excluded.default_agent_id,
                        updated_at = excluded.updated_at
                    WHERE excluded.updated_at > gateway_routing_identity.updated_at
                    """,
                    arguments: [
                        identity.gatewayID,
                        identity.scope,
                        identity.mainSessionKey,
                        identity.defaultAgentID,
                        identity.updatedAt,
                    ])
            }
            for command in snapshot.commands
                where !forgottenGatewayHashes.contains(Self.gatewayIdentityHash(command.gatewayID))
            {
                try Self.writeLegacyCommand(db, command)
            }
        }
    }

    private static func writeLegacyCommand(_ db: Database, _ command: LegacyCommand) throws {
        let attachmentBytes = command.attachments.reduce(0) { $0 + $1.data.count }
        try db.execute(
            sql: """
            INSERT OR IGNORE INTO outbox_commands(
                gateway_id, client_uuid, session_key, delivery_session_key,
                routing_contract, agent_id, text, thinking, created_at,
                status, retry_count, last_error, attachment_bytes
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                command.gatewayID,
                command.id,
                command.sessionKey,
                command.deliverySessionKey,
                command.routingContract,
                command.agentID,
                command.text,
                command.thinking,
                command.createdAt,
                command.status,
                command.retryCount,
                command.lastError,
                attachmentBytes,
            ])
        guard db.changesCount > 0 else { return }
        try db.execute(
            sql: """
            INSERT OR IGNORE INTO outbox_branch_scopes(
                gateway_id, session_key, agent_id, branch_epoch, needs_reconciliation
            ) VALUES (?, ?, ?, 0, 1)
            """,
            arguments: [command.gatewayID, command.sessionKey, command.agentID])
        for (position, attachment) in command.attachments.enumerated() {
            try db.execute(
                sql: """
                INSERT INTO outbox_attachments(
                    gateway_id, command_id, position, type, mime_type,
                    file_name, payload, duration_seconds
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    command.gatewayID,
                    command.id,
                    position,
                    attachment.type,
                    attachment.mimeType,
                    attachment.fileName,
                    attachment.data,
                    attachment.durationSeconds,
                ])
        }
    }

    private func forgottenGatewayHashesForLegacyImport() throws -> Set<String> {
        try self.stateQueue.read { db in
            try Set(String.fetchAll(
                db,
                sql: """
                SELECT gateway_hash FROM forgotten_gateways
                WHERE cleanup_phase IN (0, 2, 3) OR restore_finalized = 1
                """))
        }
    }
}
