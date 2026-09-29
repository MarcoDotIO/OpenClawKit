import Foundation
import Testing
@testable import OpenClawCore
@testable import OpenClawModels

/// Scripted provider: each streaming call follows the next script (or the last one), recording the
/// request's resolved API key so tests can tell auth profiles apart.
private actor ScriptedStreamProvider: ModelProvider {
    enum Script: Sendable {
        /// Fails before producing any chunk.
        case failBeforeFirstChunk(String)
        /// Produces one text chunk, then fails.
        case failAfterFirstChunk(String)
        /// Produces text and a final chunk.
        case succeed(String)
        /// Never produces anything until cancelled.
        case hang
    }

    nonisolated let id: String
    private var scripts: [Script]
    private(set) var streamCalls = 0
    private(set) var generateCalls = 0
    private(set) var apiKeys: [String] = []
    private(set) var streamTerminations = 0

    init(id: String, scripts: [Script]) {
        self.id = id
        self.scripts = scripts
    }

    nonisolated var capabilities: ModelProviderCapabilities {
        .legacy
    }

    func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        self.generateCalls += 1
        self.apiKeys.append(request.metadata["auth.apiKey"] ?? "")
        switch self.nextScript() {
        case .succeed(let text):
            return ModelGenerationResponse(text: text, providerID: self.id, modelID: "m")
        case .failBeforeFirstChunk(let message), .failAfterFirstChunk(let message):
            throw OpenClawCoreError.unavailable(message)
        case .hang:
            try await Task.sleep(nanoseconds: 60_000_000_000)
            throw CancellationError()
        }
    }

    func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
        self.streamCalls += 1
        self.apiKeys.append(request.metadata["auth.apiKey"] ?? "")
        let script = self.nextScript()
        let providerID = self.id
        return AsyncThrowingStream { continuation in
            let task = Task {
                switch script {
                case .failBeforeFirstChunk(let message):
                    continuation.finish(throwing: OpenClawCoreError.unavailable(message))
                case .failAfterFirstChunk(let message):
                    continuation.yield(ModelStreamChunk(text: "partial"))
                    continuation.finish(throwing: OpenClawCoreError.unavailable(message))
                case .succeed(let text):
                    continuation.yield(.usageUpdate(ModelUsage(inputTokens: 1, outputTokens: 0)))
                    continuation.yield(ModelStreamChunk(text: text))
                    continuation.yield(.completed(response: ModelGenerationResponse(text: text, providerID: providerID, modelID: "m")))
                    continuation.finish()
                case .hang:
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                    continuation.finish()
                }
            }
            continuation.onTermination = { [weak self] _ in
                task.cancel()
                Task { await self?.recordTermination() }
            }
        }
    }

    func cancelGeneration(token: String?) async {}

    private func recordTermination() {
        self.streamTerminations += 1
    }

    private func nextScript() -> Script {
        self.scripts.count > 1 ? self.scripts.removeFirst() : (self.scripts.first ?? .succeed("ok"))
    }
}

private actor DiagnosticRecorder {
    private(set) var events: [RuntimeDiagnosticEvent] = []

    func record(_ event: RuntimeDiagnosticEvent) {
        self.events.append(event)
    }
}

