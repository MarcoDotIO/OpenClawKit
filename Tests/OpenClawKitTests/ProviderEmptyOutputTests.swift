import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OpenClawCore
@testable import OpenClawModels
import OpenClawProtocol

/// Responses with no text and no tool calls are valid when the output limit was reached (for
/// example by reasoning alone) or a safety filter removed the output (`permitsEmptyOutput`); they
/// must not throw, which would make the router fall back and put the auth profile in cooldown.
@Suite("Provider empty output contract")
struct ProviderEmptyOutputTests {
    private static func gemini(_ body: String) -> (GoogleGenerativeAIModelProvider, ContractV2StubTransport) {
        let transport = ContractV2StubTransport(body: body)
        let provider = GoogleGenerativeAIModelProvider(
            id: "google",
            configuration: ProviderServiceConfig(enabled: true, apiStyle: .custom, modelID: "gemini-3-flash", apiKey: "g"),
            transport: transport
        )
        return (provider, transport)
    }

    private static func bedrock(_ body: String) -> BedrockConverseModelProvider {
        BedrockConverseModelProvider(
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .bedrockConverse,
                authMode: .awsSDK,
                modelID: "us.anthropic.claude-opus-4-7-v1:0",
                baseURL: "https://bedrock-runtime.us-east-1.amazonaws.com"
            ),
            transport: ContractV2StubTransport(body: body)
        )
    }

    private static let request = ModelGenerationRequest(sessionKey: "s", prompt: "hard")

    @Test
    func geminiThoughtOnlyMaxTokensReturnsLength() async throws {
        let (provider, _) = Self.gemini("""
        {"candidates":[{"content":{"parts":[{"text":"Counting primes...","thought":true}]},"finishReason":"MAX_TOKENS"}],
         "usageMetadata":{"promptTokenCount":10,"thoughtsTokenCount":64}}
        """)
        let response = try await provider.generate(Self.request)
        #expect(response.text.isEmpty)
        #expect(response.stopReason == .length)
        #expect(response.reasoningText == "Counting primes...")
        #expect(response.usage?.reasoningTokens == 64)
    }

    @Test
    func geminiSafetyBlockReturnsContentFilter() async throws {
        let (provider, _) = Self.gemini(#"{"candidates":[{"finishReason":"SAFETY"}]}"#)
        let response = try await provider.generate(Self.request)
        #expect(response.text.isEmpty)
        #expect(response.stopReason == .contentFilter)
    }

    @Test
    func geminiPromptBlockReturnsContentFilter() async throws {
        let (provider, _) = Self.gemini(#"{"promptFeedback":{"blockReason":"PROHIBITED_CONTENT"}}"#)
        let response = try await provider.generate(Self.request)
        #expect(response.stopReason == .contentFilter)
    }

    @Test
    func geminiCompletedEmptyResponseStillThrows() async {
        let (provider, _) = Self.gemini(#"{"candidates":[{"content":{"parts":[]},"finishReason":"STOP"}]}"#)
        await #expect(throws: OpenClawCoreError.self) {
            _ = try await provider.generate(Self.request)
        }
    }

    @Test
    func geminiMalformedFunctionCallThrows() async {
        let (provider, _) = Self.gemini(#"{"candidates":[{"content":{"parts":[{"text":"partial"}]},"finishReason":"MALFORMED_FUNCTION_CALL"}]}"#)
        await #expect(throws: OpenClawCoreError.self) {
            _ = try await provider.generate(Self.request)
        }
    }

    @Test
    func bedrockReasoningOnlyMaxTokensReturnsLength() async throws {
        let provider = Self.bedrock("""
        {"output":{"message":{"role":"assistant","content":[{"reasoningContent":{"reasoningText":{"text":"thinking...","signature":"sig"}}}]}},
         "stopReason":"max_tokens","usage":{"inputTokens":10,"outputTokens":64,"totalTokens":74}}
        """)
        let response = try await provider.generate(Self.request)
        #expect(response.text.isEmpty)
        #expect(response.stopReason == .length)
        #expect(response.reasoningText == "thinking...")
    }

    @Test
    func bedrockGuardrailReturnsContentFilter() async throws {
        let provider = Self.bedrock(#"{"output":{"message":{"role":"assistant","content":[]}},"stopReason":"guardrail_intervened"}"#)
        let response = try await provider.generate(Self.request)
        #expect(response.stopReason == .contentFilter)
    }

    @Test
    func bedrockCompletedEmptyResponseStillThrows() async {
        let provider = Self.bedrock(#"{"output":{"message":{"role":"assistant","content":[]}},"stopReason":"end_turn"}"#)
        await #expect(throws: OpenClawCoreError.self) {
            _ = try await provider.generate(Self.request)
        }
    }
}
