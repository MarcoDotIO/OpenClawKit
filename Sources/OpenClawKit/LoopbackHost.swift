import Foundation
import Network

/// Classification rules for hosts that may receive cleartext (`ws://` / `http://`) gateway traffic.
///
/// The default, ``strict``, matches upstream OpenClaw 2026.9.x: only loopback, `*.local`, private and
/// link-local IPv4 (10/8, 172.16/12, 192.168/16, 169.254/16), IPv6 unique-local (fc00::/7) and IPv6
/// link-local (fe80::/10) hosts count as local. Tailscale names (`*.ts.net`, `*.tailscale.net`),
/// dotless MagicDNS/LAN hostnames and 100.64.0.0/10 CGNAT addresses are *not* local: reach them over
/// `wss://` (for example with Tailscale Serve) instead.
///
/// Hosts that cannot use TLS yet can opt back in explicitly, process-wide, with
/// ``LocalNetworkHostPolicy/current`` = ``legacyPermissive`` (or a custom policy). The override is a
/// deliberate security downgrade: tailnet traffic is then sent unencrypted at the WebSocket layer and
/// setup codes/bootstrap tokens may be persisted for those hosts.
public struct LocalNetworkHostPolicy: Sendable, Equatable {
    /// Treats `*.ts.net`, `*.tailscale.net` and 100.64.0.0/10 (Tailscale CGNAT) hosts as local.
    public var allowsTailnetHosts: Bool
    /// Treats dotless single-label hostnames (MagicDNS or LAN names such as `mac-studio`) as local.
    public var allowsSingleLabelHostnames: Bool

    /// Creates a host policy.
    public init(allowsTailnetHosts: Bool = false, allowsSingleLabelHostnames: Bool = false) {
        self.allowsTailnetHosts = allowsTailnetHosts
        self.allowsSingleLabelHostnames = allowsSingleLabelHostnames
    }

    /// Upstream-parity policy (the default): tailnet and single-label hosts require TLS.
    public static let strict = Self()

    /// Pre-2026.3.0 SDK behavior: tailnet and single-label hosts are treated as local networks.
    public static let legacyPermissive = Self(allowsTailnetHosts: true, allowsSingleLabelHostnames: true)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var storage = Self.strict

    /// Process-wide policy used by ``LoopbackHost/isLocalNetworkHost(_:)`` and the setup-code and
    /// deep-link parsers. Defaults to ``strict``; set it once at launch, before parsing setup input or
    /// connecting, to opt in to a more permissive classification.
    public static var current: Self {
        get { self.lock.withLock { self.storage } }
        set { self.lock.withLock { self.storage = newValue } }
    }
}

/// Hostname classification helpers used by local-network and gateway trust decisions.
public enum LoopbackHost {
    /// Returns whether a host string points at loopback.
    public static func isLoopback(_ rawHost: String) -> Bool {
        self.isLoopbackHost(rawHost)
    }

    /// Returns whether a host string resolves to loopback, wildcard loopback, or localhost names.
    ///
    /// Only literal loopback addresses and `localhost` match; hostnames that merely start with
    /// `127.` (for example `127.example.com`) never do.
    public static func isLoopbackHost(_ rawHost: String) -> Bool {
        let host = self.normalizedHost(rawHost)
        if host.isEmpty {
            return false
        }
        if host == "localhost" || host == "0.0.0.0" || host == "::" {
            return true
        }

        if let ipv4 = IPv4Address(host) {
            return ipv4.rawValue.first == 127
        }
        if let ipv6 = IPv6Address(host) {
            let bytes = Array(ipv6.rawValue)
            let isV6Loopback = bytes[0..<15].allSatisfy { $0 == 0 } && bytes[15] == 1
            if isV6Loopback {
                return true
            }
            let isMappedV4 = bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xFF && bytes[11] == 0xFF
            return isMappedV4 && bytes[12] == 127
        }

        return false
    }

    /// Returns whether a host should be treated as local-network reachable under
    /// ``LocalNetworkHostPolicy/current`` (``LocalNetworkHostPolicy/strict`` by default).
    ///
    /// Loopback, `*.local`, private/link-local IPv4, IPv6 unique-local (fc00::/7) and IPv6
    /// link-local (fe80::/10) hosts are local. Tailscale and single-label hosts are local only when the
    /// policy opts in.
    public static func isLocalNetworkHost(_ rawHost: String) -> Bool {
        self.isLocalNetworkHost(rawHost, policy: LocalNetworkHostPolicy.current)
    }

