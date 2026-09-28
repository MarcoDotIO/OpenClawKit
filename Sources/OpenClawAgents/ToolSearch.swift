import Foundation
import OpenClawCore
import OpenClawProtocol

// Structured Tool Search (upstream `docs/tools/tool-search.md`, `src/agents/tool-search*.ts`):
// large tool catalogs move behind `tool_search` / `tool_describe` / `tool_call`; directly visible
// tools keep their schemas. `directory` mode adds a cache-stable prompt list of trusted tool names.

/// One searchable tool.
public struct ToolSearchCatalogEntry: Sendable, Equatable {
    /// Catalog id (the tool name).
    public var id: String
    /// `openclaw` (core and plugin tools), `mcp` or `client`.
    public var source: String
    /// MCP server or plugin id.
    public var sourceName: String?
    /// Tool name.
    public var name: String
    /// Display label.
    public var label: String?
    /// Description.
    public var description: String
    /// Parameter schema.
    public var parameters: [String: AnyCodable]
    /// Whether the tool stays directly visible to the model.
    public var directVisible: Bool

    /// Whether the metadata comes from a trusted source (core or plugin tools).
    public var isTrusted: Bool {
        self.source == "openclaw"
    }

    /// Model-facing description (untrusted metadata is marked and capped at 512 characters).
    public var searchDescription: String {
        let capped = String(self.description.prefix(512))
        return self.isTrusted ? capped : "[untrusted \(self.source) tool metadata] \(capped)"
    }

    /// Search result row.
    var resultPayload: [String: AnyCodable] {
        var payload: [String: AnyCodable] = [
            "id": AnyCodable(self.id),
            "name": AnyCodable(self.name),
            "source": AnyCodable(self.source),
            "description": AnyCodable(self.searchDescription),
        ]
        if let label, label != self.name { payload["label"] = AnyCodable(label) }
        return payload
    }
}

/// Catalog of policy-visible tools for Tool Search.
public struct ToolSearchCatalog: Sendable {
    /// Control tool names.
    public static let searchToolName = "tool_search"
    /// Control tool names.
    public static let describeToolName = "tool_describe"
    /// Control tool names.
    public static let callToolName = "tool_call"
    /// Every control tool name.
    public static let controlToolNames: Set<String> = [searchToolName, describeToolName, callToolName]
    /// Core coding primitives that always stay directly visible.
    public static let directPrimitives: Set<String> = ["read", "write", "edit", "exec", "ask_user"]

    /// Entries sorted by id.
    public let entries: [ToolSearchCatalogEntry]
    /// Resolved configuration.
    public let configuration: ToolSearchConfiguration
    private let descriptors: [String: AgentToolDescriptor]

