import Foundation

/// Minimal filesystem helpers used by OpenClawKit core subsystems.
public enum OpenClawFileSystem {
    /// Resolves the current user's home directory across supported platforms.
    /// - Returns: Home directory URL.
    public static func resolveHomeDirectory() -> URL {
        #if os(iOS) || os(tvOS) || os(visionOS) || os(watchOS)
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #else
        FileManager.default.homeDirectoryForCurrentUser
        #endif
    }

    /// Ensures a directory exists, creating intermediate components.
    /// - Parameter url: Directory URL.
    public static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Reads file contents from disk.
    /// - Parameter url: File URL.
    /// - Returns: File contents.
    public static func readData(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    /// Writes file contents atomically.
    /// - Parameters:
    ///   - data: Bytes to persist.
    ///   - url: Destination file URL.
    public static func writeData(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
    }

    /// Ensures a private directory exists: missing directories (and missing intermediates) are created
    /// with `0700`; existing directories keep their permissions.
    /// - Parameter url: Directory URL.
    public static func ensurePrivateDirectory(_ url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        #if os(Windows)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #else
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        #endif
    }

    /// Restricts a state or config file to its owner (`0600`); best effort.
    /// - Parameter url: File URL.
    public static func restrictToOwner(_ url: URL) {
        #if !os(Windows)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
        #endif
    }

    /// Checks whether a file exists at the provided URL path.
    /// - Parameter url: File or directory URL.
    /// - Returns: `true` when path exists.
    public static func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