    /// Returns whether a host should be treated as local-network reachable under an explicit policy.
    public static func isLocalNetworkHost(_ rawHost: String, policy: LocalNetworkHostPolicy) -> Bool {
        let host = self.normalizedHost(rawHost)
        guard !host.isEmpty else { return false }
        if self.isLoopbackHost(host) { return true }
        if host.hasSuffix(".local") { return true }
        if policy.allowsTailnetHosts, host.hasSuffix(".ts.net") || host.hasSuffix(".tailscale.net") {
            return true
        }
        if let ipv4 = self.parseIPv4(host) {
            if policy.allowsTailnetHosts, self.isTailscaleCGNATIPv4(ipv4) { return true }
            return self.isLocalNetworkIPv4(ipv4)
        }
        if let ipv6 = IPv6Address(host) {
            let bytes = Array(ipv6.rawValue)
            let isUniqueLocal = (bytes[0] & 0xFE) == 0xFC
            let isLinkLocal = bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80
            return isUniqueLocal || isLinkLocal
        }
        if policy.allowsSingleLabelHostnames, !host.contains("."), !host.contains(":") {
            return true
        }
        return false
    }

    /// Returns whether the host is the unspecified address (`0.0.0.0` or `::`), which is a bind
    /// wildcard and never a routable connect target.
    public static func isUnspecifiedAddress(_ rawHost: String) -> Bool {
        let host = self.normalizedHost(rawHost)
        if let ipv4 = IPv4Address(host) {
            return ipv4.rawValue.allSatisfy { $0 == 0 }
        }
        if let ipv6 = IPv6Address(host) {
            return ipv6.rawValue.allSatisfy { $0 == 0 }
        }
        return false
    }

    /// Trims whitespace, lowercases, strips surrounding `[]`, drops one trailing `.` and an IPv6
    /// `%zone` suffix.
    static func normalizedHost(_ rawHost: String) -> String {
        var host = rawHost
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.hasSuffix(".") {
            host.removeLast()
        }
        if let zoneIndex = host.firstIndex(of: "%") {
            host = String(host[..<zoneIndex])
        }
        return host
    }

    static func parseIPv4(_ host: String) -> (UInt8, UInt8, UInt8, UInt8)? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let bytes: [UInt8] = parts.compactMap { UInt8($0) }
        guard bytes.count == 4 else { return nil }
        return (bytes[0], bytes[1], bytes[2], bytes[3])
    }

    static func isLocalNetworkIPv4(_ ip: (UInt8, UInt8, UInt8, UInt8)) -> Bool {
        let (a, b, _, _) = ip
        // 10.0.0.0/8
        if a == 10 { return true }
        // 172.16.0.0/12
        if a == 172, (16...31).contains(Int(b)) { return true }
        // 192.168.0.0/16
        if a == 192, b == 168 { return true }
        // 127.0.0.0/8
        if a == 127 { return true }
        // 169.254.0.0/16 (link-local)
        if a == 169, b == 254 { return true }
        return false
    }

    /// Tailscale CGNAT range 100.64.0.0/10 (only local under an opted-in policy).
    static func isTailscaleCGNATIPv4(_ ip: (UInt8, UInt8, UInt8, UInt8)) -> Bool {
        ip.0 == 100 && (64...127).contains(Int(ip.1))
    }
}

/// Transport-security classification for a gateway URL before connecting or persisting credentials.
public enum GatewayTransportSecurityDecision: String, Sendable, Equatable {
    /// TLS (`wss://`/`https://`) or cleartext to loopback: connect normally.
    case ok
    /// Cleartext to a private/local-network host: allowed, but the app should confirm with the user.
    case warnCleartextLAN
    /// Cleartext to a public, tailnet or otherwise non-local host: switch to `wss://`/`https://`.
    case requireTLS
    /// Missing host or the unspecified address (`0.0.0.0`/`::`): never a valid connect target.
    case rejectNonRoutable
}

/// Policy helper that classifies gateway URLs by transport security (upstream #101325, #98617).
public enum GatewayTransportSecurityPolicy {
    /// Classifies a gateway URL under ``LocalNetworkHostPolicy/current``.
    public static func evaluate(url: URL) -> GatewayTransportSecurityDecision {
        self.evaluate(url: url, policy: LocalNetworkHostPolicy.current)
    }

    /// Classifies a gateway URL under an explicit host policy.
    ///
    /// Schemes other than `ws`, `wss`, `http` and `https` are treated as cleartext.
    public static func evaluate(url: URL, policy: LocalNetworkHostPolicy) -> GatewayTransportSecurityDecision {
        guard let host = url.host, !LoopbackHost.normalizedHost(host).isEmpty else {
            return .rejectNonRoutable
        }
        if LoopbackHost.isUnspecifiedAddress(host) {
            return .rejectNonRoutable
        }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "wss" || scheme == "https" {
            return .ok
        }
        if LoopbackHost.isLoopbackHost(host) {
            return .ok
        }
        if LoopbackHost.isLocalNetworkHost(host, policy: policy) {
            return .warnCleartextLAN
        }
        return .requireTLS
    }
}
