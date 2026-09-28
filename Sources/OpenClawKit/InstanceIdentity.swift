import Foundation

// Branch on the OS, never on `canImport(UIKit)`: UIKit also exists on watchOS 27, tvOS and
// visionOS, and reporting those as "iOS" makes the gateway grant iOS default node commands.
#if os(iOS) || os(tvOS) || os(visionOS)
import UIKit
#elseif os(watchOS)
import WatchKit
#endif

/// Interface idiom of an iOS/iPadOS host, reduced to the values the gateway distinguishes.
enum AppleMobileInterfaceIdiom: Sendable {
    case phone
    case pad
    case other
}

/// Platform metadata advertised by iOS/iPadOS hosts (upstream `AppleMobileInstanceMetadata`).
struct AppleMobileInstanceMetadata: Equatable, Sendable {
    let platformString: String
    let deviceFamily: String
    let modelIdentifier: String?

    static func resolve(
        version: OperatingSystemVersion,
        interfaceIdiom: AppleMobileInterfaceIdiom,
        isIOSAppOnMac: Bool,
        rawModelIdentifier: String?) -> Self
    {
        let versionString = InstancePlatformFamily.versionString(version)
        let trimmedModel = rawModelIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)

        if isIOSAppOnMac {
            // Keep the iOS protocol family so the gateway applies the mobile
            // command policy, while making the compatibility host explicit.
            return Self(
                platformString: "iOS \(versionString)",
                deviceFamily: "iOS",
                modelIdentifier: "Apple Silicon Mac")
        }

        let identity: (platform: String, family: String) = switch interfaceIdiom {
        case .phone:
            (platform: "iOS", family: "iPhone")
        case .pad:
            (platform: "iPadOS", family: "iPad")
        case .other:
            (platform: "iOS", family: "iOS")
        }
        return Self(
            platformString: "\(identity.platform) \(versionString)",
            deviceFamily: identity.family,
            modelIdentifier: trimmedModel?.isEmpty == false ? trimmedModel : nil)
    }
}

/// Non-iOS Apple platform families and the labels they advertise during gateway connect.
///
/// watchOS and macOS match upstream. tvOS and visionOS are SDK-only additions: the gateway's
/// `resolvePlatformIdByNativeLabel` places them in its `unknown` bucket, which only receives the
/// safe minimal default commands instead of the iOS mobile set.
enum InstancePlatformFamily: Sendable, Equatable {
    case watchOS
    case tvOS
    case visionOS
    case macOS

    /// `major.minor.patch`, matching the gateway regex `^(?:ios|ipados|watchos|macos) \d+(?:\.\d+){0,2}$`.
    static func versionString(_ version: OperatingSystemVersion) -> String {
        "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    var platformName: String {
        switch self {
        case .watchOS: "watchOS"
        case .tvOS: "tvOS"
        case .visionOS: "visionOS"
        case .macOS: "macOS"
        }
    }

    var deviceFamily: String {
        switch self {
        case .watchOS: "Apple Watch"
        case .tvOS: "Apple TV"
        case .visionOS: "Apple Vision"
        case .macOS: "Mac"
        }
    }

    /// Fallback display name when the platform reports an empty device name.
    var fallbackDisplayName: String {
        switch self {
        case .watchOS: "Apple Watch"
        case .tvOS, .visionOS, .macOS: "openclaw"
        }
    }

    func platformString(version: OperatingSystemVersion) -> String {
        "\(self.platformName) \(Self.versionString(version))"
    }
}

