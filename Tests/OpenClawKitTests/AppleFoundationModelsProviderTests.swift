import Foundation
import Testing
@testable import OpenClawKit
@testable import OpenClawModels
#if canImport(FoundationModels) && !os(tvOS) && !os(watchOS)
import FoundationModels
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Apple FM tests that need the FoundationModels framework but not Apple Intelligence: schema
// emission, framework error mapping, the OpenClawLanguageModel bridge, and the provider engine
// (tool boundary, in-process tools, structured output, replay, streaming) driven through a scripted
// bridged model. Live tests at the end need OPENCLAW_LIVE_APPLE_FM=1 (and OPENCLAW_LIVE_APPLE_PCC=1).

private actor RequestLog {
    private(set) var requests: [ModelGenerationRequest] = []

    func append(_ request: ModelGenerationRequest) -> Int {
        self.requests.append(request)
        return self.requests.count - 1
    }
}

/// Provider whose responses come from a script (call index -> response).
private struct ScriptedProvider: ModelProvider {
    let id = "scripted"
    let log = RequestLog()
    let script: @Sendable (ModelGenerationRequest, Int) -> ModelGenerationResponse

    var capabilities: ModelProviderCapabilities {
        ModelProviderCapabilities(supportsStreaming: true, supportsTools: true, supportsJSONSchema: true, supportsTranscript: true)
    }

    func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        let index = await self.log.append(request)
        return self.script(request, index)
    }
}

/// Provider whose script may throw (call index -> response or error).
private struct FailingScriptedProvider: ModelProvider {
    let id = "scripted"
    let log = RequestLog()
    let script: @Sendable (ModelGenerationRequest, Int) throws -> ModelGenerationResponse

    var capabilities: ModelProviderCapabilities {
        ModelProviderCapabilities(supportsStreaming: true, supportsTools: true, supportsJSONSchema: true, supportsTranscript: true)
    }

    func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        let index = await self.log.append(request)
        return try self.script(request, index)
    }
}

private actor InvocationCounter {
    private(set) var calls = 0

    func increment() {
        self.calls += 1
    }
}

/// In-process executor that counts how often each call actually ran.
private struct CountingExecutor: FoundationModelsToolExecuting {
    let counter = InvocationCounter()

    func executeTool(_ call: ModelToolCall) async throws -> FoundationModelsToolOutput {
        await self.counter.increment()
        return FoundationModelsToolOutput(text: "sent")
    }
}

private struct FixedExecutor: FoundationModelsToolExecuting {
    let text: String

    func executeTool(_ call: ModelToolCall) async throws -> FoundationModelsToolOutput {
        FoundationModelsToolOutput(text: self.text)
    }
}

private let setupToolSchema: [String: AnyCodable] = [
    "type": AnyCodable("object"),
    "required": AnyCodable([AnyCodable("action"), AnyCodable("channel")]),
    "properties": AnyCodable([
        "action": AnyCodable(["type": AnyCodable("string"), "const": AnyCodable("connect_channel")]),
        "channel": AnyCodable(["type": AnyCodable("string")]),
        "sha256": AnyCodable(["type": AnyCodable("string"), "pattern": AnyCodable("^[a-fA-F0-9]{64}$")]),
    ]),
]

private let setupCall = ModelToolCall(
    id: "call-1",
    name: "openclaw",
    arguments: ["action": AnyCodable("connect_channel"), "channel": AnyCodable("telegram")]
)

@Suite("Apple FM framework integration")
struct AppleFoundationModelsFrameworkTests {
    @Test
    func emitsDynamicGenerationSchemas() throws {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }
        let schema = try FoundationModelsSchemaConverter.generationSchema(setupToolSchema, name: "openclaw")
        let json = FoundationModelsSchemaConverter.jsonSchema(from: schema)
        #expect(json["type"]?.stringValue == "object")
        #expect(json["required"]?.arrayValue?.compactMap(\.stringValue).sorted() == ["action", "channel"])
        let properties = try #require(json["properties"]?.dictionaryValue)
        #expect(Set(properties.keys) == ["action", "channel", "sha256"])
        #expect(properties["action"]?.dictionaryValue?["enum"]?.arrayValue?.compactMap(\.stringValue) == ["connect_channel"])
        // Patterns are validated host-side, never emitted as regex guides.
        #expect(properties["sha256"]?.dictionaryValue?["pattern"] == nil)

        let bounded = try FoundationModelsSchemaConverter.generationSchema(
            [
                "type": AnyCodable("object"),
                "properties": AnyCodable(["n": AnyCodable(["type": AnyCodable("integer"), "minimum": AnyCodable(1), "maximum": AnyCodable(5)])]),
            ],
            name: "Response"
        )
        let boundedJSON = FoundationModelsSchemaConverter.jsonSchema(from: bounded)
        let n = boundedJSON["properties"]?.dictionaryValue?["n"]?.dictionaryValue
        #expect(n?["minimum"]?.intValue == 1)
        #expect(n?["maximum"]?.intValue == 5)

