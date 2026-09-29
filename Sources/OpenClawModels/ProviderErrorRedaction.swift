import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Keeps credentials out of provider error values and diagnostic strings.
///
/// `URLError`s produced by URLSession carry the full failing URL in `userInfo`
/// (`NSErrorFailingURLStringKey`, `NSErrorFailingURLKey`, nested underlying errors), so any query
/// secret or signed URL would surface through `String(describing:)` in diagnostics, hook payloads
/// and logs. Provider transports rethrow transport errors through ``sanitize(_:)``, and the router
/// describes errors for diagnostics through ``describe(_:)``.
public enum ProviderErrorRedaction {
    /// Returns `error` with request URLs removed.
    ///
    /// `URLError`s are rebuilt with only their code and localized description, so callers can still
    /// match `.cancelled`, `.timedOut` and friends. Other errors are returned unchanged.
    /// - Parameter error: Error thrown by a transport.
    /// - Returns: An equivalent error without URL-bearing user info.
    public static func sanitize(_ error: Error) -> Error {
        guard let urlError = error as? URLError else { return error }
        return URLError(urlError.code, userInfo: [NSLocalizedDescriptionKey: urlError.localizedDescription])
    }

    /// Describes an error for diagnostics with URLs dropped and credential-looking values masked.
    /// - Parameter error: Error to describe.
    /// - Returns: A redacted description.
    public static func describe(_ error: Error) -> String {
        self.redact(String(describing: self.sanitize(error)))
    }

    /// Masks credential-looking values in free text: `key=`, `api_key=`, `access_token=`, `token=`,
    /// `sig=` style query parameters, `Bearer` tokens and failing-URL entries.
    /// - Parameter text: Text that may contain credentials.
    /// - Returns: The text with credential values replaced by `[redacted]`.
    public static func redact(_ text: String) -> String {
        var result = text
        for (regex, template) in self.patterns {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: template)
        }
        return result
    }

    private static let patterns: [(NSRegularExpression, String)] = {
        let sources: [(String, String)] = [
            (#"(NSErrorFailingURL(?:String)?Key=)[^\s,}]+"#, "$1[redacted]"),
            (#"(?i)([?&](?:key|api[_-]?key|access[_-]?token|token|sig|signature|x-goog-api-key)=)[^&\s"',}]+"#, "$1[redacted]"),
            (#"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+"#, "$1[redacted]"),
        ]
        return sources.compactMap { source, template in
            (try? NSRegularExpression(pattern: source)).map { ($0, template) }
        }
    }()
}
