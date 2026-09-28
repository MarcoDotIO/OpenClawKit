import Foundation
import Testing
import OpenClawCore
import OpenClawProtocol
@testable import OpenClawModels

@Suite("Model generation contract v2")
struct ModelGenerationContractTests {
    struct LegacyProvider: ModelProvider {
        let id = "legacy"

        func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
            ModelGenerationResponse(text: "echo:\(request.prompt)", providerID: self.id)
        }
    }

    struct ToolCallingProvider: ModelProvider {
        let id = "tool-caller"

        var capabilities: ModelProviderCapabilities {
            ModelProviderCapabilities(supportsTools: true, supportsJSONSchema: true, supportsTranscript: true)
        }

        func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
            try request.validateToolSupport(supportsTools: self.capabilities.supportsTools, providerID: self.id)
            return ModelGenerationResponse(
                text: "",
                providerID: self.id,
                toolCalls: [ModelToolCall(id: "call_1", name: request.tools.first?.name ?? "none", arguments: ["q": AnyCodable("swift")])],
                usage: ModelUsage(inputTokens: 12, outputTokens: 4, reasoningTokens: 2),
                reasoningText: "need a lookup"
            )
        }
    }

    @Test
    func v1RequestsKeepCompilingAndResolveToASingleUserMessage() {
        let image = MediaAttachment(mimeType: "image/png", data: Data([1, 2, 3]))
        let audio = MediaAttachment(mimeType: "audio/wav", data: Data([4]))
        let request = ModelGenerationRequest(sessionKey: "s", prompt: "describe", attachments: [image, audio])

        #expect(request.messages.isEmpty)
        #expect(request.tools.isEmpty)
        #expect(request.toolChoice == .auto)
        #expect(request.responseFormat == .text)
        #expect(request.responseFormatJSONSchema == nil)
        #expect(request.resolvedMessages == [.user(content: [.text("describe"), .image(image), .attachment(audio)])])

        let transcript = ModelGenerationRequest(sessionKey: "s", prompt: "ignored", messages: [.user("hi"), .assistant("hello")])
        #expect(transcript.resolvedMessages == [.user("hi"), .assistant("hello")])
    }

    @Test
    func routerPreservesContractFieldsWhenRewritingMetadata() {
        let request = ModelGenerationRequest(
            sessionKey: "s",
            prompt: "p",
            messages: [.system("be brief"), .user("hi")],
            tools: [ModelToolDefinition(name: "lookup")],
            toolChoice: .named("lookup"),
            responseFormat: .jsonObject
        )
        let rewritten = request.replacingMetadata(["auth.profileID": "p1"])
        #expect(rewritten.metadata == ["auth.profileID": "p1"])
        #expect(rewritten.messages == request.messages)
        #expect(rewritten.tools == request.tools)
        #expect(rewritten.toolChoice == .named("lookup"))
        #expect(rewritten.responseFormat == .jsonObject)
    }

    @Test
    func toolSupportValidationRejectsToolsForProvidersWithoutToolCalling() throws {
        let withTools = ModelGenerationRequest(sessionKey: "s", prompt: "p", modelID: "m", tools: [ModelToolDefinition(name: "t")])
        #expect(throws: OpenClawCoreError.self) {
            try withTools.validateToolSupport(supportsTools: false, providerID: "local")
        }
        try withTools.validateToolSupport(supportsTools: true, providerID: "local")
        try withTools.validateToolSupport(supportsTools: nil, providerID: "local")
        try ModelGenerationRequest(sessionKey: "s", prompt: "p").validateToolSupport(supportsTools: false, providerID: "local")
    }

    @Test
    func responsesDefaultStopReasonAndBuildTheAssistantMessage() {
        let plain = ModelGenerationResponse(text: "ok", providerID: "p")
        #expect(plain.stopReason == .stop)
        #expect(plain.toolCalls.isEmpty)
        #expect(plain.usage == nil)
        #expect(plain.assistantMessage == .assistant("ok"))

        let call = ModelToolCall(id: "c1", name: "read", argumentsJSON: #"{"path":"/tmp"}"#)
        let withTools = ModelGenerationResponse(text: "", providerID: "p", toolCalls: [call], reasoningText: "think")
        #expect(withTools.stopReason == .toolUse)
        #expect(withTools.assistantContent == [.thinking("think", signature: nil), .toolCall(call)])
        #expect(withTools.assistantMessage.toolCalls == [call])
        #expect(ModelGenerationResponse(text: "x", providerID: "p", stopReason: .length).stopReason == .length)
    }

    @Test
    func defaultStreamCarriesReasoningToolCallsUsageAndStopReason() async throws {
        #expect(LegacyProvider().capabilities == .legacy)
        let provider = ToolCallingProvider()
        let request = ModelGenerationRequest(sessionKey: "s", prompt: "p", tools: [ModelToolDefinition(name: "search")])
        var chunks: [ModelStreamChunk] = []
        for try await chunk in await provider.generateStream(request) {
            chunks.append(chunk)
        }
        #expect(chunks.map(\.kind) == [.reasoning, .final])
        #expect(chunks[0].text.isEmpty)
        #expect(chunks[0].reasoningText == "need a lookup")
        let final = chunks[1]
        #expect(final.isFinal)
        #expect(final.stopReason == .toolUse)
        #expect(final.toolCalls.map(\.name) == ["search"])
        #expect(final.toolCalls.first?.arguments == ["q": AnyCodable("swift")])
        #expect(final.usage?.totalTokens == 16)

        var legacyChunks: [ModelStreamChunk] = []
        for try await chunk in await LegacyProvider().generateStream(ModelGenerationRequest(sessionKey: "s", prompt: "p")) {
            legacyChunks.append(chunk)
        }
        #expect(legacyChunks == [ModelStreamChunk(kind: .final, text: "echo:p", stopReason: .stop)])
        #expect(legacyChunks.first?.isFinal == true)
    }

    @Test
    func v1StreamChunkInitializerMapsToTextAndFinalKinds() {
        #expect(ModelStreamChunk(text: "a").kind == .text)
        #expect(ModelStreamChunk(text: "a").isFinal == false)
        #expect(ModelStreamChunk(text: "", isFinal: true).kind == .final)
        #expect(ModelStreamChunk.reasoningDelta("r").text.isEmpty)
        #expect(ModelStreamChunk.toolCallUpdate(ModelToolCallDelta(index: 0, argumentsDelta: "{")).kind == .toolCallDelta)
        #expect(ModelStreamChunk.usageUpdate(.zero).usage == .zero)
    }

    @Test
    func messagesRoundTripThroughUpstreamLLMCoreShapes() throws {
        let json = """
        [
          {"role": "system", "content": "be brief"},
          {"role": "user", "content": [
            {"type": "text", "text": "look"},
            {"type": "image", "data": "AQID", "mimeType": "image/png"}
          ]},
          {"role": "assistant", "content": [
            {"type": "thinking", "thinking": "hmm", "thinkingSignature": "sig"},
            {"type": "text", "text": "calling"},
            {"type": "toolCall", "id": "call_1", "name": "read", "arguments": {"path": "/tmp/a"}}
          ]},
          {"role": "toolResult", "toolCallId": "call_1", "toolName": "read",
           "content": [{"type": "text", "text": "file"}], "isError": false, "details": {"bytes": 4}}
        ]
        """
        let messages = try JSONDecoder().decode([ModelMessage].self, from: Data(json.utf8))
        #expect(messages.map(\.role) == [.system, .user, .assistant, .tool])
        #expect(messages[0] == .system("be brief"))
        guard case .user(let userContent) = messages[1], case .image(let image) = userContent[1] else {
            Issue.record("Expected user image content")
            return
        }
        #expect(image.data == Data([1, 2, 3]))
        #expect(image.mimeType == "image/png")
        #expect(messages[2].text == "calling")
        #expect(messages[2].toolCalls == [ModelToolCall(id: "call_1", name: "read", arguments: ["path": AnyCodable("/tmp/a")])])
        guard case .toolResult(let result) = messages[3] else {
            Issue.record("Expected tool result")
            return
        }
        #expect(result.toolCallID == "call_1")
        #expect(result.details == AnyCodable(["bytes": AnyCodable(4)]))

        let reencoded = try JSONDecoder().decode([ModelMessage].self, from: try JSONEncoder().encode(messages))
        #expect(reencoded == messages)
    }

    @Test
    func toolCallsAcceptObjectAndStringArguments() throws {
        let openAIStyle = try JSONDecoder().decode(
            ModelToolCall.self,
            from: Data(#"{"id":"c","name":"n","arguments":"{\"a\":1}"}"#.utf8)
        )
        #expect(openAIStyle.argumentsJSON == #"{"a":1}"#)
        #expect(openAIStyle.arguments == ["a": AnyCodable(1)])

        let partial = ModelToolCall(id: "c", name: "n", argumentsJSON: #"{"a":"#)
        #expect(partial.arguments == nil)
        let partialRoundTrip = try JSONDecoder().decode(ModelToolCall.self, from: try JSONEncoder().encode(partial))
        #expect(partialRoundTrip == partial)
        #expect(ModelToolCall(id: "c", name: "n", argumentsJSON: "  ").arguments == [:])
    }

    @Test
    func toolChoiceAndResponseFormatUseProviderNeutralWireShapes() throws {
        let choices: [ModelToolChoice] = [.auto, .none, .required, .named("lookup")]
        let encodedChoices = String(decoding: try JSONEncoder().encode(choices), as: UTF8.self)
        #expect(encodedChoices.contains(#""auto""#))
        #expect(encodedChoices.contains(#""name":"lookup""#))
        #expect(try JSONDecoder().decode([ModelToolChoice].self, from: Data(encodedChoices.utf8)) == choices)
        #expect(try JSONDecoder().decode(ModelToolChoice.self, from: Data(#""any""#.utf8)) == .required)

        let schema: [String: AnyCodable] = ["type": AnyCodable("object")]
        let formats: [ModelResponseFormat] = [.text, .jsonObject, .jsonSchema(name: "answer", schema: schema, strict: true)]
        let decodedFormats = try JSONDecoder().decode([ModelResponseFormat].self, from: try JSONEncoder().encode(formats))
        #expect(decodedFormats == formats)
        #expect(formats[2].jsonSchema == schema)

        let definition = try JSONDecoder().decode(ModelToolDefinition.self, from: Data(#"{"name":"t"}"#.utf8))
        #expect(definition.parameters == ModelToolDefinition.emptyParametersSchema)
        #expect(definition.description.isEmpty)
    }

    @Test
    func usageUsesUpstreamKeysAndAccumulates() throws {
        let usage = try JSONDecoder().decode(
            ModelUsage.self,
            from: Data(#"{"input": 10, "output": 5, "cacheRead": 3, "cacheWrite": 2}"#.utf8)
        )
        #expect(usage.totalTokens == 20)
        #expect(usage.cachedInputTokens == 3)
        let summed = usage + ModelUsage(inputTokens: 1, outputTokens: 1, reasoningTokens: 1)
        #expect(summed.inputTokens == 11)
        #expect(summed.reasoningTokens == 1)
        #expect(summed.totalTokens == 22)
        let encoded = String(decoding: try JSONEncoder().encode(ModelUsage(inputTokens: 1)), as: UTF8.self)
        #expect(encoded.contains(#""input":1"#))
        #expect(ModelUsage(inputTokens: -4).inputTokens == 0)
    }

    @Test(arguments: [
        ("stop", ModelStopReason.stop),
        ("end_turn", .stop),
        ("STOP", .stop),
        ("length", .length),
        ("max_tokens", .length),
        ("MAX_TOKENS", .length),
        ("tool_use", .toolUse),
        ("tool_calls", .toolUse),
        ("toolUse", .toolUse),
        ("stop_sequence", .stopSequence),
        ("content_filter", .contentFilter),
        ("SAFETY", .contentFilter),
        ("refusal", .refusal),
        ("error", .error),
        ("aborted", .aborted),
        ("cancelled", .aborted),
        ("pause_turn", .other("pause_turn")),
    ])
    func stopReasonsNormalizeProviderValues(raw: String, expected: ModelStopReason) throws {
        #expect(ModelStopReason(providerValue: raw) == expected)
        let decoded = try JSONDecoder().decode(ModelStopReason.self, from: try JSONEncoder().encode(expected))
        #expect(decoded == expected)
    }
}
