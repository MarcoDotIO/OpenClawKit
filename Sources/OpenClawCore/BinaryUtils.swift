import Foundation

/// Utilities for resolving executable binaries from PATH.
public enum BinaryUtils {
    /// Ensures a named executable is available on PATH.
    /// - Parameters:
    ///   - name: Executable filename to search for.
    ///   - pathEnv: Optional PATH override.
    /// - Returns: Absolute path to first matching executable.
    public static func ensureBinary(_ name: String, pathEnv: String? = ProcessInfo.processInfo.environment["PATH"]) throws -> String {
        let candidates = (pathEnv ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(name).path }

        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        throw OpenClawCoreError.unavailable("Binary not found on PATH: \(name)")
    }
}
