import Foundation

/// Helpers for classifying local-network HTTP endpoints.
///
/// Deprecated: upstream OpenClaw removed this helper. Use ``LoopbackHost/isLocalNetworkHost(_:)`` for
/// host classification or ``GatewayTransportSecurityPolicy/evaluate(url:)`` for a full transport
/// decision. Scheduled for removal in the next breaking release.
@available(*, deprecated, message: "Use LoopbackHost.isLocalNetworkHost(_:) or GatewayTransportSecurityPolicy.evaluate(url:)")
public enum LocalNetworkURLSupport {
    /// Returns whether a URL points at a local-network or loopback HTTP(S) host.
    ///
    /// Follows ``LoopbackHost/isLocalNetworkHost(_:)``, so Tailscale and single-label hosts are only
    /// local when ``LocalNetworkHostPolicy/current`` opts in.
    public static func isLocalNetworkHTTPURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        guard let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else {
            return false
        }
        return LoopbackHost.isLocalNetworkHost(host)
    }
}