        #expect(throws: FoundationModelsError.self) {
            _ = try FoundationModelsSchemaConverter.generationSchema(["type": AnyCodable("object"), "oneOf": AnyCodable([AnyCodable]())], name: "bad")
        }
        if #available(macOS 26.4, iOS 26.4, visionOS 26.4, *) {
            let nullable = try FoundationModelsSchemaConverter.generationSchema(
                ["type": AnyCodable("object"), "properties": AnyCodable(["v": AnyCodable(["type": AnyCodable([AnyCodable("string"), AnyCodable("null")])])])],
                name: "Response"
            )
            #expect(FoundationModelsSchemaConverter.jsonSchema(from: nullable)["properties"] != nil)
        }
    }

    @Test
    func mapsOS26GenerationErrors() {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }
        Self.checkGenerationErrors()
    }

    @available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
    private static func checkGenerationErrors() {
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "x")
        let overflow = FoundationModelsErrorMapper.map(LanguageModelSession.GenerationError.exceededContextWindowSize(context)) as? FoundationModelsError
        #expect(overflow?.code == .contextOverflow)
        let limited = FoundationModelsErrorMapper.map(LanguageModelSession.GenerationError.rateLimited(context)) as? FoundationModelsError
        #expect(limited?.code == .rateLimited)
        #expect(limited?.retryable == true)
        let guardrail = FoundationModelsErrorMapper.map(LanguageModelSession.GenerationError.guardrailViolation(context)) as? FoundationModelsError
        #expect(guardrail?.code == .guardrail)
        let decoding = FoundationModelsErrorMapper.map(LanguageModelSession.GenerationError.decodingFailure(context)) as? FoundationModelsError
        #expect(decoding == FoundationModelsError.malformedJSON)
        let busy = FoundationModelsErrorMapper.map(LanguageModelSession.GenerationError.concurrentRequests(context)) as? FoundationModelsError
        #expect(busy?.code == .busy)
    }

    @Test
    func mapsOS27FrameworkErrors() {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, *) else { return }
        Self.checkLanguageModelErrors()
    }

    private static func mapped(_ error: any Error) -> FoundationModelsError? {
        FoundationModelsErrorMapper.map(error) as? FoundationModelsError
    }

    @available(macOS 27.0, iOS 27.0, visionOS 27.0, *)
    private static func checkLanguageModelErrors() {
        let overflow = Self.mapped(
            LanguageModelError.contextSizeExceeded(.init(contextSize: 8_192, tokenCount: 9_000, debugDescription: "x"))
        )
        #expect(overflow?.code == .contextOverflow)
        #expect(overflow?.contextSize == 8_192)
        #expect(overflow?.tokenCount == 9_000)
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let limited = Self.mapped(LanguageModelError.rateLimited(.init(resetDate: reset, debugDescription: "x")))
        #expect(limited?.code == .rateLimited)
        #expect(limited?.resetDate == reset)
        let capability = Self.mapped(
            LanguageModelError.unsupportedCapability(.init(capability: .reasoning, debugDescription: "x"))
        )
        #expect(capability?.code == .unsupportedCapability)
        #expect(capability?.capability == "reasoning")
        let refusal = Self.mapped(LanguageModelError.refusal(.init(explanation: "no", debugDescription: "x")))
        #expect(refusal?.code == .refusal)
        let timeout = Self.mapped(LanguageModelError.timeout(.init(debugDescription: "x")))
        #expect(timeout?.code == .timeout)
        let locale = Self.mapped(
            LanguageModelError.unsupportedLanguageOrLocale(.init(languageCode: Locale.LanguageCode("xx"), debugDescription: "x"))
        )
        #expect(locale?.code == .unsupported)
        let busy = Self.mapped(LanguageModelSession.Error.concurrentRequests)
        #expect(busy?.code == .busy)
        let assets = Self.mapped(SystemLanguageModel.Error.assetsUnavailable(.init(debugDescription: "x")))
        #expect(assets?.code == .unavailable)
        let parsing = Self.mapped(GeneratedContent.ParsingError(rawContent: "Bearer secret", debugDescription: "x"))
        #expect(parsing == FoundationModelsError.malformedJSON)
        let quota = Self.mapped(
            PrivateCloudComputeLanguageModel.Error.quotaLimitReached(.init(resetDate: reset, debugDescription: "x"))
        )
        #expect(quota?.code == .rateLimited)
        #expect(quota?.resetDate == reset)
        let network = Self.mapped(PrivateCloudComputeLanguageModel.Error.networkFailure(.init(debugDescription: "x")))
        #expect(network?.code == .networkFailure)
        #expect(network?.retryable == true)
        let service = Self.mapped(
            PrivateCloudComputeLanguageModel.Error.serviceUnavailable(.init(debugDescription: "x"))
        )
        #expect(service?.code == .serviceUnavailable)
    }
}

