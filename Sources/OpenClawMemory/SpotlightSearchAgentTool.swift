#if compiler(>=6.4) && canImport(CoreSpotlight) && canImport(FoundationModels) && !os(tvOS) && !os(watchOS) && arch(arm64)
import CoreSpotlight
import Foundation
import FoundationModels
import OpenClawAgents
import OpenClawCore
import OpenClawProtocol

/// Apple's `SpotlightSearchTool` (the `_CoreSpotlight_FoundationModels` overlay) exposed as an
/// OpenClaw agent tool (`spotlight_search`), so any provider can search Spotlight, not only
/// FoundationModels sessions.
///
/// Privacy: results can include the user's personal data. The default configuration searches the
/// app's own CoreSpotlight items only; add `.files` sources explicitly when the user opts in. The
/// tool is OpenClaw-owned (not an upstream id): section `web`, profile `coding`, risk `low`.
/// Apple silicon only: the SDK's x86_64 overlay does not declare `SpotlightSearchTool`.
///
/// Invocations on one tool value (and its copies) run one at a time, because the underlying
/// `SpotlightSearchTool` publishes structured replies on a single shared stream; each call is bounded
/// by `callTimeoutSeconds` and reports a timeout as an error result.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
public struct SpotlightSearchAgentTool: AgentTool {
    /// Tool name.
    public let name = "spotlight_search"
    private let tool: SpotlightSearchTool
    private let replyTimeoutSeconds: Double
    private let callTimeoutSeconds: Double
    private let replies: SpotlightReplyCoordinator<SpotlightSearchTool.SearchReply>

    /// Creates the tool.
    /// - Parameters:
    ///   - configuration: Search configuration (default: app CoreSpotlight items).
    ///   - replyTimeoutSeconds: How long to wait for structured search replies after a call (clamped to
    ///     50 ms...one year; `.infinity` waits without a deadline).
    ///   - callTimeoutSeconds: Deadline for the Spotlight search itself (same clamping); on timeout the
    ///     tool returns an error result instead of waiting on a stalled search.
    public init(
        configuration: SpotlightSearchTool.Configuration = SpotlightSearchTool.Configuration(sources: [.coreSpotlight]),
        replyTimeoutSeconds: Double = 2,
        callTimeoutSeconds: Double = 30
    ) {
        self.tool = SpotlightSearchTool(configuration: configuration)
        self.replyTimeoutSeconds = replyTimeoutSeconds
        self.callTimeoutSeconds = callTimeoutSeconds
        self.replies = SpotlightReplyCoordinator { $0.status == .complete }
    }

    /// Creates the tool over CoreSpotlight items with the given fetch attributes (and optionally files).
    /// - Parameters:
    ///   - fetchAttributes: Attributes fetched for CoreSpotlight items.
    ///   - includeFiles: Also search the user's files (requires explicit consent).
    ///   - maximumResponseSize: Response size cap.
    ///   - indexDelegate: Optional `CSSearchableIndexDelegate` that hydrates app-indexed items, for
    ///     example the ``SpotlightMemoryIndexDelegate`` assigned to a ``SpotlightMemoryIndex``.
    public init(
        fetchAttributes: [SearchableItemAttribute],
        includeFiles: Bool = false,
        maximumResponseSize: Int? = nil,
        indexDelegate: (any CSSearchableIndexDelegate)? = nil
    ) {
        let coreSpotlight = indexDelegate.map { CoreSpotlightSource(searchableIndexDelegate: $0, fetchAttributes: fetchAttributes) }
            ?? CoreSpotlightSource(fetchAttributes: fetchAttributes)
        var sources: [SearchSource] = [.coreSpotlight(coreSpotlight)]
        if includeFiles {
            sources.append(.files(FileSource(fetchAttributes: fetchAttributes)))
        }
        self.init(configuration: SpotlightSearchTool.Configuration(sources: sources, maximumResponseSize: maximumResponseSize))
    }

    /// Fallback schema when the generation schema cannot be converted.
    public static let fallbackParameters: [String: AnyCodable] = [
        "type": AnyCodable("object"),
        "properties": AnyCodable(["query": AnyCodable(["type": AnyCodable("string")])]),
        "required": AnyCodable(["query"]),
    ]

    /// Model- and UI-facing description.
    public var descriptor: AgentToolDescriptor {
        AgentToolDescriptor(
            name: self.name,
            label: "Spotlight Search",
            description: self.tool.description,
            display: AgentToolDisplay(title: "Spotlight", emoji: "🔎", category: "web"),
            parameters: Self.parameters(from: self.tool.parameters),
            sectionID: "web",
            defaultProfiles: [.coding],
            risk: .low
        )
    }

    /// Runs a search.
    public func invoke(_ invocation: AgentToolInvocation, update _: AgentToolUpdateHandler?) async throws -> AgentToolOutput {
        let arguments = try JSONEncoder().encode(AnyCodable(invocation.arguments))
        let content = try GeneratedContent(json: String(decoding: arguments, as: UTF8.self))
        let tool = self.tool
        let replies = self.replies
        let replyTimeout = self.replyTimeoutSeconds
        let callTimeout = self.callTimeoutSeconds
        // One long-lived consumer of the shared reply stream; invocations never iterate it themselves.
        replies.ensurePump { deliver in
            for await reply in tool.searchResults {
                deliver(reply)
            }
        }
        return try await replies.withExclusiveAccess {
            // Open the slot before calling so the structured reply of this call is observed.
            replies.openSlot()
            let called = await SpotlightTimeoutRace.first(timeoutSeconds: callTimeout) { () -> Result<String, any Error>? in
                do {
                    return .success(String(describing: try await tool.call(arguments: content)))
                } catch {
                    return .failure(error)
                }
            }
            let output: String
            switch called {
            case .success(let text)?:
                output = text
            case .failure(let error)?:
                replies.closeSlot()
                throw error
            case nil:
                replies.closeSlot()
                return AgentToolOutput(content: [.text("spotlight_search timed out after \(callTimeout)s")], isError: true)
            }
            let reply = await replies.completeReply(timeoutSeconds: replyTimeout)
            replies.closeSlot()
            guard let reply else {
                return .text(output)
            }
            let rendered = Self.render(reply)
            return AgentToolOutput(content: [.text(rendered.text.isEmpty ? output : rendered.text)], details: rendered.details)
        }
    }

