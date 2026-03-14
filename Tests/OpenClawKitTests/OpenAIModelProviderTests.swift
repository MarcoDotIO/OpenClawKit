#if canImport(OpenAIKit)
import Foundation
import OpenAIKit
import OpenClawCore
import OpenClawProtocol
import Testing
@testable import OpenClawModels

@Suite("OpenAI model provider")
struct OpenAIModelProviderTests {
    final class FactoryProbe: @unchecked Sendable {
        var lastResolved: OpenAIKitResolvedRequest?
        var invocationCount = 0
    }

    final class MockChatClient: @unchecked Sendable, OpenAIKitChatRequesting {
        enum FailureMode: Sendable {
            case none
            case rateLimit(String)
        }

        let response: ChatResponse
        let failureMode: FailureMode
        private(set) var lastBody: Data?

        init(response: ChatResponse, failureMode: FailureMode = .none) {
            self.response = response
            self.failureMode = failureMode
        }

        func generateChatCompletion(parameters: ChatParameters) async throws -> ChatResponse {
            self.lastBody = try JSONEncoder().encode(parameters)
            switch self.failureMode {
            case .none:
                break
            case .rateLimit(let message):
                throw OpenAIAPIError.rateLimit(
                    try JSONDecoder().decode(
                        OpenAIErrorResponse.self,
                        from: Data(
                            """
                            {
                              "error": {
                                "message": "\(message)",
                                "type": "rate_limit_error",
                                "param": null,
                                "code": "rate_limit"
                              }
                            }
                            """.utf8
                        )
                    )
                )
            }
            return self.response
        }

        func bodyString() -> String? {
            guard let lastBody else {
                return nil
            }
            return String(data: lastBody, encoding: .utf8)
        }
    }

    actor MockLegacyTransport: OpenAICompatibleHTTPTransport {
        let response: HTTPResponseData
        private(set) var invocationCount = 0
        private(set) var lastPath: String?
        private(set) var lastAuthorization: String?
        private(set) var lastOrganization: String?
        private(set) var lastProject: String?
        private(set) var lastBody: Data?

        init(response: HTTPResponseData) {
            self.response = response
        }

        func data(for request: URLRequest) async throws -> HTTPResponseData {
            self.invocationCount += 1
            self.lastPath = request.url?.path
            self.lastAuthorization = request.value(forHTTPHeaderField: "Authorization")
            self.lastOrganization = request.value(forHTTPHeaderField: "OpenAI-Organization")
            self.lastProject = request.value(forHTTPHeaderField: "OpenAI-Project")
            self.lastBody = request.httpBody
            return self.response
        }

        func bodyString() -> String? {
            guard let lastBody else {
                return nil
            }
            return String(data: lastBody, encoding: .utf8)
        }
    }

    @Test
    func textOnlyRequestsUseOpenAIKitChatClient() async throws {
        let response = try Self.decodeChatResponse(
            """
            {
              "id": "chatcmpl_1",
              "object": "chat.completion",
              "created": 1,
              "choices": [
                {
                  "index": 0,
                  "message": {
                    "role": "assistant",
                    "content": "openai-output"
                  },
                  "finish_reason": "stop"
                }
              ],
              "usage": {
                "prompt_tokens": 3,
                "completion_tokens": 2,
                "total_tokens": 5
              }
            }
            """
        )
        let client = MockChatClient(response: response)
        let legacyTransport = MockLegacyTransport(
            response: HTTPResponseData(statusCode: 500, headers: [:], body: Data())
        )
        let probe = FactoryProbe()
        let provider = OpenAIModelProvider(
            configuration: OpenAIModelConfig(
                enabled: true,
                modelID: "gpt-4.1-mini",
                apiKey: "openai-key",
                baseURL: "https://api.openai.com/v1"
            ),
            legacyTransport: legacyTransport,
            clientFactory: { _, resolved in
                probe.invocationCount += 1
                probe.lastResolved = resolved
                return client
            }
        )

        let result = try await provider.generate(
            ModelGenerationRequest(
                sessionKey: "main",
                prompt: "Explain the adapter",
                systemPrompt: "Be concise.",
                modelID: "gpt-5",
                metadata: [
                    "openai.projectId": "proj_123",
                ],
                headers: [
                    "x-trace-id": "trace-123",
                ],
                policy: ModelGenerationPolicy(requestTimeoutMs: 3_200)
            )
        )

        #expect(result.text == "openai-output")
        #expect(result.providerID == OpenAIModelProvider.providerID)
        #expect(result.modelID == "gpt-5")
        #expect(probe.invocationCount == 1)
        #expect(await legacyTransport.invocationCount == 0)
        #expect(probe.lastResolved?.requestOptions.additionalHeaders["x-trace-id"] == "trace-123")
        #expect(probe.lastResolved?.requestOptions.timeoutInterval == 3.2)
        #expect(probe.lastResolved?.projectID == "proj_123")

        let body = try #require(client.bodyString())
        #expect(body.contains("\"model\":\"gpt-5\""))
        #expect(body.contains("\"role\":\"system\""))
        #expect(body.contains("Be concise."))
        #expect(body.contains("Explain the adapter"))
    }

