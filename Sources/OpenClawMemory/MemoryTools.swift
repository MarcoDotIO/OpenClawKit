import Foundation
import OpenClawAgents
import OpenClawCore
import OpenClawGateway
import OpenClawProtocol

/// Searches indexed session transcripts for `memory_search corpus=sessions`.
public protocol MemorySessionSearching: Sendable {
    /// Searches session transcripts.
    /// - Parameters:
    ///   - query: Query text.
    ///   - maxResults: Maximum hits.
    /// - Returns: Hits with `source: .sessions`.
    func searchSessions(query: String, maxResults: Int) async throws -> [MemorySearchHit]
}

/// Keyword search over a ``ConversationMemoryStoreProtocol`` (session hits use
/// `sessions/<sessionKey>` paths and entry indices as line numbers).
public struct ConversationMemorySessionSearch: MemorySessionSearching {
    private let store: any ConversationMemoryStoreProtocol

    /// Creates the adapter.
    /// - Parameter store: Conversation memory store.
    public init(store: any ConversationMemoryStoreProtocol) {
        self.store = store
    }

    /// Searches session entries with BM25.
    public func searchSessions(query: String, maxResults: Int) async throws -> [MemorySearchHit] {
        let entries = await self.store.allEntries()
        var index = BM25Index()
        var byID: [String: (ConversationMemoryEntry, Int)] = [:]
        var positions: [String: Int] = [:]
        for entry in entries {
            let position = (positions[entry.sessionKey] ?? 0) + 1
            positions[entry.sessionKey] = position
            index.upsert(id: entry.id, text: entry.text)
            byID[entry.id] = (entry, position)
        }
        let hits = index.search(query, limit: maxResults)
        guard let best = hits.first?.score, best > 0 else { return [] }
        return hits.compactMap { hit in
            guard let (entry, position) = byID[hit.id] else { return nil }
            return MemorySearchHit(
                path: "sessions/\(entry.sessionKey)",
                startLine: position,
                endLine: position,
                score: hit.score / best,
                textScore: hit.score / best,
                snippet: String(entry.text.prefix(MemoryEngine.snippetMaxChars)),
                source: .sessions
            )
        }
    }
}

/// Upstream `buildMemoryPromptSection` (extensions/memory-core): the `## Memory Recall` system
/// prompt section, emitted only when `memory_search` or `memory_get` is available.
public enum MemoryPromptSection {
    /// Builds the section lines (empty when neither memory tool is available).
    /// - Parameters:
    ///   - availableTools: Tool names offered to the model.
    ///   - citationsMode: `auto`, `on` or `off`.
    /// - Returns: Section lines (ending with an empty line).
    public static func build(availableTools: Set<String>, citationsMode: String? = nil) -> [String] {
        let hasSearch = availableTools.contains("memory_search")
        let hasGet = availableTools.contains("memory_get")
        guard hasSearch || hasGet else { return [] }
        let guidance = hasSearch
            ? "Before answering anything about prior work, decisions, dates, people, preferences, or todos: run memory_search"
                + (hasGet ? "; for memory-file hits, use memory_get to pull only the needed lines" : "")
                + ". If low confidence after search, say you checked."
            : "Before answering anything about prior work, decisions, dates, people, preferences, or todos that point to a specific memory file: "
                + "run memory_get to pull only the needed lines. If low confidence after reading, say you checked."
        var session: [String] = []
        if hasSearch {
            if availableTools.contains("sessions_search") {
                session.append(
                    "For session hits, use sessions_search with distinctive snippet text (and sessionKey set to the transcript ID when known)"
                        + (availableTools.contains("sessions_history")
                            ? ", then sessions_history with the returned sessionKey, messageId, and sessionId for a bounded sanitized excerpt"
                            : "; exact session history is unavailable with the enabled tools")
                        + "."
                )
            } else if availableTools.contains("sessions_history") {
                session.append(
                    "For session hits, use sessions_history with a known session key or transcript ID and a small limit; "
                        + "paginate its returned history metadata to locate the excerpt."
                )
            } else {
                session.append("Session hits are search snippets only; exact session history is unavailable with the enabled tools.")
            }
            session.append("Session search line numbers are not history offsets. Never read raw transcript files to expand session hits.")
        }
        let outcome = "Report partial, unavailable, or stale recall to the user, including returned warning and action guidance."
        let citations = citationsMode?.lowercased() == "off"
            ? "Citations are disabled: do not mention file paths or line numbers in replies unless the user explicitly asks."
            : "Citations: include Source: <path#line> when it helps the user verify memory snippets."
        return ["## Memory Recall", guidance] + session + [outcome, citations, ""]
    }

