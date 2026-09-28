#if canImport(AuthenticationServices) && !os(tvOS) && !os(watchOS)
import Foundation
import OpenClawCore
import OpenClawMCP

extension MCPOAuthClient {
    /// Builds an MCP OAuth client for Apple apps: tokens and client registration live in the
    /// Keychain (``KeychainCredentialStore`` through ``CredentialMCPOAuthStateStore``) and interactive
    /// sign-in runs in `ASWebAuthenticationSession` (``WebAuthenticationMCPOAuthPresenter``).
    ///
    /// Use a custom-scheme `config.redirectUrl` (for example `myapp://mcp/oauth`): the web
    /// authentication session cannot capture loopback `http://127.0.0.1` callbacks.
    /// - Parameters:
    ///   - serverName: MCP server name (part of the Keychain key).
    ///   - serverURL: MCP server URL (the OAuth resource indicator).
    ///   - config: OAuth settings; `config.authProfileId` scopes the stored tokens to an auth profile.
    ///   - credentialStore: Secret store; defaults to the SDK Keychain service.
    ///   - presenter: Interactive presenter; supply one with a presentation anchor in UI apps.
    /// - Returns: The OAuth client.
    /// - Throws: ``MCPOAuthError/unsupported(_:)`` for `per-requester` identities.
    public static func appleDefault(
        serverName: String,
        serverURL: URL,
        config: MCPOAuthConfig = MCPOAuthConfig(),
        credentialStore: any CredentialStore = KeychainCredentialStore(),
        presenter: WebAuthenticationMCPOAuthPresenter = WebAuthenticationMCPOAuthPresenter()) throws -> MCPOAuthClient
    {
        try MCPOAuthClient(
            serverName: serverName,
            serverURL: serverURL,
            config: config,
            store: CredentialMCPOAuthStateStore(credentialStore: credentialStore, authProfileID: config.authProfileId),
            presenter: presenter)
    }
}
#endif
