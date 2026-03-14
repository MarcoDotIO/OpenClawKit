#if os(Linux)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OpenClawCore
@testable import OpenClawModels

@Suite("Linux runtime smoke")
struct LinuxRuntimeSmokeTests {
    actor RecordingTransport: OpenAICompatibleHTTPTransport {
        private(set) var requests: [URLRequest] = []
        let responder: @Sendable (URLRequest) throws -> HTTPResponseData

        init(responder: @escaping @Sendable (URLRequest) throws -> HTTPResponseData) {
            self.responder = responder
        }

        func data(for request: URLRequest) async throws -> HTTPResponseData {
            self.requests.append(request)
            return try self.responder(request)
        }

        func snapshot() -> [URLRequest] {
            self.requests
        }
    }

    @Test
    func openAIProviderUsesLegacyTransportWhenOpenAIKitIsUnavailable() async throws {
        let transport = RecordingTransport { request in
            #expect(request.url?.path == "/v1/chat/completions")
            let body = """
            {
              "model": "gpt-5",
              "choices": [
                {
                  "index": 0,
                  "message": {
                    "role": "assistant",
                    "content": "linux chat fallback"
                  }
                }
              ]
            }
            """
            return HTTPResponseData(statusCode: 200, headers: [:], body: Data(body.utf8))
        }

        let provider = OpenAIModelProvider(
            configuration: OpenAIModelConfig(
                enabled: true,
                modelID: "gpt-5",
                apiKey: "test-key",
                baseURL: "https://api.openai.com/v1"
            ),
            legacyTransport: transport,
            clientFactory: { _, _ in
                throw OpenClawCoreError.unavailable("OpenAIKit should not be used on Linux")
            }
        )

        let response = try await provider.generate(
            ModelGenerationRequest(
                sessionKey: "linux-openai",
                prompt: "Say hello from Linux."
            )
        )

        #expect(response.text == "linux chat fallback")
        #expect(await transport.snapshot().count == 1)
    }

    @Test
    func openAIResponsesProviderUsesAdvancedTransportWhenOpenAIKitIsUnavailable() async throws {
        let transport = RecordingTransport { request in
            #expect(request.url?.path == "/v1/responses")
            let body = """
            {
              "model": "gpt-5.4",
              "output_text": "linux responses fallback"
            }
            """
            return HTTPResponseData(statusCode: 200, headers: [:], body: Data(body.utf8))
        }

        let provider = OpenAIResponsesModelProvider(
            id: "openai",
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .openAICompletions,
                authMode: .apiKey,
                modelID: "gpt-5.4",
                apiKey: "test-key",
                baseURL: "https://api.openai.com/v1"
            ),
            transport: transport,
            responsesClientFactory: { _, _ in
                throw OpenClawCoreError.unavailable("OpenAIKit responses client should not be used on Linux")
            }
        )

        let response = try await provider.generate(
            ModelGenerationRequest(
                sessionKey: "linux-openai-responses",
                prompt: "Say hello from Linux responses."
            )
        )

        #expect(response.text == "linux responses fallback")
        #expect(await transport.snapshot().count == 1)
    }
}
#endif