    /// The section as one string (lines joined with `\n`).
    /// - Parameters:
    ///   - availableTools: Tool names.
    ///   - citationsMode: Citations mode.
    /// - Returns: Section text.
    public static func text(availableTools: Set<String>, citationsMode: String? = nil) -> String {
        self.build(availableTools: availableTools, citationsMode: citationsMode).joined(separator: "\n")
    }
}

enum MemoryToolSupport {
    static let searchOutcomeGuidance =
        "Corpus outcomes cover each requested corpus; a corpus warning means results are partial and must be surfaced to the user."
    static let getOutcomeGuidance =
        "status=ok means the requested excerpt was read; status=not_found means every requested available corpus missed; "
            + "status=error means the requested read failed, not that memory is disabled."
    static let wikiWarning = "memory wiki is not available in this runtime"

    static func sourceDescription(extraPaths: Bool, sessions: Bool) -> (files: String, search: String) {
        let files = ["MEMORY.md, USER.md, Markdown files recursively under memory/", extraPaths ? "configured extra paths" : ""]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        return (files, sessions ? files + ", indexed session transcripts" : files)
    }

    static func rejectUnknownKeys(_ arguments: [String: AnyCodable], allowed: Set<String>, tool: String) throws {
        if let unknown = arguments.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw OpenClawCoreError.invalidConfiguration("\(tool): unexpected parameter \(unknown)")
        }
    }

    /// Largest value ``positiveInt(_:name:tool:)`` returns (Int32.max, so watchOS arm64_32 is covered).
    static let positiveIntCap = Int(Int32.max)

    /// Parses a model-supplied integer `>= 1`, clamping values above ``positiveIntCap`` instead of
    /// trapping on out-of-range doubles.
    static func positiveInt(_ value: AnyCodable?, name: String, tool: String) throws -> Int? {
        guard let value, !value.isNull else { return nil }
        if let int = value.intValue, int >= 1 { return min(int, Self.positiveIntCap) }
        if let double = value.doubleValue, double.isFinite, double.rounded() == double, double >= 1 {
            return double >= Double(Self.positiveIntCap) ? Self.positiveIntCap : Int(double)
        }
        throw OpenClawCoreError.invalidConfiguration("\(tool): \(name) must be an integer >= 1")
    }

    static func encode(_ value: some Encodable) -> AnyCodable {
        (try? AnyCodable(encoding: value)) ?? AnyCodable.nullValue
    }
}

/// `memory_search` agent tool (upstream `MEMORY_SEARCH_TOOL_CONTRACT`).
///
/// Parameters `{query, maxResults?, minScore?, corpus?: memory|wiki|all|sessions}` with no other keys.
/// `wiki` has no backing store in the SDK and reports `disabled`; `sessions` needs a
/// ``MemorySessionSearching`` source and `sessions` in the engine's ``MemoryEngineConfiguration/sources``.
public struct MemorySearchTool: AgentTool {
    /// Tool name.
    public let name = "memory_search"
    private let engine: MemoryEngine
    private let sessionSearch: (any MemorySessionSearching)?
    private let hasExtraPaths: Bool
    private let sessionsEnabled: Bool

    /// Creates the tool.
    /// - Parameters:
    ///   - engine: Memory engine.
    ///   - configuration: Engine settings (for the source description and session corpus).
    ///   - sessionSearch: Session transcript search.
    public init(
        engine: MemoryEngine,
        configuration: MemoryEngineConfiguration = MemoryEngineConfiguration(),
        sessionSearch: (any MemorySessionSearching)? = nil
    ) {
        self.engine = engine
        self.sessionSearch = sessionSearch
        self.hasExtraPaths = !configuration.extraPaths.isEmpty
        self.sessionsEnabled = configuration.sources.contains(.sessions) && sessionSearch != nil
    }

