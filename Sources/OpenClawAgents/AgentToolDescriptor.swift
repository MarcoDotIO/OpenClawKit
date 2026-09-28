import Foundation
import OpenClawModels
import OpenClawProtocol

// AgentTool v2 contract: descriptors (name, description, JSON-Schema parameters, display and
// catalog metadata), structured outputs, and invocation context. Shapes follow upstream
// `packages/agent-core/src/types.ts` (AgentTool, AgentToolResult, AgentToolUpdateCallback) and
// `packages/llm-core/src/types.ts` (TextContent/ImageContent).

// MARK: - Descriptor vocabulary

/// Where an agent tool comes from.
///
/// Wire shape: `{"kind":"core"}`, `{"kind":"plugin","pluginId":…}`,
/// `{"kind":"mcp","mcpServer":…,"mcpToolName":…}`, `{"kind":"client"}` and
/// `{"kind":"channel","channelId":…}`.
public enum AgentToolSource: Codable, Sendable, Equatable, Hashable {
    /// Built into OpenClaw core.
    case core
    /// Registered by a plugin.
    case plugin(id: String)
    /// Bridged from a Model Context Protocol server tool.
    case mcp(server: String, toolName: String)
    /// Provided by the connected client application.
    case client
    /// Provided by a channel adapter.
    case channel(id: String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case pluginID = "pluginId"
        case mcpServer
        case mcpToolName
        case channelID = "channelId"
    }

    /// Decodes a tool source.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "core":
            self = .core
        case "plugin":
            self = .plugin(id: try container.decode(String.self, forKey: .pluginID))
        case "mcp":
            self = .mcp(
                server: try container.decode(String.self, forKey: .mcpServer),
                toolName: try container.decode(String.self, forKey: .mcpToolName)
            )
        case "client":
            self = .client
        case "channel":
            self = .channel(id: try container.decode(String.self, forKey: .channelID))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Unknown tool source \(kind)")
        }
    }

    /// Encodes a tool source.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .core:
            try container.encode("core", forKey: .kind)
        case .plugin(let id):
            try container.encode("plugin", forKey: .kind)
            try container.encode(id, forKey: .pluginID)
        case .mcp(let server, let toolName):
            try container.encode("mcp", forKey: .kind)
            try container.encode(server, forKey: .mcpServer)
            try container.encode(toolName, forKey: .mcpToolName)
        case .client:
            try container.encode("client", forKey: .kind)
        case .channel(let id):
            try container.encode("channel", forKey: .kind)
            try container.encode(id, forKey: .channelID)
        }
    }
}

/// Tool profile identifier (open vocabulary; upstream profiles are minimal, coding, messaging, full).
public struct ToolProfileID: RawRepresentable, Codable, Sendable, Hashable, ExpressibleByStringLiteral {
    /// Profile identifier.
    public let rawValue: String

    /// Creates a profile identifier.
    /// - Parameter rawValue: Profile identifier.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates a profile identifier from a string literal.
    /// - Parameter value: Profile identifier.
    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    /// Decodes a profile identifier from a string.
    public init(from decoder: Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    /// Encodes the profile identifier as a string.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }

    /// Minimal profile.
    public static let minimal: ToolProfileID = "minimal"
    /// Coding profile.
    public static let coding: ToolProfileID = "coding"
    /// Messaging profile.
    public static let messaging: ToolProfileID = "messaging"
    /// Full profile (every tool).
    public static let full: ToolProfileID = "full"
}

/// Risk classification shown before running a tool.
public enum ToolRisk: String, Codable, Sendable, Equatable, CaseIterable {
    /// Read-only or otherwise harmless.
    case low
    /// Changes local state.
    case medium
    /// Runs code, spends money, or reaches external systems.
    case high
}

/// Whether a tool may run concurrently with other tool calls in the same batch.
public enum ToolExecutionMode: String, Codable, Sendable, Equatable, CaseIterable {
    /// Runs one at a time with the other calls of the batch.
    case sequential
    /// May run concurrently with the other calls of the batch.
    case parallel
}

/// How a tool is exposed to models.
public enum ToolCatalogMode: String, Codable, Sendable, Equatable, CaseIterable {
    /// Eligible for catalog/tool-search style exposure.
    case catalog
    /// Always exposed directly; hidden catalog bridges cannot preserve its result contract.
    case directOnly = "direct-only"
}

/// Origin class of tool output that can taint later model-authored content.
public enum ToolResultContentSource: String, Codable, Sendable, Equatable, CaseIterable {
    /// Output contains externally controlled network content.
    case network
}

/// Presentation metadata for tool UIs (parity with `tool-display.json`).
public struct AgentToolDisplay: Codable, Sendable, Equatable {
    /// Display title.
    public var title: String?
    /// Display emoji.
    public var emoji: String?
    /// Display category or section label.
    public var category: String?

