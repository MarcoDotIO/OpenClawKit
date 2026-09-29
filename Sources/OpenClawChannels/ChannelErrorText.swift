import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Credential-safe error text for channel health, `channels.status`, diagnostics and chat replies.
///
/// Channel APIs put credentials in request URLs (Telegram `/bot<token>/`, BlueBubbles
/// `?password=`), and `String(describing:)` of a `URLError`/`NSError` prints the failing URL from
/// its `userInfo`. ``describe(_:)`` never prints `userInfo` for URL errors and runs every string
/// through ``redact(_:)`` (upstream `redactSensitiveText`).
public enum ChannelErrorText {
    /// Replacement for redacted credentials.
    public static let redactedMarker = "<redacted>"

    /// Describes an error without leaking credential-bearing URLs or tokens.
    /// - Parameter error: Any error.
    /// - Returns: Redacted, human-readable text.
    public static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return self.redact("URLError \(urlError.code.rawValue): \(urlError.localizedDescription)")
        }
        if let localized = (error as? LocalizedError)?.errorDescription {
            return self.redact(localized)
        }
        return self.redact(String(describing: error))
    }

    /// Redacts Telegram bot tokens, credential query items, URL userinfo and bearer tokens.
    /// - Parameter text: Text that may contain credentials.
    /// - Returns: Text with credentials replaced by ``redactedMarker``.
    public static func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        for rule in self.rules {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = rule.regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: rule.template)
        }
        return result
    }

    private struct Rule: @unchecked Sendable {
        let regex: NSRegularExpression
        let template: String
    }

    private static let rules: [Rule] = {
        let marker = NSRegularExpression.escapedTemplate(for: redactedMarker)
        let queryKeys = "access[-_]?token|auth[-_]?token|refresh[-_]?token|id[-_]?token|api[-_]?key|apikey|client[-_]?secret"
            + "|app[-_]?secret|private[-_]?key|token|key|secret|password|passwd|pass|auth|signature|sig|guid"
        let patterns: [(String, String)] = [
            // Telegram bot API path segment and bare tokens (`123456:AA...`).
            (#"\bbot\d{6,}:[A-Za-z0-9_-]{20,}"#, "bot\(marker)"),
            (#"\b\d{6,}:[A-Za-z0-9_-]{20,}\b"#, marker),
            // Credential query items (`?password=...`, `&token=...`), also percent-encoded `=`.
            (#"([?&;](?:"# + queryKeys + #")(?:=|%3D))[^&#\s"'<>]+"#, "$1\(marker)"),
            // URL userinfo (`https://user:secret@host`).
            (#"(://)[^/@\s"'<>]+:[^/@\s"'<>]*@"#, "$1\(marker)@"),
            // Authorization header values.
            (#"\b(Bearer|Basic|Bot)\s+[-A-Za-z0-9._~+/=]{8,}"#, "$1 \(marker)"),
        ]
        return patterns.compactMap { pattern, template in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            return Rule(regex: regex, template: template)
        }
    }()
}
