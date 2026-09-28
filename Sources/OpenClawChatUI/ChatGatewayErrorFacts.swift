import Foundation
import OpenClawKit

/// Structured facts read from a `GatewayResponseError`.
///
/// Mirrors upstream's `GatewayResponseError.detailsReason`, `missingScope`, and `isAuthorizationFailure`
/// accessors without extending the kit type, so a later kit port of those accessors cannot collide.
enum ChatGatewayErrorFacts {
    /// Trimmed `details.reason`.
    static func reason(_ error: GatewayResponseError) -> String? {
        let trimmed = error.details["reason"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Trimmed `details.reason` when the error is a gateway response error.
    static func reason(_ error: any Error) -> String? {
        (error as? GatewayResponseError).flatMap { self.reason($0) }
    }

    /// Missing scope from structured details, or parsed from pre-details gateway messages.
    static func missingScope(_ error: GatewayResponseError) -> String? {
        if error.details["code"]?.stringValue == "MISSING_SCOPE",
           let scope = error.details["missingScope"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !scope.isEmpty
        {
            return scope
        }
        guard error.code == "FORBIDDEN" || error.code == "INVALID_REQUEST" else { return nil }
        guard let marker = error.message.range(of: "missing scope:", options: .caseInsensitive) else {
            return nil
        }
        let suffix = error.message[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return suffix.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
    }

    /// Whether the gateway rejected the caller's role or scope.
    static func isAuthorizationFailure(_ error: GatewayResponseError) -> Bool {
        if self.missingScope(error) != nil { return true }
        return error.code == "INVALID_REQUEST" &&
            error.message.localizedCaseInsensitiveContains("unauthorized role")
    }
}
