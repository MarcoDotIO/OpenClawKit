#if canImport(OpenAIKit)
import Foundation
import OpenAIKit
import OpenClawCore
import Testing
@testable import OpenClawModels

@Suite("OpenAIKit backend")
struct OpenAIKitBackendTests {
    @Test
    func openAIModelResolutionMapsRequestOverridesIntoConfiguration() throws {
        let resolved = try OpenAIKitClientFactory.resolve(
            providerID: OpenAIModelProvider.providerID,
            configuration: OpenAIModelConfig(
                enabled: true,
                modelID: "gpt-4.1-mini",
                apiKey: "configured-key",
                baseURL: "https://api.openai.com/v1"
            ),
            request: ModelGenerationRequest(
                sessionKey: "main",
                prompt: "Hello",
                modelID: "gpt-5",
                metadata: [
                    "provider.baseURL": "https://gateway.openclaw.test/v1",
                    "openai.organizationId": "org-openclaw",
                    "openai.projectId": "proj-openclaw",
                    "openai.webhookSecret": "whsec_123",
                ],
                headers: [
                    "x-trace-id": "trace-123",
                    "x-empty": "   ",
                ],
                policy: ModelGenerationPolicy(requestTimeoutMs: 4_500)
            )
        )

        #expect(resolved.authorization == .bearerToken("configured-key"))
        #expect(resolved.baseURL.absoluteString == "https://gateway.openclaw.test/v1")
        #expect(resolved.modelID == "gpt-5")
        #expect(resolved.organizationID == "org-openclaw")
        #expect(resolved.projectID == "proj-openclaw")
        #expect(resolved.webhookSecret == "whsec_123")
        #expect(resolved.requestOptions.timeoutInterval == 4.5)
        #expect(resolved.requestOptions.maxRetries == 0)
        #expect(resolved.requestOptions.additionalHeaders == ["x-trace-id": "trace-123"])

        let configuration = try #require(resolved.clientConfiguration)
        #expect(configuration.apiKey == "configured-key")
        #expect(configuration.baseURL.absoluteString == "https://gateway.openclaw.test/v1")
        #expect(configuration.organizationId == "org-openclaw")
        #expect(configuration.projectId == "proj-openclaw")
        #expect(configuration.webhookSecret == "whsec_123")
        #expect(configuration.requestOptions.timeoutInterval == 4.5)
        #expect(configuration.requestOptions.additionalHeaders["x-trace-id"] == "trace-123")
    }

    @Test
    func providerServiceResolutionMergesHeadersAndMetadata() throws {
        let resolved = try OpenAIKitClientFactory.resolve(
            providerID: "openai-codex",
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .openAICompletions,
                authMode: .oauthToken,
                modelID: "codex-mini",
                accessToken: "oauth-token",
                baseURL: "https://api.openai.com/v1",
                organizationID: "legacy-org-header",
                headers: [
                    "x-team": "platform",
                    "x-request-id": "configured",
                ],
                metadata: [
                    "openai.projectId": "project-configured",
                    "openai.maxRetries": "4",
                    "openai.requestTimeoutMs": "2200",
                ]
            ),
            request: ModelGenerationRequest(
                sessionKey: "main",
                prompt: "Ship it",
                metadata: [
                    "openai.projectId": "project-request",
                    "openai.webhookSecret": "whsec_request",
                ],
                headers: [
                    "x-request-id": "request-override",
                    "x-user": "codex",
                ]
            )
        )

        #expect(resolved.authorization == .bearerToken("oauth-token"))
        #expect(resolved.modelID == "codex-mini")
        #expect(resolved.organizationID == nil)
        #expect(resolved.projectID == "project-request")
        #expect(resolved.webhookSecret == "whsec_request")
        #expect(resolved.requestOptions.timeoutInterval == 2.2)
        #expect(resolved.requestOptions.maxRetries == 4)
        #expect(resolved.requestOptions.additionalHeaders["x-team"] == "platform")
        #expect(resolved.requestOptions.additionalHeaders["x-request-id"] == "request-override")
        #expect(resolved.requestOptions.additionalHeaders["x-user"] == "codex")
        #expect(resolved.requestOptions.additionalHeaders["x-organization-id"] == "legacy-org-header")

