import Foundation

/// Shared Bonjour constants used when discovering OpenClaw gateways on the local network.
public enum OpenClawBonjour {
    // v0: internal-only, subject to rename.
    /// Bonjour service type advertised by OpenClaw gateways.
    public static let gatewayServiceType = "_openclaw-gw._tcp"
    /// Default Bonjour service domain used for local discovery.
    public static let gatewayServiceDomain = "local."
    /// Optional wide-area Bonjour domain sourced from the environment.
    public static var wideAreaGatewayServiceDomain: String? {
        let env = ProcessInfo.processInfo.environment
        return resolveWideAreaDomain(env["OPENCLAW_WIDE_AREA_DOMAIN"])
    }

    /// Ordered list of service domains that should be queried for gateway discovery.
    public static var gatewayServiceDomains: [String] {
        var domains = [gatewayServiceDomain]
        if let wideArea = wideAreaGatewayServiceDomain {
            domains.append(wideArea)
        }
        return domains
    }

    private static func resolveWideAreaDomain(_ raw: String?) -> String? {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let normalized = normalizeServiceDomain(trimmed)
        return normalized == gatewayServiceDomain ? nil : normalized
    }

    /// Normalizes a raw Bonjour service domain into the dotted lowercased form expected by discovery APIs.
    public static func normalizeServiceDomain(_ raw: String?) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return self.gatewayServiceDomain
        }

        let lower = trimmed.lowercased()
        if lower == "local" || lower == "local." {
            return self.gatewayServiceDomain
        }

        return lower.hasSuffix(".") ? lower : (lower + ".")
    }
}
