import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OpenClawCore
@testable import OpenClawModels
import OpenClawProtocol

/// Stub transport shared by the provider contract-v2 tests: records requests and replies with a
/// fixed body (JSON or an SSE/NDJSON stream replayed through the buffered fallback).
actor ContractV2StubTransport: OpenAICompatibleHTTPTransport, AnthropicHTTPTransport, GeminiHTTPTransport,
    XAIHTTPTransport, BedrockHTTPTransport
{
    private let body: Data
    private let statusCode: Int
    private(set) var requests: [URLRequest] = []

    init(body: String, statusCode: Int = 200) {
        self.body = Data(body.utf8)
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> HTTPResponseData {
        self.requests.append(request)
        return HTTPResponseData(statusCode: self.statusCode, headers: [:], body: self.body)
    }

    func lastRequest() -> URLRequest? {
        self.requests.last
    }

    func lastBodyObject() -> [String: AnyCodable]? {
        guard let body = self.requests.last?.httpBody else { return nil }
        return try? JSONDecoder().decode([String: AnyCodable].self, from: body)
    }
}

/// Stub that also conforms to the incremental streaming transport.
actor ContractV2StreamingStubTransport: OpenAICompatibleHTTPTransport, ModelHTTPStreamingTransport {
    private let lines: [String]
    private(set) var streamedRequests = 0

    init(lines: [String]) {
        self.lines = lines
    }

    func data(for request: URLRequest) async throws -> HTTPResponseData {
        HTTPResponseData(statusCode: 500, headers: [:], body: Data())
    }

    func lineStream(for request: URLRequest) async throws -> ModelHTTPLineStream {
        self.streamedRequests += 1
        let lines = self.lines
        return ModelHTTPLineStream(
            statusCode: 200,
            headers: [:],
            lines: AsyncThrowingStream { continuation in
                for line in lines {
                    continuation.yield(line)
                }
                continuation.finish()
            }
        )
    }
}

private let weatherTool = ModelToolDefinition(
    name: "get_weather",
    description: "Look up the weather",
    parameters: [
        "type": AnyCodable("object"),
        "properties": AnyCodable(["city": AnyCodable(["type": AnyCodable("string")])]),
        "required": AnyCodable([AnyCodable("city")]),
    ]
)

private let toolTranscript: [ModelMessage] = [
    .user("Weather in Paris?"),
    .assistant(content: [.toolCall(ModelToolCall(id: "call_1", name: "get_weather", argumentsJSON: #"{"city":"Paris"}"#))]),
    .toolResult(ModelToolResult(toolCallID: "call_1", toolName: "get_weather", content: [.text("18C and sunny")])),
]

private func collect(_ stream: AsyncThrowingStream<ModelStreamChunk, Error>) async throws -> [ModelStreamChunk] {
    var chunks: [ModelStreamChunk] = []
    for try await chunk in stream {
        chunks.append(chunk)
    }
    return chunks
}

@Suite("Provider contract v2")
struct ProviderContractV2Tests {
    // MARK: - OpenAI Chat Completions

    @Test
    func chatCompletionsMapsTranscriptToolsAndParsesToolCalls() async throws {
        let transport = ContractV2StubTransport(body: """
        {"model":"gpt-5.4","choices":[{"index":0,"finish_reason":"tool_calls","message":{"role":"assistant","content":null,
        "tool_calls":[{"id":"call_2","type":"function","function":{"name":"get_weather","arguments":"{\\"city\\":\\"Lyon\\"}"}}]}}],
        "usage":{"prompt_tokens":120,"completion_tokens":30,"total_tokens":150,"prompt_tokens_details":{"cached_tokens":20},
        "completion_tokens_details":{"reasoning_tokens":10}}}
        """)
        let provider = ProviderServiceOpenAIModelProvider(
            id: "openrouter",
            configuration: ProviderServiceConfig(enabled: true, modelID: "gpt-5.4", apiKey: "key", baseURL: "https://openrouter.ai/api/v1"),
            transport: transport
        )
        #expect(provider.capabilities.supportsTools)
        #expect(provider.capabilities.supportsStreaming)

        let response = try await provider.generate(
            ModelGenerationRequest(
                sessionKey: "s",
                prompt: "",
                systemPrompt: "Be brief.",
                messages: toolTranscript,
                tools: [weatherTool],
                toolChoice: .required
            )
        )

        #expect(response.stopReason == .toolUse)
        #expect(response.toolCalls == [ModelToolCall(id: "call_2", name: "get_weather", argumentsJSON: #"{"city":"Lyon"}"#)])
        #expect(response.usage == ModelUsage(inputTokens: 100, outputTokens: 30, cacheReadTokens: 20, reasoningTokens: 10, totalTokens: 150))

        let body = try #require(await transport.lastBodyObject())
        let messages = try #require(body["messages"]?.arrayValue)
        #expect(messages.count == 4)
        #expect(messages[0].wireString("role") == "system")
        #expect(messages[2][wireKey: "tool_calls"]?.arrayValue?.first?[wireKey: "function"]?.wireString("name") == "get_weather")
        #expect(messages[3].wireString("role") == "tool")
        #expect(messages[3].wireString("tool_call_id") == "call_1")
        #expect(messages[3].wireString("content") == "18C and sunny")
        #expect(body["tool_choice"]?.stringValue == "required")
        let tool = try #require(body["tools"]?.arrayValue?.first)
        #expect(tool.wireString("type") == "function")
        #expect(tool[wireKey: "function"]?.wireString("name") == "get_weather")
        #expect(tool[wireKey: "function"]?[wireKey: "parameters"]?.wireString("type") == "object")
    }

    @Test
    func chatCompletionsSendsJSONSchemaResponseFormat() async throws {
        let transport = ContractV2StubTransport(body: #"{"choices":[{"message":{"role":"assistant","content":"{\"ok\":true}"},"finish_reason":"stop"}]}"#)
        let provider = ProviderServiceOpenAIModelProvider(
            id: "groq",
            configuration: ProviderServiceConfig(enabled: true, modelID: "m", apiKey: "k", baseURL: "https://api.groq.com/openai/v1"),
            transport: transport
        )
        let response = try await provider.generate(
            ModelGenerationRequest(
                sessionKey: "s",
                prompt: "json please",
                responseFormat: .jsonSchema(name: "answer", schema: ["type": AnyCodable("object")], strict: true)
            )
        )
        #expect(response.text == #"{"ok":true}"#)
        #expect(response.stopReason == .stop)
        let format = try #require(await transport.lastBodyObject()?["response_format"])
        #expect(format.wireString("type") == "json_schema")
        #expect(format[wireKey: "json_schema"]?.wireString("name") == "answer")
        #expect(format[wireKey: "json_schema"]?[wireKey: "strict"]?.boolValue == true)
    }

    @Test
    func chatCompletionsStreamsTextToolDeltasAndUsage() async throws {
        let sse = [
            #"data: {"model":"gpt-5.4","choices":[{"index":0,"delta":{"role":"assistant","content":"Hel"}}]}"#,
            "",
            #"data: {"choices":[{"index":0,"delta":{"content":"lo"}}]}"#,
            "",
            #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_9","type":"function","#
                + #""function":{"name":"get_weather","arguments":"{\"ci"}}]}}]}"#,
            "",
            #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ty\":\"Oslo\"}"}}]},"finish_reason":"tool_calls"}]}"#,
            "",
            #"data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}"#,
            "",
            "data: [DONE]",
            "",
        ]
        let transport = ContractV2StreamingStubTransport(lines: sse)
        let provider = ProviderServiceOpenAIModelProvider(
            id: "openai-compatible",
            configuration: ProviderServiceConfig(enabled: true, modelID: "gpt-5.4", apiKey: "k", baseURL: "https://example.test/v1"),
            transport: transport
        )
        let chunks = try await collect(
            await provider.generateStream(ModelGenerationRequest(sessionKey: "s", prompt: "hi", tools: [weatherTool]))
        )
        #expect(await transport.streamedRequests == 1)
        #expect(chunks.filter { $0.kind == .text }.map(\.text).joined() == "Hello")
        let deltas = chunks.compactMap(\.toolCallDelta)
        #expect(deltas.first?.id == "call_9")
        #expect(deltas.first?.name == "get_weather")
        #expect(deltas.map(\.argumentsDelta).joined() == #"{"city":"Oslo"}"#)
        #expect(chunks.contains { $0.kind == .usage && $0.usage?.totalTokens == 15 })
        let final = try #require(chunks.last)
        #expect(final.kind == .final)
        #expect(final.stopReason == .toolUse)
        #expect(final.toolCalls == [ModelToolCall(id: "call_9", name: "get_weather", argumentsJSON: #"{"city":"Oslo"}"#)])
        #expect(final.usage?.inputTokens == 10)
    }

    @Test
    func chatCompletionsBufferedStreamFallbackParsesSSE() async throws {
        let transport = ContractV2StubTransport(body: """
        data: {"choices":[{"index":0,"delta":{"reasoning_content":"thinking…"}}]}

        data: {"choices":[{"index":0,"delta":{"content":"done"},"finish_reason":"stop"}]}

        data: [DONE]

        """)
        let provider = ProviderServiceOpenAIModelProvider(
            id: "deepseek",
            configuration: ProviderServiceConfig(enabled: true, modelID: "deepseek-chat", apiKey: "k", baseURL: "https://api.deepseek.com"),
            transport: transport
        )
        let chunks = try await collect(await provider.generateStream(ModelGenerationRequest(sessionKey: "s", prompt: "hi")))
        #expect(chunks.first?.kind == .reasoning)
        #expect(chunks.first?.reasoningText == "thinking…")
        #expect(chunks.filter { $0.kind == .text }.map(\.text).joined() == "done")
        #expect(chunks.last?.stopReason == .stop)
        let body = try #require(await transport.lastBodyObject())
        #expect(body["stream"]?.boolValue == true)
        // DeepSeek is a non-standard endpoint: no stream_options by default.
        #expect(body["stream_options"] == nil)
    }

    @Test
    func toolsAreRejectedWhenModelCompatDisablesThem() async throws {
        let transport = ContractV2StubTransport(body: "{}")
        let config = ModelProviderConfig(
            enabled: true,
            baseURL: "https://example.test/v1",
            apiKey: "k",
            models: [ModelDefinitionConfig(id: "no-tools", compat: ModelCompatConfig(supportsTools: false))]
        )
        let provider = ProviderServiceOpenAIModelProvider(
            id: "custom",
            configuration: config.legacyServiceConfig(providerID: "custom"),
            transport: transport,
            runtime: ModelProviderRuntimeContext(providerConfig: config, api: .openAICompletions)
        )
        await #expect(throws: OpenClawCoreError.self) {
            _ = try await provider.generate(ModelGenerationRequest(sessionKey: "s", prompt: "x", tools: [weatherTool]))
        }
        #expect(await transport.requests.isEmpty)
    }

    // MARK: - OpenAI Responses

    @Test
    func responsesMapsFunctionCallsAndParsesOutput() async throws {
        let transport = ContractV2StubTransport(body: """
        {"id":"resp_1","model":"gpt-5.4","status":"completed","output":[
          {"type":"reasoning","summary":[{"type":"summary_text","text":"Need weather."}]},
          {"type":"function_call","id":"fc_1","call_id":"call_7","name":"get_weather","arguments":"{\\"city\\":\\"Rome\\"}"}],
         "usage":{"input_tokens":50,"output_tokens":12,"total_tokens":62,"input_tokens_details":{"cached_tokens":8},
         "output_tokens_details":{"reasoning_tokens":4}}}
        """)
        let provider = OpenAIResponsesModelProvider(
            id: "openai",
            configuration: ProviderServiceConfig(enabled: true, modelID: "gpt-5.4", apiKey: "k", baseURL: "https://api.openai.com/v1"),
            transport: transport,
            responsesClientFactory: { _, _ in
                throw OpenClawCoreError.unavailable("OpenAIKit must not be used for v2 requests")
            }
        )
        let response = try await provider.generate(
            ModelGenerationRequest(
                sessionKey: "s",
                prompt: "",
                systemPrompt: "Be brief.",
                messages: toolTranscript,
                tools: [weatherTool],
                toolChoice: .named("get_weather"),
                responseFormat: .jsonObject
            )
        )
        #expect(response.toolCalls == [ModelToolCall(id: "call_7", name: "get_weather", argumentsJSON: #"{"city":"Rome"}"#)])
        #expect(response.stopReason == .toolUse)
        #expect(response.reasoningText == "Need weather.")
        #expect(response.usage == ModelUsage(inputTokens: 42, outputTokens: 12, cacheReadTokens: 8, reasoningTokens: 4, totalTokens: 62))

        let body = try #require(await transport.lastBodyObject())
        #expect(body["instructions"]?.stringValue == "Be brief.")
        let input = try #require(body["input"]?.arrayValue)
        #expect(input.contains { $0.wireString("type") == "function_call" && $0.wireString("call_id") == "call_1" })
        #expect(input.contains { $0.wireString("type") == "function_call_output" && $0.wireString("output") == "18C and sunny" })
        #expect(body["tool_choice"]?.wireString("name") == "get_weather")
        #expect(body["tools"]?.arrayValue?.first?.wireString("name") == "get_weather")
        #expect(body["text"]?[wireKey: "format"]?.wireString("type") == "json_object")
        #expect(body["store"]?.boolValue == false)
    }

    @Test
    func responsesStreamEventsProduceChunks() async throws {
        let transport = ContractV2StubTransport(body: """
        event: response.created
        data: {"type":"response.created","response":{"model":"gpt-5.4"}}

        data: {"type":"response.reasoning_summary_text.delta","delta":"hmm"}

        data: {"type":"response.output_text.delta","delta":"Hi"}

        data: {"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","id":"fc_2",\
        "call_id":"call_3","name":"get_weather","arguments":""}}

        data: {"type":"response.function_call_arguments.delta","output_index":1,"item_id":"fc_2","delta":"{\\"city\\":"}

        data: {"type":"response.function_call_arguments.delta","output_index":1,"item_id":"fc_2","delta":"\\"Nice\\"}"}

        data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":5,"output_tokens":6,"total_tokens":11}}}

        """)
        let provider = OpenAIResponsesModelProvider(
            id: "openai",
            configuration: ProviderServiceConfig(enabled: true, modelID: "gpt-5.4", apiKey: "k", baseURL: "https://api.openai.com/v1"),
            transport: transport
        )
        let chunks = try await collect(await provider.generateStream(ModelGenerationRequest(sessionKey: "s", prompt: "hi", tools: [weatherTool])))
        #expect(chunks.compactMap(\.reasoningText).joined() == "hmm")
        #expect(chunks.filter { $0.kind == .text }.map(\.text).joined() == "Hi")
        let final = try #require(chunks.last)
        #expect(final.toolCalls == [ModelToolCall(id: "call_3", name: "get_weather", argumentsJSON: #"{"city":"Nice"}"#)])
        #expect(final.stopReason == .toolUse)
        #expect(final.usage?.totalTokens == 11)
        #expect(await transport.lastBodyObject()?["stream"]?.boolValue == true)
    }

    @Test
    func legacyCodexConfigMigratesOntoChatGPTRoute() throws {
        let config = OpenAIRouteResolution.migrateLegacyCodexConfig(
            ModelProviderConfig(enabled: true, baseURL: "", apiKey: "tok", auth: .apiKey, api: nil, models: [ModelDefinitionConfig(id: "gpt-5.4-codex")])
        )
        #expect(config.api == .openAIChatGPTResponses)
        #expect(config.auth == .oauth)
        #expect(config.baseURL == OpenAIRouteResolution.chatGPTBaseURL)
        #expect(config.models.first?.id == "gpt-5.4")
        #expect(config.models.first?.api == .openAIChatGPTResponses)

        let provider = try ModelProviderFactory.makeProvider(providerID: "openai-codex", config: config)
        #expect(provider is OpenAIResponsesModelProvider)
        #expect(provider.capabilities.supportsTools)

        let ref = try #require(OpenAIRouteResolution.resolveLegacyCodexRef("codex/gpt-5.4-codex"))
        #expect(ref.ref == "openai/gpt-5.4")
        #expect(ref.api == .openAIChatGPTResponses)
        #expect(ref.auth == .oauth)
        #expect(OpenAIRouteResolution.resolveLegacyCodexRef("openai/gpt-5.4") == nil)
    }

    @Test
    func chatGPTRouteRequestShape() async throws {
        let transport = ContractV2StubTransport(body: """
        data: {"type":"response.output_text.delta","delta":"ok"}

        """)
        let config = ModelProviderConfig(
            enabled: true,
            baseURL: "https://chatgpt.com/backend-api",
            apiKey: "tok",
            auth: .oauth,
            api: .openAIChatGPTResponses,
            models: [ModelDefinitionConfig(id: "gpt-5.4", reasoning: true)]
        )
        let provider = OpenAIResponsesModelProvider(
            id: "openai",
            configuration: config.legacyServiceConfig(providerID: "openai"),
            transport: transport,
            runtime: ModelProviderRuntimeContext(providerConfig: config, api: .openAIChatGPTResponses)
        )
        let response = try await provider.generate(
            ModelGenerationRequest(
                sessionKey: "sess",
                prompt: "hi",
                metadata: ["openai.chatgptAccountID": "acct_9"],
                policy: ModelGenerationPolicy(thinkingLevel: .high)
            )
        )
        #expect(response.text == "ok")
        let request = try #require(await transport.lastRequest())
        #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/codex/responses")
        #expect(request.value(forHTTPHeaderField: "chatgpt-account-id") == "acct_9")
        #expect(request.value(forHTTPHeaderField: "originator") == "openclaw")
        #expect(request.value(forHTTPHeaderField: "OpenAI-Beta") == "responses=experimental")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        let body = try #require(await transport.lastBodyObject())
        #expect(body["store"]?.boolValue == false)
        #expect(body["stream"]?.boolValue == true)
        #expect(body["instructions"]?.stringValue == OpenAIResponsesWire.defaultChatGPTInstructions)
        #expect(body["include"]?.arrayValue?.first?.stringValue == "reasoning.encrypted_content")
        #expect(body["reasoning"]?.wireString("effort") == "high")
        #expect(body["reasoning"]?.wireString("summary") == "auto")
    }

    // MARK: - Anthropic

    @Test
    func anthropicMapsToolUseTranscriptAndParsesResponse() async throws {
        let transport = ContractV2StubTransport(body: """
        {"id":"msg_1","model":"claude-sonnet-4-5","stop_reason":"tool_use","content":[
          {"type":"thinking","thinking":"plan","signature":"sig"},
          {"type":"text","text":"Checking."},
          {"type":"tool_use","id":"toolu_1","name":"get_weather","input":{"city":"Bern"}}],
         "usage":{"input_tokens":40,"output_tokens":9,"cache_read_input_tokens":3,"cache_creation_input_tokens":2}}
        """)
        let provider = ProviderServiceAnthropicModelProvider(
            id: "anthropic",
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .anthropicMessages,
                modelID: "claude-sonnet-4-5",
                apiKey: "sk-ant",
                baseURL: "https://api.anthropic.com"
            ),
            transport: transport
        )
        let response = try await provider.generate(
            ModelGenerationRequest(
                sessionKey: "s",
                prompt: "",
                systemPrompt: "Be brief.",
                messages: toolTranscript,
                tools: [weatherTool],
                toolChoice: .required
            )
        )
        #expect(response.toolCalls == [ModelToolCall(id: "toolu_1", name: "get_weather", argumentsJSON: #"{"city":"Bern"}"#)])
        #expect(response.stopReason == .toolUse)
        #expect(response.reasoningText == "plan")
        #expect(response.usage == ModelUsage(inputTokens: 40, outputTokens: 9, cacheReadTokens: 3, cacheWriteTokens: 2))

        let request = try #require(await transport.lastRequest())
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "fine-grained-tool-streaming-2025-05-14,interleaved-thinking-2025-05-14")
        let body = try #require(await transport.lastBodyObject())
        #expect(body["system"]?.stringValue == "Be brief.")
        let messages = try #require(body["messages"]?.arrayValue)
        #expect(messages.count == 3)
        #expect(messages[1][wireKey: "content"]?.arrayValue?.first?.wireString("type") == "tool_use")
        let result = try #require(messages[2][wireKey: "content"]?.arrayValue?.first)
        #expect(result.wireString("type") == "tool_result")
        #expect(result.wireString("tool_use_id") == "call_1")
        #expect(body["tool_choice"]?.wireString("type") == "any")
        #expect(body["tools"]?.arrayValue?.first?[wireKey: "input_schema"]?.wireString("type") == "object")
    }

    @Test
    func anthropicStreamsTextThinkingToolInputAndUsage() async throws {
        let transport = ContractV2StubTransport(body: """
        event: message_start
        data: {"type":"message_start","message":{"model":"claude-opus-5","usage":{"input_tokens":12,"output_tokens":1}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"why"}}

        event: content_block_start
        data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"On it"}}

        event: content_block_start
        data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_9","name":"get_weather","input":{}}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\\"city\\":\\"Oslo\\"}"}}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":20}}

        event: message_stop
        data: {"type":"message_stop"}

        """)
        let provider = ProviderServiceAnthropicModelProvider(
            id: "minimax",
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .anthropicMessages,
                modelID: "claude-opus-5",
                apiKey: "k",
                baseURL: "https://api.minimax.io/anthropic"
            ),
            transport: transport
        )
        let chunks = try await collect(await provider.generateStream(ModelGenerationRequest(sessionKey: "s", prompt: "hi", tools: [weatherTool])))
        #expect(chunks.compactMap(\.reasoningText).joined() == "why")
        #expect(chunks.filter { $0.kind == .text }.map(\.text).joined() == "On it")
        let final = try #require(chunks.last)
        #expect(final.toolCalls == [ModelToolCall(id: "toolu_9", name: "get_weather", argumentsJSON: #"{"city":"Oslo"}"#)])
        #expect(final.stopReason == .toolUse)
        #expect(final.usage == ModelUsage(inputTokens: 12, outputTokens: 20))
        let request = try #require(await transport.lastRequest())
        #expect(request.url?.absoluteString == "https://api.minimax.io/anthropic/v1/messages")
        // Betas are only sent to the direct Anthropic API.
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == nil)
    }

    @Test
    func anthropicThinkingSignatureRoundTripsIntoTheNextTurn() async throws {
        let transport = ContractV2StubTransport(body: """
        {"stop_reason":"tool_use","content":[{"type":"thinking","thinking":"plan","signature":"sig-1"},
        {"type":"tool_use","id":"toolu_1","name":"get_weather","input":{"city":"Bern"}}]}
        """)
        let provider = ProviderServiceAnthropicModelProvider(
            id: "anthropic",
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .anthropicMessages,
                modelID: "claude-sonnet-4-6",
                apiKey: "k",
                baseURL: "https://api.anthropic.com"
            ),
            transport: transport
        )
        let thinkingPolicy = ModelGenerationPolicy(thinkingLevel: .high)
        let first = try await provider.generate(
            ModelGenerationRequest(sessionKey: "s", prompt: "", policy: thinkingPolicy, messages: [.user("go")], tools: [weatherTool])
        )
        #expect(first.reasoningSignature == "sig-1")
        #expect(first.assistantContent.first == .thinking("plan", signature: "sig-1"))

        let transcript: [ModelMessage] = [
            .user("go"),
            first.assistantMessage,
            .toolResult(ModelToolResult(toolCallID: "toolu_1", toolName: "get_weather", content: [.text("sunny")])),
        ]
        _ = try? await provider.generate(
            ModelGenerationRequest(sessionKey: "s", prompt: "", policy: thinkingPolicy, messages: transcript, tools: [weatherTool])
        )
        let body = try #require(await transport.lastBodyObject())
        let assistant = try #require(body["messages"]?.arrayValue?[1][wireKey: "content"]?.arrayValue)
        #expect(assistant.first?.wireString("type") == "thinking")
        #expect(assistant.first?.wireString("signature") == "sig-1")
        #expect(body["thinking"]?.wireString("type") == "adaptive")

        // Without a signed thinking block the active tool turn must be sent with thinking disabled.
        _ = try? await provider.generate(
            ModelGenerationRequest(sessionKey: "s", prompt: "", policy: thinkingPolicy, messages: toolTranscript, tools: [weatherTool])
        )
        #expect(await transport.lastBodyObject()?["thinking"]?.wireString("type") == "disabled")
    }

    @Test
    func geminiThoughtSignaturesAreReplayedWithFunctionCalls() async throws {
        let transport = ContractV2StubTransport(body: """
        {"candidates":[{"content":{"parts":[{"functionCall":{"name":"get_weather","args":{"city":"Rome"}},"thoughtSignature":"ts-1"}]}}]}
        """)
        let provider = GoogleGenerativeAIModelProvider(
            id: "google",
            configuration: ProviderServiceConfig(enabled: true, apiStyle: .custom, modelID: "gemini-3-pro-preview", apiKey: "g"),
            transport: transport
        )
        let first = try await provider.generate(ModelGenerationRequest(sessionKey: "s", prompt: "", messages: [.user("go")], tools: [weatherTool]))
        let call = try #require(first.toolCalls.first)
        _ = try await provider.generate(
            ModelGenerationRequest(
                sessionKey: "s",
                prompt: "",
                messages: [
                    .user("go"),
                    first.assistantMessage,
                    .toolResult(ModelToolResult(toolCallID: call.id, toolName: call.name, content: [.text("warm")])),
                    .assistant(content: [.toolCall(ModelToolCall(id: "foreign", name: "get_weather", argumentsJSON: "{}"))]),
                ],
                tools: [weatherTool]
            )
        )
        let contents = try #require(await transport.lastBodyObject()?["contents"]?.arrayValue)
        #expect(contents[1][wireKey: "parts"]?.arrayValue?.first?.wireString("thoughtSignature") == "ts-1")
        #expect(contents[3][wireKey: "parts"]?.arrayValue?.first?.wireString("thoughtSignature") == "skip_thought_signature_validator")
    }

    // MARK: - Google

    @Test
    func geminiMapsFunctionCallsAndUsage() async throws {
        let transport = ContractV2StubTransport(body: """
        {"candidates":[{"content":{"role":"model","parts":[{"text":"thinking","thought":true},{"functionCall":{"name":"get_weather","args":{"city":"Kyiv"}}}]},
        "finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":30,"candidatesTokenCount":7,"thoughtsTokenCount":3,"totalTokenCount":40}}
        """)
        let provider = GoogleGenerativeAIModelProvider(
            id: "google",
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .custom,
                modelID: "gemini-2.5-flash",
                apiKey: "gem",
                baseURL: "https://generativelanguage.googleapis.com/v1beta"
            ),
            transport: transport
        )
        let response = try await provider.generate(
            ModelGenerationRequest(sessionKey: "s", prompt: "", systemPrompt: "Brief.", messages: toolTranscript, tools: [weatherTool], toolChoice: .required)
        )
        #expect(response.toolCalls.count == 1)
        #expect(response.toolCalls.first?.name == "get_weather")
        #expect(response.toolCalls.first?.arguments == ["city": AnyCodable("Kyiv")])
        #expect(response.stopReason == .toolUse)
        #expect(response.reasoningText == "thinking")
        #expect(response.usage == ModelUsage(inputTokens: 30, outputTokens: 10, reasoningTokens: 3, totalTokens: 40))

        let body = try #require(await transport.lastBodyObject())
        #expect(body["systemInstruction"]?[wireKey: "parts"]?.arrayValue?.first?.wireString("text") == "Brief.")
        let contents = try #require(body["contents"]?.arrayValue)
        #expect(contents.map { $0.wireString("role") } == ["user", "model", "user"])
        #expect(contents[1][wireKey: "parts"]?.arrayValue?.first?[wireKey: "functionCall"]?.wireString("name") == "get_weather")
        #expect(contents[2][wireKey: "parts"]?.arrayValue?.first?[wireKey: "functionResponse"]?.wireString("name") == "get_weather")
        #expect(body["toolConfig"]?[wireKey: "functionCallingConfig"]?.wireString("mode") == "ANY")
        #expect(body["tools"]?.arrayValue?.first?[wireKey: "functionDeclarations"]?.arrayValue?.first?.wireString("name") == "get_weather")
    }

    @Test
    func geminiStreamUsesAltSSE() async throws {
        let transport = ContractV2StubTransport(body: """
        data: {"candidates":[{"content":{"parts":[{"text":"Hel"}]}}]}

        data: {"candidates":[{"content":{"parts":[{"text":"lo"}]},"finishReason":"MAX_TOKENS"}],"usageMetadata":{"promptTokenCount":2,"candidatesTokenCount":2}}

        """)
        let provider = GeminiModelProvider(
            configuration: GeminiModelConfig(enabled: true, modelID: "gemini-2.0-flash", apiKey: "gem"),
            transport: transport
        )
        let chunks = try await collect(await provider.generateStream(ModelGenerationRequest(sessionKey: "s", prompt: "hi")))
        #expect(chunks.filter { $0.kind == .text }.map(\.text).joined() == "Hello")
        #expect(chunks.last?.stopReason == .length)
        let url = try #require(await transport.lastRequest()?.url?.absoluteString)
        #expect(url.contains(":streamGenerateContent"))
        #expect(url.contains("alt=sse"))
        // The API key travels in `x-goog-api-key`, never in the URL (upstream parity; keeps keys out of logs).
        #expect(!url.contains("key=gem"))
        #expect(await transport.lastRequest()?.value(forHTTPHeaderField: "x-goog-api-key") == "gem")
    }

    @Test
    func vertexSubstitutesLocationInBaseURL() async throws {
        let transport = ContractV2StubTransport(body: #"{"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}"#)
        let config = ModelProviderConfig(
            enabled: true,
            baseURL: "https://{location}-aiplatform.googleapis.com/v1/projects/p/locations/{location}/publishers/google",
            auth: .token,
            api: .googleVertex,
            models: [ModelDefinitionConfig(id: "gemini-3-pro-preview")],
            region: "europe-west4",
            apiKeyInput: .string("vertex-token")
        )
        let provider = GoogleGenerativeAIModelProvider(
            id: "google-vertex",
            configuration: config.legacyServiceConfig(providerID: "google-vertex"),
            transport: transport,
            runtime: ModelProviderRuntimeContext(providerConfig: config, api: .googleVertex)
        )
        _ = try await provider.generate(ModelGenerationRequest(sessionKey: "s", prompt: "hi"))
        let url = try #require(await transport.lastRequest()?.url?.absoluteString)
        #expect(url.hasPrefix("https://europe-west4-aiplatform.googleapis.com/v1/projects/p/locations/europe-west4/"))
        #expect(await transport.lastRequest()?.value(forHTTPHeaderField: "Authorization") == "Bearer vertex-token")
    }

    // MARK: - Bedrock

    @Test
    func bedrockMapsToolUseAndUsage() async throws {
        let transport = ContractV2StubTransport(body: """
        {"output":{"message":{"role":"assistant","content":[{"toolUse":{"toolUseId":"tu_1","name":"get_weather","input":{"city":"Lima"}}}]}},
         "stopReason":"tool_use","usage":{"inputTokens":14,"outputTokens":6,"totalTokens":20}}
        """)
        let provider = BedrockConverseModelProvider(
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .bedrockConverse,
                authMode: .awsSDK,
                modelID: "us.anthropic.claude-opus-4-7-v1:0",
                baseURL: "https://bedrock-runtime.us-east-1.amazonaws.com"
            ),
            transport: transport
        )
        #expect(provider.capabilities.supportsTools)
        let response = try await provider.generate(
            ModelGenerationRequest(
                sessionKey: "s",
                prompt: "",
                policy: ModelGenerationPolicy(temperature: 0.3),
                messages: toolTranscript,
                tools: [weatherTool]
            )
        )
        #expect(response.toolCalls == [ModelToolCall(id: "tu_1", name: "get_weather", argumentsJSON: #"{"city":"Lima"}"#)])
        #expect(response.stopReason == .toolUse)
        #expect(response.usage?.totalTokens == 20)
        let body = try #require(await transport.lastBodyObject())
        #expect(body["toolConfig"]?[wireKey: "tools"]?.arrayValue?.first?[wireKey: "toolSpec"]?.wireString("name") == "get_weather")
        // Opus 4.7 profiles reject temperature.
        #expect(body["inferenceConfig"]?[wireKey: "temperature"] == nil)
        let messages = try #require(body["messages"]?.arrayValue)
        #expect(messages[2][wireKey: "content"]?.arrayValue?.first?[wireKey: "toolResult"]?.wireString("status") == "success")
    }

    // MARK: - Ollama

    @Test
    func ollamaNativeChatMapsToolsAndStreamsNDJSON() async throws {
        let transport = ContractV2StubTransport(body: """
        {"model":"qwen3","message":{"role":"assistant","content":"","thinking":"hm"},"done":false}
        {"model":"qwen3","message":{"role":"assistant","content":"",\
        "tool_calls":[{"function":{"name":"get_weather","arguments":{"city":"Doha"}}}]},"done":false}
        {"model":"qwen3","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop","prompt_eval_count":9,"eval_count":4}
        """)
        let config = ModelProviderConfig(
            enabled: true,
            baseURL: "http://127.0.0.1:11434/v1",
            auth: nil,
            api: .ollama,
            models: [ModelDefinitionConfig(id: "qwen3", reasoning: true, contextTokens: 32_768)]
        )
        let provider = OllamaModelProvider(
            configuration: config.legacyServiceConfig(providerID: "ollama"),
            transport: transport,
            runtime: ModelProviderRuntimeContext(providerConfig: config, api: .ollama)
        )
        let chunks = try await collect(
            await provider.generateStream(
                ModelGenerationRequest(
                    sessionKey: "s",
                    prompt: "",
                    policy: ModelGenerationPolicy(thinkingLevel: .off),
                    messages: toolTranscript,
                    tools: [weatherTool]
                )
            )
        )
        #expect(chunks.compactMap(\.reasoningText).joined() == "hm")
        let final = try #require(chunks.last)
        #expect(final.toolCalls.first?.name == "get_weather")
        #expect(final.stopReason == .toolUse)
        #expect(final.usage == ModelUsage(inputTokens: 9, outputTokens: 4))
        let request = try #require(await transport.lastRequest())
        #expect(request.url?.absoluteString == "http://127.0.0.1:11434/api/chat")
        let body = try #require(await transport.lastBodyObject())
        #expect(body["options"]?.wireInt("num_ctx") == 32_768)
        #expect(body["think"]?.boolValue == false)
        #expect(body["tools"]?.arrayValue?.first?[wireKey: "function"]?.wireString("name") == "get_weather")
        let messages = try #require(body["messages"]?.arrayValue)
        #expect(messages.last?.wireString("role") == "tool")
        #expect(messages.last?.wireString("tool_name") == "get_weather")
    }

    // MARK: - Errors

    @Test
    func httpErrorsIncludeProviderMessage() async throws {
        let transport = ContractV2StubTransport(body: #"{"error":{"message":"bad tool schema"}}"#, statusCode: 400)
        let provider = ProviderServiceOpenAIModelProvider(
            id: "openrouter",
            configuration: ProviderServiceConfig(enabled: true, modelID: "m", apiKey: "k", baseURL: "https://openrouter.ai/api/v1"),
            transport: transport
        )
        do {
            _ = try await provider.generate(ModelGenerationRequest(sessionKey: "s", prompt: "x"))
            Issue.record("Expected an HTTP error")
        } catch let error as OpenClawCoreError {
            guard case .unavailable(let detail) = error else {
                Issue.record("Unexpected error \(error)")
                return
            }
            #expect(detail == "openrouter request failed with status 400: bad tool schema")
        }
    }
}