    /// Builds a catalog from policy-filtered descriptors.
    /// - Parameters:
    ///   - descriptors: Visible descriptors.
    ///   - configuration: Tool Search configuration.
    public init(descriptors: [AgentToolDescriptor], configuration: ToolSearchConfiguration) {
        self.configuration = configuration
        self.descriptors = Dictionary(descriptors.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        self.entries = descriptors
            .filter { !Self.controlToolNames.contains($0.name) }
            .map { descriptor in
                let source: String
                let sourceName: String?
                switch descriptor.source {
                case .core:
                    source = "openclaw"
                    sourceName = nil
                case .plugin(let id):
                    source = "openclaw"
                    sourceName = id
                case .mcp(let server, _):
                    source = "mcp"
                    sourceName = server
                case .client, .channel:
                    source = "client"
                    sourceName = nil
                }
                return ToolSearchCatalogEntry(
                    id: descriptor.name,
                    source: source,
                    sourceName: sourceName,
                    name: descriptor.name,
                    label: descriptor.label,
                    description: descriptor.description,
                    parameters: descriptor.parameters,
                    directVisible: descriptor.catalogMode == .directOnly || Self.directPrimitives.contains(descriptor.name)
                )
            }
            .sorted { $0.id < $1.id }
    }

    /// Whether the catalog should hide tools behind search (enabled and at least ``ToolSearchConfiguration/minCatalogSize`` tools).
    public var isActive: Bool {
        self.configuration.enabled && self.entries.count >= self.configuration.minCatalogSize
    }

    /// Descriptor for an id.
    /// - Parameter id: Catalog id.
    /// - Returns: The descriptor.
    public func descriptor(for id: String) -> AgentToolDescriptor? {
        self.descriptors[id] ?? self.descriptors[AgentToolRegistry.canonicalName(id)]
    }

    /// Descriptors sent to the model: directly visible tools plus the control tools.
    public var modelVisibleDescriptors: [AgentToolDescriptor] {
        let direct = self.entries.filter(\.directVisible).compactMap { self.descriptors[$0.id] }
        return (direct + Self.controlDescriptors).sorted { $0.name < $1.name }
    }

    /// Ranks entries for a query (BM25 over name and description tokens; exact names first).
    /// - Parameters:
    ///   - query: Query text.
    ///   - limit: Maximum results.
    /// - Returns: Ranked entries.
    public func search(_ query: String, limit: Int) -> [ToolSearchCatalogEntry] {
        let terms = Self.tokenize(query)
        guard !terms.isEmpty, limit > 0 else { return [] }
        let documents = self.entries.map { Self.tokenize("\($0.name) \($0.label ?? "") \($0.description)") }
        let averageLength = max(1, Double(documents.map(\.count).reduce(0, +)) / Double(max(1, documents.count)))
        var documentFrequency: [String: Int] = [:]
        for document in documents {
            for term in Set(document) {
                documentFrequency[term, default: 0] += 1
            }
        }
        let count = Double(documents.count)
        let lowered = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var scored: [(Double, ToolSearchCatalogEntry)] = []
        for (index, document) in documents.enumerated() {
            let entry = self.entries[index]
            var score = 0.0
            for term in terms {
                let frequency = Double(document.filter { $0 == term }.count)
                guard frequency > 0 else { continue }
                let df = Double(documentFrequency[term] ?? 0)
                let idf = log(1 + (count - df + 0.5) / (df + 0.5))
                let length = Double(document.count)
                score += idf * (frequency * 2.2) / (frequency + 1.2 * (0.25 + 0.75 * length / averageLength))
            }
            if entry.name.lowercased() == lowered {
                score += 100
            }
            if score > 0 {
                scored.append((score, entry))
            }
        }
        return scored
            .sorted { $0.0 == $1.0 ? $0.1.id < $1.1.id : $0.0 > $1.0 }
            .prefix(limit)
            .map(\.1)
    }

    /// Cache-stable directory of trusted tool names and short descriptions (sorted, ≤ 18000 characters).
    /// - Returns: The directory prompt section, or `nil` when there are no trusted tools.
    public func directoryPrompt() -> String? {
        let trusted = self.entries.filter(\.isTrusted)
        guard !trusted.isEmpty else { return nil }
        var lines = ["## Tool Directory", "Use tool_describe for schemas and tool_call to run tools not listed directly."]
        var total = lines.joined(separator: "\n").count
        for entry in trusted {
            let summary = entry.description.split(separator: "\n").first.map { String($0.prefix(120)) } ?? ""
            let line = summary.isEmpty ? "- \(entry.name)" : "- \(entry.name): \(summary)"
            guard total + line.count + 1 <= ToolSearchConfiguration.maxDirectoryChars else { break }
            lines.append(line)
            total += line.count + 1
        }
        return lines.joined(separator: "\n")
    }

    /// Bounded input signature shown when `tool_call` arguments are invalid (≤ 512 characters).
    /// - Parameter descriptor: Target descriptor.
    /// - Returns: Signature text.
    public static func inputSignature(_ descriptor: AgentToolDescriptor) -> String {
        let properties = descriptor.parameters["properties"]?.dictionaryValue ?? [:]
        let required = Set(descriptor.parameters["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        let fields = properties.keys.sorted().map { key -> String in
            let type = properties[key]?.dictionaryValue?["type"]?.stringValue ?? "any"
            return "\(key)\(required.contains(key) ? "" : "?"): \(type)"
        }
        return String("\(descriptor.name)({\(fields.joined(separator: ", "))})".prefix(512))
    }

    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var previousLower = false
        for character in text {
            if character.isLetter || character.isNumber {
                if character.isUppercase, previousLower, !current.isEmpty {
                    tokens.append(current.lowercased())
                    current = ""
                }
                current.append(character)
                previousLower = character.isLowercase
            } else {
                if !current.isEmpty {
                    tokens.append(current.lowercased())
                }
                current = ""
                previousLower = false
            }
        }
        if !current.isEmpty {
            tokens.append(current.lowercased())
        }
        return tokens
    }

    /// Descriptors of the control tools.
    public static let controlDescriptors: [AgentToolDescriptor] = [
        AgentToolDescriptor(
            name: searchToolName,
            label: "Tool Search",
            description: "Search the tool catalog. Pass `query` (English keywords) or `queries` for up to 16 searches; "
                + "then use tool_describe for a schema and tool_call to run a tool.",
            parameters: [
                "type": AnyCodable("object"),
                "additionalProperties": AnyCodable(false),
                "properties": AnyCodable([
                    "query": AnyCodable(["type": AnyCodable(["string", "null"])]),
                    "limit": AnyCodable(["type": AnyCodable(["integer", "null"]), "minimum": AnyCodable(1)]),
                    "queries": AnyCodable([
                        "type": AnyCodable(["array", "null"]),
                        "maxItems": AnyCodable(ToolSearchConfiguration.maxBatchQueries),
                        "items": AnyCodable([
                            "type": AnyCodable("object"),
                            "required": AnyCodable(["query"]),
                            "properties": AnyCodable([
                                "query": AnyCodable(["type": AnyCodable("string"), "minLength": AnyCodable(1)]),
                                "limit": AnyCodable(["type": AnyCodable("integer"), "minimum": AnyCodable(1)]),
                            ]),
                        ]),
                    ]),
                ]),
            ],
            catalogMode: .directOnly
        ),
        AgentToolDescriptor(
            name: describeToolName,
            label: "Tool Describe",
            description: "Return the full description and JSON Schema of a catalog tool.",
            parameters: [
                "type": AnyCodable("object"),
                "required": AnyCodable(["id"]),
                "additionalProperties": AnyCodable(false),
                "properties": AnyCodable(["id": AnyCodable(["type": AnyCodable("string"), "minLength": AnyCodable(1)])]),
            ],
            catalogMode: .directOnly
        ),
        AgentToolDescriptor(
            name: callToolName,
            label: "Tool Call",
            description: "Call a catalog tool by id with arguments matching its schema.",
            parameters: [
                "type": AnyCodable("object"),
                "required": AnyCodable(["id"]),
                "additionalProperties": AnyCodable(false),
                "properties": AnyCodable([
                    "id": AnyCodable(["type": AnyCodable("string"), "minLength": AnyCodable(1)]),
                    "args": AnyCodable(["type": AnyCodable(["object", "null"])]),
                ]),
            ],
            catalogMode: .directOnly
        ),
    ]

    /// Runs `tool_search`.
    /// - Parameter arguments: Tool arguments.
    /// - Returns: The tool output.
    public func runSearch(_ arguments: [String: AnyCodable]) -> AgentToolOutput {
        let defaultLimit = self.configuration.searchDefaultLimit
        let maxLimit = self.configuration.maxSearchLimit
        if let queries = arguments["queries"]?.arrayValue, !queries.isEmpty {
            guard queries.count <= ToolSearchConfiguration.maxBatchQueries else {
                return .error("tool_search accepts at most \(ToolSearchConfiguration.maxBatchQueries) queries")
            }
            var searches: [(String, Int)] = []
            for raw in queries {
                guard let query = raw.dictionaryValue?["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !query.isEmpty, query.count <= ToolSearchConfiguration.maxBatchQueryGraphemes
                else {
                    return .error("each tool_search query needs 1-\(ToolSearchConfiguration.maxBatchQueryGraphemes) characters")
                }
                let limit = min(maxLimit, max(1, raw.dictionaryValue?["limit"]?.intValue ?? defaultLimit))
                searches.append((query, limit))
            }
            guard searches.map(\.0.utf8.count).reduce(0, +) <= ToolSearchConfiguration.maxBatchQueryBytes else {
                return .error("tool_search batch queries exceed \(ToolSearchConfiguration.maxBatchQueryBytes) bytes")
            }
            guard searches.map(\.1).reduce(0, +) <= ToolSearchConfiguration.maxResults else {
                return .error("tool_search batch limits exceed \(ToolSearchConfiguration.maxResults) results")
            }
            var batches: [AnyCodable] = []
            var budget = ToolSearchConfiguration.maxBatchResponseChars
            for (query, limit) in searches {
                var rows: [AnyCodable] = []
                for entry in self.search(query, limit: limit) {
                    let row = AnyCodable(entry.resultPayload)
                    let size = AgentToolOutput.renderText(row).count
                    guard size <= budget else { break }
                    budget -= size
                    rows.append(row)
                }
                batches.append(AnyCodable(["query": AnyCodable(query), "results": AnyCodable(rows)]))
            }
            return .json(AnyCodable(["batches": AnyCodable(batches)]))
        }
        guard let query = arguments["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            return .error("tool_search requires query or queries")
        }
        let limit = min(maxLimit, max(1, arguments["limit"]?.intValue ?? defaultLimit))
        let rows = self.search(query, limit: limit).map { AnyCodable($0.resultPayload) }
        return .json(AnyCodable(["results": AnyCodable(rows)]))
    }

    /// Runs `tool_describe`.
    /// - Parameter arguments: Tool arguments.
    /// - Returns: The tool output.
    public func runDescribe(_ arguments: [String: AnyCodable]) -> AgentToolOutput {
        guard let id = arguments["id"]?.stringValue, let entry = self.entries.first(where: { $0.id == id }) else {
            return .error("Unknown tool id: \(arguments["id"]?.stringValue ?? "")")
        }
        return .json(AnyCodable([
            "id": AnyCodable(entry.id),
            "name": AnyCodable(entry.name),
            "source": AnyCodable(entry.source),
            "description": AnyCodable(entry.isTrusted ? entry.description : entry.searchDescription),
            "parameters": AnyCodable(entry.parameters),
        ]))
    }
}
