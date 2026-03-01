@_exported import OpenClawAgents
@_exported import OpenClawChannels
@_exported import OpenClawCore
@_exported import OpenClawGateway
@_exported import OpenClawMedia
@_exported import OpenClawMemory
@_exported import OpenClawModels
@_exported import OpenClawPlugins
@_exported import OpenClawProtocol
@_exported import OpenClawSkills
import Foundation

/// High-level facade for integrating OpenClawKit into host apps.
public struct OpenClawSDK: Sendable {
    /// Shared singleton instance for convenience integrations.
    public static let shared = OpenClawSDK()

    /// Build metadata for the linked SDK bundle.
    public let buildInfo: OpenClawBuildInfo

    /// Creates an SDK facade with explicit build metadata.
    /// - Parameter buildInfo: Build information exposed by the SDK.
    public init(buildInfo: OpenClawBuildInfo = OpenClawBuildInfo(protocolVersion: GATEWAY_PROTOCOL_VERSION)) {
        self.buildInfo = buildInfo
    }

    /// Loads configuration from disk with in-memory caching.
    /// - Parameters:
    ///   - fileURL: Path to config JSON.
    ///   - cacheTTLms: Cache lifetime in milliseconds.
    /// - Returns: Decoded configuration payload.
    public func loadConfig(from fileURL: URL, cacheTTLms: Int = 200) async throws -> OpenClawConfig {
        let store = ConfigStore(fileURL: fileURL, cacheTTLms: cacheTTLms)
        return try await store.loadCached()
    }

    /// Saves configuration to disk.
    /// - Parameters:
    ///   - config: Configuration value to persist.
    ///   - fileURL: Destination config path.
    public func saveConfig(_ config: OpenClawConfig, to fileURL: URL) async throws {
        let store = ConfigStore(fileURL: fileURL)
        try await store.save(config)
    }

    /// Loads and returns a session store actor from disk.
    /// - Parameter fileURL: Path to session store file.
    /// - Returns: Initialized session store.
    public func loadSessionStore(from fileURL: URL) async throws -> SessionStore {
        let store = SessionStore(fileURL: fileURL)
        try await store.load()
        return store
    }

    /// Saves an existing session store actor.
    /// - Parameter store: Session store to persist.
    public func saveSessionStore(_ store: SessionStore) async throws {
        try await store.save()
    }

    /// Resolves the effective session key for routing.
    /// - Parameters:
    ///   - explicit: Explicit key from caller.
    ///   - context: Optional routing context.
    ///   - config: Routing configuration.
    /// - Returns: Resolved session key.
    public func resolveSessionKey(
        explicit: String?,
        context: SessionRoutingContext?,
        config: OpenClawConfig
    ) -> String {
        SessionKeyResolver.resolve(explicit: explicit, context: context, config: config)
    }

    /// Validates that a port is available to bind.
    /// - Parameter port: Candidate port.
    public func ensurePortAvailable(_ port: Int) throws {
        try PortUtils.ensurePortAvailable(port)
    }

    /// Executes a process command.
    /// - Parameters:
    ///   - command: Command plus arguments.
    ///   - cwd: Optional working directory.
    /// - Returns: Process result containing exit code/stdout/stderr.
    public func runExec(_ command: [String], cwd: URL? = nil) async throws -> ProcessResult {
        let runner = ProcessRunner()
        return try await runner.run(command, cwd: cwd)
    }

