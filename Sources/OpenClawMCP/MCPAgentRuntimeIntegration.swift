import Foundation
import OpenClawAgents
import OpenClawCore
import OpenClawProtocol

// Wiring between the MCP client runtime and the embedded agent runtime. OpenClawAgents cannot depend
// on OpenClawMCP, so these adapters live here.

public extension MCPSessionToolOverrides {
    /// Maps a session's tool overlay (`sessions.patch toolOverrides`) onto MCP overrides: servers set
    /// to `false` are disabled and `mcpToolsDeny` entries are denied.
    /// - Parameter overrides: Session tool overrides.
    init(_ overrides: SessionToolOverrides?) {
        let disabled = (overrides?.mcpServers ?? [:]).filter { !$0.value }.map(\.key)
        self.init(disabledServers: Set(disabled), deniedTools: overrides?.mcpToolsDeny ?? [:])
    }
}

public extension MCPConfig {
    /// Builds the MCP runtime settings from a config document's `mcp` section.
    /// - Parameter document: Config document.
    /// - Returns: The settings (empty when the document has no `mcp` section).
    /// - Throws: `DecodingError` when the section does not match the upstream shape.
    static func resolve(from document: OpenClawConfigDocument) throws -> MCPConfig {
        guard let section = document.mcp else { return MCPConfig() }
        let data = try JSONEncoder().encode(section)
        return try JSONDecoder().decode(MCPConfig.self, from: data)
    }
}

public extension EmbeddedAgentRuntime {
    /// Registers the tools of every enabled MCP server into the runtime's tool registry.
    ///
    /// Tools are named `<server>__<tool>` (core tool names win collisions) and carry the source
    /// `.mcp(server:toolName:)`, so ``ToolPolicy`` entries (`bundle-mcp`, `<server>__*`) and each
    /// session's `toolOverrides` (disabled servers, denied tools) apply per run.
    /// - Parameters:
    ///   - manager: MCP client manager.
    ///   - overrides: Global overrides applied at registration (session overrides apply per run).
    /// - Returns: Registered tool names.
    @discardableResult
    func registerMCPTools(from manager: MCPClientManager, overrides: SessionToolOverrides? = nil) async -> [String] {
        await manager.registerTools(into: self.toolRegistry, overrides: MCPSessionToolOverrides(overrides))
    }

    /// Removes previously registered MCP tools (for example before re-registering after
    /// ``MCPClientManager/reload(config:)``).
    /// - Returns: Removed tool names.
    @discardableResult
    func unregisterMCPTools() async -> [String] {
        var removed: [String] = []
        for descriptor in await self.toolRegistry.descriptors() {
            guard case .mcp = descriptor.source else { continue }
            if await self.toolRegistry.unregister(named: descriptor.name) {
                removed.append(descriptor.name)
            }
        }
        return removed
    }
}
