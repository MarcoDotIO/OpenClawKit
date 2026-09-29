import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OpenClawCore
@testable import OpenClawModels
import OpenClawProtocol

/// Transport whose every request fails with a URLSession-style error carrying the failing URL.
private actor FailingURLTransport: OpenAICompatibleHTTPTransport, GeminiHTTPTransport {
    func data(for request: URLRequest) async throws -> HTTPResponseData {
        throw URLError(
            .networkConnectionLost,
            userInfo: [
                NSURLErrorFailingURLStringErrorKey: request.url?.absoluteString ?? "",
                NSLocalizedDescriptionKey: "The network connection was lost.",
            ]
        )
    }
}

private let terminalWeatherTool = ModelToolDefinition(
    name: "get_weather",
    description: "Look up the weather",
    parameters: ["type": AnyCodable("object")]
)

/// A stream that ends without its provider's terminal event (proxy close, upstream abort) or with an
/// in-stream error must fail instead of looking like a complete turn (upstream
/// `openai-completions-stream.ts`, `openai-responses-stream-internal.ts`, `anthropic-stream-reducer.ts`,
/// `google-stream.ts`, Ollama `OLLAMA_INCOMPLETE_STREAM_ERROR`).
@Suite("Provider stream terminal events")
struct ProviderStreamTerminalTests {
    private static func collect(_ stream: AsyncThrowingStream<ModelStreamChunk, Error>) async throws -> [ModelStreamChunk] {
        var chunks: [ModelStreamChunk] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }
        return chunks
    }

    private static func streamError(_ stream: AsyncThrowingStream<ModelStreamChunk, Error>) async -> String? {
        do {
            _ = try await self.collect(stream)
            return nil
        } catch {
            return String(describing: error)
        }
    }

    private static let request = ModelGenerationRequest(sessionKey: "s", prompt: "hi", tools: [terminalWeatherTool])

    // MARK: - Chat Completions

    private static func chat(_ body: String) -> ProviderServiceOpenAIModelProvider {
        ProviderServiceOpenAIModelProvider(
            id: "openrouter",
            configuration: ProviderServiceConfig(enabled: true, modelID: "m", apiKey: "k", baseURL: "https://openrouter.ai/api/v1"),
            transport: ContractV2StubTransport(body: body)
        )
    }

    @Test
    func chatCompletionsStreamCutBeforeFinishThrows() async {
        let provider = Self.chat("""
        data: {"choices":[{"index":0,"delta":{"content":"Half an ans"}}]}

        """)
        let error = await Self.streamError(await provider.generateStream(Self.request))
        #expect(error?.contains("stream ended before a terminal event") == true)
    }

    @Test
    func chatCompletionsStreamCutInsideToolArgumentsThrows() async {
        let provider = Self.chat("""
        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"get_weather","arguments":"{\\"path\\": \\"/tm"}}]}}]}

        """)
        let error = await Self.streamError(await provider.generateStream(Self.request))
        #expect(error?.contains("stream ended before a terminal event") == true)
    }

    @Test
    func chatCompletionsInStreamErrorPayloadThrows() async {
        let provider = Self.chat("""
        data: {"choices":[{"index":0,"delta":{"content":"par"}}]}

        data: {"error":{"message":"upstream overloaded","code":502}}

        data: [DONE]

        """)
        let error = await Self.streamError(await provider.generateStream(Self.request))
        #expect(error?.contains("upstream overloaded") == true)
    }

    @Test
    func chatCompletionsErrorFinishReasonThrows() async {
        let provider = Self.chat("""
        data: {"choices":[{"index":0,"delta":{"content":"par"},"finish_reason":"error"}]}

        data: [DONE]

        """)
        let error = await Self.streamError(await provider.generateStream(Self.request))
        #expect(error?.contains("finish_reason: error") == true)
    }

    @Test
    func chatCompletionsDoneWithoutFinishReasonStillCompletes() async throws {
        let provider = Self.chat("""
        data: {"choices":[{"index":0,"delta":{"content":"ok"}}]}

        data: [DONE]

        """)
        let chunks = try await Self.collect(await provider.generateStream(Self.request))
        #expect(chunks.last?.kind == .final)
        #expect(chunks.filter { $0.kind == .text }.map(\.text).joined() == "ok")
    }

    @Test
    func chatCompletionsIndexlessParallelCallsStayDistinct() async throws {
        let provider = Self.chat("""
        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"id":"call_a","function":{"name":"read","arguments":"{\\"p\\":1}"}},\
        {"id":"call_b","function":{"name":"list","arguments":"{}"}}]}}]}

        data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

        data: [DONE]

        """)
        let chunks = try await Self.collect(await provider.generateStream(Self.request))
        let final = try #require(chunks.last)
        #expect(final.toolCalls == [
            ModelToolCall(id: "call_a", name: "read", argumentsJSON: #"{"p":1}"#),
            ModelToolCall(id: "call_b", name: "list", argumentsJSON: "{}"),
        ])
    }

    @Test
    func chatCompletionsIDOnlyContinuationsAppendToTheirCall() async throws {
        let provider = Self.chat("""
        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_a","function":{"name":"read","arguments":"{\\"p\\""}}]}}]}

        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"id":"call_a","function":{"arguments":":1"}}]}}]}

        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"function":{"arguments":"}"}}]}}]}

        data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

        """)
        let chunks = try await Self.collect(await provider.generateStream(Self.request))
        #expect(chunks.last?.toolCalls == [ModelToolCall(id: "call_a", name: "read", argumentsJSON: #"{"p":1}"#)])
    }

    // MARK: - Responses

    private static func responses(_ body: String) -> OpenAIResponsesModelProvider {
        OpenAIResponsesModelProvider(
            id: "openai",
            configuration: ProviderServiceConfig(enabled: true, modelID: "gpt-5.4", apiKey: "k", baseURL: "https://api.openai.com/v1"),
            transport: ContractV2StubTransport(body: body)
        )
    }

    @Test
    func responsesStreamCutBeforeTerminalEventThrows() async {
        let provider = Self.responses("""
        data: {"type":"response.created","response":{"model":"gpt-5.4"}}

        data: {"type":"response.output_text.delta","delta":"Half"}

        """)
        let error = await Self.streamError(await provider.generateStream(Self.request))
        #expect(error?.contains("stream ended before a terminal response event") == true)
    }

    @Test
    func responsesStreamCutInsideFunctionCallThrows() async {
        let provider = Self.responses("""
        data: {"type":"response.output_item.added","output_index":0,\
        "item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"get_weather","arguments":""}}

        data: {"type":"response.function_call_arguments.delta","output_index":0,"item_id":"fc_1","delta":"{\\"city\\":"}

        """)
        let error = await Self.streamError(await provider.generateStream(Self.request))
        #expect(error?.contains("unresolved tool calls") == true)
    }

    @Test
    func responsesIncompleteWithOpenFunctionCallThrows() async {
        let provider = Self.responses("""
        data: {"type":"response.output_item.added","output_index":0,\
        "item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"get_weather","arguments":""}}

        data: {"type":"response.function_call_arguments.delta","output_index":0,"item_id":"fc_1","delta":"{\\"city\\":"}

        data: {"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}}

        """)
        let error = await Self.streamError(await provider.generateStream(Self.request))
        #expect(error?.contains("unresolved tool calls") == true)
    }

    @Test
    func responsesEmptyStreamThrows() async {
        let provider = Self.responses("")
        let error = await Self.streamError(await provider.generateStream(Self.request))
        #expect(error?.contains("stream ended before a terminal response event") == true)
    }

    @Test
    func responsesPlainJSONFallbackStillCompletes() async throws {
        let provider = Self.responses(#"{"output_text":"ok","status":"completed"}"#)
        let chunks = try await Self.collect(await provider.generateStream(Self.request))
        #expect(chunks.last?.kind == .final)
        #expect(chunks.filter { $0.kind == .text }.map(\.text).joined() == "ok")
    }

    @Test
    func chatGPTRouteGenerateOverCutStreamThrows() async {
        let transport = ContractV2StubTransport(body: """
        data: {"type":"response.output_text.delta","delta":"partial"}

        """)
        let config = ModelProviderConfig(
            enabled: true,
            baseURL: "https://chatgpt.com/backend-api",
            apiKey: "tok",
            auth: .oauth,
            api: .openAIChatGPTResponses,
            models: [ModelDefinitionConfig(id: "gpt-5.4")]
        )
        let provider = OpenAIResponsesModelProvider(
            id: "openai",
            configuration: config.legacyServiceConfig(providerID: "openai"),
            transport: transport,
            runtime: ModelProviderRuntimeContext(providerConfig: config, api: .openAIChatGPTResponses)
        )
        await #expect(throws: OpenClawCoreError.self) {
            _ = try await provider.generate(ModelGenerationRequest(sessionKey: "s", prompt: "hi"))
        }
    }

    // MARK: - Anthropic

    private static func anthropic(id: String, baseURL: String, body: String) -> ProviderServiceAnthropicModelProvider {
        ProviderServiceAnthropicModelProvider(
            id: id,
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .anthropicMessages,
                modelID: "claude-sonnet-4-5",
                apiKey: "sk-ant",
                baseURL: baseURL
            ),
            transport: ContractV2StubTransport(body: body)
        )
    }

    private static let anthropicTextWithStopReason = """
    event: message_start
    data: {"type":"message_start","message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":3}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}

    """

    @Test
    func anthropicDirectStreamRequiresMessageStop() async {
        let provider = Self.anthropic(id: "anthropic", baseURL: "https://api.anthropic.com", body: Self.anthropicTextWithStopReason)
        let error = await Self.streamError(await provider.generateStream(Self.request))
        #expect(error?.contains("stream ended before message_stop") == true)
    }

    @Test
    func anthropicCompatibleStreamAcceptsStopReasonWithoutMessageStop() async throws {
        let provider = Self.anthropic(id: "minimax", baseURL: "https://api.minimax.io/anthropic", body: Self.anthropicTextWithStopReason)
        let chunks = try await Self.collect(await provider.generateStream(Self.request))
        #expect(chunks.last?.stopReason == .stop)
    }

    @Test
    func anthropicStreamCutInsideToolUseThrows() async {
        let provider = Self.anthropic(id: "minimax", baseURL: "https://api.minimax.io/anthropic", body: """
        event: message_start
        data: {"type":"message_start","message":{"model":"claude-sonnet-4-5"}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"get_weather","input":{}}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"path\\": \\"/tm"}}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}

        """)
        let error = await Self.streamError(await provider.generateStream(Self.request))
        #expect(error?.contains("incomplete tool call") == true)
    }

    @Test
    func anthropicStartedStreamWithoutTerminalFactThrows() async {
        let provider = Self.anthropic(id: "minimax", baseURL: "https://api.minimax.io/anthropic", body: """
        event: message_start
        data: {"type":"message_start","message":{"model":"claude-sonnet-4-5"}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Half"}}

        """)
        let error = await Self.streamError(await provider.generateStream(Self.request))
        #expect(error?.contains("stream ended before a terminal event") == true)
    }

    // MARK: - Gemini

    private static func gemini(_ body: String) -> GoogleGenerativeAIModelProvider {
        GoogleGenerativeAIModelProvider(
            id: "google",
            configuration: ProviderServiceConfig(enabled: true, apiStyle: .custom, modelID: "gemini-3-flash", apiKey: "g"),
            transport: ContractV2StubTransport(body: body)
        )
    }

    @Test
    func geminiStreamWithoutFinishReasonThrows() async {
        let provider = Self.gemini("""
        data: {"candidates":[{"content":{"parts":[{"text":"Half"}]}}]}

        """)
        let error = await Self.streamError(await provider.generateStream(Self.request))
        #expect(error?.contains("stream ended before a terminal finish reason") == true)
    }

    @Test
    func geminiArrayFallbackWithFinishReasonCompletes() async throws {
        let provider = Self.gemini(#"[{"candidates":[{"content":{"parts":[{"text":"ok"}]},"finishReason":"STOP"}]}]"#)
        let chunks = try await Self.collect(await provider.generateStream(Self.request))
        #expect(chunks.last?.stopReason == .stop)
    }

    // MARK: - Ollama

    @Test
    func ollamaStreamWithoutDoneThrows() async {
        let provider = OllamaModelProvider(
            configuration: ProviderServiceConfig(enabled: true, apiStyle: .ollama, authMode: .none, modelID: "llama3", baseURL: "http://127.0.0.1:11434"),
            transport: ContractV2StubTransport(body: """
            {"model":"llama3","message":{"role":"assistant","content":"Half"},"done":false}
            """)
        )
        let error = await Self.streamError(await provider.generateStream(Self.request))
        #expect(error?.contains("stream ended before the final done chunk") == true)
    }

    // MARK: - Transport errors

    /// URLSession errors carry the failing URL; it must not reach error descriptions (diagnostics,
    /// hook payloads) — and Gemini keys are no longer in the URL at all.
    @Test
    func transportErrorsDropTheFailingURL() async throws {
        let provider = GoogleGenerativeAIModelProvider(
            id: "google",
            configuration: ProviderServiceConfig(enabled: true, apiStyle: .custom, modelID: "gemini-3-flash", apiKey: "AIzaSECRETKEY123"),
            transport: FailingURLTransport()
        )
        do {
            _ = try await provider.generate(ModelGenerationRequest(sessionKey: "s", prompt: "hi"))
            Issue.record("Expected a transport error")
        } catch {
            #expect((error as? URLError)?.code == .networkConnectionLost)
            #expect(!String(describing: error).contains("generativelanguage.googleapis.com"))
            #expect(!String(describing: error).contains("AIzaSECRETKEY123"))
        }
        let streamError = await Self.streamError(await provider.generateStream(ModelGenerationRequest(sessionKey: "s", prompt: "hi")))
        #expect(streamError?.contains("generativelanguage.googleapis.com") == false)

        let chat = ProviderServiceOpenAIModelProvider(
            id: "proxy",
            configuration: ProviderServiceConfig(enabled: true, modelID: "m", apiKey: "k", baseURL: "https://proxy.example/v1?api_key=SECRET999"),
            transport: FailingURLTransport()
        )
        let chatError = await Self.streamError(await chat.generateStream(ModelGenerationRequest(sessionKey: "s", prompt: "hi")))
        #expect(chatError?.contains("SECRET999") == false)
    }
}