@Suite("Apple FM LanguageModel bridge and engine")
struct AppleFoundationModelsBridgeTests {
    @Test
    func bridgedProviderAnswersFoundationModelsSessions() async throws {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, *) else { return }
        try await Self.checkBridgeRespond()
    }

    @available(macOS 27.0, iOS 27.0, visionOS 27.0, *)
    private static func checkBridgeRespond() async throws {
        let provider = ScriptedProvider { request, _ in
            ModelGenerationResponse(
                text: "echo: \(request.resolvedMessages.last?.text ?? "")",
                providerID: "scripted",
                usage: ModelUsage(inputTokens: 11, outputTokens: 3)
            )
        }
        let model = OpenClawLanguageModel(provider: provider, modelID: "m1")
        #expect(model.capabilities.contains(.toolCalling))
        #expect(model.capabilities.contains(.guidedGeneration))
        #expect(!model.capabilities.contains(.vision))
        let session = LanguageModelSession(model: model, instructions: "Be brief")
        let response = try await session.respond(to: "hello bridge", options: GenerationOptions(temperature: 0.5, maximumResponseTokens: 42))
        #expect(response.content == "echo: hello bridge")
        #expect(response.usage.input.totalTokenCount == 11)
        #expect(response.usage.output.totalTokenCount == 3)
        let request = try #require(await provider.log.requests.first)
        #expect(request.systemPrompt == "Be brief")
        #expect(request.messages == [.user("hello bridge")])
        #expect(request.providerID == "scripted")
        #expect(request.modelID == "m1")
        #expect(request.policy.maxTokens == 42)
        #expect(request.policy.temperature == 0.5)

        var snapshots = 0
        var last = ""
        for try await snapshot in session.streamResponse(to: "again") {
            snapshots += 1
            last = snapshot.content
        }
        #expect(snapshots >= 1)
        #expect(last == "echo: again")
        let replay = try #require(await provider.log.requests.last)
        #expect(replay.messages.count == 3)
        #expect(replay.messages.last == .user("again"))
    }

    @Test
    func proposeOnlyToolsStopAtTheBoundaryWithTheProposedCall() async throws {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, *) else { return }
        try await Self.checkBoundary()
    }

    @available(macOS 27.0, iOS 27.0, visionOS 27.0, *)
    private static func checkBoundary() async throws {
        let provider = ScriptedProvider { _, _ in
            let call = ModelToolCall(id: "p1", name: "openclaw", arguments: setupCall.arguments ?? [:])
            return ModelGenerationResponse(text: "", providerID: "scripted", toolCalls: [call])
        }
        let request = ModelGenerationRequest(
            sessionKey: "s",
            prompt: "Connect Telegram.",
            systemPrompt: "Only propose actions through the supplied tool.",
            policy: ModelGenerationPolicy(maxTokens: 128),
            tools: [ModelToolDefinition(name: "openclaw", description: "Set up OpenClaw", parameters: setupToolSchema)]
        )
        let context = AppleFMRunContext(request: request, options: FoundationModelsProviderOptions(), providerID: "apple-fm", target: .system, sink: nil)
        let result = try await AppleFMGeneration27.run(model: OpenClawLanguageModel(provider: provider), context: context, tokenCounter: nil)
        #expect(result.response.stopReason == .toolUse)
        #expect(result.response.text.isEmpty)
        #expect(result.response.providerID == "apple-fm")
        #expect(result.response.modelID == "system")
        let call = try #require(result.response.toolCalls.first)
        #expect(result.response.toolCalls.count == 1)
        #expect(call.name == "openclaw")
        #expect(call.arguments == setupCall.arguments)
        #expect(!call.id.isEmpty)
        #expect(result.executedToolCalls.isEmpty)
        // The host tool reached the model as a JSON Schema declaration with the upstream policy.
        let seen = try #require(await provider.log.requests.first)
        #expect(seen.tools.map(\.name) == ["openclaw"])
        #expect(seen.policy.maxTokens == 128)
        #expect(seen.toolChoice == .auto)
    }

    @Test
    func inProcessToolsRunInsideTheSession() async throws {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, *) else { return }
        try await Self.checkInProcess()
    }

    @available(macOS 27.0, iOS 27.0, visionOS 27.0, *)
    private static func checkInProcess() async throws {
        let provider = ScriptedProvider { request, index in
            if index == 0 {
                let call = ModelToolCall(id: "p1", name: "lookup", arguments: ["q": AnyCodable("x")])
                return ModelGenerationResponse(text: "", providerID: "scripted", toolCalls: [call])
            }
            return ModelGenerationResponse(text: "done: \(request.resolvedMessages.last?.text ?? "")", providerID: "scripted")
        }
        let options = FoundationModelsProviderOptions(tools: FoundationModelsToolOptions(execution: .executeInProcess(FixedExecutor(text: "42"))))
        let request = ModelGenerationRequest(
            sessionKey: "s",
            prompt: "Look it up.",
            tools: [
                ModelToolDefinition(
                    name: "lookup",
                    parameters: ["type": AnyCodable("object"), "properties": AnyCodable(["q": AnyCodable(["type": AnyCodable("string")])])]
                ),
            ]
        )
        let context = AppleFMRunContext(request: request, options: options, providerID: "apple-fm", target: .system, sink: nil)
        let result = try await AppleFMGeneration27.run(model: OpenClawLanguageModel(provider: provider), context: context, tokenCounter: nil)
        #expect(result.response.text == "done: 42")
        #expect(result.response.stopReason == .stop)
        #expect(result.executedToolCalls.count == 1)
        #expect(result.executedToolCalls.first?.output.text == "42")
        #expect(result.executedToolCalls.first?.call.arguments == ["q": AnyCodable("x")])
        let second = try #require(await provider.log.requests.last)
        guard case .toolResult(let toolResult) = second.messages.last else {
            Issue.record("expected the tool output to be replayed to the provider")
            return
        }
        #expect(toolResult.toolName == "lookup")
        #expect(toolResult.toolCallID == "p1")
        #expect(toolResult.content == [.text("42")])
    }

    @Test
    func privateCloudFallbackNeverRepeatsInProcessTools() async throws {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, *) else { return }
        try await Self.checkFallbackAfterInProcessTools()
    }

    @available(macOS 27.0, iOS 27.0, visionOS 27.0, *)
    private static func checkFallbackAfterInProcessTools() async throws {
        // The model sends a message through an in-process tool, then the next turn hits a transient
        // (fallback-eligible) failure.
        let provider = FailingScriptedProvider { _, index in
            if index == 0 {
                return ModelGenerationResponse(
                    text: "",
                    providerID: "scripted",
                    toolCalls: [ModelToolCall(id: "p1", name: "send", arguments: ["to": AnyCodable("ops")])]
                )
            }
            throw FoundationModelsError(code: .rateLimited, message: "quota reached")
        }
        let executor = CountingExecutor()
        let options = FoundationModelsProviderOptions(tools: FoundationModelsToolOptions(execution: .executeInProcess(executor)))
        let request = ModelGenerationRequest(
            sessionKey: "s",
            prompt: "Tell ops.",
            tools: [
                ModelToolDefinition(
                    name: "send",
                    parameters: ["type": AnyCodable("object"), "properties": AnyCodable(["to": AnyCodable(["type": AnyCodable("string")])])]
                ),
            ]
        )
        let recorder = FoundationModelsToolCallRecorder()
        let context = AppleFMRunContext(
            request: request,
            options: options,
            providerID: "apple-fm",
            target: .privateCloudCompute,
            sink: nil,
            recorder: recorder
        )
        let fallbacks = InvocationCounter()
        do {
            _ = try await AppleFoundationModelsEngine.attemptWithFallback(recorder: recorder, sink: nil) {
                try await AppleFMGeneration27.run(model: OpenClawLanguageModel(provider: provider), context: context, tokenCounter: nil)
            } fallback: { _ in
                await fallbacks.increment()
                return FoundationModelsGenerationResult(response: ModelGenerationResponse(text: "again", providerID: "apple-fm"), target: .system)
            }
            Issue.record("expected the failure to propagate instead of falling back")
        } catch {
            let failure = await AppleFoundationModelsEngine.failure(error, recorder: recorder)
            let modelError = try #require(failure as? FoundationModelsError)
            #expect(modelError.code == .rateLimited)
            #expect(!modelError.retryable)
            #expect(modelError.executedToolCalls.map(\.call.name) == ["send"])
            #expect(modelError.executedToolCalls.first?.output.text == "sent")
        }
        #expect(await fallbacks.calls == 0)
        #expect(await executor.counter.calls == 1)

        // Without side effects the same failure still falls back to the on-device model.
        let clean = FoundationModelsToolCallRecorder()
        let result = try await AppleFoundationModelsEngine.attemptWithFallback(recorder: clean, sink: nil) {
            throw FoundationModelsError(code: .networkFailure, message: "offline")
        } fallback: { error in
            #expect(error.code == .networkFailure)
            return FoundationModelsGenerationResult(response: ModelGenerationResponse(text: "on device", providerID: "apple-fm"), target: .system)
        }
        #expect(result.response.text == "on device")
        // A non-transient failure never falls back.
        await #expect(throws: FoundationModelsError.self) {
            _ = try await AppleFoundationModelsEngine.attemptWithFallback(recorder: clean, sink: nil) {
                throw FoundationModelsError(code: .guardrail, message: "blocked")
            } fallback: { _ in
                Issue.record("guardrail failures must not fall back")
                return FoundationModelsGenerationResult(response: ModelGenerationResponse(text: "", providerID: "apple-fm"), target: .system)
            }
        }
    }

    @Test
    func structuredOutputIsRevalidatedAgainstTheCallerSchema() async throws {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, *) else { return }
        try await Self.checkStructuredOutput()
    }

    @available(macOS 27.0, iOS 27.0, visionOS 27.0, *)
    private static func checkStructuredOutput() async throws {
        let schema: [String: AnyCodable] = [
            "type": AnyCodable("object"),
            "properties": AnyCodable(["value": AnyCodable(["type": AnyCodable("string"), "minLength": AnyCodable(1)])]),
            "required": AnyCodable([AnyCodable("value")]),
        ]
        func run(_ text: String) async throws -> ModelGenerationResponse {
            let provider = ScriptedProvider { _, _ in ModelGenerationResponse(text: text, providerID: "scripted") }
            let request = ModelGenerationRequest(sessionKey: "s", prompt: "Answer.", responseFormat: .jsonSchema(name: "answer", schema: schema, strict: true))
            let context = AppleFMRunContext(request: request, options: FoundationModelsProviderOptions(), providerID: "apple-fm", target: .system, sink: nil)
            let response = try await AppleFMGeneration27.run(model: OpenClawLanguageModel(provider: provider), context: context, tokenCounter: nil).response
            let seen = try #require(await provider.log.requests.first)
            #expect(seen.responseFormat.jsonSchema != nil)
            return response
        }
        let valid = try await run(#"{"value":"ready"}"#)
        let decoded = try JSONDecoder().decode([String: AnyCodable].self, from: Data(valid.text.utf8))
        #expect(decoded["value"]?.stringValue == "ready")
        do {
            _ = try await run(#"{"value":""}"#)
            Issue.record("Expected a schema violation")
        } catch let error as FoundationModelsError {
            #expect(error == FoundationModelsError.schemaViolation(paths: ["value"]))
        }
    }

    @Test
    func replaysTheTranscriptThroughTheFramework() async throws {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, *) else { return }
        try await Self.checkReplay()
    }

    @available(macOS 27.0, iOS 27.0, visionOS 27.0, *)
    private static func checkReplay() async throws {
        let provider = ScriptedProvider { _, _ in ModelGenerationResponse(text: "Continue in the setup form.", providerID: "scripted") }
        let request = ModelGenerationRequest(
            sessionKey: "s",
            prompt: "",
            systemPrompt: "Only propose actions through the supplied tool.",
            messages: [
                .user("Connect Telegram."),
                .assistant(content: [.thinking("check setup", signature: nil), .toolCall(setupCall)]),
                .toolResult(ModelToolResult(toolCallID: "call-1", toolName: "openclaw", content: [.text("The protected setup form is ready.")])),
            ],
            tools: [ModelToolDefinition(name: "openclaw", description: "Set up OpenClaw", parameters: setupToolSchema)]
        )
        let context = AppleFMRunContext(request: request, options: FoundationModelsProviderOptions(), providerID: "apple-fm", target: .system, sink: nil)
        let result = try await AppleFMGeneration27.run(model: OpenClawLanguageModel(provider: provider), context: context, tokenCounter: nil)
        #expect(result.response.text == "Continue in the setup form.")
        #expect(result.response.stopReason == .stop)
        let seen = try #require(await provider.log.requests.first)
        #expect(seen.systemPrompt == "Only propose actions through the supplied tool.")
        try #require(seen.messages.count >= 3)
        #expect(seen.messages[0] == .user("Connect Telegram."))
        guard case .assistant(let parts) = seen.messages[1], parts.count == 2,
              case .thinking("check setup", nil) = parts[0],
              case .toolCall(let call) = parts[1]
        else {
            Issue.record("unexpected assistant replay \(seen.messages[1])")
            return
        }
        // Argument text keeps the framework's formatting (never re-encoded, so large integers survive).
        #expect(call.id == "call-1")
        #expect(call.name == "openclaw")
        #expect(call.arguments == setupCall.arguments)
        #expect(
            seen.messages[2]
                == .toolResult(ModelToolResult(toolCallID: "call-1", toolName: "openclaw", content: [.text("The protected setup form is ready.")]))
        )
    }

    @Test
    func streamsTextThroughTheSink() async throws {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, *) else { return }
        try await Self.checkStreaming()
    }

    @available(macOS 27.0, iOS 27.0, visionOS 27.0, *)
    private static func checkStreaming() async throws {
        let provider = ScriptedProvider { _, _ in ModelGenerationResponse(text: "streamed answer", providerID: "scripted") }
        let collected = ChunkCollector()
        let sink = FoundationModelsTextSink { chunk in collected.append(chunk) }
        let request = ModelGenerationRequest(sessionKey: "s", prompt: "Stream.")
        let context = AppleFMRunContext(request: request, options: FoundationModelsProviderOptions(), providerID: "apple-fm", target: .system, sink: sink)
        let result = try await AppleFMGeneration27.run(model: OpenClawLanguageModel(provider: provider), context: context, tokenCounter: nil)
        #expect(result.response.text == "streamed answer")
        #expect(sink.didEmit)
        #expect(collected.chunks.map(\.text).joined() == "streamed answer")
        #expect(collected.chunks.allSatisfy { $0.kind == .text })
    }

    @Test
    func rejectsToolsForModelsWithoutToolCalling() async throws {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, *) else { return }
        try await Self.checkToolSupport()
    }

    @available(macOS 27.0, iOS 27.0, visionOS 27.0, *)
    private static func checkToolSupport() async throws {
        let provider = ScriptedProvider { _, _ in ModelGenerationResponse(text: "x", providerID: "scripted") }
        let model = OpenClawLanguageModel(provider: provider, supportsToolCalling: false)
        let request = ModelGenerationRequest(sessionKey: "s", prompt: "x", tools: [ModelToolDefinition(name: "t")])
        let context = AppleFMRunContext(request: request, options: FoundationModelsProviderOptions(), providerID: "apple-fm", target: .system, sink: nil)
        await #expect(throws: OpenClawCoreError.self) {
            _ = try await AppleFMGeneration27.run(model: model, context: context, tokenCounter: nil)
        }
    }

    @Test
    func mapsOptionsOntoFoundationModels27Controls() {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, *) else { return }
        #expect(AppleFMGeneration27.toolCallingMode(.auto) == .allowed)
        #expect(AppleFMGeneration27.toolCallingMode(.required) == .required)
        #expect(AppleFMGeneration27.toolCallingMode(.none) == .disallowed)
        #expect(AppleFMGeneration27.reasoningLevel(ModelGenerationPolicy(thinkingLevel: .off)) == nil)
        #expect(AppleFMGeneration27.reasoningLevel(ModelGenerationPolicy(thinkingLevel: .minimal)) == .light)
        #expect(AppleFMGeneration27.reasoningLevel(ModelGenerationPolicy(thinkingLevel: .adaptive)) == .moderate)
        #expect(AppleFMGeneration27.reasoningLevel(ModelGenerationPolicy(thinkingLevel: .ultra)) == .deep)
        #expect(AppleFMGeneration27.reasoningLevel(ModelGenerationPolicy(reasoningEffort: .low)) == .light)
        #expect(AppleFMPreparation.sampling(ModelGenerationPolicy(topK: 1)) == .greedy)
        #expect(AppleFMPreparation.sampling(ModelGenerationPolicy(temperature: 0)) == .greedy)
        #expect(AppleFMPreparation.sampling(ModelGenerationPolicy(topK: 40, localRuntimeHints: ["seed": "7"])) == .random(top: 40, seed: 7))
        #expect(AppleFMPreparation.sampling(ModelGenerationPolicy(topP: 0.9)) == .random(probabilityThreshold: 0.9))
        #expect(AppleFMPreparation.sampling(ModelGenerationPolicy(temperature: 0.7)) == nil)
        let usage = AppleFMGeneration27.usage(
            LanguageModelSession.Usage(input: .init(totalTokenCount: 100, cachedTokenCount: 40), output: .init(totalTokenCount: 20, reasoningTokenCount: 5))
        )
        #expect(usage == ModelUsage(inputTokens: 60, outputTokens: 20, cacheReadTokens: 40, reasoningTokens: 5))
        #expect(usage.totalTokens == 120)
    }
}

