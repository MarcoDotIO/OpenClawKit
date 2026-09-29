import Foundation

/// App Group used to share state between a host app and its extensions (share extension, widgets,
/// watch companion).
///
/// The SDK never assumes an App Group: upstream's `group.ai.openclawfoundation.app.shared` belongs to
/// the official OpenClaw app's team and cannot be used by third-party apps. Set the Info.plist key
/// `OpenClawAppGroupIdentifier` (in the host app *and* every extension) to your own App Group, or set
/// ``overrideIdentifier`` in code before first use. When neither is set, shared state falls back to
/// `UserDefaults.standard`, which extensions cannot see.
public enum OpenClawAppGroup {
    /// Info.plist key read by ``identifier``.
    public static let infoPlistKey = "OpenClawAppGroupIdentifier"

    /// App Group suite used by SDK releases before 2026.3.0; read once for migration.
    static let legacyIdentifier = "group.ai.openclaw.shared"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedOverride: String?

    /// Programmatic App Group identifier used when the Info.plist key is absent.
    public static var overrideIdentifier: String? {
        get { self.lock.withLock { self.storedOverride } }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.lock.withLock { self.storedOverride = trimmed?.isEmpty == false ? trimmed : nil }
        }
    }

    /// Effective App Group identifier: the trimmed Info.plist `OpenClawAppGroupIdentifier` value,
    /// else ``overrideIdentifier``, else `nil`.
    public static var identifier: String? {
        self.identifier(infoDictionaryValue: Bundle.main.object(forInfoDictionaryKey: self.infoPlistKey))
    }

    static func identifier(infoDictionaryValue: Any?) -> String? {
        let raw = (infoDictionaryValue as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? self.overrideIdentifier : raw
    }

    /// Shared defaults suite for ``identifier``, or `UserDefaults.standard` when no App Group is set.
    public static var sharedDefaults: UserDefaults {
        self.identifier.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }
}
