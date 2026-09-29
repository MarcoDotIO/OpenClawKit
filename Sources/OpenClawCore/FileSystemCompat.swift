import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

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

    /// Writes file contents atomically with owner-only permissions: the bytes go to a temporary file
    /// created with `0600` (so they are never readable by others, not even briefly) that then
    /// replaces `url`.
    /// - Parameters:
    ///   - data: Bytes to persist.
    ///   - url: Destination file URL.
    public static func writePrivateData(_ data: Data, to url: URL) throws {
        #if os(Windows)
        try self.writeData(data, to: url)
        #else
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else {
            throw OpenClawCoreError.unavailable("Could not create \(temporary.lastPathComponent) (errno \(errno))")
        }
        var committed = false
        defer {
            if !committed {
                _ = unlink(temporary.path)
            }
        }
        let written = data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let count = write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        let synced = fsync(descriptor) == 0
        _ = close(descriptor)
        guard written, synced else {
            throw OpenClawCoreError.unavailable("Could not write \(url.lastPathComponent)")
        }
        guard rename(temporary.path, url.path) == 0 else {
            throw OpenClawCoreError.unavailable("Could not replace \(url.lastPathComponent) (errno \(errno))")
        }
        committed = true
        #endif
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