    /// Creates tool display metadata.
    /// - Parameters:
    ///   - title: Display title.
    ///   - emoji: Display emoji.
    ///   - category: Display category.
    public init(title: String? = nil, emoji: String? = nil, category: String? = nil) {
        self.title = title
        self.emoji = emoji
        self.category = category
    }
}

// MARK: - Descriptor

/// Model- and UI-facing description of an agent tool.
///
/// ``modelToolDefinition`` converts a descriptor into the ``ModelToolDefinition`` sent to model
/// providers. Unknown or missing keys decode to their defaults.
public struct AgentToolDescriptor: Codable, Sendable, Equatable {
    /// Maximum length of a model-facing tool name.
    public static let maxNameLength = 64

    /// Empty-object parameter schema used when a tool declares no parameters.
    public static let emptyParametersSchema: [String: AnyCodable] = ModelToolDefinition.emptyParametersSchema

    /// Model-facing tool name (see ``isValidName(_:)``).
    public var name: String
    /// Human-readable label for UI display.
    public var label: String
    /// Description shown to the model.
    public var description: String
    /// Optional one-line summary for UI surfaces.
    public var displaySummary: String?
    /// Optional presentation metadata.
    public var display: AgentToolDisplay?
    /// JSON Schema object describing the arguments.
    public var parameters: [String: AnyCodable]
    /// Optional JSON Schema of the structured ``AgentToolOutput/details``.
    public var outputSchema: [String: AnyCodable]?
    /// Tool origin.
    public var source: AgentToolSource
    /// Optional catalog section identifier.
    public var sectionID: String?
    /// Profiles that enable the tool by default.
    public var defaultProfiles: [ToolProfileID]
    /// Optional risk classification.
    public var risk: ToolRisk?
    /// Free-form tags.
    public var tags: [String]
    /// Optional per-tool execution mode override.
    public var executionMode: ToolExecutionMode?
    /// Whether re-running the tool on transcript replay is safe.
    public var replaySafe: Bool
    /// How the tool is exposed to models.
    public var catalogMode: ToolCatalogMode
    /// Keep lifecycle telemetry but hide transient channel progress.
    public var hideFromChannelProgress: Bool
    /// Origin class of the tool output.
    public var resultContentSource: ToolResultContentSource?

