import Foundation
import OpenClawAgents
import OpenClawCore
import OpenClawProtocol

/// Calls one MCP tool (server name, wire tool name, arguments).
public typealias MCPToolCaller = @Sendable (_ server: String, _ tool: String, _ arguments: [String: AnyCodable]) async throws -> MCPCallToolResult

/// An MCP server tool exposed as an OpenClaw agent tool (`<server>__<tool>`).
///
/// The descriptor's source is `.mcp(server:toolName:)` with the declared server name and the server's
/// tool name. Descriptions are untrusted server metadata: they are scrubbed and capped (see
/// ``MCPToolCatalogNormalizer/sanitizeMetadataText(_:)``). Results map `text` and `image` blocks to
/// content, summarize `audio`, `resource` and `resource_link` blocks as text, and carry
/// `structuredContent` as details. A tool that declares an `outputSchema` must return
/// `structuredContent` that validates, unless it reports an error.
public struct MCPAgentTool: AgentTool {
    /// Model-facing safe name.
    public let name: String
    /// Declared server name.
    public let serverName: String
    /// Server tool definition.
    public let definition: MCPToolDefinition
    /// Whether calls may run in parallel.
    public let supportsParallelToolCalls: Bool
    private let caller: MCPToolCaller

    /// Creates an MCP agent tool.
    /// - Parameters:
    ///   - name: Safe model-facing name.
    ///   - serverName: Declared server name.
    ///   - definition: Tool definition.
    ///   - supportsParallelToolCalls: Parallel flag.
    ///   - caller: Tool caller.
    public init(name: String, serverName: String, definition: MCPToolDefinition, supportsParallelToolCalls: Bool, caller: @escaping MCPToolCaller) {
        self.name = name
        self.serverName = serverName
        self.definition = definition
        self.supportsParallelToolCalls = supportsParallelToolCalls
        self.caller = caller
    }

    /// Model- and UI-facing description.
    public var descriptor: AgentToolDescriptor {
        let description = MCPToolCatalogNormalizer.sanitizeMetadataText(self.definition.description)
            ?? "Provided by MCP server \"\(self.serverName)\"."
        return AgentToolDescriptor(
            name: self.name,
            label: MCPToolCatalogNormalizer.sanitizeMetadataText(self.definition.title) ?? self.definition.name,
            description: description,
            parameters: self.definition.inputSchema,
            outputSchema: self.definition.outputSchema,
            source: .mcp(server: self.serverName, toolName: self.definition.name),
            tags: ["mcp"],
            executionMode: self.supportsParallelToolCalls ? .parallel : .sequential,
            resultContentSource: .network
        )
    }

    /// Calls the MCP tool and maps its result.
    public func invoke(_ invocation: AgentToolInvocation, update _: AgentToolUpdateHandler?) async throws -> AgentToolOutput {
        let result = try await self.caller(self.serverName, self.definition.name, invocation.arguments)
        return try Self.output(for: result, outputSchema: self.definition.outputSchema, toolName: self.definition.name)
    }

    /// Maps an MCP call result onto an agent tool output (upstream result validation included).
    /// - Parameters:
    ///   - result: MCP result.
    ///   - outputSchema: Declared output schema.
    ///   - toolName: Tool name (for messages).
    /// - Returns: The output.
    public static func output(for result: MCPCallToolResult, outputSchema: [String: AnyCodable]?, toolName: String) throws -> AgentToolOutput {
        if let outputSchema, !result.isError {
            guard let structured = result.structuredContent else {
                throw MCPTransportError.protocolViolation("Tool \(toolName) has an output schema but did not return structured content")
            }
            do {
                try MCPJSONSchemaValidator.validate(structured, against: outputSchema)
            } catch {
                throw MCPTransportError.protocolViolation(
                    "Structured content does not match the tool's output schema: \(error.localizedDescription)"
                )
            }
        }
        var blocks: [AgentToolContentBlock] = []
        var extra: [AnyCodable] = []
        for raw in result.content {
            guard let block = raw.dictionaryValue else { continue }
            switch block["type"]?.stringValue {
            case "text":
                blocks.append(.text(block["text"]?.stringValue ?? ""))
            case "image":
                if let data = block["data"]?.stringValue, let mimeType = block["mimeType"]?.stringValue {
                    blocks.append(.image(data: data, mimeType: mimeType))
                }
            case "audio":
                blocks.append(.text("[audio: \(block["mimeType"]?.stringValue ?? "unknown type")]"))
                extra.append(raw)
            case "resource":
                let resource = block["resource"]?.dictionaryValue ?? [:]
                if let text = resource["text"]?.stringValue {
                    blocks.append(.text(text))
                } else {
                    blocks.append(.text("[resource: \(resource["uri"]?.stringValue ?? "embedded")]"))
                }
                extra.append(raw)
            case "resource_link":
                let label = block["name"]?.stringValue ?? block["uri"]?.stringValue ?? "resource"
                blocks.append(.text("[resource link: \(label) \(block["uri"]?.stringValue ?? "")]".replacingOccurrences(of: " ]", with: "]")))
                extra.append(raw)
            default:
                extra.append(raw)
            }
        }
        var details: AnyCodable?
        if let structured = result.structuredContent {
            details = structured
        } else if !extra.isEmpty {
            details = AnyCodable(["content": AnyCodable(extra)])
        }
        if blocks.isEmpty, let structured = result.structuredContent {
            blocks.append(.text(AgentToolOutput.json(structured).text))
        }
        return AgentToolOutput(content: blocks, details: details, isError: result.isError)
    }
}