@Suite("Model router streaming fallback and cancellation")
struct ModelRouterStreamingFallbackTests {
    private static func collect(_ stream: AsyncThrowingStream<ModelStreamChunk, Error>) async throws -> [ModelStreamChunk] {
        var chunks: [ModelStreamChunk] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }
        return chunks
    }

    private static func makeAuthStore(profiles: [String: String]) async throws -> AuthProfileStore {
        let root = FileManager().temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = AuthProfileStore(
            fileURL: root.appendingPathComponent("profiles.json"),
            credentialStore: FileCredentialStore(fileURL: root.appendingPathComponent("credentials.json"))
        )
        for (profileID, key) in profiles {
            try await store.setCredential(.apiKey(APIKeyAuthProfileCredential(provider: "primary", key: key)), for: profileID)
        }
        return store
    }

    @Test
    func streamFailingBeforeFirstChunkFallsBackToNextProvider() async throws {
        let primary = ScriptedStreamProvider(id: "primary", scripts: [.failBeforeFirstChunk("primary request failed with status 401")])
        let fallback = ScriptedStreamProvider(id: "fallback", scripts: [.succeed("from fallback")])
        let diagnostics = DiagnosticRecorder()
        let router = ModelRouter(
            defaultProviderID: "primary",
            providers: [primary, fallback],
            diagnosticsSink: { await diagnostics.record($0) }
        )
        let chunks = try await Self.collect(
            await router.generateStream(
                ModelGenerationRequest(
                    sessionKey: "s",
                    prompt: "hi",
                    providerID: "primary",
                    policy: ModelGenerationPolicy(fallbackProviderIDs: ["fallback"])
                )
            )
        )
        #expect(chunks.filter { $0.kind == .text }.map(\.text).joined() == "from fallback")
        #expect(chunks.last?.kind == .final)
        // The usage chunk that preceded the first content chunk is still delivered.
        #expect(chunks.first?.kind == .usage)
        #expect(await primary.streamCalls == 1)
        #expect(await fallback.streamCalls == 1)
        let retry = try #require(await diagnostics.events.first { $0.name == "model.request.retry" })
        #expect(retry.metadata["streaming"] == "true")
        #expect(retry.metadata["nextProviderID"] == "fallback")
    }

    @Test
    func streamFailingAfterFirstChunkDoesNotFallBack() async throws {
        let primary = ScriptedStreamProvider(id: "primary", scripts: [.failAfterFirstChunk("connection reset mid-stream")])
        let fallback = ScriptedStreamProvider(id: "fallback", scripts: [.succeed("from fallback")])
        let router = ModelRouter(defaultProviderID: "primary", providers: [primary, fallback])
        var texts: [String] = []
        await #expect(throws: OpenClawCoreError.self) {
            for try await chunk in await router.generateStream(
                ModelGenerationRequest(
                    sessionKey: "s",
                    prompt: "hi",
                    providerID: "primary",
                    policy: ModelGenerationPolicy(fallbackProviderIDs: ["fallback"])
                )
            ) {
                texts.append(chunk.text)
            }
        }
        #expect(texts == ["partial"])
        #expect(await fallback.streamCalls == 0)
    }

    @Test
    func streamingRotatesAuthProfilesAndRecordsOutcomes() async throws {
        let store = try await Self.makeAuthStore(profiles: ["primary:bad": "key-bad", "primary:good": "key-good"])
        let primary = ScriptedStreamProvider(
            id: "primary",
            scripts: [.failBeforeFirstChunk("primary request failed with status 429"), .succeed("ok")]
        )
        let router = ModelRouter(
            defaultProviderID: "primary",
            providers: [primary],
            authConfig: AuthConfig(
                profiles: [
                    "primary:bad": AuthProfileConfig(provider: "primary", mode: .apiKey),
                    "primary:good": AuthProfileConfig(provider: "primary", mode: .apiKey),
                ],
                order: ["primary": ["primary:bad", "primary:good"]]
            ),
            authProfileStore: store
        )
        let chunks = try await Self.collect(await router.generateStream(ModelGenerationRequest(sessionKey: "s", prompt: "hi")))
        #expect(chunks.last?.kind == .final)
        #expect(await primary.apiKeys == ["key-bad", "key-good"])
        let snapshot = await store.snapshot()
        #expect(snapshot.usageStats["primary:bad"]?.cooldownUntil != nil)
        #expect(snapshot.lastGood["primary"] == "primary:good")
    }

    @Test
    func streamingSuccessIsRecordedOnlyAfterTheStreamCompletes() async throws {
        let store = try await Self.makeAuthStore(profiles: ["primary:only": "key-only"])
        let primary = ScriptedStreamProvider(id: "primary", scripts: [.failBeforeFirstChunk("primary request failed with status 401")])
        let router = ModelRouter(
            defaultProviderID: "primary",
            providers: [primary],
            authConfig: AuthConfig(
                profiles: ["primary:only": AuthProfileConfig(provider: "primary", mode: .apiKey)],
                order: ["primary": ["primary:only"]]
            ),
            authProfileStore: store
        )
        await #expect(throws: OpenClawCoreError.self) {
            _ = try await Self.collect(await router.generateStream(ModelGenerationRequest(sessionKey: "s", prompt: "hi")))
        }
        let snapshot = await store.snapshot()
        #expect(snapshot.lastGood["primary"] == nil)
        #expect(snapshot.usageStats["primary:only"]?.errorCount == 1)
    }

    @Test
    func cancelledGenerateRecordsNoFailureAndStopsTheChain() async throws {
        let store = try await Self.makeAuthStore(profiles: ["primary:a": "key-a", "primary:b": "key-b"])
        let primary = ScriptedStreamProvider(id: "primary", scripts: [.hang])
        let fallback = ScriptedStreamProvider(id: "fallback", scripts: [.succeed("from fallback")])
        let router = ModelRouter(
            defaultProviderID: "primary",
            providers: [primary, fallback],
            authConfig: AuthConfig(
                profiles: [
                    "primary:a": AuthProfileConfig(provider: "primary", mode: .apiKey),
                    "primary:b": AuthProfileConfig(provider: "primary", mode: .apiKey),
                ],
                order: ["primary": ["primary:a", "primary:b"]]
            ),
            authProfileStore: store
        )
        let task = Task {
            try await router.generate(
                ModelGenerationRequest(
                    sessionKey: "s",
                    prompt: "hi",
                    providerID: "primary",
                    policy: ModelGenerationPolicy(fallbackProviderIDs: ["fallback"])
                )
            )
        }
        while await primary.generateCalls == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(await primary.generateCalls == 1)
        #expect(await fallback.generateCalls == 0)
        let snapshot = await store.snapshot()
        #expect(snapshot.usageStats["primary:a"]?.cooldownUntil == nil)
        #expect(snapshot.usageStats["primary:b"]?.cooldownUntil == nil)
    }

    @Test
    func cancellingTheStreamConsumerCancelsTheProviderStream() async throws {
        let store = try await Self.makeAuthStore(profiles: ["primary:a": "key-a"])
        let primary = ScriptedStreamProvider(id: "primary", scripts: [.hang])
        let fallback = ScriptedStreamProvider(id: "fallback", scripts: [.succeed("from fallback")])
        let router = ModelRouter(
            defaultProviderID: "primary",
            providers: [primary, fallback],
            authConfig: AuthConfig(
                profiles: ["primary:a": AuthProfileConfig(provider: "primary", mode: .apiKey)],
                order: ["primary": ["primary:a"]]
            ),
            authProfileStore: store
        )
        let stream = await router.generateStream(
            ModelGenerationRequest(
                sessionKey: "s",
                prompt: "hi",
                providerID: "primary",
                policy: ModelGenerationPolicy(fallbackProviderIDs: ["fallback"])
            )
        )
        let consumer = Task {
            for try await _ in stream {}
        }
        while await primary.streamCalls == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        consumer.cancel()
        _ = await consumer.result
        let deadline = Date().addingTimeInterval(5)
        while await primary.streamTerminations == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(await primary.streamTerminations == 1)
        #expect(await fallback.streamCalls == 0)
        #expect(await store.snapshot().usageStats["primary:a"]?.cooldownUntil == nil)
    }

    @Test
    func retryDiagnosticsRedactURLSecrets() async throws {
        let failingURL = "https://generativelanguage.googleapis.com/v1beta/models/gemini:streamGenerateContent?alt=sse&key=AIzaSECRET123"
        let urlError = URLError(
            .networkConnectionLost,
            userInfo: [NSURLErrorFailingURLStringErrorKey: failingURL, NSLocalizedDescriptionKey: "The network connection was lost."]
        )
        #expect(String(describing: urlError).contains("AIzaSECRET123"))
        let sanitized = ProviderErrorRedaction.sanitize(urlError)
        #expect((sanitized as? URLError)?.code == .networkConnectionLost)
        #expect(!String(describing: sanitized).contains("AIzaSECRET123"))
        #expect(!ProviderErrorRedaction.describe(urlError).contains("AIzaSECRET123"))
        #expect(ProviderErrorRedaction.redact("GET \(failingURL) failed") == "GET https://generativelanguage.googleapis.com/v1beta/models/gemini:streamGenerateContent?alt=sse&key=[redacted] failed")
        #expect(ProviderErrorRedaction.redact("Authorization: Bearer sk-live-abc.def") == "Authorization: Bearer [redacted]")
    }
}