private final class ChunkCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ModelStreamChunk] = []

    var chunks: [ModelStreamChunk] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.storage
    }

    func append(_ chunk: ModelStreamChunk) {
        self.lock.lock()
        self.storage.append(chunk)
        self.lock.unlock()
    }
}

// MARK: - Agent tool bridge

private struct WeatherTool: AgentTool {
    let name = "weather"

    var descriptor: AgentToolDescriptor {
        AgentToolDescriptor(
            name: "weather",
            description: "Current weather for a city",
            parameters: [
                "type": AnyCodable("object"),
                "properties": AnyCodable(["city": AnyCodable(["type": AnyCodable("string")])]),
                "required": AnyCodable([AnyCodable("city")]),
            ]
        )
    }

    func invoke(_ invocation: AgentToolInvocation, update: AgentToolUpdateHandler?) async throws -> AgentToolOutput {
        guard let city = invocation.arguments["city"]?.stringValue else {
            throw OpenClawCoreError.invalidConfiguration("city is required")
        }
        return .text("Sunny in \(city)")
    }
}

private struct LenientSchemaTool: AgentTool {
    let name = "search"

    var descriptor: AgentToolDescriptor {
        AgentToolDescriptor(
            name: "search",
            description: "Search",
            parameters: [
                "type": AnyCodable("object"),
                "properties": AnyCodable(["q": AnyCodable(["type": AnyCodable("string"), "format": AnyCodable("uri")])]),
            ]
        )
    }

