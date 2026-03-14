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

    /// Checks whether a file exists at the provided URL path.
    /// - Parameter url: File or directory URL.
    /// - Returns: `true` when path exists.
    public static func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
