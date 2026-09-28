import Foundation

/// xAI OAuth constants (upstream `extensions/xai/xai-oauth.ts`).
///
/// Endpoints resolve through OpenID discovery at ``discoveryURL``; ``tokenURL`` and
/// ``legacyTokenURL`` are the documented fallbacks.
public enum XAIOAuthConfiguration {
    /// Public OAuth client id.
    public static let clientID = "b1a00492-073a-47ea-816f-4c329264a828"
    /// Requested scopes.
    public static let scope = "openid profile email offline_access grok-cli:access api:access"
    /// OAuth issuer.
    public static let issuer = URL(string: "https://auth.x.ai")!
    /// OpenID discovery document.
    public static let discoveryURL = URL(string: "https://auth.x.ai/.well-known/openid-configuration")!
    /// Token endpoint.
    public static let tokenURL = URL(string: "https://auth.x.ai/oauth2/token")!
    /// Legacy token endpoint.
    public static let legacyTokenURL = URL(string: "https://auth.x.ai/oauth/token")!
    /// Device-code grant type.
    public static let deviceCodeGrantType = "urn:ietf:params:oauth:grant-type:device_code"
    /// Default device-code poll interval in seconds.
    public static let defaultPollIntervalSeconds = 5
    /// Minimum device-code poll interval in seconds.
    public static let minimumPollIntervalSeconds = 1
    /// Seconds added to the poll interval on `slow_down`.
    public static let slowDownIncrementSeconds = 5
    /// Refresh attempts.
    public static let refreshMaxAttempts = 3
    /// Delay between refresh attempts in milliseconds.
    public static let refreshRetryDelayMs = 250
    /// Overall login timeout in seconds.
    public static let overallTimeoutSeconds = 300
    /// Per-request timeout in seconds.
    public static let fetchTimeoutSeconds = 30
}

/// OpenAI ChatGPT (Codex) OAuth constants (upstream `extensions/openai/openai-chatgpt-*.ts`).
public enum OpenAIChatGPTOAuthConfiguration {
    /// Public OAuth client id.
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    /// Browser authorization endpoint.
    public static let authorizationURL = URL(string: "https://auth.openai.com/oauth/authorize")!
    /// Browser callback (loopback).
    public static let callbackURL = URL(string: "http://localhost:1455/auth/callback")!
    /// Token endpoint.
    public static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    /// Device user-code endpoint.
    public static let deviceAuthorizationURL = URL(string: "https://auth.openai.com/api/accounts/deviceauth/usercode")!
    /// Device token polling endpoint.
    public static let deviceTokenURL = URL(string: "https://auth.openai.com/api/accounts/deviceauth/token")!
    /// Page where the user enters the device code.
    public static let deviceVerificationURL = URL(string: "https://auth.openai.com/codex/device")!
    /// Device-flow callback used for the final code exchange.
    public static let deviceCallbackURL = URL(string: "https://auth.openai.com/deviceauth/callback")!
    /// Requested scopes.
    public static let scopes = ["openid", "profile", "email", "offline_access"]
}

public extension InteractiveAuthFlowCatalog {
    /// Legacy provider ids and their canonical provider for auth flows (`openai-codex` merged into
    /// `openai`).
    static let legacyProviderAliases: [String: String] = [
        "openai-codex": "openai",
        "codex": "openai",
        "x-ai": "xai",
        "grok": "xai",
    ]

    /// Deprecated auth providers and the migration hint shown to users.
    static let deprecatedProviders: [String: String] = [
        "qwen-portal": "Legacy Qwen Portal OAuth profiles are not refreshable; use a qwen API key (provider `qwen`).",
    ]

    /// Upstream 2026.9.6 auth flows: OpenAI ChatGPT login and device pairing, xAI OAuth and device
    /// code (endpoints via discovery), and metadata-only OpenRouter and Chutes OAuth entries.
    static let upstreamProviderDescriptors: [InteractiveAuthFlowDescriptor] = [
        InteractiveAuthFlowDescriptor(
            providerID: "openai",
            displayName: "ChatGPT Login",
            kind: .browserOAuth,
            authorizationURL: OpenAIChatGPTOAuthConfiguration.authorizationURL,
            tokenURL: OpenAIChatGPTOAuthConfiguration.tokenURL,
            callbackURL: OpenAIChatGPTOAuthConfiguration.callbackURL,
            clientID: OpenAIChatGPTOAuthConfiguration.clientID,
            scopes: OpenAIChatGPTOAuthConfiguration.scopes
        ),
        InteractiveAuthFlowDescriptor(
            providerID: "openai",
            displayName: "ChatGPT Device Pairing",
            kind: .deviceCode,
            deviceAuthorizationURL: OpenAIChatGPTOAuthConfiguration.deviceAuthorizationURL,
            tokenURL: OpenAIChatGPTOAuthConfiguration.deviceTokenURL,
            callbackURL: OpenAIChatGPTOAuthConfiguration.deviceCallbackURL,
            clientID: OpenAIChatGPTOAuthConfiguration.clientID,
            scopes: OpenAIChatGPTOAuthConfiguration.scopes
        ),
        InteractiveAuthFlowDescriptor(
            providerID: "xai",
            displayName: "xAI OAuth",
            kind: .browserOAuth,
            authorizationURL: XAIOAuthConfiguration.issuer,
            tokenURL: XAIOAuthConfiguration.tokenURL,
            clientID: XAIOAuthConfiguration.clientID,
            scopes: XAIOAuthConfiguration.scope.split(separator: " ").map(String.init)
        ),
        InteractiveAuthFlowDescriptor(
            providerID: "xai",
            displayName: "xAI Device Code",
            kind: .deviceCode,
            deviceAuthorizationURL: XAIOAuthConfiguration.discoveryURL,
            tokenURL: XAIOAuthConfiguration.tokenURL,
            clientID: XAIOAuthConfiguration.clientID,
            scopes: XAIOAuthConfiguration.scope.split(separator: " ").map(String.init)
        ),
        InteractiveAuthFlowDescriptor(providerID: "openrouter", displayName: "OpenRouter OAuth", kind: .browserOAuth),
        InteractiveAuthFlowDescriptor(providerID: "chutes", displayName: "Chutes OAuth", kind: .browserOAuth),
    ]

    /// Every known flow for a provider (upstream descriptors first, then SDK built-ins), resolving
    /// legacy aliases such as `openai-codex`.
    /// - Parameter providerID: Provider identifier or legacy alias.
    /// - Returns: Matching descriptors.
    static func descriptors(forProvider providerID: String) -> [InteractiveAuthFlowDescriptor] {
        let normalized = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let canonical = self.legacyProviderAliases[normalized] ?? normalized
        return self.descriptors.filter { $0.providerID == canonical }
    }
}
