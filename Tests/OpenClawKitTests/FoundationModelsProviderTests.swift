import Testing
@testable import OpenClawKit

@Suite("Foundation Models provider")
struct FoundationModelsProviderTests {
    @Test
    func providerThrowsUnavailableWhenRuntimeIsNotReady() async throws {
        let availability = FoundationModelsProvider.runtimeAvailability()
        guard !availability.isAvailable else {
            return
        }

        let provider = FoundationModelsProvider()
        do {
            _ = try await provider.generate(
                ModelGenerationRequest(sessionKey: "main", prompt: "hello")
            )
            Issue.record("Expected Foundation Models to be unavailable")
        } catch {
            #expect(String(describing: error).contains(availability.message))
        }
    }

    @Test
    func routerFallsBackToDefaultProviderWhenRequestedProviderIsMissing() async throws {
        let router = ModelRouter()
        let response = try await router.generate(
            ModelGenerationRequest(
                sessionKey: "main",
                prompt: "hello",
                providerID: FoundationModelsProvider.providerID
            )
        )

        #expect(response.providerID == EchoModelProvider.defaultID)
        #expect(response.text == "OK")
    }
}
