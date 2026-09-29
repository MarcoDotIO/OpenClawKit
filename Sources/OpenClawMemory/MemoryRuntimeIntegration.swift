import Foundation
import OpenClawAgents
import OpenClawCore
import OpenClawProtocol

// Wiring between OpenClawMemory and the embedded agent runtime (OpenClawAgents cannot depend on this
// module): memory tools, the `## Memory Recall` prompt section, the Spotlight search tool, config
// resolution, transcript import and a closure embedding adapter.

/// What
/// ``EmbeddedAgentRuntime/installMemory(engine:configuration:sessionSearch:citationsMode:spotlightSearch:includeSystemFiles:spotlightIndexDelegate:)``
/// set up.
public struct MemoryRuntimeInstallation: Sendable, Equatable {
    /// Registered memory tool names (`memory_search`, `memory_get`).
    public var memoryTools: [String]
    /// Whether `spotlight_search` was registered.
    public var spotlightSearch: Bool

    /// Creates an installation record.
    /// - Parameters:
    ///   - memoryTools: Registered memory tools.
    ///   - spotlightSearch: Whether Spotlight search was registered.
    public init(memoryTools: [String], spotlightSearch: Bool) {
        self.memoryTools = memoryTools
        self.spotlightSearch = spotlightSearch
    }
}

public extension EmbeddedAgentRuntime {
    /// Installs memory for every run: registers `memory_search` and `memory_get`, adds the upstream
    /// `## Memory Recall` system-prompt section (emitted only on turns that offer a memory tool), and
    /// optionally registers the Apple `spotlight_search` tool where the platform supports it.
    /// - Parameters:
    ///   - engine: Memory engine.
    ///   - configuration: Engine settings.
    ///   - sessionSearch: Optional session transcript search.
    ///   - citationsMode: `memory.citations` (`auto`, `on` or `off`).
    ///   - spotlightSearch: Also register `spotlight_search` (iOS/macOS/visionOS 27 on Apple silicon).
    ///   - includeSystemFiles: Let Spotlight search the user's files too.
    ///   - spotlightIndexDelegate: Optional `SpotlightMemoryIndexDelegate` (any
    ///     `CSSearchableIndexDelegate`) so `spotlight_search` hydrates memory items indexed by a
    ///     `SpotlightMemoryIndex`.
    /// - Returns: What was installed.
    @discardableResult
    func installMemory(
        engine: MemoryEngine,
        configuration: MemoryEngineConfiguration = MemoryEngineConfiguration(),
        sessionSearch: (any MemorySessionSearching)? = nil,
        citationsMode: String? = nil,
        spotlightSearch: Bool = false,
        includeSystemFiles: Bool = false,
        spotlightIndexDelegate: (any AnyObject & Sendable)? = nil
    ) async -> MemoryRuntimeInstallation {
        await MemoryToolRegistration.registerMemoryTools(
            into: self.toolRegistry,
            engine: engine,
            configuration: configuration,
            sessionSearch: sessionSearch
        )
        var spotlight = false
        if spotlightSearch {
            spotlight = await MemoryToolRegistration.registerSpotlightSearch(
                into: self.toolRegistry,
                includeSystemFiles: includeSystemFiles,
                indexDelegate: spotlightIndexDelegate
            )
        }
        self.addPromptContributor { context in
            MemoryRuntimeIntegration.promptSection(availableTools: context.availableToolNames, citationsMode: citationsMode)
        }
        return MemoryRuntimeInstallation(memoryTools: ["memory_search", "memory_get"], spotlightSearch: spotlight)
    }
}

