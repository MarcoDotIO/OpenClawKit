import Foundation
import Network

/// Human-readable status strings for gateway discovery state.
public enum GatewayDiscoveryStatusText {
    /// Status when no browser is running.
    public static var idle: String {
        String(localized: "Idle", bundle: OpenClawKitResources.bundle)
    }

    /// Status after discovery was stopped.
    public static var stopped: String {
        String(localized: "Stopped", bundle: OpenClawKitResources.bundle)
    }

    /// Hint to show when browsing finds no gateway. Only macOS gateways advertise over mDNS by
    /// default, so point users at the Bonjour plugin, a setup code or manual host entry.
    public static var noGatewaysFoundHint: String {
        String(
            localized: """
            No gateways found. Linux and container gateways do not advertise on the local network by default \
            (run `openclaw plugins enable bonjour` on the gateway host). You can also scan a setup code or \
            enter the host manually.
            """,
            bundle: OpenClawKitResources.bundle)
    }

    /// Builds a user-facing status string from the current browser states.
    public static func make(states: [NWBrowser.State], hasBrowsers: Bool) -> String {
        if states.isEmpty {
            return hasBrowsers ? String(localized: "Setup", bundle: OpenClawKitResources.bundle) : self.idle
        }

        if let failed = states.first(where: { state in
            if case .failed = state { return true }
            return false
        }) {
            if case let .failed(err) = failed {
                return "\(String(localized: "Failed", bundle: OpenClawKitResources.bundle)): \(err)"
            }
        }

        if let waiting = states.first(where: { state in
            if case .waiting = state { return true }
            return false
        }) {
            if case let .waiting(err) = waiting {
                return "\(String(localized: "Waiting", bundle: OpenClawKitResources.bundle)): \(err)"
            }
        }

        if states.contains(where: { if case .ready = $0 { true } else { false } }) {
            return String(localized: "Searching…", bundle: OpenClawKitResources.bundle)
        }

        if states.contains(where: { if case .setup = $0 { true } else { false } }) {
            return String(localized: "Setup", bundle: OpenClawKitResources.bundle)
        }

        return String(localized: "Searching…", bundle: OpenClawKitResources.bundle)
    }
}
