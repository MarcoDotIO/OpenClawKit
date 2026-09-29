import Foundation
import Testing
@testable import OpenClawCore
@testable import OpenClawModels

/// `models.providers` keys that normalize to one provider id must not yield two providers with the
/// same id (the router keeps only the last one registered).
@Suite("Model provider factory alias grouping")
struct ModelProviderFactoryAliasTests {
    private static func decode(_ json: String) throws -> ModelProviderConfig {
        try JSONDecoder().decode(ModelProviderConfig.self, from: Data(json.utf8))
    }

    @Test
    func platformOpenAIWinsOverLegacyCodexWithProviderAuth() throws {
        let platform = try Self.decode(#"""
        {"enabled":true,"baseUrl":"https://api.openai.com/v1","apiKey":"sk-platform","api":"openai-responses","models":[{"id":"gpt-5.5"}]}
        """#)
        let codex = try Self.decode(#"{"enabled":true,"auth":"oauth","models":[{"id":"gpt-5.4-codex"}]}"#)
        let result = ModelProviderFactory.makeProviders(from: ["openai": platform, "openai-codex": codex])

        let ids = result.providers.map(\.id)
        #expect(ids == ["openai"])
        #expect(Set(ids).count == ids.count)
        #expect(result.providers.first is OpenAIResponsesModelProvider)
        #expect(result.skipped["openai-codex"]?.contains("duplicate of normalized provider \"openai\"") == true)
        #expect(result.skipped["openai"] == nil)
    }

    @Test
    func legacyCodexModelsMergeIntoOpenAIWhenUnblocked() throws {
        let platform = try Self.decode(#"""
        {"enabled":true,"baseUrl":"https://api.openai.com/v1","api":"openai-responses","models":[{"id":"gpt-5.5"}]}
        """#)
        let codex = try Self.decode(#"{"enabled":true,"models":[{"id":"gpt-5.4-codex"},{"id":"gpt-5.5"}]}"#)
        let merged = try #require(
            ModelProviderFactory.mergeLegacyCodexConfig(codex, aliasID: "codex", into: platform, canonicalID: "openai")
        )
        #expect(merged.models.map(\.id) == ["gpt-5.5", "gpt-5.4"])
        let chatGPTModel = try #require(merged.model(withID: "gpt-5.4"))
        #expect(chatGPTModel.api == .openAIChatGPTResponses)
        #expect(chatGPTModel.baseURL == OpenAIRouteResolution.chatGPTBaseURL)

        let result = ModelProviderFactory.makeProviders(from: ["openai": platform, "codex": codex])
        #expect(result.providers.map(\.id) == ["openai"])
        #expect(result.skipped.isEmpty)
        let routing = try #require(result.providers.first as? RoutingModelProvider)
        #expect(routing.route(forModelID: "gpt-5.4").api == .openAIChatGPTResponses)
        #expect(routing.route(forModelID: "gpt-5.5").api == .openAIResponses)
    }

    @Test
    func geminiAliasIsReportedWhenGoogleIsConfigured() throws {
        let google = try Self.decode(#"""
        {"enabled":true,"baseUrl":"https://generativelanguage.googleapis.com/v1beta","api":"google-generative-ai","models":[{"id":"gemini-3-flash"}]}
        """#)
        let gemini = try Self.decode(#"""
        {"enabled":true,"baseUrl":"https://generativelanguage.googleapis.com/v1beta","api":"google-generative-ai","models":[{"id":"gemini-2.5-pro"}]}
        """#)
        let result = ModelProviderFactory.makeProviders(from: ["gemini": gemini, "google": google])
        let ids = result.providers.map(\.id)
        #expect(ids == ["google"])
        #expect(result.skipped["gemini"]?.contains("\"google\"") == true)
    }

    @Test
    func singleAliasKeyStillBuilds() throws {
        let codex = try Self.decode(#"{"enabled":true,"models":[{"id":"gpt-5.4-codex"}]}"#)
        let result = ModelProviderFactory.makeProviders(from: ["openai-codex": codex])
        #expect(result.providers.map(\.id) == ["openai"])
        #expect(result.skipped.isEmpty)
    }
}
