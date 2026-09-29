import Foundation

/// Errors raised by the Sign in with ChatGPT authorization, token and account flows.
///
/// Messages never include tokens, authorization codes or PKCE verifiers.
public enum SignInWithChatGPTError: Error, LocalizedError, Sendable, Equatable {
    /// The user declined the consent screen (`error=access_denied`). Stop; do not retry automatically.
    case accessDenied
    /// The authorization server returned another `error` on the callback.
    case authorizationFailed(code: String, description: String?)
    /// The callback `state` does not match the pending authorization.
    case stateMismatch
    /// The callback `client_id` differs from the client id the authorization was started with.
    case clientMismatch(expected: String, received: String)
    /// The callback has no `code`.
    case missingAuthorizationCode
    /// A registration callback did not return the issued client id.
    case missingIssuedClientID
    /// The callback URL is not the pending redirect URI.
    case invalidCallback(String)
    /// The code exchange returned `invalid_grant`; restart the sign-in.
    case authorizationCodeRejected(String?)
    /// The refresh token was rejected (expired, revoked, reused …); tokens were cleared and the
    /// account must sign in again with its saved client id.
    case reauthenticationRequired(subject: String, reason: String)
    /// The token endpoint returned `invalid_client`: a configuration error, not a user error.
    case invalidClient(String?)
    /// The grant does not include `chatgpt.tokens.use.direct`, so the token cannot be used for plan
    /// inference. Ask the user to sign in again and re-enable plan usage.
    case planUsageNotGranted
    /// The ID token failed validation.
    case invalidIDToken(String)
    /// A token-endpoint request failed.
    case tokenRequestFailed(statusCode: Int, code: String?, description: String?)
    /// The server returned a response the client could not use.
    case invalidServerResponse(String)
    /// No signed-in account is available.
    case notSignedIn
    /// No account with this subject is known.
    case unknownAccount(String)
    /// The user closed the browser before finishing.
    case cancelled
    /// The browser callback did not arrive in time.
    case timedOut
    /// The loopback callback listener could not start.
    case callbackListenerUnavailable(String)
    /// Token revocation failed after retries.
    case revocationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Sign in with ChatGPT was cancelled on the consent screen."
        case .authorizationFailed(let code, let description):
            return "Sign in with ChatGPT failed (\(code))\(description.map { ": \($0)" } ?? "")."
        case .stateMismatch:
            return "Sign in with ChatGPT callback state does not match this sign-in."
        case .clientMismatch:
            return "Sign in with ChatGPT callback was issued for a different client."
        case .missingAuthorizationCode:
            return "Sign in with ChatGPT callback did not include an authorization code."
        case .missingIssuedClientID:
            return "Sign in with ChatGPT registration did not return a client id."
        case .invalidCallback(let detail):
            return "Sign in with ChatGPT callback is invalid: \(detail)."
        case .authorizationCodeRejected(let description):
            return "Sign in with ChatGPT authorization code was rejected\(description.map { ": \($0)" } ?? ""); sign in again."
        case .reauthenticationRequired(_, let reason):
            return "Your ChatGPT session ended (\(reason)); sign in again."
        case .invalidClient(let description):
            return "Sign in with ChatGPT client is not valid\(description.map { ": \($0)" } ?? "")."
        case .planUsageNotGranted:
            return "ChatGPT plan usage was not granted; sign in again and allow plan usage."
        case .invalidIDToken(let detail):
            return "Sign in with ChatGPT ID token is invalid: \(detail)."
        case .tokenRequestFailed(let statusCode, let code, let description):
            let detail = [code, description].compactMap { $0 }.joined(separator: ": ")
            return "Sign in with ChatGPT token request failed with status \(statusCode)\(detail.isEmpty ? "" : " (\(detail))")."
        case .invalidServerResponse(let detail):
            return "Sign in with ChatGPT received an invalid response: \(detail)."
        case .notSignedIn:
            return "No ChatGPT account is signed in."
        case .unknownAccount:
            return "The ChatGPT account is not known on this device."
        case .cancelled:
            return "Sign in with ChatGPT was cancelled."
        case .timedOut:
            return "Sign in with ChatGPT timed out waiting for the browser."
        case .callbackListenerUnavailable(let detail):
            return "Sign in with ChatGPT could not listen for the browser callback: \(detail)."
        case .revocationFailed(let detail):
            return "Signing out of ChatGPT could not revoke the session: \(detail)."
        }
    }

    /// Whether signing in again (with the saved client id) resolves the error.
    public var requiresSignIn: Bool {
        switch self {
        case .reauthenticationRequired, .authorizationCodeRejected, .planUsageNotGranted, .notSignedIn, .stateMismatch, .timedOut:
            return true
        default:
            return false
        }
    }
}

