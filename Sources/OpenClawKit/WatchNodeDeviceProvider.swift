#if os(watchOS)
import Foundation
import WatchKit

/// watchOS `device.info` and `device.status` payloads for a direct Watch node (`WKInterfaceDevice`).
public enum OpenClawWatchNodeDeviceProvider {
    /// `device.info` for the current Watch.
    @MainActor
    public static func deviceInfo(bundle: Bundle = .main) -> OpenClawDeviceInfoPayload {
        let device = WKInterfaceDevice.current()
        let info = bundle.infoDictionary ?? [:]
        return OpenClawDeviceInfoPayload(
            deviceName: device.name,
            modelIdentifier: InstanceIdentity.modelIdentifier ?? "Apple Watch",
            systemName: "watchOS",
            systemVersion: device.systemVersion,
            appVersion: (info["CFBundleShortVersionString"] as? String) ?? "0",
            appBuild: (info["CFBundleVersion"] as? String) ?? "0",
            locale: Locale.preferredLanguages.first ?? Locale.current.identifier)
    }

    /// `device.status` for the current Watch.
    ///
    /// - Parameters:
    ///   - isConnected: Whether the direct node session is connected (network `satisfied` versus
    ///     `requiresConnection`).
    ///   - networkMetrics: Latest transport metrics, for example from
    ///     ``OpenClawWatchNodeURLSessionTransport/latestNetworkMetrics()``.
    @MainActor
    public static func deviceStatus(
        isConnected: Bool,
        networkMetrics: OpenClawWatchNodeNetworkMetrics?) -> OpenClawDeviceStatusPayload
    {
        let device = WKInterfaceDevice.current()
        let wasMonitoring = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true
        defer { device.isBatteryMonitoringEnabled = wasMonitoring }
        let batteryState: OpenClawBatteryState = switch device.batteryState {
        case .charging: .charging
        case .full: .full
        case .unplugged: .unplugged
        case .unknown: .unknown
        @unknown default: .unknown
        }
        // WKInterfaceDevice.batteryLevel is a normalized 0.0–1.0 fraction (negative when unknown).
        let level = device.batteryLevel >= 0 ? Double(device.batteryLevel) : nil
        let battery = OpenClawBatteryStatusPayload(
            level: level,
            state: batteryState,
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            levelPercent: OpenClawBatteryStatusPayload.percent(fromLevel: level))
        let thermalState: OpenClawThermalState = switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .nominal
        }
        let attributes = (try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())) ?? [:]
        let total = (attributes[.systemSize] as? NSNumber)?.int64Value ?? 0
        let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        return OpenClawDeviceStatusPayload(
            battery: battery,
            thermal: OpenClawThermalStatusPayload(state: thermalState),
            storage: OpenClawStorageStatusPayload(totalBytes: total, freeBytes: free, usedBytes: max(0, total - free)),
            network: OpenClawNetworkStatusPayload(
                status: isConnected ? .satisfied : .requiresConnection,
                isExpensive: networkMetrics?.isExpensive ?? false,
                isConstrained: networkMetrics?.isConstrained ?? false,
                interfaces: networkMetrics?.isCellular == true ? [.cellular] : [.other]),
            uptimeSeconds: ProcessInfo.processInfo.systemUptime)
    }
}

extension OpenClawWatchNodeCommandRouter {
    /// The watchOS router: `WKInterfaceDevice` payloads, the transport's network metrics, and
    /// `UNUserNotificationCenter` notifications.
    ///
    /// - Parameters:
    ///   - transport: Transport whose metrics feed `device.status`.
    ///   - isConnected: Reports whether the direct node session is connected.
    public static func watchDefault(
        transport: OpenClawWatchNodeURLSessionTransport,
        notifier: any OpenClawWatchNodeNotifying = OpenClawWatchNodeUserNotifier(),
        isConnected: @escaping @Sendable () async -> Bool) -> OpenClawWatchNodeCommandRouter
    {
        OpenClawWatchNodeCommandRouter(
            deviceInfo: { await OpenClawWatchNodeDeviceProvider.deviceInfo() },
            deviceStatus: {
                let connected = await isConnected()
                let metrics = transport.latestNetworkMetrics()
                return await OpenClawWatchNodeDeviceProvider.deviceStatus(
                    isConnected: connected,
                    networkMetrics: metrics)
            },
            notifier: notifier)
    }
}

extension OpenClawWatchNodeClient {
    /// A client wired with the watchOS defaults: Keychain configuration, a shared `URLSession` transport
    /// whose metrics feed `device.status`, and the ``OpenClawWatchNodeCommandRouter/watchDefault(transport:notifier:isConnected:)``
    /// router.
    public static func watchDefault(
        store: any OpenClawWatchNodeConfigurationStoring = OpenClawWatchNodeKeychainConfigurationStore(),
        profile: GatewayDeviceIdentityProfile = .primary,
        notifier: any OpenClawWatchNodeNotifying = OpenClawWatchNodeUserNotifier()) -> OpenClawWatchNodeClient
    {
        let transport = OpenClawWatchNodeURLSessionTransport()
        let reference = WatchNodeClientReference()
        let router = OpenClawWatchNodeCommandRouter.watchDefault(
            transport: transport,
            notifier: notifier,
            isConnected: { await reference.client?.isConnected ?? false })
        let client = OpenClawWatchNodeClient(handler: router, store: store, transport: transport, profile: profile)
        reference.client = client
        return client
    }
}

/// Weak back-reference so the router can read the client's connection state without a retain cycle.
private final class WatchNodeClientReference: @unchecked Sendable {
    private let lock = NSLock()
    private weak var storedClient: OpenClawWatchNodeClient?

    var client: OpenClawWatchNodeClient? {
        get { self.lock.withLock { self.storedClient } }
        set { self.lock.withLock { self.storedClient = newValue } }
    }
}
#endif
