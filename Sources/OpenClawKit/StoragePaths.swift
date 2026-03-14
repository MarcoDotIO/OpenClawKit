import Foundation

/// Storage path helpers for OpenClaw node-hosted canvas and cache artifacts.
public enum OpenClawNodeStorage {
    /// Returns the app support directory used for durable OpenClaw data.
    public static func appSupportDir() throws -> URL {
        let base = FileManager().urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let base else {
            throw NSError(domain: "OpenClawNodeStorage", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Application Support directory unavailable",
            ])
        }
        return base.appendingPathComponent("OpenClaw", isDirectory: true)
    }

    /// Returns the per-session directory used for persistent canvas state.
    public static func canvasRoot(sessionKey: String) throws -> URL {
        let root = try appSupportDir().appendingPathComponent("canvas", isDirectory: true)
        let safe = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = safe.isEmpty ? "main" : safe
        return root.appendingPathComponent(session, isDirectory: true)
    }

    /// Returns the caches directory used for transient OpenClaw artifacts.
    public static func cachesDir() throws -> URL {
        let base = FileManager().urls(for: .cachesDirectory, in: .userDomainMask).first
        guard let base else {
            throw NSError(domain: "OpenClawNodeStorage", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Caches directory unavailable",
            ])
        }
        return base.appendingPathComponent("OpenClaw", isDirectory: true)
    }

    /// Returns the per-session cache directory used for captured canvas snapshots.
    public static func canvasSnapshotsRoot(sessionKey: String) throws -> URL {
        let root = try cachesDir().appendingPathComponent("canvas-snapshots", isDirectory: true)
        let safe = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = safe.isEmpty ? "main" : safe
        return root.appendingPathComponent(session, isDirectory: true)
    }
}