    func invoke(_ invocation: AgentToolInvocation, update: AgentToolUpdateHandler?) async throws -> AgentToolOutput {
        .text("ok")
    }
}

private struct BrokenSchemaTool: AgentTool {
    let name = "broken"

    var descriptor: AgentToolDescriptor {
        AgentToolDescriptor(
            name: "broken",
            parameters: ["type": AnyCodable("string"), "minLength": AnyCodable(5), "maxLength": AnyCodable(2)]
        )
    }

    func invoke(_ invocation: AgentToolInvocation, update: AgentToolUpdateHandler?) async throws -> AgentToolOutput {
        .text("never")
    }
}

@Suite("Apple FM agent tool bridge")
struct FoundationModelsAgentToolBridgeTests {
    @Test
    func adaptersRunAgentToolsFromGeneratedArguments() async throws {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }
        let adapter = try FoundationModelsAgentToolAdapter(tool: WeatherTool())
        #expect(adapter.name == "weather")
        #expect(adapter.description == "Current weather for a city")
        #expect(adapter.schemaNotices.isEmpty)
        #expect(try await adapter.call(arguments: GeneratedContent(json: #"{"city":"Paris"}"#)) == "Sunny in Paris")
        #expect(try await adapter.call(arguments: GeneratedContent(json: "{}")) == "Tool error: Invalid configuration: city is required")

