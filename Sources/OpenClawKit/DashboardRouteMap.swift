import Foundation

/// Control UI (dashboard) route constants and same-app URL helpers.
///
/// Metadata only: hosts that embed the Control UI in a `WKWebView` use these to deep-link into a
/// page without letting untrusted input change the origin or the auth-token fragment.
public enum DashboardRouteMap {
    /// Settings root.
    public static let settingsPath = "/settings"
    /// Appearance settings.
    public static let appearanceSettingsPath = "/settings/appearance"
    /// This-device settings.
    public static let deviceSettingsPath = "/settings/device"
    /// This-device permission settings.
    public static let devicePermissionsSettingsPath = "/settings/device/permissions"
    /// Channel settings.
    public static let channelsSettingsPath = "/settings/channels"
    /// Skills page.
    public static let skillsPagePath = "/skills"
    /// Automations (cron jobs) page.
    public static let cronJobsPagePath = "/automations"
    /// Activity page.
    public static let activityPagePath = "/activity"
    /// Workboard page.
    public static let workboardPagePath = "/workboard"
    /// Skill workshop page.
    public static let skillWorkshopPagePath = "/skills/workshop"
    /// Memory dreaming settings page.
    public static let dreamingPagePath = "/settings/memory/dreams"
    /// Usage page.
    public static let usagePagePath = "/usage"
    /// Sessions page.
    public static let sessionsPagePath = "/sessions"
    /// Paired devices settings.
    public static let devicesSettingsPath = "/settings/devices"
    /// Custodian page.
    public static let custodianPagePath = "/custodian"
    /// Control UI query that renders /custodian with onboarding chrome.
    public static let custodianOnboardingSearch = "?onboarding=1"

    /// Whether `path` is an absolute same-app path (no scheme, host, query or fragment, no `//` prefix).
    public static func isValidSameAppPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.hasPrefix("//"),
              let components = URLComponents(string: path)
        else {
            return false
        }
        return components.scheme == nil &&
            components.host == nil &&
            components.query == nil &&
            components.fragment == nil
    }

    /// A same-app search must stay a plain query: no scheme/host smuggling and
    /// no fragment, which the dashboard URL reserves for the auth token.
    public static func isValidSameAppSearch(_ search: String) -> Bool {
        guard search.hasPrefix("?"), !search.contains("#") else { return false }
        // Parse bridge input: assigning an invalid percentEncodedQuery traps.
        return URLComponents(string: search, encodingInvalidCharacters: false)?.percentEncodedQuery != nil
    }

    /// Appends a validated same-app path (and optional search) to the dashboard base URL, keeping the
    /// base origin; returns `nil` for invalid input.
    public static func dashboardURL(
        byAppendingSameAppPath path: String,
        search: String? = nil,
        to baseURL: URL) -> URL?
    {
        guard self.isValidSameAppPath(path),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        else {
            return nil
        }
        if let search {
            guard self.isValidSameAppSearch(search) else { return nil }
            components.percentEncodedQuery = String(search.dropFirst())
        }
        let basePath = components.percentEncodedPath.hasSuffix("/")
            ? components.percentEncodedPath : components.percentEncodedPath + "/"
        guard let route = URLComponents(string: path) else { return nil }
        components.percentEncodedPath = basePath + route.percentEncodedPath.dropFirst()
        return components.url
    }
}