    /// Upstream JSON Schema of the parameters.
    public static let parametersSchema: [String: AnyCodable] = [
        "type": AnyCodable("object"),
        "properties": AnyCodable([
            "query": AnyCodable(["type": AnyCodable("string")]),
            "maxResults": AnyCodable(["type": AnyCodable("integer"), "minimum": AnyCodable(1)]),
            "minScore": AnyCodable(["type": AnyCodable("number")]),
            "corpus": AnyCodable(["type": AnyCodable("string"), "enum": AnyCodable(["memory", "wiki", "all", "sessions"])]),
        ]),
        "required": AnyCodable(["query"]),
        "additionalProperties": AnyCodable(false),
    ]

    /// Model- and UI-facing description.
    public var descriptor: AgentToolDescriptor {
        let sources = MemoryToolSupport.sourceDescription(extraPaths: self.hasExtraPaths, sessions: self.sessionsEnabled)
        let description = "Mandatory recall step: semantically search \(sources.search) before answering questions about prior work, decisions, dates, "
            + "people, preferences, or todos. Session results are transcript search references, not readable memory-file paths. "
            + "Optional `corpus=wiki` or `corpus=all` also searches registered compiled-wiki supplements. "
            + "`corpus=memory` restricts hits to indexed memory files (excludes session transcript chunks from ranking). "
            + "`corpus=sessions` searches indexed session transcripts under the same visibility rules as session history tools and returns "
            + "unavailable when semantic session indexing is disabled. \(MemoryToolSupport.searchOutcomeGuidance) "
            + "If response has disabled=true or stale=true, tell the user and include the warning/action guidance."
        return AgentToolDescriptor(
            name: self.name,
            label: "Memory Search",
            description: description,
            parameters: Self.parametersSchema,
            sectionID: "memory",
            defaultProfiles: [.coding],
            risk: .low,
            replaySafe: true
        )
    }

    /// Runs the search.
    public func invoke(_ invocation: AgentToolInvocation, update _: AgentToolUpdateHandler?) async throws -> AgentToolOutput {
        let arguments = invocation.arguments
        try MemoryToolSupport.rejectUnknownKeys(arguments, allowed: ["query", "maxResults", "minScore", "corpus"], tool: self.name)
        guard let query = arguments["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("memory_search: query must be a non-empty string")
        }
        let maxResults = try MemoryToolSupport.positiveInt(arguments["maxResults"], name: "maxResults", tool: self.name)
        let minScore = arguments["minScore"]?.doubleValue
        let corpus = arguments["corpus"]?.stringValue ?? "memory"
        guard ["memory", "wiki", "all", "sessions"].contains(corpus) else {
            throw OpenClawCoreError.invalidConfiguration("memory_search: corpus must be memory, wiki, all or sessions")
        }

        var details: [String: AnyCodable] = [:]
        var corpora: [AnyCodable] = []
        var results: [MemorySearchHit] = []
        if corpus == "wiki" {
            details["disabled"] = AnyCodable(true)
            details["warning"] = AnyCodable(MemoryToolSupport.wikiWarning)
            corpora.append(AnyCodable([
                "corpus": AnyCodable("wiki"),
                "status": AnyCodable("unavailable"),
                "warning": AnyCodable(MemoryToolSupport.wikiWarning)
            ]))
        }
        if corpus == "memory" || corpus == "all" {
            let outcome = try await self.engine.search(query: query, maxResults: maxResults, minScore: minScore)
            results.append(contentsOf: outcome.hits)
            details["provider"] = AnyCodable(outcome.provider)
            details["searchMode"] = AnyCodable(outcome.searchMode)
            if let bootstrap = outcome.embeddingBootstrap {
                details["debug"] = AnyCodable(["embeddingBootstrap": MemoryToolSupport.encode(bootstrap)])
            }
            corpora.append(AnyCodable(["corpus": AnyCodable("memory"), "status": AnyCodable("ok")]))
            if corpus == "all" {
                corpora.append(AnyCodable([
                    "corpus": AnyCodable("wiki"),
                    "status": AnyCodable("unavailable"),
                    "warning": AnyCodable(MemoryToolSupport.wikiWarning)
                ]))
            }
        }
        if corpus == "sessions" {
            if self.sessionsEnabled, let sessionSearch {
                results = try await sessionSearch.searchSessions(query: query, maxResults: maxResults ?? 6)
                corpora.append(AnyCodable(["corpus": AnyCodable("sessions"), "status": AnyCodable("ok")]))
            } else {
                let warning = "session transcript search is disabled (add sessions to memory.search.sources)"
                details["warning"] = AnyCodable(warning)
                corpora.append(AnyCodable(["corpus": AnyCodable("sessions"), "status": AnyCodable("unavailable"), "warning": AnyCodable(warning)]))
            }
        }
        details["results"] = MemoryToolSupport.encode(results)
        details["corpora"] = AnyCodable(corpora)
        return .json(AnyCodable(details))
    }
}