        let lenient = try FoundationModelsAgentToolAdapter(tool: LenientSchemaTool())
        #expect(lenient.schemaNotices == ["search.q: dropped unsupported keyword format"])
        #expect(throws: FoundationModelsError.self) {
            _ = try FoundationModelsAgentToolAdapter(tool: BrokenSchemaTool())
        }
    }

    @Test
    func registryAdaptersSkipUnconvertibleToolsAndExecutorRunsCalls() async throws {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }
        let registry = AgentToolRegistry(tools: [WeatherTool(), BrokenSchemaTool()])
        let (tools, skipped) = await FoundationModelsAgentTools.adapters(for: registry)
        #expect(tools.map(\.name) == ["weather"])
        #expect(skipped.map(\.name) == ["broken"])
        #expect(skipped.first?.reason.contains("Invalid string length bounds") == true)

        let executor = FoundationModelsAgentToolExecutor(registry: registry)
        let output = try await executor.executeTool(ModelToolCall(id: "c1", name: "weather", arguments: ["city": AnyCodable("Oslo")]))
        #expect(output == FoundationModelsToolOutput(text: "Sunny in Oslo"))
        let missing = try await executor.executeTool(ModelToolCall(id: "c2", name: "nope", argumentsJSON: "{}"))
        #expect(missing.isError)
        #expect(missing.text == "Tool not found: nope")
    }

    @Test
    func agentProfileCompactsHistory() {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, *) else { return }
        let entries: [Transcript.Entry] = [
            .instructions(Transcript.Instructions(segments: [], toolDefinitions: [])),
            .prompt(Transcript.Prompt(segments: [.text(.init(content: "a"))])),
            .response(Transcript.Response(assetIDs: [], segments: [.text(.init(content: "b"))])),
            .toolOutput(Transcript.ToolOutput(id: "c", toolName: "t", segments: [])),
            .prompt(Transcript.Prompt(segments: [.text(.init(content: "c"))])),
        ]
        let compacted = OpenClawAgentProfile.compact(entries, keep: 2)
        #expect(compacted.count == 2)
        if case .instructions = compacted.first {} else { Issue.record("instructions must survive compaction") }
        if case .prompt = compacted.last {} else { Issue.record("expected the latest prompt") }
        #expect(OpenClawAgentProfile.compact(entries, keep: 10).count == entries.count)
        let profile = OpenClawAgentProfile(systemPrompt: "You are OpenClaw.", route: .onDevice)
        #expect(!profile.usesPrivateCloudCompute)
        #expect(OpenClawAgentProfile(systemPrompt: "x", route: .privateCloud).usesPrivateCloudCompute)
    }

    @Test
    func agentSessionFactoryBridgesRegistryTools() async throws {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, *) else { return }
        let registry = AgentToolRegistry(tools: [WeatherTool(), BrokenSchemaTool()])
        let (session, skipped) = await FoundationModelsAgentSession.make(
            systemPrompt: "You are OpenClaw.",
            registry: registry,
            hooks: HookRegistry()
        )
        #expect(skipped.map(\.name) == ["broken"])
        #expect(!session.isResponding)
    }
}