    /// Executes a process command with timeout cancellation.
    /// - Parameters:
    ///   - command: Command plus arguments.
    ///   - timeoutMs: Timeout in milliseconds.
    ///   - cwd: Optional working directory.
    /// - Returns: Process result when completed before timeout.
    public func runCommandWithTimeout(
        _ command: [String],
        timeoutMs: Int,
        cwd: URL? = nil
    ) async throws -> ProcessResult {
        let timeoutNs = UInt64(max(0, timeoutMs)) * 1_000_000
        return try await withThrowingTaskGroup(of: ProcessResult.self) { group in
            group.addTask {
                try await self.runExec(command, cwd: cwd)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNs)
                throw OpenClawCoreError.unavailable("Command timed out")
            }
            guard let result = try await group.next() else {
                throw OpenClawCoreError.unavailable("Command timed out")
            }
            group.cancelAll()
            return result
        }
    }

    /// Resolves a binary on PATH and returns absolute path.
    /// - Parameter name: Binary name.
    /// - Returns: Absolute binary path.
    public func ensureBinary(_ name: String) throws -> String {
        try BinaryUtils.ensureBinary(name)
    }

    /// Creates a diagnostics pipeline for centralized usage/event aggregation.
    /// - Parameters:
    ///   - eventLimit: Number of recent events to retain in-memory.
    ///   - replayStore: Optional replay store used for deterministic capture.
    /// - Returns: Diagnostics pipeline actor.
    public func makeDiagnosticsPipeline(
        eventLimit: Int = 500,
        replayStore: (any ReplayStore)? = nil,
        timelineSink: (any RuntimeTimelineSink)? = nil
    ) -> RuntimeDiagnosticsPipeline {
        RuntimeDiagnosticsPipeline(
            eventLimit: eventLimit,
            replayStore: replayStore,
            timelineSink: timelineSink
        )
    }

    /// Creates a default file-backed replay store.
    /// - Parameter fileURL: Optional custom replay log location.
    /// - Returns: Replay store actor.
    public func makeReplayStore(fileURL: URL? = nil) -> FileReplayStore {
        FileReplayStore(fileURL: fileURL)
    }

    /// Creates a replay engine over the provided store.
    /// - Parameter store: Replay store implementation.
    /// - Returns: Replay engine facade.
    public func makeReplayEngine(store: any ReplayStore) -> ReplayEngine {
        ReplayEngine(store: store)
    }

    /// Replays events for one run identifier.
    /// - Parameters:
    ///   - runID: Run identifier to replay.
    ///   - store: Replay store implementation.
    ///   - limit: Optional maximum number of returned events.
    public func replayEvents(
        forRunID runID: String,
        from store: any ReplayStore,
        limit: Int? = nil
    ) async throws -> [ReplayEventEnvelope] {
        let engine = ReplayEngine(store: store)
        return try await engine.events(forRunID: runID, limit: limit)
    }

    /// Replays events for one session key.
    /// - Parameters:
    ///   - sessionKey: Session key to replay.
    ///   - store: Replay store implementation.
    ///   - limit: Optional maximum number of returned events.
    public func replayEvents(
        forSessionKey sessionKey: String,
        from store: any ReplayStore,
        limit: Int? = nil
    ) async throws -> [ReplayEventEnvelope] {
        let engine = ReplayEngine(store: store)
        return try await engine.events(forSessionKey: sessionKey, limit: limit)
    }

    /// Replays events for an inclusive time window.
    /// - Parameters:
    ///   - window: Inclusive replay time window.
    ///   - store: Replay store implementation.
    ///   - limit: Optional maximum number of returned events.
    public func replayEvents(
        in window: ReplayTimeWindow,
        from store: any ReplayStore,
        limit: Int? = nil
    ) async throws -> [ReplayEventEnvelope] {
        let engine = ReplayEngine(store: store)
        return try await engine.events(in: window, limit: limit)
    }

    /// Builds an intent graph for a run request.
    /// - Parameters:
    ///   - request: Run request payload.
    ///   - runtime: Optional preconfigured runtime to use.
    ///   - diagnosticsPipeline: Optional diagnostics pipeline for ephemeral runtime creation.
    /// - Returns: Deterministic intent graph representation.
    public func makeIntentGraph(
        for request: AgentRunRequest,
        runtime: EmbeddedAgentRuntime? = nil,
        diagnosticsPipeline: RuntimeDiagnosticsPipeline? = nil
    ) async -> IntentGraph {
        if let runtime {
            return await runtime.makeIntentGraph(for: request)
        }
        let diagnosticsSink = await diagnosticsPipeline?.sink()
        let ephemeralRuntime = EmbeddedAgentRuntime(diagnosticsSink: diagnosticsSink)
        return await ephemeralRuntime.makeIntentGraph(for: request)
    }

    /// Executes a run request through the intent graph API surface.
    /// - Parameters:
    ///   - request: Run request payload.
    ///   - runtime: Optional preconfigured runtime to use.
    ///   - timeoutMs: Timeout in milliseconds.
    ///   - diagnosticsPipeline: Optional diagnostics pipeline for ephemeral runtime creation.
    /// - Returns: Combined graph and run result payload.
    public func runIntentGraph(
        _ request: AgentRunRequest,
        runtime: EmbeddedAgentRuntime? = nil,
        timeoutMs: Int = 30_000,
        diagnosticsPipeline: RuntimeDiagnosticsPipeline? = nil
    ) async throws -> IntentGraphRunResult {
        if let runtime {
            return try await runtime.runIntentGraph(request, timeoutMs: timeoutMs)
        }
        let diagnosticsSink = await diagnosticsPipeline?.sink()
        let ephemeralRuntime = EmbeddedAgentRuntime(diagnosticsSink: diagnosticsSink)
        return try await ephemeralRuntime.runIntentGraph(request, timeoutMs: timeoutMs)
    }

    /// Applies diagnostics feedback to adaptive model-router state.
    /// - Parameters:
    ///   - router: Model router to optimize.
    ///   - diagnosticsPipeline: Diagnostics pipeline containing provider telemetry.
    ///   - decayFactor: Historical retention factor (`0...1`).
    /// - Returns: Updated adaptive routing snapshot.
    public func optimizeModelRouter(
        _ router: ModelRouter,
        using diagnosticsPipeline: RuntimeDiagnosticsPipeline,
        decayFactor: Double = 0.85
    ) async -> AdaptiveRoutingSnapshot? {
        await router.optimizeRouting(
            using: diagnosticsPipeline,
            decayFactor: decayFactor
        )
    }

    /// Returns timeline records derived from recent diagnostics events.
    /// - Parameters:
    ///   - pipeline: Runtime diagnostics pipeline.
    ///   - limit: Maximum number of records to include.
    public func runtimeTimeline(
        from pipeline: RuntimeDiagnosticsPipeline,
        limit: Int = 500
    ) async -> [RuntimeTimelineRecord] {
        let events = await pipeline.recentEvents(limit: limit)
        return events.map(RuntimeTimelineRecord.init(event:))
    }

    /// Exports timeline records to a JSON file for profiling correlation.
    /// - Parameters:
    ///   - pipeline: Runtime diagnostics pipeline.
    ///   - limit: Maximum number of records to export.
    ///   - fileURL: Destination JSON file URL.
    /// - Returns: Written file URL.
    @discardableResult
    public func exportRuntimeTimeline(
        from pipeline: RuntimeDiagnosticsPipeline,
        limit: Int = 500,
        to fileURL: URL
    ) async throws -> URL {
        let timeline = await self.runtimeTimeline(from: pipeline, limit: limit)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let payload = try encoder.encode(timeline)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try payload.write(to: fileURL, options: [.atomic])
        return fileURL
    }

    /// Runs a lightweight security audit and optionally publishes findings to diagnostics.
    /// - Parameters:
    ///   - options: Security audit options.
    ///   - diagnosticsPipeline: Optional diagnostics pipeline for structured audit events.
    ///   - replayLedgerSigner: Optional replay-ledger signer for signature verification.
    /// - Returns: Security audit report.
    public func runSecurityAudit(
        options: SecurityAuditOptions = SecurityAuditOptions(),
        diagnosticsPipeline: RuntimeDiagnosticsPipeline? = nil,
        replayLedgerSigner: (any ReplayLedgerSigner)? = nil
    ) async -> SecurityAuditReport {
        let report = SecurityAuditRunner.run(
            options: options,
            replayLedgerSigner: replayLedgerSigner
        )
        if let diagnosticsPipeline {
            await diagnosticsPipeline.record(
                RuntimeDiagnosticEvent(
                    subsystem: "security",
                    name: "audit.completed",
                    metadata: [
                        "totalFindings": String(report.findings.count),
                        "errors": String(report.count(for: .error)),
                        "warnings": String(report.count(for: .warning)),
                        "highestSeverity": report.highestSeverity.rawValue,
                        "replayLedgerValid": String(report.replayLedgerIntegrity?.isValid ?? true),
                        "replayLedgerEvents": String(report.replayLedgerIntegrity?.validatedEventCount ?? 0),
                    ]
                )
            )
            for finding in report.findings {
                await diagnosticsPipeline.record(
                    RuntimeDiagnosticEvent(
                        subsystem: "security",
                        name: "audit.finding",
                        metadata: [
                            "id": finding.id,
                            "severity": finding.severity.rawValue,
                            "summary": finding.summary,
                            "path": finding.filePath ?? "",
                        ]
                    )
                )
            }
        }
        return report
    }

    /// Builds an auto-reply engine backed by in-memory web channel adapter.
    /// - Parameters:
    ///   - config: Runtime configuration.
    ///   - sessionStoreURL: Session store path.
    /// - Returns: Ready-to-use auto-reply engine.
    public func monitorWebChannel(
        config: OpenClawConfig,
        sessionStoreURL: URL,
        diagnosticsPipeline: RuntimeDiagnosticsPipeline? = nil
    ) async throws -> AutoReplyEngine {
        let diagnosticsSink = await diagnosticsPipeline?.sink()
        let sessionStore = SessionStore(fileURL: sessionStoreURL)
        try await sessionStore.load()
        let channelRegistry = ChannelRegistry(
            sendRetryPolicy: ChannelSendRetryPolicy(),
            sendThrottlePolicy: ChannelSendThrottlePolicy(),
            diagnosticsSink: diagnosticsSink
        )
        let webchat = InMemoryChannelAdapter(id: .webchat)
        await channelRegistry.register(webchat)
        try await webchat.start()
        let runtime = EmbeddedAgentRuntime(diagnosticsSink: diagnosticsSink)
        return AutoReplyEngine(
            config: config,
            sessionStore: sessionStore,
            channelRegistry: channelRegistry,
            runtime: runtime,
            diagnosticsSink: diagnosticsSink
        )
    }

    /// Processes one inbound message using a temporary engine built from config.
    /// - Parameters:
    ///   - config: Runtime configuration.
    ///   - sessionStoreURL: Session store path.
    ///   - inbound: Message payload to process.
    /// - Returns: Generated outbound message.
    public func getReplyFromConfig(
        config: OpenClawConfig,
        sessionStoreURL: URL,
        inbound: InboundMessage,
        diagnosticsPipeline: RuntimeDiagnosticsPipeline? = nil
    ) async throws -> OutboundMessage {
        let engine = try await monitorWebChannel(
            config: config,
            sessionStoreURL: sessionStoreURL,
            diagnosticsPipeline: diagnosticsPipeline
        )
        return try await engine.process(inbound)
    }

    /// Suspends until the task is cancelled.
    public func waitForever() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
}
