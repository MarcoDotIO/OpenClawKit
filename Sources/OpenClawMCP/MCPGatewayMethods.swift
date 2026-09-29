import Foundation
import OpenClawAgents
import OpenClawGateway
import OpenClawProtocol

/// Registers `mcp.authLogin {sessionId, serverName}` backed by ``MCPOAuthClient/signIn(wwwAuthenticate:)``.
///
/// `clients` returns the OAuth client of an HTTP server configured with `auth: "oauth"` (for example
/// the same clients handed to ``MCPClientManager`` through its authorization-provider factory);
/// `nil` answers `INVALID_REQUEST` (the connector cannot use operator browser sign-in). The flow
/// runs inline and answers the finished wizard result (see `registerMCPAuthLoginGatewayMethod(on:signIn:)`).
/// - Parameters:
///   - registrar: Gateway server or registrar.
///   - clients: OAuth client lookup by server name.
public func registerMCPOAuthGatewayMethods(
    on registrar: some GatewayMethodRegistrar,
    clients: @escaping @Sendable (_ serverName: String) async -> MCPOAuthClient?
) async {
    await registerMCPAuthLoginGatewayMethod(on: registrar) { serverName in
        guard let client = await clients(serverName) else {
            throw GatewayMCPAuthLoginError.unsupportedServer(serverName)
        }
        try await client.signIn()
    }
}

public extension MCPClientManager {
    /// `tools.effective` notices for MCP servers that were skipped or failed to connect
    /// (feed to `AgentToolGatewayOptions.notices`).
    /// - Returns: One `mcp-not-yet-connected` warning listing the affected servers, or none.
    func toolInventoryNotices() -> [AgentToolInventoryNotice] {
        let servers = Array(Set(self.currentNotices().map(\.server))).sorted()
        guard !servers.isEmpty else { return [] }
        let listed = servers.prefix(3).map { "\"\($0)\"" }.joined(separator: ", ")
        let names = servers.count > 3 ? "\(listed), and \(servers.count - 3) more MCP servers" : listed
        return [
            AgentToolInventoryNotice(
                id: "mcp-not-yet-connected",
                severity: "warning",
                message: "MCP servers \(names) are configured but not connected for this session yet. "
                    + "MCP tools will appear here after an agent run discovers them.",
                servers: servers
            ),
        ]
    }
}