/// An inference or admission error returned while using a ChatGPT plan access token.
///
/// Built from structured error codes (`subscription_sharing_*`, `chatpass_v2_*`) found in HTTP error
/// bodies or `response.failed` stream events, and from direct-admission `401`/`403`/`503` responses
/// that carry `{"detail": …}`. ``recovery`` tells the app which UI to show; ``Kind/usageLimitReached``
/// maps to the "Usage limit reached" modal.
public struct ChatGPTPlanError: Error, LocalizedError, Sendable, Equatable {
    /// Error category.
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        /// `subscription_sharing_user_not_eligible` (403): the plan does not include app usage.
        case notEligible = "subscription_sharing_user_not_eligible"
        /// `subscription_sharing_usage_limit_exceeded` (429): the plan or app limit is used up.
        case usageLimitReached = "subscription_sharing_usage_limit_exceeded"
        /// `subscription_sharing_usage_unavailable` (503): usage accounting is temporarily down.
        case usageUnavailable = "subscription_sharing_usage_unavailable"
        /// `subscription_sharing_unsupported_capability` (400): the request uses a feature plan usage
        /// does not support (for example a hosted tool or audio input).
        case unsupportedCapability = "subscription_sharing_unsupported_capability"
        /// `subscription_sharing_route_not_supported` (403): the endpoint is not available with plan usage.
        case routeNotSupported = "subscription_sharing_route_not_supported"
        /// `subscription_sharing_invalid_user` (401): the user behind the token is not valid.
        case invalidUser = "subscription_sharing_invalid_user"
        /// `chatpass_v2_scope_not_authorized` (403): plan usage is not authorized for this grant.
        case scopeNotAuthorized = "chatpass_v2_scope_not_authorized"
        /// `chatpass_v2_invalid_authorization_context` (403): the grant's authorization context is invalid.
        case invalidAuthorizationContext = "chatpass_v2_invalid_authorization_context"
        /// `subscription_sharing_user_unavailable` (503): the account is temporarily unavailable.
        case userUnavailable = "subscription_sharing_user_unavailable"
        /// Direct-admission rejection (`401`, `403` or `503` with a `detail` message).
        case admissionDenied = "direct_admission"
    }

    /// What the app should offer the user.
    public enum Recovery: String, Sendable, Equatable {
        /// Show the usage-limit UI ("Manage usage", optionally "Buy app credits").
        case manageUsage
        /// Sign in again (re-enabling plan usage when needed).
        case signInAgain
        /// Retry later.
        case retryLater
        /// Change the request (remove the unsupported feature).
        case changeRequest
    }

    /// Category.
    public let kind: Kind
    /// HTTP status, when the error came from an HTTP response.
    public let statusCode: Int?
    /// Raw error code as returned by the server.
    public let code: String?
    /// Server message (already free of credentials).
    public let message: String?
    /// `Retry-After` delay in seconds, when present.
    public let retryAfter: TimeInterval?

    /// Creates an error.
    /// - Parameters:
    ///   - kind: Category.
    ///   - statusCode: HTTP status.
    ///   - code: Raw server error code.
    ///   - message: Server message.
    ///   - retryAfter: `Retry-After` delay in seconds.
    public init(kind: Kind, statusCode: Int? = nil, code: String? = nil, message: String? = nil, retryAfter: TimeInterval? = nil) {
        self.kind = kind
        self.statusCode = statusCode
        self.code = code ?? (kind == .admissionDenied ? nil : kind.rawValue)
        self.message = message
        self.retryAfter = retryAfter
    }

    /// Suggested recovery.
    public var recovery: Recovery {
        switch self.kind {
        case .usageLimitReached, .notEligible:
            return .manageUsage
        case .invalidUser, .scopeNotAuthorized, .invalidAuthorizationContext:
            return .signInAgain
        case .usageUnavailable, .userUnavailable:
            return .retryLater
        case .unsupportedCapability, .routeNotSupported:
            return .changeRequest
        case .admissionDenied:
            switch self.statusCode {
            case 401?: return .signInAgain
            case 503?: return .retryLater
            default: return .manageUsage
            }
        }
    }

    /// Whether this error should present the "Usage limit reached" UI.
    public var isUsageLimit: Bool {
        self.kind == .usageLimitReached
    }

    /// Whether signing in again should re-request plan consent (`force_reconsent` / `prompt=consent`).
    public var requiresPlanReconsent: Bool {
        self.kind == .scopeNotAuthorized || self.kind == .invalidAuthorizationContext
    }

    public var errorDescription: String? {
        let detail = self.message.map { ": \($0)" } ?? ""
        switch self.kind {
        case .usageLimitReached:
            return "Usage limit reached\(detail). Review your plan or this app's limit in ChatGPT settings."
        case .notEligible:
            return "Your ChatGPT plan can't be used in this app\(detail)."
        case .usageUnavailable, .userUnavailable:
            return "ChatGPT plan usage is temporarily unavailable\(detail). Try again later."
        case .unsupportedCapability:
            return "This request uses a feature that isn't available with ChatGPT plan usage\(detail)."
        case .routeNotSupported:
            return "This endpoint isn't available with ChatGPT plan usage\(detail)."
        case .invalidUser, .scopeNotAuthorized, .invalidAuthorizationContext:
            return "ChatGPT plan usage needs you to sign in again\(detail)."
        case .admissionDenied:
            return "ChatGPT plan request was not admitted (status \(self.statusCode ?? 0))\(detail)."
        }
    }

    /// Maximum characters of a server message kept on the error.
    static let maxMessageLength = 500

    /// Classifies a structured error code (for example from a `response.failed` stream event).
    /// - Parameters:
    ///   - code: Server error code.
    ///   - message: Server message.
    ///   - statusCode: HTTP status, when known.
    ///   - retryAfter: `Retry-After` delay in seconds.
    /// - Returns: The error, or `nil` for codes that are not plan-usage errors.
    public static func classify(code: String?, message: String? = nil, statusCode: Int? = nil, retryAfter: TimeInterval? = nil) -> Self? {
        guard let code = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), let kind = Kind(rawValue: code), kind != .admissionDenied else {
            return nil
        }
        return Self(kind: kind, statusCode: statusCode, code: code, message: self.trimmed(message), retryAfter: retryAfter)
    }

    /// Classifies an HTTP error response from the Responses or models endpoint.
    ///
    /// Recognizes `{"error": {"code": …, "message": …}}`, `{"code": …, "message": …}`,
    /// `{"error": "<code>"}` and direct-admission `{"detail": …}` bodies (`401`, `403`, `503`).
    /// - Parameters:
    ///   - statusCode: HTTP status.
    ///   - body: Response body.
    ///   - headers: Response headers (for `Retry-After`).
    /// - Returns: The error, or `nil` when the response is not a plan-usage error.
    public static func classify(statusCode: Int, body: Data, headers: [String: String] = [:]) -> Self? {
        guard !(200..<300).contains(statusCode) else { return nil }
        let retryAfter = headers.first { $0.key.lowercased() == "retry-after" }.flatMap { TimeInterval($0.value.trimmingCharacters(in: .whitespaces)) }
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let error = object?["error"]
        let nested = error as? [String: Any]
        let code = (nested?["code"] as? String) ?? (object?["code"] as? String) ?? (error as? String)
        let message = (nested?["message"] as? String) ?? (object?["message"] as? String) ?? (object?["error_description"] as? String)
        if let classified = self.classify(code: code, message: message, statusCode: statusCode, retryAfter: retryAfter) {
            return classified
        }
        if [401, 403, 503].contains(statusCode), let detail = self.detailMessage(object?["detail"]) {
            return Self(kind: .admissionDenied, statusCode: statusCode, code: nil, message: self.trimmed(detail), retryAfter: retryAfter)
        }
        return nil
    }

    private static func detailMessage(_ value: Any?) -> String? {
        if let text = value as? String {
            return text
        }
        if let object = value as? [String: Any] {
            return (object["message"] as? String) ?? (object["code"] as? String)
        }
        return nil
    }

    private static func trimmed(_ message: String?) -> String? {
        guard let message = message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else { return nil }
        return message.count > self.maxMessageLength ? String(message.prefix(self.maxMessageLength)) + "…" : message
    }
}
