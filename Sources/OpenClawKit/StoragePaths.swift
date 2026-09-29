import Foundation

/// Resolves OpenClaw state directories (the root that holds `state/openclaw.sqlite`).
///
/// The SDK default is unchanged: an App Group container when the host opts in with the Info.plist
/// key `OpenClawAppGroupIdentifier`, otherwise `~/Library/Application Support/OpenClaw`. Sharing
/// state with the OpenClaw CLI/gateway on the same Mac is opt-in through ``cliShared(profile:environment:)``.
public enum OpenClawStateDirectory {
    /// The state directory the device identity and device-auth stores currently use.
    ///
    /// Resolving it counts as first use: ``DeviceIdentityStore/configureStateDirectory(_:)`` can no
    /// longer select a different directory afterwards.
    public static func resolved() -> URL {
        DeviceIdentityPaths.stateDirURL()
    }

    #if os(macOS)
    /// The state directory the OpenClaw CLI and gateway use for the current user.
    ///
    /// Mirrors upstream `resolveStateDir`: a non-empty `OPENCLAW_STATE_DIR` wins (with `~`/`~/`
    /// expanded against the effective home); otherwise `~/.openclaw`, or `~/.openclaw-<profile>` for a
    /// named profile (`profile`, else `OPENCLAW_PROFILE`; `default` means none). The effective home is
    /// `OPENCLAW_HOME` when set, else `HOME`, else the account home directory.
    ///
    /// Pass the result to ``DeviceIdentityStore/configureStateDirectory(_:)`` before first use, and to
    /// ``ExecApprovalsSQLiteStore``, to share one identity and one approvals document with the CLI.
    /// Sandboxed apps cannot reach this directory.
    public static func cliShared(
        profile: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        let home = self.effectiveHomeDirectory(environment: environment)
        if let override = self.normalized(environment["OPENCLAW_STATE_DIR"]) {
            return URL(fileURLWithPath: self.expandTilde(override, home: home), isDirectory: true)
                .standardizedFileURL
        }
        let profileName = self.normalized(profile ?? environment["OPENCLAW_PROFILE"])
            .flatMap { $0.lowercased() == "default" ? nil : $0 }
        let directoryName = profileName.map { ".openclaw-\($0)" } ?? ".openclaw"
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
            .standardizedFileURL
    }

    private static func effectiveHomeDirectory(environment: [String: String]) -> String {
        let osHome = self.normalized(environment["HOME"]) ?? NSHomeDirectory()
        guard let explicit = self.normalized(environment["OPENCLAW_HOME"]) else { return osHome }
        return self.expandTilde(explicit, home: osHome)
    }

    private static func expandTilde(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst() }
        return path
    }

    /// Trims a value and treats empty, `undefined`, and `null` as unset (upstream `normalizeHomeDirValue`).
    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, trimmed != "undefined", trimmed != "null"
        else { return nil }
        return trimmed
    }
    #endif
}

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