// MARK: - Live tests (Apple Intelligence required)

private let liveAppleFM = ProcessInfo.processInfo.environment["OPENCLAW_LIVE_APPLE_FM"] == "1"
    && FoundationModelsProvider.runtimeAvailability().isAvailable
private let livePCC = ProcessInfo.processInfo.environment["OPENCLAW_LIVE_APPLE_PCC"] == "1"

#if canImport(ImageIO) && canImport(CoreGraphics)
private func redSquarePNG() -> Data? {
    guard let context = CGContext(
        data: nil,
        width: 64,
        height: 64,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return nil
    }
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    guard let image = context.makeImage() else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
}
#endif

@Suite("Apple FM live", .serialized, .enabled(if: liveAppleFM))
struct AppleFoundationModelsLiveTests {
    private let provider = FoundationModelsProvider()

    @Test
    func factsProbeTheSystemModel() async throws {
        let facts = FoundationModelsProvider.systemModelFacts()
        #expect(facts.available)
        #expect(facts.contextWindow >= 4_096)
        #expect(!facts.modelName.isEmpty)
        let count = try await self.provider.tokenCount(prompt: "Hello there", systemPrompt: "Be brief.")
        #expect(count > 0)
        #expect(await FoundationModelsProvider.supportsLocale(Locale(identifier: "en_US")))
    }

    @Test
    func respondsAndStreams() async throws {
        let request = ModelGenerationRequest(
            sessionKey: "live",
            prompt: "Reply with exactly the word OK.",
            systemPrompt: "You follow instructions exactly.",
            policy: ModelGenerationPolicy(maxTokens: 16, temperature: 0)
        )
        let response = try await self.provider.generate(request)
        #expect(response.text.localizedCaseInsensitiveContains("ok"))
        #expect(response.modelID == "system")
        #expect(response.stopReason == .stop)
        var text = ""
        var sawFinal = false
        for try await chunk in await self.provider.generateStream(request) {
            text += chunk.text
            sawFinal = sawFinal || chunk.isFinal
        }
        #expect(sawFinal)
        #expect(text.localizedCaseInsensitiveContains("ok"))
    }