    // MARK: - Helpers

    /// Converts a `GenerationSchema` (Codable) into the JSON Schema subset tools accept.
    static func parameters(from schema: GenerationSchema) -> [String: AnyCodable] {
        guard let data = try? JSONEncoder().encode(schema),
              let decoded = try? JSONDecoder().decode(AnyCodable.self, from: data),
              var object = decoded.dictionaryValue.map(Self.subset)
        else {
            return Self.fallbackParameters
        }
        if object["type"] == nil { object["type"] = AnyCodable("object") }
        return object["properties"] == nil ? Self.fallbackParameters : object
    }

    private static let allowedKeys: Set<String> = [
        "type", "properties", "required", "items", "enum", "description", "anyOf", "minimum", "maximum",
        "minItems", "maxItems", "additionalProperties", "format", "pattern", "const",
    ]

    private static func subset(_ object: [String: AnyCodable]) -> [String: AnyCodable] {
        var result: [String: AnyCodable] = [:]
        for (key, value) in object where Self.allowedKeys.contains(key) {
            switch key {
            case "properties":
                var properties: [String: AnyCodable] = [:]
                for (name, property) in value.dictionaryValue ?? [:] {
                    properties[name] = AnyCodable(Self.subset(property.dictionaryValue ?? [:]))
                }
                result[key] = AnyCodable(properties)
            case "items":
                result[key] = value.dictionaryValue.map { AnyCodable(Self.subset($0)) } ?? value
            case "anyOf":
                result[key] = AnyCodable((value.arrayValue ?? []).map { AnyCodable(Self.subset($0.dictionaryValue ?? [:])) })
            default:
                result[key] = value
            }
        }
        return result
    }

    static func render(_ reply: SpotlightSearchTool.SearchReply) -> (text: String, details: AnyCodable) {
        var lines: [String] = []
        if let label = reply.label { lines.append(label) }
        var details: [String: AnyCodable] = [
            "status": AnyCodable(reply.status == .complete ? "complete" : "partial"),
            "label": reply.label.map { AnyCodable($0) } ?? AnyCodable.nullValue,
        ]
        func describe(_ item: CSSearchableItem, score: Double? = nil) -> AnyCodable {
            let attributes = item.attributeSet
            let title = attributes.title ?? attributes.displayName ?? item.uniqueIdentifier
            lines.append("- \(title)" + (score.map { String(format: " (%.2f)", $0) } ?? ""))
            var object: [String: AnyCodable] = [
                "id": AnyCodable(item.uniqueIdentifier),
                "title": AnyCodable(title),
            ]
            if let domain = item.domainIdentifier { object["domain"] = AnyCodable(domain) }
            if let text = attributes.contentDescription ?? attributes.textContent { object["text"] = AnyCodable(String(text.prefix(500))) }
            if let score { object["score"] = AnyCodable(score) }
            return AnyCodable(object)
        }
        switch reply.content {
        case .items(let items):
            details["items"] = AnyCodable(items.map { describe($0.item) })
        case .scoredItems(let items):
            details["items"] = AnyCodable(items.map { describe($0.item.item, score: $0.score) })
        case .groupedItems(let groups):
            var grouped: [String: AnyCodable] = [:]
            for (attribute, items) in groups {
                lines.append("\(attribute.rawValue):")
                grouped[attribute.rawValue] = AnyCodable(items.map { describe($0.item) })
            }
            details["groups"] = AnyCodable(grouped)
        case .count(let count):
            lines.append("\(count.header.map { "\($0): " } ?? "")\(count.value) results")
            details["count"] = AnyCodable(count.value)
        case .table(let table):
            if let header = table.header { lines.append(header) }
            lines.append(table.columns.map(\.name).joined(separator: " | "))
            let rows = table.rows.map { row in
                row.values.map { value -> String in
                    switch value {
                    case .string(let text): return text
                    case .integer(let number): return String(number)
                    case .double(let number): return String(number)
                    case .date(let date): return ISO8601DateFormatter().string(from: date)
                    case .boolean(let flag): return flag ? "true" : "false"
                    case .none: return ""
                    @unknown default: return ""
                    }
                }
            }
            lines.append(contentsOf: rows.map { $0.joined(separator: " | ") })
            details["table"] = AnyCodable([
                "columns": AnyCodable(table.columns.map { AnyCodable($0.name) }),
                "rows": AnyCodable(rows.map { AnyCodable($0.map { AnyCodable($0) }) })
            ])
        case .statistic(let statistic):
            lines.append("\(statistic.name): \(statistic.value)")
            details["statistic"] = AnyCodable(["name": AnyCodable(statistic.name), "value": AnyCodable(statistic.value)])
        case .text(let text):
            if let header = text.header { lines.append(header) }
            lines.append(text.body)
            details["text"] = AnyCodable(text.body)
        @unknown default:
            break
        }
        return (lines.joined(separator: "\n"), AnyCodable(details))
    }
}
#endif