/// `memory_get` agent tool (upstream `MEMORY_GET_TOOL_CONTRACT`).
///
/// Parameters `{path, from?, lines?, corpus?: memory|wiki|all}`; only `MEMORY.md`, `USER.md`,
/// `memory/**` and configured extra paths are readable (transcript paths are rejected). Excerpts
/// default to 200 lines.
public struct MemoryGetTool: AgentTool {
    /// Tool name.
    public let name = "memory_get"
    private let engine: MemoryEngine
    private let hasExtraPaths: Bool

    /// Creates the tool.
    /// - Parameters:
    ///   - engine: Memory engine.
    ///   - configuration: Engine settings.
    public init(engine: MemoryEngine, configuration: MemoryEngineConfiguration = MemoryEngineConfiguration()) {
        self.engine = engine
        self.hasExtraPaths = !configuration.extraPaths.isEmpty
    }

    /// Upstream JSON Schema of the parameters.
    public static let parametersSchema: [String: AnyCodable] = [
        "type": AnyCodable("object"),
        "properties": AnyCodable([
            "path": AnyCodable(["type": AnyCodable("string")]),
            "from": AnyCodable(["type": AnyCodable("integer"), "minimum": AnyCodable(1)]),
            "lines": AnyCodable(["type": AnyCodable("integer"), "minimum": AnyCodable(1)]),
            "corpus": AnyCodable(["type": AnyCodable("string"), "enum": AnyCodable(["memory", "wiki", "all"])]),
        ]),
        "required": AnyCodable(["path"]),
        "additionalProperties": AnyCodable(false),
    ]

    /// Model- and UI-facing description.
    public var descriptor: AgentToolDescriptor {
        let files = MemoryToolSupport.sourceDescription(extraPaths: self.hasExtraPaths, sessions: false).files
        let description = "Safe exact excerpt read from \(files). Session transcript paths are unsupported; use the available session-history "
            + "workflow for session hits. Defaults to a bounded excerpt when lines are omitted and includes truncation/continuation info when "
            + "more content exists. `corpus=wiki` reads registered compiled-wiki supplements. \(MemoryToolSupport.getOutcomeGuidance) "
            + MemoryToolSupport.searchOutcomeGuidance
        return AgentToolDescriptor(
            name: self.name,
            label: "Memory Get",
            description: description,
            parameters: Self.parametersSchema,
            sectionID: "memory",
            defaultProfiles: [.coding],
            risk: .low,
            replaySafe: true
        )
    }

    /// Reads the excerpt.
    public func invoke(_ invocation: AgentToolInvocation, update _: AgentToolUpdateHandler?) async throws -> AgentToolOutput {
        let arguments = invocation.arguments
        try MemoryToolSupport.rejectUnknownKeys(arguments, allowed: ["path", "from", "lines", "corpus"], tool: self.name)
        guard let path = arguments["path"]?.stringValue, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("memory_get: path must be a non-empty string")
        }
        let from = try MemoryToolSupport.positiveInt(arguments["from"], name: "from", tool: self.name)
        let lines = try MemoryToolSupport.positiveInt(arguments["lines"], name: "lines", tool: self.name)
        let corpus = arguments["corpus"]?.stringValue ?? "memory"
        guard ["memory", "wiki", "all"].contains(corpus) else {
            throw OpenClawCoreError.invalidConfiguration("memory_get: corpus must be memory, wiki or all")
        }
        if corpus == "wiki" {
            let result = MemoryReadResult(status: "not_found", text: "", path: path)
            var details = MemoryToolSupport.encode(result).dictionaryValue ?? [:]
            details["warning"] = AnyCodable(MemoryToolSupport.wikiWarning)
            return .json(AnyCodable(details))
        }
        let result = await self.engine.read(path: path, from: from, lines: lines)
        let output = AgentToolOutput.json(MemoryToolSupport.encode(result))
        return result.status == "error" ? AgentToolOutput(content: output.content, details: output.details, isError: true) : output
    }
}