    /// Creates a tool descriptor.
    /// - Parameters:
    ///   - name: Model-facing tool name.
    ///   - label: UI label; defaults to `name`.
    ///   - description: Description shown to the model.
    ///   - displaySummary: Optional UI summary.
    ///   - display: Optional presentation metadata.
    ///   - parameters: JSON Schema object for the arguments.
    ///   - outputSchema: Optional JSON Schema of the output details.
    ///   - source: Tool origin.
    ///   - sectionID: Optional catalog section.
    ///   - defaultProfiles: Profiles that enable the tool by default.
    ///   - risk: Optional risk classification.
    ///   - tags: Free-form tags.
    ///   - executionMode: Optional execution mode override.
    ///   - replaySafe: Whether replay may re-run the tool.
    ///   - catalogMode: Model exposure mode.
    ///   - hideFromChannelProgress: Hide transient channel progress.
    ///   - resultContentSource: Origin class of the output.
    public init(
        name: String,
        label: String? = nil,
        description: String = "",
        displaySummary: String? = nil,
        display: AgentToolDisplay? = nil,
        parameters: [String: AnyCodable] = AgentToolDescriptor.emptyParametersSchema,
        outputSchema: [String: AnyCodable]? = nil,
        source: AgentToolSource = .core,
        sectionID: String? = nil,
        defaultProfiles: [ToolProfileID] = [],
        risk: ToolRisk? = nil,
        tags: [String] = [],
        executionMode: ToolExecutionMode? = nil,
        replaySafe: Bool = false,
        catalogMode: ToolCatalogMode = .catalog,
        hideFromChannelProgress: Bool = false,
        resultContentSource: ToolResultContentSource? = nil
    ) {
        self.name = name
        self.label = label ?? name
        self.description = description
        self.displaySummary = displaySummary
        self.display = display
        self.parameters = parameters
        self.outputSchema = outputSchema
        self.source = source
        self.sectionID = sectionID
        self.defaultProfiles = defaultProfiles
        self.risk = risk
        self.tags = tags
        self.executionMode = executionMode
        self.replaySafe = replaySafe
        self.catalogMode = catalogMode
        self.hideFromChannelProgress = hideFromChannelProgress
        self.resultContentSource = resultContentSource
    }

    /// Returns whether `name` is a valid model-facing tool name: `^[A-Za-z][A-Za-z0-9_-]{0,63}$`.
    /// - Parameter name: Candidate tool name.
    /// - Returns: `true` when providers accept the name.
    public static func isValidName(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        guard let first = scalars.first, scalars.count <= Self.maxNameLength, Self.isASCIILetter(first) else {
            return false
        }
        return scalars.dropFirst().allSatisfy { scalar in
            Self.isASCIILetter(scalar) || (48...57).contains(scalar.value) || scalar == "_" || scalar == "-"
        }
    }

    /// Whether ``name`` passes ``isValidName(_:)``.
    public var hasValidName: Bool {
        Self.isValidName(self.name)
    }

    /// Provider-facing tool declaration for this descriptor.
    public var modelToolDefinition: ModelToolDefinition {
        self.modelToolDefinition(strict: nil)
    }

    /// Provider-facing tool declaration for this descriptor.
    /// - Parameter strict: Optional strict-schema request.
    /// - Returns: The model tool definition.
    public func modelToolDefinition(strict: Bool?) -> ModelToolDefinition {
        ModelToolDefinition(name: self.name, description: self.description, parameters: self.parameters, strict: strict)
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case label
        case description
        case displaySummary
        case display
        case parameters
        case outputSchema
        case source
        case sectionID = "sectionId"
        case defaultProfiles
        case risk
        case tags
        case executionMode
        case replaySafe
        case catalogMode
        case hideFromChannelProgress
        case resultContentSource
    }

    /// Decodes a descriptor; only `name` is required and unknown vocabulary values fall back to defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        self.init(
            name: name,
            label: try container.decodeIfPresent(String.self, forKey: .label),
            description: try container.decodeIfPresent(String.self, forKey: .description) ?? "",
            displaySummary: try container.decodeIfPresent(String.self, forKey: .displaySummary),
            display: try container.decodeIfPresent(AgentToolDisplay.self, forKey: .display),
            parameters: try container.decodeIfPresent([String: AnyCodable].self, forKey: .parameters)
                ?? Self.emptyParametersSchema,
            outputSchema: try container.decodeIfPresent([String: AnyCodable].self, forKey: .outputSchema),
            source: (try? container.decodeIfPresent(AgentToolSource.self, forKey: .source)) ?? .core,
            sectionID: try container.decodeIfPresent(String.self, forKey: .sectionID),
            defaultProfiles: try container.decodeIfPresent([ToolProfileID].self, forKey: .defaultProfiles) ?? [],
            risk: try? container.decodeIfPresent(ToolRisk.self, forKey: .risk),
            tags: try container.decodeIfPresent([String].self, forKey: .tags) ?? [],
            executionMode: try? container.decodeIfPresent(ToolExecutionMode.self, forKey: .executionMode),
            replaySafe: try container.decodeIfPresent(Bool.self, forKey: .replaySafe) ?? false,
            catalogMode: (try? container.decodeIfPresent(ToolCatalogMode.self, forKey: .catalogMode)) ?? .catalog,
            hideFromChannelProgress: try container.decodeIfPresent(Bool.self, forKey: .hideFromChannelProgress) ?? false,
            resultContentSource: try? container.decodeIfPresent(ToolResultContentSource.self, forKey: .resultContentSource)
        )
    }
}