/// Shared instance and device metadata used by gateway and device-auth handshakes.
///
/// `platformString` and `deviceFamily` feed both `connect.client.platform/deviceFamily` and the
/// signed `GatewayDeviceAuthPayload.buildV3` metadata, so they must come from this one owner.
public enum InstanceIdentity {
    private static let suiteName = "ai.openclaw.shared"
    private static let instanceIdKey = "instanceId"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

#if os(iOS) || os(tvOS) || os(visionOS) || os(watchOS)
    private static func readMainActor<T: Sendable>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { body() }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { body() }
        }
    }

    private static func mobileMachineIdentifier() -> String? {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { ptr in
            String(bytes: ptr.prefix { $0 != 0 }, encoding: .utf8)
        }
        let trimmed = machine?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
#endif

#if os(iOS)
    private static let appleMobileMetadata: AppleMobileInstanceMetadata = {
        let interfaceIdiom = Self.readMainActor {
            switch UIDevice.current.userInterfaceIdiom {
            case .phone: AppleMobileInterfaceIdiom.phone
            case .pad: AppleMobileInterfaceIdiom.pad
            default: AppleMobileInterfaceIdiom.other
            }
        }
        return AppleMobileInstanceMetadata.resolve(
            version: ProcessInfo.processInfo.operatingSystemVersion,
            interfaceIdiom: interfaceIdiom,
            isIOSAppOnMac: ProcessInfo.processInfo.isiOSAppOnMac,
            rawModelIdentifier: Self.mobileMachineIdentifier())
    }()
#elseif os(watchOS)
    private static let platformFamily = InstancePlatformFamily.watchOS
#elseif os(tvOS)
    private static let platformFamily = InstancePlatformFamily.tvOS
#elseif os(visionOS)
    private static let platformFamily = InstancePlatformFamily.visionOS
#else
    private static let platformFamily = InstancePlatformFamily.macOS
#endif

    /// Stable per-installation identifier persisted in shared defaults.
    public static let instanceId: String = {
        let defaults = Self.defaults
        if let existing = defaults.string(forKey: instanceIdKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !existing.isEmpty
        {
            return existing
        }

        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: instanceIdKey)
        return id
    }()

    /// User-facing device or host name used in client identification.
    public static let displayName: String = {
#if os(iOS)
        if ProcessInfo.processInfo.isiOSAppOnMac {
            return "OpenClaw Mac App"
        }
        let name = Self.readMainActor {
            UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return name.isEmpty ? "openclaw" : name
#elseif os(watchOS)
        let name = Self.readMainActor {
            WKInterfaceDevice.current().name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return name.isEmpty ? Self.platformFamily.fallbackDisplayName : name
#elseif os(tvOS) || os(visionOS)
        let name = Self.readMainActor {
            UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return name.isEmpty ? Self.platformFamily.fallbackDisplayName : name
#else
        if let name = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty
        {
            return name
        }
        return Self.platformFamily.fallbackDisplayName
#endif
    }()

    /// Hardware model identifier when the platform exposes one.
    public static let modelIdentifier: String? = {
#if os(iOS)
        return Self.appleMobileMetadata.modelIdentifier
#elseif os(watchOS) || os(tvOS) || os(visionOS)
        return Self.mobileMachineIdentifier()
#else
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else { return nil }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }

        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        guard let raw = String(bytes: bytes, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
#endif
    }()

    /// Broad device family label: `iPhone`, `iPad`, `iOS` (iOS app on Mac or other idioms),
    /// `Apple Watch`, `Apple TV`, `Apple Vision`, or `Mac`.
    public static let deviceFamily: String = {
#if os(iOS)
        return Self.appleMobileMetadata.deviceFamily
#else
        return Self.platformFamily.deviceFamily
#endif
    }()

    /// Operating system name and version string used during gateway connect, for example
    /// `iOS 27.0.0`, `iPadOS 27.0.0`, `watchOS 27.0.0`, `tvOS 27.0.0`, `visionOS 27.0.0` or `macOS 27.0.0`.
    public static let platformString: String = {
#if os(iOS)
        return Self.appleMobileMetadata.platformString
#else
        return Self.platformFamily.platformString(version: ProcessInfo.processInfo.operatingSystemVersion)
#endif
    }()
}
