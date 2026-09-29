import Foundation
import Testing
import OpenClawCore
import OpenClawGateway
import OpenClawMCP
import OpenClawProtocol

/// OpenClawMCP wiring of `mcp.authLogin` and the `tools.effective` MCP notices.
@Suite("MCP gateway methods")
struct MCPGatewayMethodsTests {
    struct RefusingTransportError: Error, LocalizedError {
        var errorDescription: String? { "connection refused" }
    }

    @Test
    func authLoginRejectsServersWithoutAnOAuthClient() async throws {
        let (server, _) = GatewayServerTestHarness.bareServer("mcp-oauth-wiring")
        await registerMCPOAuthGatewayMethods(on: server) { _ in nil }
        let response = await GatewayServerTestHarness.call(server, "mcp.authLogin", ["sessionId": AnyCodable("w"), "serverName": AnyCodable("docs")])
        #expect(response.error?.errorCode == .invalidRequest)
        #expect(await server.supportedMethods().contains("mcp.authLogin"))
    }

    @Test
    func managerNoticesBecomeToolInventoryNotices() async throws {
        let config = MCPConfig(servers: [
            (name: "calendar", config: MCPServerConfig(url: "https://calendar.example.invalid/mcp")),
        ])
        let manager = MCPClientManager(config: config, transportFactory: { _, _, _ in throw RefusingTransportError() })
        #expect(await manager.toolInventoryNotices().isEmpty)
        _ = await manager.tools()
        let notices = await manager.toolInventoryNotices()
        #expect(notices.count == 1)
        #expect(notices.first?.id == "mcp-not-yet-connected")
        #expect(notices.first?.servers == ["calendar"])
        #expect(notices.first?.message.contains("\"calendar\"") == true)
    }
}