public extension Array where Element == AgentToolDescriptor {
    /// Provider-facing tool declarations for these descriptors, in order.
    var modelToolDefinitions: [ModelToolDefinition] {
        self.map(\.modelToolDefinition)
    }
}

// MARK: - Output

/// Content block returned to the model by a tool (upstream llm-core `TextContent`/`ImageContent`).
///
/// Wire shape: `{"type":"text","text":…}` and `{"type":"image","data":"<base64>","mimeType":…}`.
public enum AgentToolContentBlock: Codable, Sendable, Equatable {
    /// Text content.
    case text(String)
    /// Base64-encoded image content.
    case image(data: String, mimeType: String)

    /// Text payload of a `.text` block.
    public var text: String? {
        guard case .text(let value) = self else { return nil }
        return value
    }

    /// Model content part for this block; images with invalid base64 data become `nil`.
    public var modelContentPart: ModelContentPart? {
        switch self {
        case .text(let value):
            return .text(value)
        case .image(let data, let mimeType):
            guard let bytes = Data(base64Encoded: data) else { return nil }
            return .image(MediaAttachment(mimeType: mimeType, data: bytes))
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case data
        case mimeType
    }

    /// Decodes a content block.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        case "image":
            self = .image(
                data: try container.decode(String.self, forKey: .data),
                mimeType: try container.decode(String.self, forKey: .mimeType)
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown content block \(type)")
        }
    }

    /// Encodes a content block.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode("text", forKey: .type)
            try container.encode(value, forKey: .text)
        case .image(let data, let mimeType):
            try container.encode("image", forKey: .type)
            try container.encode(data, forKey: .data)
            try container.encode(mimeType, forKey: .mimeType)
        }
    }
}

/// Channel-safe progress hint attached to partial tool updates; never model content.
public struct AgentToolProgress: Codable, Sendable, Equatable {
    /// Public progress text.
    public var message: String?
    /// Completion fraction in `0...1`.
    public var fraction: Double?
    /// Optional stable identifier for progress-line replacement.
    public var id: String?

    /// Creates a progress hint.
    /// - Parameters:
    ///   - message: Public progress text.
    ///   - fraction: Completion fraction, clamped to `0...1`.
    ///   - id: Optional stable identifier.
    public init(message: String? = nil, fraction: Double? = nil, id: String? = nil) {
        self.message = message
        self.fraction = fraction.map { Swift.min(1, Swift.max(0, $0)) }
        self.id = id
    }
}

/// Final or partial result produced by a tool (upstream `AgentToolResult`).
public struct AgentToolOutput: Sendable, Equatable {
    /// Content returned to the model.
    public var content: [AgentToolContentBlock]
    /// Structured details for logs and UI rendering.
    public var details: AnyCodable?
    /// Whether the tool failed.
    public var isError: Bool
    /// Hint that the agent should stop after the current tool batch.
    public var terminate: Bool
    /// Optional progress hint for partial updates.
    public var progress: AgentToolProgress?

    /// Creates a tool output.
    /// - Parameters:
    ///   - content: Content returned to the model.
    ///   - details: Structured details.
    ///   - isError: Whether the tool failed.
    ///   - terminate: Stop after the current batch.
    ///   - progress: Optional progress hint.
    public init(
        content: [AgentToolContentBlock] = [],
        details: AnyCodable? = nil,
        isError: Bool = false,
        terminate: Bool = false,
        progress: AgentToolProgress? = nil
    ) {
        self.content = content
        self.details = details
        self.isError = isError
        self.terminate = terminate
        self.progress = progress
    }

