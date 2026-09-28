import Foundation

/// Text helpers for presenting discovered gateways.
///
/// Gateways truncate mDNS service instance names and host labels to the 63-byte DNS label limit at a
/// UTF-8 boundary, and wide-area DNS-SD in minimal mode may omit optional TXT keys. Prefer the TXT
/// `displayName` when present and treat every TXT field as optional.
public enum GatewayDiscoveryText {
    /// Maximum length of one DNS label in bytes.
    public static let maxDNSLabelBytes = 63

    /// Collapses whitespace and strips a trailing ` (OpenClaw)` marker and ` (N)` collision suffix.
    public static func prettifyInstanceName(_ decodedName: String) -> String {
        let normalized = decodedName.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let stripped = normalized.replacingOccurrences(of: " (OpenClaw)", with: "")
            .replacingOccurrences(of: #"\s+\(\d+\)$"#, with: "", options: .regularExpression)
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Trimmed TXT value, or `nil` when missing or blank.
    public static func txtValue(_ dict: [String: String], key: String) -> String? {
        let raw = dict[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? nil : raw
    }

    /// TXT boolean (`1`, `true` or `yes`, case-insensitive); missing means `false`.
    public static func txtBoolValue(_ dict: [String: String], key: String) -> Bool {
        guard let raw = self.txtValue(dict, key: key)?.lowercased() else { return false }
        return raw == "1" || raw == "true" || raw == "yes"
    }

    /// Display name for a discovered gateway: TXT `displayName` when present, otherwise the decoded
    /// and prettified (possibly truncated) service instance name.
    public static func displayName(instanceName: String, txt: [String: String]) -> String {
        if let name = self.txtValue(txt, key: "displayName") {
            return name
        }
        return self.prettifyInstanceName(BonjourEscapes.decode(instanceName))
    }

    /// Truncates `value` to at most `maxBytes` UTF-8 bytes without splitting a character, mirroring
    /// how gateways shorten advertised names.
    public static func truncatedToDNSLabel(_ value: String, maxBytes: Int = Self.maxDNSLabelBytes) -> String {
        guard value.utf8.count > maxBytes else { return value }
        var result = ""
        var used = 0
        for character in value {
            let size = String(character).utf8.count
            guard used + size <= maxBytes else { break }
            result.append(character)
            used += size
        }
        return result
    }

    /// Whether an advertised (possibly truncated) instance name belongs to `fullName`.
    public static func instanceName(_ advertised: String, matches fullName: String) -> Bool {
        let decoded = BonjourEscapes.decode(advertised)
        if decoded == fullName { return true }
        return decoded.utf8.count <= self.maxDNSLabelBytes && decoded == self.truncatedToDNSLabel(fullName)
    }
}
