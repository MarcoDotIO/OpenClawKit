#if canImport(OpenAIKit)
import Foundation
import OpenAIKit
import OpenClawCore
import OpenClawProtocol
import Testing
@testable import OpenClawModels

@Suite("OpenAI responses provider")
struct OpenAIResponsesModelProviderTests {
    final class FactoryProbe: @unchecked Sendable {
        var lastResolved: OpenAIKitResolvedRequest?
        var invocationCount = 0
    }

    final class MockResponsesClient: @unchecked Sendable, OpenAIKitResponsesRequesting {
        enum FailureMode: Sendable {
            case none
            case rateLimit(String)
        }

        let response: ResponseObject
        let failureMode: FailureMode
        private(set) var lastBody: Data?

        init(response: ResponseObject, failureMode: FailureMode = .none) {
            self.response = response
            self.failureMode = failureMode
        }

        func createResponse(parameters: ResponseCreateParameters) async throws -> ResponseObject {
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

    actor MockResponsesTransport: OpenAICompatibleHTTPTransport {
        let response: HTTPResponseData
        private(set) var invocationCount = 0
        private(set) var lastPath: String?
        private(set) var lastAuthorization: String?
        private(set) var lastBody: Data?

        init(response: HTTPResponseData) {
            self.response = response
        }

        func data(for request: URLRequest) async throws -> HTTPResponseData {
            self.invocationCount += 1
            self.lastPath = request.url?.path
            self.lastAuthorization = request.value(forHTTPHeaderField: "Authorization")
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
    func simpleRequestsUseOpenAIKitResponsesClient() async throws {
        let client = MockResponsesClient(
            response: try Self.decodeResponseObject(
                """
                {
                  "id": "resp_1",
                  "object": "response",
                  "model": "gpt-5",
                  "status": "completed",
                  "output_text": "simple-output"
                }
                """
            )
        )
        let transport = MockResponsesTransport(
            response: HTTPResponseData(statusCode: 500, headers: [:], body: Data())
        )
        let probe = FactoryProbe()
        let provider = OpenAIResponsesModelProvider(
            id: "openai",
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .custom,
                authMode: .apiKey,
                modelID: "gpt-5",
                apiKey: "openai-key",
                baseURL: "https://api.openai.com/v1"
            ),
            transport: transport,
            responsesClientFactory: { _, resolved in
                probe.invocationCount += 1
                probe.lastResolved = resolved
                return client
            }
        )

        let result = try await provider.generate(
            ModelGenerationRequest(
                sessionKey: "main",
                prompt: "hello",
                systemPrompt: "Be concise.",
                headers: ["x-trace-id": "trace-123"],
                policy: ModelGenerationPolicy(requestTimeoutMs: 2_500)
            )
        )

        #expect(result.text == "simple-output")
        #expect(result.modelID == "gpt-5")
        #expect(probe.invocationCount == 1)
        #expect(await transport.invocationCount == 0)
        #expect(probe.lastResolved?.requestOptions.additionalHeaders["x-trace-id"] == "trace-123")
        #expect(probe.lastResolved?.requestOptions.timeoutInterval == 2.5)

        let body = try #require(client.bodyString())
        #expect(body.contains("\"model\":\"gpt-5\""))
        #expect(body.contains("\"input\":\"hello\""))
        #expect(body.contains("\"instructions\":\"Be concise.\""))
    }

    @Test
    func advancedRequestsUseLocalResponsesAdapter() async throws {
        let client = MockResponsesClient(
            response: try Self.decodeResponseObject(
                """
                {
                  "id": "resp_unused",
                  "object": "response",
                  "output_text": "unused"
                }
                """
            )
        )
        let transport = MockResponsesTransport(
            response: HTTPResponseData(
                statusCode: 200,
                headers: [:],
                body: Data(
                    """
                    {
                      "model": "codex-mini",
                      "output_text": "advanced-output"
                    }
                    """.utf8
                )
            )
        )
        let probe = FactoryProbe()
        let provider = OpenAIResponsesModelProvider(
            id: "openai-codex",
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .custom,
                authMode: .bearerToken,
                modelID: "codex-mini",
                accessToken: "codex-token",
                baseURL: "https://api.openai.com/v1"
            ),
            transport: transport,
            responsesClientFactory: { _, resolved in
                probe.invocationCount += 1
                probe.lastResolved = resolved
                return client
            }
        )

        let result = try await provider.generate(
            ModelGenerationRequest(
                sessionKey: "main",
                prompt: "Describe this image",
                systemPrompt: "Use code terms.",
                policy: ModelGenerationPolicy(
                    reasoningEffort: .high,
                    serviceTier: .priority,
                    storeResponse: true,
                    codexTransport: .sse
                ),
                attachments: [
                    MediaAttachment(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                        mimeType: "image/png",
                        data: Data([0x89, 0x50, 0x4e, 0x47]),
                        fileName: "diagram.png"
                    ),
                ]
            )
        )

        #expect(result.text == "advanced-output")
        #expect(probe.invocationCount == 0)
        #expect(await transport.invocationCount == 1)
        #expect(await transport.lastPath == "/v1/responses")
        #expect(await transport.lastAuthorization == "Bearer codex-token")
        let body = try #require(await transport.bodyString())
        #expect(body.contains("\"input_image\""))
        #expect(body.contains("\"service_tier\":\"priority\""))
        #expect(body.contains("\"effort\":\"high\""))
        #expect(body.contains("\"store\":true"))
        #expect(body.contains("\"stream\":true"))
    }

    @Test
    func responsesProviderNormalizesOpenAIKitFailures() async throws {
        let client = MockResponsesClient(
            response: try Self.decodeResponseObject(
                """
                {
                  "id": "resp_unused",
                  "object": "response",
                  "output_text": "unused"
                }
                """
            ),
            failureMode: .rateLimit("Too many requests")
        )
        let provider = OpenAIResponsesModelProvider(
            id: "openai",
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .custom,
                authMode: .apiKey,
                modelID: "gpt-5",
                apiKey: "openai-key",
                baseURL: "https://api.openai.com/v1"
            ),
            transport: MockResponsesTransport(
                response: HTTPResponseData(statusCode: 500, headers: [:], body: Data())
            ),
            responsesClientFactory: { _, _ in client }
        )

        do {
            _ = try await provider.generate(
                ModelGenerationRequest(sessionKey: "main", prompt: "hello")
            )
            Issue.record("Expected OpenAIKit responses error normalization")
        } catch let error as OpenClawCoreError {
            guard case .unavailable(let detail) = error else {
                Issue.record("Expected unavailable error, received \(error)")
                return
            }
            #expect(detail == "openai request failed with status 429: Too many requests")
        }
    }

