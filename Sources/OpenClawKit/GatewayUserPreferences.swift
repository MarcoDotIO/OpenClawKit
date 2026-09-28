import Foundation

/// Helpers for gateway user preferences (`users.prefs.get`).
public enum GatewayUserPreferences {
    /// Preference key holding the profile accent color.
    public static let accentKey = "ui.accent"

    /// Params for fetching only the accent: `{"keys":["ui.accent"]}`.
    public static var accentRequestParams: [String: AnyCodable] {
        ["keys": AnyCodable([AnyCodable(self.accentKey)])]
    }

    /// Strict #rrggbb validation (leading "#" optional); canonical lowercase "#rrggbb".
    public static func normalizedAccentHex(_ raw: String?) -> String? {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let hex = (trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed).lowercased()
        guard hex.count == 6, hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return "#\(hex)"
    }

    /// Only an available profile preference may override the caller's Gateway accent.
    ///
    /// Decodes a `users.prefs.get` result: returns the normalized `entries["ui.accent"]` when
    /// `status == "ok"`, else `nil`. Throws only for malformed JSON.
    public static func decodeProfileAccentHex(_ data: Data) throws -> String? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["status"] as? String == "ok"
        else { return nil }
        let entries = json["entries"] as? [String: Any]
        return self.normalizedAccentHex(entries?[self.accentKey] as? String)
    }
}
