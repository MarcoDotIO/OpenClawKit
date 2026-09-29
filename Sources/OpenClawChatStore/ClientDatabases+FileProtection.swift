import Foundation
import OSLog

private let protectionLogger = Logger(subsystem: "ai.openclaw", category: "OpenClawClientDatabases")

// SDK addition (not in upstream): the store directory and its SQLite files carry the same
// private permissions and data-protection class as OpenClawNativeState. The class is
// `completeUntilFirstUserAuthentication` so background launches (outbox flushes, Watch
// deliveries) can open the databases after the first unlock.

extension OpenClawClientDatabases {
    /// Default store directory: `Application Support/OpenClawKit/ChatStore`, or the same path
    /// inside the app-group container when `appGroupIdentifier` is set.
    ///
    /// The directory is not created; ``init(directoryURL:legacyDirectoryURLs:registeredGatewayIDs:)``
    /// creates it with private permissions.
    ///
    /// The app container (the default, and upstream's only placement) is the safe choice. An
    /// app-group directory shared with another process has extra host obligations:
    /// - Call ``suspend()`` when the app enters the background (and before background tasks expire)
    ///   and ``resume()`` when it becomes active and at the start of every background-mode callback.
    ///   Otherwise iOS can terminate the app (`0xDEAD10CC`) for holding a SQLite lock on a
    ///   shared-container file at suspension.
    /// - Live change notifications (the outbox `changes()` stream and view-model refreshes) only
    ///   reach the process that made the change. Another process sees queued commands and cached
    ///   transcripts on its next load, so reload after it hands off work.
    /// - First open and migration are coordinated with `NSFileCoordinator`, so concurrent launches
    ///   do not race the schema; writes wait up to five seconds for another process's lock.
    /// - Throws: `CocoaError(.fileNoSuchFile)` when the app-group container is unavailable (for
    ///   example, a missing entitlement), or the Application Support lookup error.
    public static func defaultDirectoryURL(appGroupIdentifier: String? = nil) throws -> URL {
        let fileManager = FileManager.default
        let baseURL: URL
        if let appGroupIdentifier {
            guard let containerURL = fileManager.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupIdentifier)
            else {
                throw CocoaError(.fileNoSuchFile, userInfo: [
                    NSLocalizedDescriptionKey: "App group container \(appGroupIdentifier) is unavailable.",
                ])
            }
            baseURL = containerURL
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        } else {
            baseURL = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true)
        }
        return baseURL
            .appendingPathComponent("OpenClawKit", isDirectory: true)
            .appendingPathComponent("ChatStore", isDirectory: true)
    }

    /// Creates the directory (0700) and applies the data-protection class where it exists.
    static func securePrivateDirectory(_ url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #if os(iOS) || os(watchOS) || os(visionOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        try fileManager.setAttributes(attributes, ofItemAtPath: url.path)
    }

    /// Restricts a database and its sidecars to the owner (0600) with the data-protection class.
    ///
    /// SQLite creates `-wal`/`-shm`/`-journal` files with the database file's permissions, so
    /// securing the main file right after open also covers sidecars created later.
    static func securePrivateDatabaseFiles(_ databaseURL: URL) {
        let fileManager = FileManager.default
        for url in [databaseURL] + ["-wal", "-shm", "-journal"].map({ suffix in
            URL(fileURLWithPath: databaseURL.path + suffix, isDirectory: false)
        }) where fileManager.fileExists(atPath: url.path) {
            var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
            #if os(iOS) || os(watchOS) || os(visionOS)
            attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
            #endif
            do {
                try fileManager.setAttributes(attributes, ofItemAtPath: url.path)
            } catch {
                // A sidecar can vanish between the probe and chmod; the private directory
                // still fences access, so a failed chmod never blocks opening the store.
                protectionLogger.error(
                    "chat store permission update failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
