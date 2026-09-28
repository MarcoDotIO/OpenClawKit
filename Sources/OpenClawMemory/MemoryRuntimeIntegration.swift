import Foundation
import OpenClawAgents
import OpenClawCore
import OpenClawProtocol

// Wiring between OpenClawMemory and the embedded agent runtime (OpenClawAgents cannot depend on this
// module): memory tools, the `## Memory Recall` prompt section, the Spotlight search tool, config
// resolution, transcript import and a closure embedding adapter.

/// What ``EmbeddedAgentRuntime/installMemory(engine:configuration:sessionSearch:citationsMode:spotlightSearch:includeSystemFiles:)`` set up.
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
    /// - Returns: What was installed.
    @discardableResult
    func installMemory(
        engine: MemoryEngine,
        configuration: MemoryEngineConfiguration = MemoryEngineConfiguration(),
        sessionSearch: (any MemorySessionSearching)? = nil,
        citationsMode: String? = nil,
        spotlightSearch: Bool = false,
        includeSystemFiles: Bool = false
    ) async -> MemoryRuntimeInstallation {
        await MemoryToolRegistration.registerMemoryTools(
            into: self.toolRegistry,
            engine: engine,
            configuration: configuration,
            sessionSearch: sessionSearch
        )
        var spotlight = false
        if spotlightSearch {
            spotlight = await MemoryToolRegistration.registerSpotlightSearch(into: self.toolRegistry, includeSystemFiles: includeSystemFiles)
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
        let root = document.memory?.search
        let agent: OpenClawConfigDocument.MemorySearch? = agentID.flatMap { id in
            let entries = document.agents?.entries ?? [:]
            let key = entries.keys.first { $0.lowercased() == id.lowercased() }
            return key.flatMap { entries[$0]?.memory?.search }
        }
        guard agent?.enabled ?? root?.enabled ?? true else { return nil }
        let defaults = MemoryEngineConfiguration()
        let query = agent?.query?.dictionaryValue ?? root?.query?.dictionaryValue ?? [:]
        let rootQuery = root?.query?.dictionaryValue ?? [:]
        let maxResults = query["maxResults"]?.intValue ?? rootQuery["maxResults"]?.intValue ?? defaults.maxResults
        let minScore = query["minScore"]?.doubleValue ?? rootQuery["minScore"]?.doubleValue ?? defaults.minScore
        let rawSources = agent?.sources ?? root?.sources
        let sources = rawSources?.compactMap { MemoryHitSource(rawValue: $0.lowercased()) }
        let extraPaths = ((root?.extraPaths ?? []) + (agent?.extraPaths ?? [])).compactMap { raw -> MemoryExtraPath? in
            guard let data = try? JSONEncoder().encode(raw) else { return nil }
            return try? JSONDecoder().decode(MemoryExtraPath.self, from: data)
        }
        var configuration = defaults
        configuration.provider = (agent?.provider ?? root?.provider)?.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.model = (agent?.model ?? root?.model)?.trimmingCharacters(in: .whitespacesAndNewlines)
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
