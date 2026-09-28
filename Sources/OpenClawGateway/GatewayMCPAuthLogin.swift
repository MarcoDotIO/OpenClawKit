import Foundation
import OpenClawProtocol

/// Runs the OAuth sign-in of one MCP server for `mcp.authLogin`; returns once tokens are stored.
public typealias GatewayMCPSignInHandler = @Sendable (_ serverName: String) async throws -> Void

/// Errors a ``GatewayMCPSignInHandler`` throws to choose the `mcp.authLogin` answer.
public enum GatewayMCPAuthLoginError: Error, LocalizedError, Sendable, Equatable {
    /// The server is unknown, disabled, not HTTP, or not configured for operator OAuth sign-in.
    case unsupportedServer(String)

    /// Upstream wording for connectors that cannot use operator browser sign-in.
    public var errorDescription: String? {
        switch self {
        case .unsupportedServer:
            return "This connector cannot use operator browser sign-in. Check its existing account settings."
        }
    }
}

/// Registers `mcp.authLogin {sessionId, serverName}` (upstream 2026.9, `operator.admin`).
///
/// Upstream runs the sign-in as a wizard session and answers `{sessionId, done: false, status:
/// "running"}` for clients to poll. The in-process server runs the flow inline (the presenter shows
/// the browser sheet on this device) and answers the finished `WizardStartResult`:
/// `{sessionId, done: true, status: "done"}`, or `{sessionId, done: true, status: "error", error}`
/// when the flow fails. ``GatewayMCPAuthLoginError/unsupportedServer(_:)`` answers `INVALID_REQUEST`.
///
/// OpenClawMCP wires this to `MCPOAuthClient.signIn()` through `registerMCPOAuthGatewayMethods(on:clients:)`.
/// - Parameters:
///   - registrar: Gateway server or registrar.
///   - signIn: Sign-in handler for a server name.
public func registerMCPAuthLoginGatewayMethod(
    on registrar: some GatewayMethodRegistrar,
    signIn: @escaping GatewayMCPSignInHandler
) async {
    await registrar.register(method: "mcp.authLogin") { request in
        let params = try request.decodeParams(McpAuthLoginParams.self)
        let serverName = params.servername.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionID = params.sessionid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serverName.isEmpty, !sessionID.isEmpty else {
            throw GatewayMethodError.invalidRequest("mcp.authLogin requires sessionId and serverName")
        }
        guard request.connection.allows(scope: GatewayConnectionContext.operatorAdminScope) else {
            throw GatewayMethodError.invalidRequest("Connector sign-in requires an administrator connection.")
        }
        do {
            try await signIn(serverName)
            return AnyCodable(["sessionId": AnyCodable(sessionID), "done": AnyCodable(true), "status": AnyCodable("done")])
        } catch let error as GatewayMCPAuthLoginError {
            throw GatewayMethodError.invalidRequest(error.localizedDescription)
        } catch is CancellationError {
            return AnyCodable(["sessionId": AnyCodable(sessionID), "done": AnyCodable(true), "status": AnyCodable("cancelled")])
        } catch {
            return AnyCodable([
                "sessionId": AnyCodable(sessionID),
                "done": AnyCodable(true),
                "status": AnyCodable("error"),
                "error": AnyCodable(error.localizedDescription),
            ])
        }
    }
}