        let configuration = try #require(resolved.clientConfiguration)
        #expect(configuration.apiKey == "oauth-token")
        #expect(configuration.projectId == "project-request")
        #expect(configuration.organizationId == nil)
        #expect(configuration.requestOptions.maxRetries == 4)
        #expect(configuration.requestOptions.additionalHeaders["x-organization-id"] == "legacy-org-header")
    }

    @Test
    func providerServiceResolutionAllowsAuthorizationHeaderOverrideWithoutBearerCredential() throws {
        let resolved = try OpenAIKitClientFactory.resolve(
            providerID: "openai-proxy",
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .openAICompletions,
                authMode: .none,
                modelID: "proxy-model",
                baseURL: "https://proxy.openclaw.test/v1",
                headers: [
                    "Authorization": "Basic proxy-token",
                ]
            ),
            request: ModelGenerationRequest(
                sessionKey: "main",
                prompt: "Hello"
            )
        )

        #expect(resolved.authorization == .none)
        let configuration = try #require(resolved.clientConfiguration)
        #expect(configuration.apiKey == "openclawkit-header-override")
        #expect(configuration.requestOptions.additionalHeaders["Authorization"] == "Basic proxy-token")
    }

    @Test
    func makeClientRejectsRequestsWithoutSupportedAuthorization() throws {
        let resolved = OpenAIKitResolvedRequest(
            authorization: .none,
            baseURL: URL(string: "https://api.openai.com/v1")!,
            modelID: "gpt-4.1-mini",
            organizationID: nil,
            projectID: nil,
            webhookSecret: nil,
            requestOptions: OpenAIRequestOptions()
        )

        #expect(throws: OpenClawCoreError.self) {
            _ = try OpenAIKitClientFactory.makeClient(providerID: "openai", resolved: resolved)
        }
    }

    @Test
    func errorNormalizerMapsOpenAIKitConfigurationErrors() {
        let noKey = OpenAIKitErrorNormalizer.normalize(OpenAIError.noApiKey, providerID: "openai")
        let invalidURL = OpenAIKitErrorNormalizer.normalize(OpenAIError.invalidUrl, providerID: "openai")
        let incompatible = OpenAIKitErrorNormalizer.normalize(
            OpenAIError.incompatibleImageParameter(incorrctInput: "bad-image"),
            providerID: "openai"
        )

        guard case .invalidConfiguration(let noKeyMessage) = noKey else {
            Issue.record("Expected invalid configuration for missing API key")
            return
        }
        #expect(noKeyMessage == "openai API key is required")

        guard case .invalidConfiguration(let invalidURLMessage) = invalidURL else {
            Issue.record("Expected invalid configuration for invalid URL")
            return
        }
        #expect(invalidURLMessage == "openai base URL is invalid")

        guard case .invalidConfiguration(let incompatibleMessage) = incompatible else {
            Issue.record("Expected invalid configuration for incompatible payload")
            return
        }
        #expect(incompatibleMessage.contains("incompatible"))
    }

    @Test
    func errorNormalizerMapsAPIAndTransportErrors() {
        let payload = try! JSONDecoder().decode(
            OpenAIErrorResponse.self,
            from: Data(
                """
                {
                  "error": {
                    "message": "Too many requests",
                    "type": "rate_limit_error",
                    "param": null,
                    "code": "rate_limit"
                  }
                }
                """.utf8
            )
        )
        let apiError = OpenAIKitErrorNormalizer.normalize(
            OpenAIAPIError.rateLimit(payload),
            providerID: "openai"
        )
        let urlError = OpenAIKitErrorNormalizer.normalize(
            URLError(.timedOut),
            providerID: "openai"
        )
        let passthrough = OpenAIKitErrorNormalizer.normalize(
            OpenClawCoreError.unavailable("already normalized"),
            providerID: "openai"
        )

        guard case .unavailable(let apiMessage) = apiError else {
            Issue.record("Expected unavailable error for API failure")
            return
        }
        #expect(apiMessage == "openai request failed with status 429: Too many requests")

        guard case .unavailable(let transportMessage) = urlError else {
            Issue.record("Expected unavailable error for transport failure")
            return
        }
        #expect(transportMessage.contains("transport failed"))

        guard case .unavailable(let passthroughMessage) = passthrough else {
            Issue.record("Expected passthrough unavailable error")
            return
        }
        #expect(passthroughMessage == "already normalized")
    }
}
#endif
