import Foundation

/// Gateway user display preferences shared with the Control UI (port of the upstream
/// `apps/shared/OpenClawKit/Sources/OpenClawKit/GatewayUserPreferences.swift`).
///
/// `ui.prefs` in `openclaw.json` is the canonical cross-client home for operator display
/// preferences; clients stay in sync by reading `config.get` (see ``OpenClawConfigDocument/UI``).
/// Per-profile overrides come from `users.prefs.get`.
public enum GatewayUserPreferences {
    /// Preference key holding the profile accent color.
    public static let accentKey = "ui.accent"

    /// Params for fetching only the accent with `users.prefs.get`: `{"keys":["ui.accent"]}`.
    public static var accentRequestParams: [String: AnyCodable] {
        ["keys": AnyCodable([AnyCodable(self.accentKey)])]
    }

    /// Strict `#rrggbb` validation (leading `#` optional); canonical lowercase `#rrggbb`.
    /// - Parameter raw: Candidate color.
    /// - Returns: Canonical hex, or `nil` when invalid.
    public static func normalizedAccentHex(_ raw: String?) -> String? {
        OpenClawConfigDocument.UI.normalizedAccentHex(raw)
    }

    /// Only an available profile preference may override the caller's Gateway accent.
    ///
    /// Accepts only a `{status: "ok", entries: {"ui.accent": "#rrggbb"}}` payload.
    /// - Parameter data: Profile-preferences response payload.
    /// - Returns: The normalized accent, or `nil`.
    /// - Throws: When the payload is not valid JSON.
    public static func decodeProfileAccentHex(_ data: Data) throws -> String? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["status"] as? String == "ok"
        else { return nil }
        let entries = json["entries"] as? [String: Any]
        return self.normalizedAccentHex(entries?[self.accentKey] as? String)
    }

    /// Gateway user-accent contract shared with the Control UI and Talk config:
    /// `ui.prefs.accent` wins over `ui.seamColor`; invalid values fall through.
    /// - Parameter ui: The document's `ui` section.
    /// - Returns: The accent hex, or `nil`.
    public static func gatewayUserAccentHex(ui: OpenClawConfigDocument.UI?) -> String? {
        ui?.accentHex
    }
}