    @Test
    func proposesToolCallsAndReplaysResults() async throws {
        let tools = [ModelToolDefinition(name: "openclaw", description: "Set up OpenClaw channels", parameters: setupToolSchema)]
        let first = try await self.provider.generate(
            ModelGenerationRequest(
                sessionKey: "live",
                prompt: "Connect Telegram.",
                systemPrompt: "Only propose actions through the supplied tool.",
                tools: tools,
                toolChoice: .required
            )
        )
        #expect(first.stopReason == .toolUse)
        let call = try #require(first.toolCalls.first)
        #expect(call.name == "openclaw")
        #expect(call.arguments?["action"]?.stringValue == "connect_channel")
        let second = try await self.provider.generate(
            ModelGenerationRequest(
                sessionKey: "live",
                prompt: "",
                systemPrompt: "Only propose actions through the supplied tool.",
                messages: [
                    .user("Connect Telegram."),
                    first.assistantMessage,
                    .toolResult(ModelToolResult(toolCallID: call.id, toolName: call.name, content: [.text("The protected setup form is ready.")])),
                ],
                tools: tools
            )
        )
        #expect(second.stopReason == .stop)
        #expect(!second.text.isEmpty)
    }

    @Test
    func producesValidatedStructuredOutput() async throws {
        let schema: [String: AnyCodable] = [
            "type": AnyCodable("object"),
            "properties": AnyCodable(["query": AnyCodable(["type": AnyCodable("string"), "minLength": AnyCodable(1)])]),
            "required": AnyCodable([AnyCodable("query")]),
        ]
        let response = try await self.provider.generate(
            ModelGenerationRequest(
                sessionKey: "live",
                prompt: "Write a search query about swift concurrency.",
                responseFormat: .jsonSchema(name: "search", schema: schema, strict: true)
            )
        )
        let decoded = try JSONDecoder().decode([String: AnyCodable].self, from: Data(response.text.utf8))
        #expect(decoded["query"]?.stringValue?.isEmpty == false)
    }

    @Test
    func describesAttachedImagesWhenTheModelHasVision() async throws {
        guard FoundationModelsProvider.systemModelFacts().supportsVision else { return }
        #if canImport(ImageIO) && canImport(CoreGraphics)
        let png = try #require(redSquarePNG())
        let response = try await self.provider.generate(
            ModelGenerationRequest(
                sessionKey: "live",
                prompt: "What color is this image? Answer with one word.",
                attachments: [MediaAttachment(mimeType: "image/png", data: png)]
            )
        )
        #expect(response.text.lowercased().contains("red"))
        #endif
    }

    @Test
    func cancellationPublishesNoToolCall() async throws {
        let token = "live-cancel"
        let request = ModelGenerationRequest(
            sessionKey: "live",
            prompt: "Connect Telegram.",
            policy: ModelGenerationPolicy(cancellationToken: token),
            tools: [ModelToolDefinition(name: "openclaw", description: "Set up OpenClaw channels", parameters: setupToolSchema)],
            toolChoice: .required
        )
        let provider = self.provider
        let task = Task { try await provider.generate(request) }
        // Let the request register its token and start native inference, then cancel it.
        try await Task.sleep(nanoseconds: 200_000_000)
        await provider.cancelGeneration(token: token)
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }
}

@Suite("Apple FM Private Cloud Compute live", .serialized, .enabled(if: livePCC))
struct AppleFoundationModelsPrivateCloudLiveTests {
    @Test
    func respondsThroughPrivateCloudCompute() async throws {
        let facts = await FoundationModelsProvider.facts(target: .privateCloudCompute)
        guard facts.available else { return }
        #expect(facts.contextWindow > 0)
        #expect(FoundationModelsProvider.privateCloudQuota() != nil)
        let request = ModelGenerationRequest(sessionKey: "live", prompt: "What is 17*3? Answer with the number only.", modelID: "pcc")
        let strict = FoundationModelsProvider(options: FoundationModelsProviderOptions(fallbackToOnDevice: false))
        do {
            let response = try await strict.generate(request)
            #expect(response.modelID == "private-cloud-compute")
            #expect(response.text.contains("51"))
        } catch let error as FoundationModelsError where error == FoundationModelsErrorMapper.notEntitled {
            // Processes without Apple's managed PCC entitlement (for example `swift test`) are rejected;
            // the on-device fallback below still has to answer.
        }
        guard FoundationModelsProvider.runtimeAvailability().isAvailable else { return }
        let result = try await FoundationModelsProvider().generateDetailed(request)
        #expect(result.response.text.contains("51"))
        #expect(result.target == (result.fellBackToOnDevice ? .system : .privateCloudCompute))
        #expect(result.response.modelID == result.target.modelID)
    }
}
#endif