    /// Creates a text-only output.
    /// - Parameters:
    ///   - text: Text returned to the model.
    ///   - details: Optional structured details.
    /// - Returns: A text output.
    public static func text(_ text: String, details: AnyCodable? = nil) -> AgentToolOutput {
        AgentToolOutput(content: [.text(text)], details: details)
    }

    /// Wraps a JSON value: it becomes ``details`` plus one text block (strings verbatim, everything
    /// else as compact JSON).
    /// - Parameter value: Tool return value.
    /// - Returns: A JSON output.
    public static func json(_ value: AnyCodable) -> AgentToolOutput {
        AgentToolOutput(content: [.text(Self.renderText(value))], details: value)
    }

    /// Creates an error output whose text is shown to the model.
    /// - Parameter message: Error description.
    /// - Returns: An error output.
    public static func error(_ message: String) -> AgentToolOutput {
        AgentToolOutput(content: [.text(message)], isError: true)
    }

    /// Concatenated text of all `.text` blocks.
    public var text: String {
        self.content.compactMap(\.text).joined(separator: "\n")
    }

    /// Converts this output into the tool-result message sent back to the model.
    /// - Parameters:
    ///   - toolCallID: Identifier of the answered tool call.
    ///   - toolName: Tool name.
    /// - Returns: The model tool result.
    public func modelToolResult(toolCallID: String, toolName: String) -> ModelToolResult {
        ModelToolResult(
            toolCallID: toolCallID,
            toolName: toolName,
            content: self.content.compactMap(\.modelContentPart),
            isError: self.isError,
            details: self.details
        )
    }

    static func renderText(_ value: AnyCodable) -> String {
        if case .string(let text) = value.value {
            return text
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else {
            return String(describing: value.value)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Invocation

/// Run-scoped context passed to every tool invocation.
public struct AgentToolInvocationContext: Sendable, Equatable {
    /// Agent run identifier.
    public var runID: String?
    /// Session key of the run.
    public var sessionKey: String?
    /// Agent identifier.
    public var agentID: String?
    /// Parent tool call when a tool invokes another tool.
    public var parentToolCallID: String?

    /// Creates an invocation context.
    /// - Parameters:
    ///   - runID: Agent run identifier.
    ///   - sessionKey: Session key.
    ///   - agentID: Agent identifier.
    ///   - parentToolCallID: Parent tool call identifier.
    public init(runID: String? = nil, sessionKey: String? = nil, agentID: String? = nil, parentToolCallID: String? = nil) {
        self.runID = runID
        self.sessionKey = sessionKey
        self.agentID = agentID
        self.parentToolCallID = parentToolCallID
    }
}

/// One tool invocation: the call identifier, arguments, and run context.
public struct AgentToolInvocation: Sendable, Equatable {
    /// Tool call identifier.
    public var toolCallID: String
    /// Agent run identifier.
    public var runID: String?
    /// Session key of the run.
    public var sessionKey: String?
    /// Agent identifier.
    public var agentID: String?
    /// Parent tool call when a tool invokes another tool.
    public var parentToolCallID: String?
    /// Tool arguments.
    public var arguments: [String: AnyCodable]
    /// Set by the default `execute(arguments:)` bridge to detect tools that implement neither entry point.
    var isExecuteBridge = false

    /// Creates an invocation.
    /// - Parameters:
    ///   - toolCallID: Tool call identifier; defaults to a new `call_<uuid>` identifier.
    ///   - arguments: Tool arguments.
    ///   - context: Run-scoped context.
    public init(
        toolCallID: String = AgentToolCall.makeID(),
        arguments: [String: AnyCodable] = [:],
        context: AgentToolInvocationContext = AgentToolInvocationContext()
    ) {
        self.toolCallID = toolCallID
        self.arguments = arguments
        self.runID = context.runID
        self.sessionKey = context.sessionKey
        self.agentID = context.agentID
        self.parentToolCallID = context.parentToolCallID
    }
}

/// Callback tools use to stream partial results while running.
public typealias AgentToolUpdateHandler = @Sendable (AgentToolOutput) async -> Void
