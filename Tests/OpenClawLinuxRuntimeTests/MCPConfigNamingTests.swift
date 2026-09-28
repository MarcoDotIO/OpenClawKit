import Foundation
import Testing
import OpenClawProtocol
@testable import OpenClawMCP

@Suite("MCP config, transport precedence and naming")
struct MCPConfigNamingTests {
    // Ported from upstream src/agents/agent-bundle-mcp-names.test.ts.
    @Test
    func sanitizesAndDisambiguatesServerNames() {
        var used = Set<String>()
        #expect(MCPToolNaming.sanitizeServerName("vigil-harbor", used: &used) == "vigil-harbor")
        #expect(MCPToolNaming.sanitizeServerName("vigil:harbor", used: &used) == "vigil-harbor-2")
    }

    @Test
    func keepsFragmentsProviderSafeWhenStartingWithDigits() {
        var used = Set<String>()
        let server = MCPToolNaming.sanitizeServerName("12306", used: &used)
        #expect(server == "mcp-12306")
        #expect(MCPToolNaming.buildSafeToolName(serverName: server, toolName: "2024-query", reservedNames: []) == "mcp-12306__tool-2024-query")
    }

    @Test
    func avoidsReservedCollisionsAndTruncates() {
        #expect(MCPToolNaming.buildSafeToolName(serverName: "memory", toolName: "status", reservedNames: ["memory__status"]) == "memory__status-2")
        #expect(MCPToolNaming.buildSafeToolName(serverName: "link", toolName: "spend-request_create", reservedNames: []) == "link__spend-request_create")
        let long = MCPToolNaming.buildSafeToolName(serverName: "memory", toolName: String(repeating: "x", count: 200), reservedNames: [])
        #expect(long.hasPrefix("memory__"))
        #expect(long.count <= 64)
        var used = Set<String>()
        #expect(MCPToolNaming.sanitizeServerName(String(repeating: "s", count: 40), used: &used).count == 30)
        #expect(MCPToolNaming.sanitizeServerName("", used: &used) == "mcp")
        #expect(MCPToolNaming.assignSafeServerNames(["a b", "a:b", "a-b"]) == ["a b": "a-b", "a:b": "a-b-2", "a-b": "a-b-3"])
    }

    @Test
    func transportPrecedenceMatchesUpstreamQuirk() throws {
        #expect(try MCPServerConfig(command: "server", url: "https://x", transport: "streamable-http").resolveTransport().get() == .stdio)
        #expect(try MCPServerConfig(url: "https://x").resolveTransport().get() == .sse)
        #expect(try MCPServerConfig(url: "https://x", transport: "streamable-http").resolveTransport().get() == .streamableHTTP)
        #expect(try MCPServerConfig(url: "https://x", type: "http").resolveTransport().get() == .streamableHTTP)
        #expect(try MCPServerConfig(url: "https://x", transport: "sse", type: "http").resolveTransport().get() == .sse)
        if case .failure(let issue) = MCPServerConfig(url: "https://x", transport: "websocket").resolveTransport() {
            #expect(issue.message.contains("websocket"))
        } else {
            Issue.record("websocket transport must be skipped")
        }
        if case .success = MCPServerConfig(url: "ftp://x").resolveTransport() {
            Issue.record("ftp urls must be rejected")
        }
    }

    @Test
    func toolFilterIncludesThenExcludes() {
        let filter = MCPToolFilter(include: ["read_*", "list"], exclude: ["read_secret*"])
        #expect(filter.allows("read_file"))
        #expect(filter.allows("list"))
        #expect(!filter.allows("read_secret_key"))
        #expect(!filter.allows("write_file"))
        #expect(MCPToolFilter.matches(pattern: "a*b*c", value: "axxbyyc"))
        #expect(!MCPToolFilter.matches(pattern: "a*b*c", value: "acb"))
        #expect(MCPToolFilter.matches(pattern: "*", value: "anything"))
        #expect(MCPToolFilter().allows("x"))
    }