/// Helpers for wiring memory into agent runtimes.
public enum MemoryRuntimeIntegration {
    /// The `## Memory Recall` section for a turn, or `nil` when no memory tool is offered.
    /// - Parameters:
    ///   - availableTools: Tools offered to the model.
    ///   - citationsMode: `auto`, `on` or `off`.
    /// - Returns: The section text.
    public static func promptSection(availableTools: Set<String>, citationsMode: String? = nil) -> String? {
        let lines = MemoryPromptSection.build(availableTools: availableTools, citationsMode: citationsMode)
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Transcript import rows for conversation-memory entries, oldest first (ties keep entry id
    /// order), for ``SessionTranscriptImporter/importRows(_:into:sessionID:cwd:)``.
    /// - Parameter entries: Conversation-memory entries of one session.
    /// - Returns: Import rows.
    public static func transcriptImportRows(from entries: [ConversationMemoryEntry]) -> [SessionTranscriptImportRow] {
        entries.sorted { lhs, rhs in
            lhs.createdAtMs == rhs.createdAtMs ? lhs.id < rhs.id : lhs.createdAtMs < rhs.createdAtMs
        }
        .map(\.transcriptImportRow)
    }

    /// Imports conversation-memory entries into a session transcript so existing apps keep their
    /// history after moving to transcript stores.
    /// - Parameters:
    ///   - entries: Conversation-memory entries of one session.
    ///   - store: Target transcript store.
    ///   - sessionID: Target transcript session.
    ///   - cwd: Working directory recorded when the session is created.
    /// - Returns: Number of imported messages.
    @discardableResult
    public static func importConversationMemory(
        _ entries: [ConversationMemoryEntry],
        into store: any SessionTranscriptStore,
        sessionID: String,
        cwd: String = ""
    ) async throws -> Int {
        try await SessionTranscriptImporter.importRows(Self.transcriptImportRows(from: entries), into: store, sessionID: sessionID, cwd: cwd)
    }
}

public extension ConversationMemoryEntry {
    /// Transcript import row for this entry (role, text and creation time).
    var transcriptImportRow: SessionTranscriptImportRow {
        SessionTranscriptImportRow(role: self.role.rawValue, text: self.text, timestampMs: self.createdAtMs)
    }
}

public extension MemoryEngineConfiguration {
    /// Memory search settings from `memory.search` with `agents.entries.<id>.memory.search`
    /// overrides (upstream `resolveMemorySearchIndexConfig`): `provider` (`auto` default), `model`,
    /// `sources`, `extraPaths` (root plus agent), `query.maxResults` and `query.minScore` (clamped to
    /// `0...1`). Other knobs keep the upstream defaults.
    /// - Parameters:
    ///   - document: Config document.
    ///   - agentID: Agent whose overrides apply.
    /// - Returns: The settings, or `nil` when memory search is disabled (`enabled: false`).
    static func resolve(from document: OpenClawConfigDocument, agentID: String? = nil) -> MemoryEngineConfiguration? {
        // Read the encoded upstream shape so the mapping keeps working as document sections gain types.
        let json = (try? AnyCodable(encoding: document))?.dictionaryValue ?? [:]
        func object(_ value: AnyCodable?, _ path: [String]) -> [String: AnyCodable]? {
            var current = value
            for key in path {
                current = current?.dictionaryValue?[key]
            }
            return current?.dictionaryValue
        }
        let root = object(AnyCodable(json), ["memory", "search"]) ?? [:]
        let entries = object(AnyCodable(json), ["agents", "entries"]) ?? [:]
        let agentKey = agentID.flatMap { id in entries.keys.first { $0.lowercased() == id.lowercased() } }
        let agent = agentKey.flatMap { object(entries[$0], ["memory", "search"]) } ?? [:]
        func layered(_ key: String) -> AnyCodable? {
            if let value = agent[key], !value.isNull { return value }
            if let value = root[key], !value.isNull { return value }
            return nil
        }
        guard layered("enabled")?.boolValue ?? true else { return nil }
        let defaults = MemoryEngineConfiguration()
        let agentQuery = agent["query"]?.dictionaryValue ?? [:]
        let rootQuery = root["query"]?.dictionaryValue ?? [:]
        let maxResults = agentQuery["maxResults"]?.intValue ?? rootQuery["maxResults"]?.intValue ?? defaults.maxResults
        let minScore = agentQuery["minScore"]?.doubleValue ?? rootQuery["minScore"]?.doubleValue ?? defaults.minScore
        let sources = layered("sources")?.arrayValue?.compactMap { $0.stringValue.flatMap { MemoryHitSource(rawValue: $0.lowercased()) } }
        let rawPaths = (root["extraPaths"]?.arrayValue ?? []) + (agent["extraPaths"]?.arrayValue ?? [])
        let extraPaths = rawPaths.compactMap { raw -> MemoryExtraPath? in
            guard let data = try? JSONEncoder().encode(raw) else { return nil }
            return try? JSONDecoder().decode(MemoryExtraPath.self, from: data)
        }
        var configuration = defaults
        configuration.provider = layered("provider")?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.model = layered("model")?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.extraPaths = extraPaths
        if let sources, !sources.isEmpty {
            configuration.sources = sources
        }
        configuration.maxResults = max(1, maxResults)
        configuration.minScore = min(1, max(0, minScore))
        return configuration
    }
}

/// Embedding provider backed by a closure, for embedders that live in modules OpenClawMemory does
/// not depend on (for example `CoreAIEmbeddingProvider` in OpenClawModels):
///
/// ```swift
/// let embeddings = ClosureMemoryEmbeddingProvider(id: "coreai", model: "minilm") { texts, _ in
///     try await coreAIEmbedder.embed(texts)
/// }
/// let engine = MemoryEngine(..., embeddingProvider: embeddings)
/// ```
public struct ClosureMemoryEmbeddingProvider: MemoryEmbeddingProvider {
    /// Embeds texts for an input type.
    public typealias Embed = @Sendable (_ texts: [String], _ inputType: MemoryEmbeddingInputType) async throws -> [[Float]]

    /// Provider identifier.
    public let id: String
    /// Model identifier.
    public let model: String
    /// Vector dimensions (0 when unknown).
    public let dimensions: Int
    private let body: Embed

    /// Creates the provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - model: Model identifier.
    ///   - dimensions: Vector dimensions (0 when unknown).
    ///   - embed: Embedding closure.
    public init(id: String, model: String, dimensions: Int = 0, embed: @escaping Embed) {
        self.id = id
        self.model = model
        self.dimensions = max(0, dimensions)
        self.body = embed
    }

    /// Embeds texts through the closure.
    public func embed(_ texts: [String], inputType: MemoryEmbeddingInputType) async throws -> [[Float]] {
        try await self.body(texts, inputType)
    }
}
