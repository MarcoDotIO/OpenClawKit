import Foundation

// Ported from upstream OpenClaw 2026.9.6 `ChatInlineWidgetView.swift` (resource + URL resolution only).
// The route-aware `resolveResource(target:replacing:currentSurfaceRoutes:...)` helper needs the kit's
// `GatewayCanvasHostRoute` and ships with the concrete gateway transport and widget view.

/// Which canvas surface produced a widget resource.
package enum OpenClawChatWidgetSurfaceRole: Sendable, Hashable {
    /// The node canvas host.
    case node
    /// The operator canvas surface.
    case operatorSurface
    /// A resource resolved by a URL-only (legacy) transport.
    case legacy
}

/// Resolved URL (and optional TLS pin) for an inline canvas widget.
public struct OpenClawChatWidgetResource: Sendable, Equatable {
    /// Widget document URL.
    public let url: URL
    /// SHA-256 TLS certificate fingerprint the web view must pin.
    public let tlsFingerprintSHA256: String?
    /// Surface that produced the resource.
    package let surfaceRole: OpenClawChatWidgetSurfaceRole
    /// Surfaces already attempted for this widget.
    package let attemptedSurfaceRoles: Set<OpenClawChatWidgetSurfaceRole>

    /// Creates a legacy (URL-only) widget resource.
    public init(url: URL, tlsFingerprintSHA256: String? = nil) {
        self.url = url
        self.tlsFingerprintSHA256 = tlsFingerprintSHA256
        self.surfaceRole = .legacy
        self.attemptedSurfaceRoles = []
    }

    /// Creates a resource tagged with the surface that produced it.
    package init(
        url: URL,
        tlsFingerprintSHA256: String?,
        surfaceRole: OpenClawChatWidgetSurfaceRole,
        attemptedSurfaceRoles: Set<OpenClawChatWidgetSurfaceRole>)
    {
        self.url = url
        self.tlsFingerprintSHA256 = tlsFingerprintSHA256
        self.surfaceRole = surfaceRole
        self.attemptedSurfaceRoles = attemptedSurfaceRoles
    }

    /// A pinned fingerprint is only meaningful over HTTPS.
    package var hasValidTLSBinding: Bool {
        self.tlsFingerprintSHA256 == nil || self.url.scheme?.lowercased() == "https"
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.url == rhs.url && lhs.tlsFingerprintSHA256 == rhs.tlsFingerprintSHA256
    }
}

/// Resolves relative canvas document targets against a capability surface URL.
public enum OpenClawChatWidgetURLResolver {
    private static let documentsPath = "/__openclaw__/canvas/documents"

    /// Joins a relative `/__openclaw__/canvas/documents/...` target onto a `.../__openclaw__/cap/<token>` surface.
    public static func resolve(surfaceURL rawSurfaceURL: String?, target rawTarget: String) -> URL? {
        guard let target = self.relativeWidgetTarget(rawTarget),
              var surface = self.capabilitySurface(rawSurfaceURL)
        else { return nil }

        var surfacePath = surface.percentEncodedPath
        while surfacePath.hasSuffix("/") {
            surfacePath.removeLast()
        }
        surface.percentEncodedPath = surfacePath + target.percentEncodedPath
        surface.percentEncodedQuery = target.percentEncodedQuery
        surface.fragment = target.fragment
        return surface.url
    }

    /// Whether a target is a canonical relative canvas document path.
    public static func supportsTarget(_ rawTarget: String) -> Bool {
        self.relativeWidgetTarget(rawTarget) != nil
    }

    private static func relativeWidgetTarget(_ rawTarget: String) -> URLComponents? {
        let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard target.hasPrefix("/"),
              let components = URLComponents(string: target),
              components.scheme == nil,
              components.host == nil,
              components.user == nil,
              components.password == nil,
              self.isCanonicalPath(components.percentEncodedPath),
              components.percentEncodedPath.hasPrefix("\(self.documentsPath)/")
        else { return nil }
        return components
    }

    private static func capabilitySurface(_ rawSurfaceURL: String?) -> URLComponents? {
        let raw = rawSurfaceURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty,
              let components = URLComponents(string: raw),
              self.isWebURL(components),
              components.user == nil,
              components.password == nil,
              components.percentEncodedQuery == nil,
              components.fragment == nil
        else { return nil }

        let segments = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true)
        guard segments.count >= 3,
              segments[segments.count - 3] == "__openclaw__",
              segments[segments.count - 2] == "cap",
              let capability = String(segments[segments.count - 1]).removingPercentEncoding,
              !capability.isEmpty
        else { return nil }
        return components
    }

    private static func isWebURL(_ components: URLComponents) -> Bool {
        let scheme = components.scheme?.lowercased()
        return (scheme == "http" || scheme == "https") && components.host?.isEmpty == false
    }

    private static func isCanonicalPath(_ path: String) -> Bool {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.first?.isEmpty == true else { return false }
        for (index, encodedSegment) in segments.enumerated() {
            if index == 0 || (index == segments.count - 1 && encodedSegment.isEmpty) {
                continue
            }
            guard !encodedSegment.isEmpty else { return false }
            guard let segment = self.decodeRepeatedly(String(encodedSegment)) else { return false }
            if segment == "." || segment == ".." || segment.contains("/") || segment.contains("\\") {
                return false
            }
        }
        return true
    }

    private static func decodeRepeatedly(_ encoded: String) -> String? {
        var value = encoded
        for _ in 0..<8 {
            guard let decoded = value.removingPercentEncoding else { return nil }
            if decoded == value { return decoded }
            value = decoded
        }
        return nil
    }
}