    @Test
    func fastModeInjectsOpenAIResponsesDefaultsForPublicAPI() async throws {
        let transport = MockResponsesTransport(
            response: HTTPResponseData(
                statusCode: 200,
                headers: [:],
                body: Data(
                    """
                    {
                      "model": "gpt-5.4",
                      "output_text": "fast-output"
                    }
                    """.utf8
                )
            )
        )
        let provider = OpenAIResponsesModelProvider(
            id: "openai",
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .custom,
                authMode: .apiKey,
                modelID: "gpt-5.4",
                fastMode: true,
                apiKey: "openai-key",
                baseURL: "https://api.openai.com/v1"
            ),
            transport: transport,
            responsesClientFactory: { _, _ in
                Issue.record("Fast mode should force the local advanced adapter path")
                return MockResponsesClient(response: try Self.decodeResponseObject("{\"id\":\"unused\",\"object\":\"response\",\"output_text\":\"unused\"}"))
            }
        )

        let result = try await provider.generate(
            ModelGenerationRequest(
                sessionKey: "main",
                prompt: "hello"
            )
        )

        #expect(result.text == "fast-output")
        let body = try #require(await transport.bodyString())
        #expect(body.contains("\"service_tier\":\"priority\""))
        #expect(body.contains("\"effort\":\"low\""))
        #expect(body.contains("\"verbosity\":\"low\""))
    }

    @Test
    func fastModeSkipsServiceTierForCodexAndPreservesRequestOverrides() async throws {
        let transport = MockResponsesTransport(
            response: HTTPResponseData(
                statusCode: 200,
                headers: [:],
                body: Data(
                    """
                    {
                      "model": "gpt-5.4",
                      "output_text": "codex-output"
                    }
                    """.utf8
                )
            )
        )
        let provider = OpenAIResponsesModelProvider(
            id: "openai-codex",
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .custom,
                authMode: .bearerToken,
                modelID: "gpt-5.4",
                fastMode: true,
                accessToken: "codex-token",
                baseURL: "https://chatgpt.com/backend-api"
            ),
            transport: transport,
            responsesClientFactory: { _, _ in
                Issue.record("Codex fast mode should use the local advanced adapter path")
                return MockResponsesClient(response: try Self.decodeResponseObject("{\"id\":\"unused\",\"object\":\"response\",\"output_text\":\"unused\"}"))
            }
        )

        _ = try await provider.generate(
            ModelGenerationRequest(
                sessionKey: "main",
                prompt: "ship it",
                policy: ModelGenerationPolicy(
                    reasoningEffort: .high,
                    fastMode: true
                )
            )
        )

        let body = try #require(await transport.bodyString())
        #expect(body.contains("\"effort\":\"high\""))
        #expect(body.contains("\"verbosity\":\"low\""))
        #expect(body.contains("service_tier") == false)
    }

    private static func decodeResponseObject(_ json: String) throws -> ResponseObject {
        try JSONDecoder().decode(ResponseObject.self, from: Data(json.utf8))
    }
}
#endif
