import Foundation
import OpenClawKit

/// ``OpenClawIntentHost`` backed by the in-process `EmbeddedAgentRuntime`.
///
/// Streams `runStream` output as run events, tracks recently used sessions in memory (or reads a
/// `SessionStore` when given one), and aborts by cancelling the session's run task.
public actor EmbeddedOpenClawIntentHost: OpenClawIntentHost {
    private let runtime: EmbeddedAgentRuntime
    private let sessionStore: SessionStore?
    private let defaultSessionKey: String
    private let timeoutMs: Int
    private let agentList: [OpenClawIntentAgentSummary]
    private let talkHandler: (@Sendable (String?) async throws -> Void)?
    private let usesLocalModels: Bool
    private var recentSessions: [String: OpenClawIntentSessionSummary] = [:]
    private var runTasks: [String: Task<Void, Never>] = [:]

    /// Creates an embedded intent host.
    /// - Parameters:
    ///   - runtime: Embedded agent runtime.
    ///   - sessionStore: Optional session store used to list sessions.
    ///   - defaultSessionKey: Session used when an intent does not name one.
    ///   - timeoutMs: Per-run timeout passed to the runtime.
    ///   - agents: Agents offered to intents (defaults to a single `main` agent).
    ///   - usesLocalModels: Whether runs execute on local models (requests background GPU on OS 27).
    ///   - startTalk: Optional handler that starts talk mode in the app.
    public init(
        runtime: EmbeddedAgentRuntime,
        sessionStore: SessionStore? = nil,
        defaultSessionKey: String = "app-intents",
        timeoutMs: Int = 120_000,
        agents: [OpenClawIntentAgentSummary] = [OpenClawIntentAgentSummary(agentId: "main", displayName: "OpenClaw")],
        usesLocalModels: Bool = false,
        startTalk: (@Sendable (String?) async throws -> Void)? = nil)
    {
        self.runtime = runtime
        self.sessionStore = sessionStore
        self.defaultSessionKey = defaultSessionKey
        self.timeoutMs = max(1, timeoutMs)
        self.agentList = agents
        self.usesLocalModels = usesLocalModels
        self.talkHandler = startTalk
    }

    /// Whether long-running runs request background GPU time.
    nonisolated public var prefersBackgroundGPU: Bool {
        self.usesLocalModels
    }

    /// Lists sessions from the session store (or recent intent sessions), filtered by title or key.
    public func sessions(matching query: String?, limit: Int) async throws -> [OpenClawIntentSessionSummary] {
        let needle = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let all = await self.allSessions()
        let filtered = needle.isEmpty ? all : all.filter {
            $0.title.lowercased().contains(needle) || $0.sessionKey.lowercased().contains(needle)
        }
        return Array(filtered.prefix(max(1, limit)))
    }

    /// Resolves sessions by key (unknown keys resolve as bare keys).
    public func sessions(forKeys keys: [String]) async throws -> [OpenClawIntentSessionSummary] {
        let all = await self.allSessions()
        let byKey = Dictionary(all.map { ($0.sessionKey, $0) }, uniquingKeysWith: { first, _ in first })
        return keys.map { byKey[$0] ?? OpenClawIntentSessionSummary(sessionKey: $0, title: $0) }
    }

    /// Returns the configured agents.
    public func agents() async throws -> [OpenClawIntentAgentSummary] {
        self.agentList
    }

    /// Streams an embedded run.
    public func send(prompt: String, sessionKey: String?, agentId: String?) async throws
        -> AsyncThrowingStream<OpenClawIntentRunEvent, any Error>
    {
        let message = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { throw OpenClawIntentError.emptyPrompt }
        let trimmedKey = sessionKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = trimmedKey?.isEmpty == false ? trimmedKey! : self.defaultSessionKey
        self.recentSessions[key] = OpenClawIntentSessionSummary(
            sessionKey: key,
            title: self.recentSessions[key]?.title ?? key,
            agentId: agentId,
            updatedAt: Date())

        let request = AgentRunRequest(sessionKey: key, prompt: message)
        let runID = request.runID
        let chunks = await self.runtime.runStream(request, timeoutMs: self.timeoutMs)
        let (stream, continuation) = AsyncThrowingStream<OpenClawIntentRunEvent, any Error>.makeStream()
        let progress = OpenClawRunProgress()
        progress.advance(to: .running)
        continuation.yield(OpenClawIntentRunEvent(
            phase: .running,
            fractionCompleted: progress.fractionCompleted,
            runId: runID,
            sessionKey: key))

        self.runTasks[key]?.cancel()
        let task = Task {
            var text = ""
            do {
                for try await chunk in chunks {
                    try Task.checkCancellation()
                    text += chunk.text
                    progress.advance(to: chunk.isFinal ? .completed : .streaming)
                    continuation.yield(OpenClawIntentRunEvent(
                        phase: chunk.isFinal ? .completed : .streaming,
                        fractionCompleted: progress.fractionCompleted,
                        text: text.isEmpty ? nil : text,
                        runId: runID,
                        sessionKey: key))
                }
                continuation.finish()
            } catch is CancellationError {
                continuation.yield(OpenClawIntentRunEvent(
                    phase: .aborted,
                    fractionCompleted: 1,
                    text: text.isEmpty ? nil : text,
                    runId: runID,
                    sessionKey: key))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        self.runTasks[key] = task
        continuation.onTermination = { termination in
            if case .cancelled = termination {
                task.cancel()
            }
        }
        return stream
    }

    /// Cancels the session's active run.
    public func abort(sessionKey: String) async {
        self.runTasks.removeValue(forKey: sessionKey)?.cancel()
    }

    /// Starts talk mode through the configured handler.
    public func startTalk(sessionKey: String?) async throws {
        guard let talkHandler else {
            throw OpenClawIntentError.unsupported("Live voice is not available in this app.")
        }
        try await talkHandler(sessionKey)
    }

    private func allSessions() async -> [OpenClawIntentSessionSummary] {
        var merged = self.recentSessions
        if let sessionStore {
            for record in await sessionStore.allRecords() where merged[record.key] == nil {
                let label = record.label?.trimmingCharacters(in: .whitespacesAndNewlines)
                merged[record.key] = OpenClawIntentSessionSummary(
                    sessionKey: record.key,
                    title: label?.isEmpty == false ? label! : record.key,
                    agentId: record.agentID,
                    updatedAt: Date(timeIntervalSince1970: Double(record.updatedAtMs) / 1000))
            }
        }
        return merged.values.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }
}