    @Test
    func multimodalRequestsFallBackToLegacyTransport() async throws {
        let chatResponse = try Self.decodeChatResponse(
            """
            {
              "id": "chatcmpl_unused",
              "object": "chat.completion",
              "created": 1,
              "choices": [
                {
                  "index": 0,
                  "message": {
                    "role": "assistant",
                    "content": "unused"
                  },
                  "finish_reason": "stop"
                }
              ]
            }
            """
        )
        let client = MockChatClient(response: chatResponse)
        let legacyTransport = MockLegacyTransport(
            response: HTTPResponseData(
                statusCode: 200,
                headers: [:],
                body: Data(
                    """
                    {
                      "model": "gpt-4.1-mini",
                      "choices": [
                        {
                          "index": 0,
                          "message": {
                            "role": "assistant",
                            "content": "multimodal-output"
                          }
                        }
                      ]
                    }
                    """.utf8
                )
            )
        )
        let probe = FactoryProbe()
        let provider = OpenAIModelProvider(
            configuration: OpenAIModelConfig(
                enabled: true,
                modelID: "gpt-4.1-mini",
                apiKey: "openai-key",
                baseURL: "https://api.openai.com/v1"
            ),
            legacyTransport: legacyTransport,
            clientFactory: { _, resolved in
                probe.invocationCount += 1
                probe.lastResolved = resolved
                return client
            }
        )

        let result = try await provider.generate(
            ModelGenerationRequest(
                sessionKey: "main",
                prompt: "Describe this image",
                metadata: [
                    "openai.organizationId": "org_123",
                    "openai.projectId": "proj_456",
                ],
                headers: [
                    "x-request-id": "legacy-123",
                ],
                attachments: [
                    MediaAttachment(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                        mimeType: "image/png",
                        data: Data([0x89, 0x50, 0x4e, 0x47]),
                        fileName: "diagram.png"
                    ),
                ]
            )
        )

        #expect(result.text == "multimodal-output")
        #expect(probe.invocationCount == 0)
        #expect(await legacyTransport.invocationCount == 1)
        #expect(await legacyTransport.lastPath == "/v1/chat/completions")
        #expect(await legacyTransport.lastAuthorization == "Bearer openai-key")
        #expect(await legacyTransport.lastOrganization == "org_123")
        #expect(await legacyTransport.lastProject == "proj_456")
        let body = try #require(await legacyTransport.bodyString())
        #expect(body.contains("\"image_url\""))
        #expect(body.contains("diagram.png"))
    }

    @Test
    func providerNormalizesOpenAIKitFailures() async throws {
        let client = MockChatClient(
            response: try Self.decodeChatResponse(
                """
                {
                  "id": "chatcmpl_unused",
                  "object": "chat.completion",
                  "created": 1,
                  "choices": []
                }
                """
            ),
            failureMode: .rateLimit("Rate limited")
        )
        let provider = OpenAIModelProvider(
            configuration: OpenAIModelConfig(
                enabled: true,
                modelID: "gpt-4.1-mini",
                apiKey: "openai-key",
                baseURL: "https://api.openai.com/v1"
            ),
            legacyTransport: MockLegacyTransport(
                response: HTTPResponseData(statusCode: 500, headers: [:], body: Data())
            ),
            clientFactory: { _, _ in client }
        )

        do {
            _ = try await provider.generate(
                ModelGenerationRequest(sessionKey: "main", prompt: "Hello")
            )
            Issue.record("Expected OpenAIKit error normalization")
        } catch let error as OpenClawCoreError {
            guard case .unavailable(let detail) = error else {
                Issue.record("Expected unavailable error, received \(error)")
                return
            }
            #expect(detail == "openai request failed with status 429: Rate limited")
        }
    }

    private static func decodeChatResponse(_ json: String) throws -> ChatResponse {
        try JSONDecoder().decode(ChatResponse.self, from: Data(json.utf8))
    }
}
#endif