/// Wiring for the in-process `memory.search` gateway method.
public struct MemoryGatewayConfiguration: Sendable {
    /// Resolves the engine for an agent (`nil` means the agent has no memory index).
    public var engineProvider: @Sendable (_ agentID: String) async -> MemoryEngine?
    /// Configured agents; unknown `agentId` values are `INVALID_REQUEST`.
    public var knownAgentIDs: Set<String>
    /// Agent used when the request has no `agentId`.
    public var defaultAgentID: String

    /// Creates the configuration.
    /// - Parameters:
    ///   - engineProvider: Engine resolver.
    ///   - knownAgentIDs: Known agents.
    ///   - defaultAgentID: Default agent.
    public init(
        engineProvider: @escaping @Sendable (_ agentID: String) async -> MemoryEngine?,
        knownAgentIDs: Set<String> = ["main"],
        defaultAgentID: String = "main"
    ) {
        self.engineProvider = engineProvider
        self.knownAgentIDs = knownAgentIDs
        self.defaultAgentID = defaultAgentID
    }
}

/// Upstream `memory.search` defaults.
enum MemoryGatewayLimits {
    static let defaultMaxResults = 20
    static let maxResults = 50
}

/// Registers `memory.search {query, maxResults?, minScore?, agentId?}`.
///
/// Returns `{agentId, provider, searchMode, results, warning?}`; `maxResults` defaults to 20 and is
/// clamped to `1...50`.
/// - Parameters:
///   - registrar: Gateway server or registrar.
///   - configuration: Handler wiring.
public func registerMemoryGatewayMethods(on registrar: some GatewayMethodRegistrar, configuration: MemoryGatewayConfiguration) async {
    await registrar.register(method: "memory.search") { request in
        let params = request.params
        guard let query = params["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            throw GatewayMethodError.invalidRequest("query must be a non-empty string")
        }
        var maxResults = MemoryGatewayLimits.defaultMaxResults
        if let raw = params["maxResults"], !raw.isNull {
            guard let number = raw.doubleValue, number.isFinite else {
                throw GatewayMethodError.invalidRequest("maxResults and minScore must be finite numbers when provided")
            }
            maxResults = min(MemoryGatewayLimits.maxResults, max(1, Int(number.rounded(.down))))
        }
        var minScore: Double?
        if let raw = params["minScore"], !raw.isNull {
            guard let number = raw.doubleValue, number.isFinite else {
                throw GatewayMethodError.invalidRequest("maxResults and minScore must be finite numbers when provided")
            }
            minScore = number
        }
        var agentID = configuration.defaultAgentID
        if let raw = params["agentId"] {
            guard let text = raw.stringValue else {
                throw GatewayMethodError.invalidRequest("agentId must be a string")
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty, configuration.knownAgentIDs.contains(trimmed) else {
                throw GatewayMethodError.invalidRequest("unknown agentId")
            }
            agentID = trimmed
        }
        guard let engine = await configuration.engineProvider(agentID) else {
            return AnyCodable([
                "agentId": AnyCodable(agentID),
                "provider": AnyCodable("none"),
                "searchMode": AnyCodable("fts-only"),
                "results": AnyCodable([AnyCodable]()),
                "warning": AnyCodable("memory search is not configured for this agent"),
            ])
        }
        do {
            let outcome = try await engine.search(query: query, maxResults: maxResults, minScore: minScore)
            var response: [String: AnyCodable] = [
                "agentId": AnyCodable(agentID),
                "provider": AnyCodable(outcome.provider),
                "searchMode": AnyCodable(outcome.searchMode),
                "results": MemoryToolSupport.encode(outcome.hits),
            ]
            if let bootstrap = outcome.embeddingBootstrap {
                response["warning"] = AnyCodable("semantic search unavailable (\(bootstrap.reason)); results are keyword-only")
            }
            return AnyCodable(response)
        } catch let error as MemoryUnavailableError {
            throw GatewayMethodError.unavailable(error.localizedDescription)
        }
    }
}
