import Foundation
#if canImport(AuthenticationServices) && !os(tvOS) && !os(watchOS)
import AuthenticationServices
#endif

/// Interactive auth flow kind used by provider login helpers.
public enum InteractiveAuthFlowKind: String, Codable, Sendable, Equatable {
    case browserOAuth = "browser_oauth"
    case deviceCode = "device_code"
}

/// Descriptor for one provider-auth flow aligned with the TS reference.
public struct InteractiveAuthFlowDescriptor: Sendable, Equatable {
    /// Stable provider identifier.
    public var providerID: String
    /// User-facing provider name.
    public var displayName: String
    /// Login flow kind.
    public var kind: InteractiveAuthFlowKind
    /// Browser authorization URL when the flow requires browser login.
    public var authorizationURL: URL?
    /// Device authorization endpoint for device-code flows.
    public var deviceAuthorizationURL: URL?
    /// Token endpoint used for refresh or device-code polling.
    public var tokenURL: URL?
    /// Callback URL used for browser OAuth flows when applicable.
    public var callbackURL: URL?
    /// OAuth client identifier when required by the provider flow.
    public var clientID: String?
    /// Requested OAuth scopes when known.
    public var scopes: [String]

    /// Creates an interactive auth descriptor.
    public init(
        providerID: String,
        displayName: String,
        kind: InteractiveAuthFlowKind,
        authorizationURL: URL? = nil,
        deviceAuthorizationURL: URL? = nil,
        tokenURL: URL? = nil,
        callbackURL: URL? = nil,
        clientID: String? = nil,
        scopes: [String] = []
    ) {
        self.providerID = providerID
        self.displayName = displayName
        self.kind = kind
        self.authorizationURL = authorizationURL
        self.deviceAuthorizationURL = deviceAuthorizationURL
        self.tokenURL = tokenURL
        self.callbackURL = callbackURL
        self.clientID = clientID
        self.scopes = scopes
    }
}

/// Shared catalog of provider login flows exposed to host apps.
public enum InteractiveAuthFlowCatalog {
    /// Known interactive auth descriptors keyed by provider ID.
    public static let descriptors: [InteractiveAuthFlowDescriptor] = [
        InteractiveAuthFlowDescriptor(
            providerID: "openai-codex",
            displayName: "OpenAI Codex",
            kind: .browserOAuth,
            authorizationURL: URL(string: "https://auth.openai.com/oauth/authorize"),
            callbackURL: URL(string: "http://127.0.0.1:1455/oauth-callback"),
            scopes: ["openid", "profile", "email", "offline_access"]
        ),
        InteractiveAuthFlowDescriptor(
            providerID: "github-copilot",
            displayName: "GitHub Copilot",
            kind: .deviceCode,
            deviceAuthorizationURL: URL(string: "https://github.com/login/device/code"),
            tokenURL: URL(string: "https://github.com/login/oauth/access_token"),
            clientID: "Iv1.b507a08c87ecfe98",
            scopes: ["read:user"]
        ),
        InteractiveAuthFlowDescriptor(
            providerID: "qwen-portal",
            displayName: "Qwen Portal",
            kind: .deviceCode,
            deviceAuthorizationURL: URL(string: "https://chat.qwen.ai/api/v1/oauth2/device/code"),
            tokenURL: URL(string: "https://chat.qwen.ai/api/v1/oauth2/token"),
            clientID: "f0304373b74a44d2b584a3fb70ca9e56",
            scopes: ["openid", "profile", "email", "model.completion"]
        ),
        InteractiveAuthFlowDescriptor(
            providerID: "minimax-portal",
            displayName: "MiniMax Portal",
            kind: .deviceCode,
            deviceAuthorizationURL: URL(string: "https://api.minimax.io/oauth/code"),
            tokenURL: URL(string: "https://api.minimax.io/oauth/token"),
            clientID: "78257093-7e40-4613-99e0-527b14b39113",
            scopes: ["group_id", "profile", "model.completion"]
        ),
    ]

    /// Returns one auth-flow descriptor for the requested provider identifier.
    public static func descriptor(for providerID: String) -> InteractiveAuthFlowDescriptor? {
        let normalized = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return self.descriptors.first(where: { $0.providerID == normalized })
    }
}

#if canImport(AuthenticationServices) && !os(tvOS) && !os(watchOS)
/// Apple-system browser presenter used for provider OAuth flows.
@MainActor
public final class AppleWebAuthenticationSessionPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let presentationAnchorProvider: (() -> ASPresentationAnchor)?
    private var session: ASWebAuthenticationSession?

    /// Creates a web-auth presenter.
    /// - Parameter presentationAnchorProvider: Optional anchor provider for UIKit/AppKit-hosted flows.
    public init(
        presentationAnchorProvider: (() -> ASPresentationAnchor)? = nil
    ) {
        self.presentationAnchorProvider = presentationAnchorProvider
    }

    /// Starts an Apple-system browser auth session and returns the callback URL.
    /// - Parameters:
    ///   - authorizationURL: Provider authorization URL.
    ///   - callbackScheme: Callback scheme or `nil` for full callback URL capture.
    public func authenticate(
        authorizationURL: URL,
        callbackScheme: String?
    ) async throws -> URL {
        guard self.session == nil else {
            throw OpenClawCoreError.unavailable("An OAuth browser session is already in progress")
        }

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authorizationURL,
                callbackURLScheme: callbackScheme
            ) { [weak self] callbackURL, error in
                Task { @MainActor [weak self] in
                    self?.session = nil
                    if let callbackURL {
                        continuation.resume(returning: callbackURL)
                    } else if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(
                            throwing: OpenClawCoreError.unavailable("OAuth browser session ended without a callback URL")
                        )
                    }
                }
            }
            session.prefersEphemeralWebBrowserSession = false
            if self.presentationAnchorProvider != nil {
                session.presentationContextProvider = self
            }
            self.session = session
            if !session.start() {
                self.session = nil
                continuation.resume(
                    throwing: OpenClawCoreError.unavailable("Failed to start OAuth browser session")
                )
            }
        }
    }

    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        _ = session
        return self.presentationAnchorProvider?() ?? ASPresentationAnchor()
    }
}
#endif
