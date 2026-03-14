import Foundation

/// Helpers for classifying local-network HTTP endpoints.
public enum LocalNetworkURLSupport {
    /// Returns whether a URL points at a local-network or loopback HTTP(S) host.
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