    @Test
    func decodesUpstreamShapeAndValidates() throws {
        let json = """
        {
          "sessionIdleTtlMs": 1000,
          "servers": {
            "files": {"command": "npx", "args": ["-y", "server"], "env": {"PORT": 8080, "DEBUG": true}, "timeout": 5},
            "remote": {"url": "https://mcp.example.com", "transport": "streamable-http", "headers": {"Authorization": "Bearer x"},
                       "requestTimeoutMs": 1500, "toolFilter": {"include": ["a"]}, "codex": {"agents": ["main"]}, "disabled": true},
            "__proto__": {"url": "https://x"},
            "broken": {"transport": "stdio"},
            "per": {"url": "https://x", "oauth": {"identity": "per-requester"}}
          }
        }
        """
        let config = try JSONDecoder().decode(MCPConfig.self, from: Data(json.utf8))
        #expect(config.effectiveSessionIdleTtlMs == 1000)
        let files = try #require(config.server(named: "files"))
        #expect(files.env == ["PORT": "8080", "DEBUG": "true"])
        #expect(files.args == ["-y", "server"])
        let remote = try #require(config.server(named: "remote"))
        #expect(remote.effectiveRequestTimeoutMs == 1500)
        #expect(remote.effectiveConnectionTimeoutMs == 30_000)
        #expect(remote.extra["codex"] != nil)
        let reencoded = try JSONDecoder().decode(MCPConfig.self, from: try JSONEncoder().encode(config))
        #expect(reencoded.server(named: "remote")?.extra["codex"] == remote.extra["codex"])

        let issues = config.validate()
        #expect(issues.contains { $0.server == "files" && $0.path == "timeout" })
        #expect(issues.contains { $0.server == "remote" && $0.path == "disabled" && $0.message.contains("enabled: false") })
        #expect(issues.contains { $0.server == "__proto__" })
        #expect(issues.contains { $0.server == "broken" && $0.path == "command" })
        #expect(issues.contains { $0.server == "per" && $0.message.contains("requires auth: \"oauth\"") })
    }

    @Test
    func catalogNormalizationDropsAmbiguousAndTaskRequiredTools() {
        let tools = [
            MCPToolDefinition(name: " a "),
            MCPToolDefinition(name: "b"),
            MCPToolDefinition(name: "b"),
            MCPToolDefinition(name: ""),
            MCPToolDefinition(name: "task", taskSupport: "required"),
            MCPToolDefinition(name: "optional-task", taskSupport: "optional"),
        ]
        #expect(MCPToolCatalogNormalizer.normalize(tools, filter: nil).map(\.name) == ["a", "optional-task"])
        let long = String(repeating: "é", count: 1_300)
        let sanitized = MCPToolCatalogNormalizer.sanitizeMetadataText(long)
        #expect(sanitized?.hasSuffix("...") == true)
        #expect((sanitized?.utf16.count ?? 0) <= 1_203)
        #expect(MCPToolCatalogNormalizer.sanitizeMetadataText("  ") == nil)
    }

    @Test
    func schemaValidatorSubset() throws {
        let schema: [String: AnyCodable] = [
            "type": AnyCodable("object"),
            "additionalProperties": AnyCodable(false),
            "required": AnyCodable(["count"]),
            "properties": AnyCodable([
                "count": AnyCodable(["type": AnyCodable("integer"), "minimum": AnyCodable(1)]),
                "tags": AnyCodable(["type": AnyCodable("array"), "items": AnyCodable(["type": AnyCodable("string")])]),
                "mode": AnyCodable(["enum": AnyCodable(["a", "b"])]),
            ]),
        ]
        try MCPJSONSchemaValidator.validate(AnyCodable(["count": AnyCodable(2), "tags": AnyCodable(["x"]), "mode": AnyCodable("a")]), against: schema)
        #expect(throws: MCPJSONSchemaValidator.Failure.self) {
            try MCPJSONSchemaValidator.validate(AnyCodable(["count": AnyCodable(0)]), against: schema)
        }
        #expect(throws: MCPJSONSchemaValidator.Failure.self) {
            try MCPJSONSchemaValidator.validate(AnyCodable(["count": AnyCodable(1), "extra": AnyCodable(true)]), against: schema)
        }
        #expect(throws: MCPJSONSchemaValidator.Failure.self) {
            try MCPJSONSchemaValidator.validate(AnyCodable(["count": AnyCodable(1), "tags": AnyCodable([AnyCodable(1)])]), against: schema)
        }
        #expect(throws: MCPJSONSchemaValidator.Failure.self) {
            try MCPJSONSchemaValidator.validate(AnyCodable(["count": AnyCodable(1), "mode": AnyCodable("z")]), against: schema)
        }
    }

    @Test
    func jsonRPCMessageRoundTrip() throws {
        let request = MCPJSONRPCMessage.request(id: .int(7), method: "tools/call", params: AnyCodable(["name": AnyCodable("x")]))
        let data = try request.encoded()
        #expect(!String(decoding: data, as: UTF8.self).contains("\n"))
        #expect(try MCPJSONRPCMessage.decode(data) == [request])
        let batchJSON = #"[{"jsonrpc":"2.0","id":"a","error":{"code":-32601,"message":"nope"}},"#
            + #"{"jsonrpc":"2.0","method":"notifications/x"}]"#
        let batch = try MCPJSONRPCMessage.decode(Data(batchJSON.utf8))
        #expect(batch == [
            .error(id: .string("a"), error: MCPJSONRPCError(code: -32601, message: "nope")),
            .notification(method: "notifications/x", params: nil),
        ])
    }
}
