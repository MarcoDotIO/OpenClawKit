import Testing
@testable import OpenClawKit

@Suite("Agent tool registry")
struct AgentToolRegistryTests {
    struct EchoTool: AgentTool {
        let name = "echo"

        func execute(arguments: [String: AnyCodable]) async throws -> AnyCodable {
            arguments["value"] ?? AnyCodable("")
        }
    }

    @Test
    func supportsPreloadedToolsAndLookup() async throws {
        let registry = AgentToolRegistry(tools: [EchoTool()])

        #expect(await registry.hasTool(named: "echo") == true)
        #expect(await registry.hasTool(named: "missing") == false)

        let result = try await registry.execute(
            AgentToolCall(name: "echo", arguments: ["value": AnyCodable("ok")])
        )
        #expect(result == AgentToolResult(name: "echo", value: AnyCodable("ok")))
    }

    @Test
    func throwsWhenExecutingMissingTool() async throws {
        let registry = AgentToolRegistry()

        do {
            _ = try await registry.execute(AgentToolCall(name: "missing"))
            Issue.record("Expected missing tool failure")
        } catch {
            let typed = error as? AgentRuntimeError
            #expect(typed?.errorDescription == "Tool not found: missing")
        }
    }
}
