import Foundation
import Testing
@testable import OpenClawCore
@testable import OpenClawModels

@Suite("Provider catalog capabilities and metadata")
struct ProviderCatalogCapabilityTests {
    @Test
    func capabilityVocabularyAcceptsUpstreamAndLegacySpellings() throws {
        let decoded = try JSONDecoder().decode(
            [ProviderCapability].self,
            from: Data(#"["memory-embedding", "text-inference", "embedding", "web-fetch", "document-extractors", "usage"]"#.utf8)
        )
        #expect(decoded == [.embedding, .text, .embedding, .webFetch, .documentExtraction, .usage])
        #expect(try String(data: JSONEncoder().encode([ProviderCapability.embedding]), encoding: .utf8) == #"["embedding"]"#)
        #expect(ProviderCapability.lossyList(["web-content-extractors", "decision", "transcript-source", "tools"])
            == [.webContentExtraction, .transcriptSource, .tool])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([ProviderCapability].self, from: Data(#"["agent-harness"]"#.utf8))
        }
    }

    @Test
    func textEntriesCarryUpstreamContractCapabilities() throws {
        func capabilities(_ id: String) throws -> Set<ProviderCapability> {
            Set(try #require(OpenClawReferenceProviderCatalog.entry(for: id)).capabilities)
        }
        #expect(try capabilities("openai").isSuperset(of: [
            .text, .speech, .realtimeTranscription, .realtimeVoice, .embedding, .mediaUnderstanding, .imageGeneration,
            .videoGeneration, .usage,
        ]))
        #expect(try capabilities("anthropic") == [.text, .mediaUnderstanding, .usage])
        #expect(try capabilities("google").isSuperset(of: [.embedding, .webSearch, .musicGeneration, .realtimeVoice]))
        #expect(try capabilities("xai").isSuperset(of: [.webSearch, .usage, .tool, .realtimeVoice]))
        #expect(try capabilities("minimax").contains(.speech))
        #expect(try capabilities("minimax-portal").contains(.speech) == false)
        #expect(try capabilities("moonshot").contains(.webSearch))
        #expect(try capabilities("deepinfra").isSuperset(of: [.mediaUnderstanding, .embedding, .imageGeneration, .speech, .videoGeneration]))
        #expect(try capabilities("llama-cpp").contains(.embedding))
        #expect(try capabilities("amazon-bedrock").contains(.embedding))
        #expect(try capabilities("github-copilot").isSuperset(of: [.embedding, .usage]))
        #expect(try capabilities("xiaomi").isSuperset(of: [.speech, .usage]))
        #expect(try capabilities("xiaomi-token-plan") == [.text, .usage])
        #expect(try capabilities("clawrouter") == [.text, .usage])

        let google = try #require(OpenClawReferenceProviderCatalog.entry(for: "google"))
        #expect(google.capabilityProviderIDs[.embedding] == ["gemini"])
        let xai = try #require(OpenClawReferenceProviderCatalog.entry(for: "xai"))
        #expect(xai.capabilityProviderIDs[.webSearch] == ["grok"])
        #expect(xai.capabilityProviderIDs[.realtimeVoice] == ["xai", "grok-voice", "xai-realtime-voice"])
        let llama = try #require(OpenClawReferenceProviderCatalog.entry(for: "llama-cpp"))
        #expect(llama.capabilityProviderIDs[.embedding] == ["local"])
    }

    @Test
    func capabilityQueriesListProvidersAndRegisteredIDs() {
        let embedding = OpenClawReferenceProviderCatalog.entries(withCapability: .embedding).map(\.providerID)
        #expect(embedding.contains("openai"))
        #expect(embedding.contains("google"))
        #expect(OpenClawReferenceProviderCatalog.metadataEntries(withCapability: .embedding).map(\.providerID) == ["voyage"])
        #expect(OpenClawReferenceProviderCatalog.capabilityProviderIDs[.embedding]?.contains("gemini") == true)
        #expect(OpenClawReferenceProviderCatalog.capabilityProviderIDs[.webContentExtraction] == ["readability"])
        #expect(OpenClawReferenceProviderCatalog.capabilityProviderIDs[.documentExtraction] == ["pdf"])
    }

    @Test
    func metadataEntriesCoverNewCapabilityProviders() throws {
        let catalog = OpenClawReferenceProviderCatalog.self
        let azure = try #require(catalog.metadataEntry(for: "azure"))
        #expect(azure.providerID == "azure-speech")
        #expect(azure.authEnvVars.first == "AZURE_SPEECH_KEY")
        #expect(catalog.metadataEntry(for: "fish-audio")?.pluginID == "fish-audio-speech")
        #expect(catalog.metadataEntry(for: "pixverse")?.capabilities == [.videoGeneration])
        #expect(catalog.metadataEntry(for: "parallel-free")?.providerID == "parallel")
        #expect(catalog.metadataEntry(for: "edge")?.providerID == "microsoft")
        #expect(catalog.metadataEntry(for: "pdf")?.capabilities == [.documentExtraction])
        #expect(catalog.metadataEntry(for: "readability")?.capabilities == [.webContentExtraction])
        #expect(catalog.metadataEntry(for: "comfy")?.authEnvVars == ["COMFY_API_KEY", "COMFY_CLOUD_API_KEY"])
        #expect(catalog.metadataEntry(for: "runway")?.authEnvVars == ["RUNWAYML_API_SECRET", "RUNWAY_API_KEY"])
        #expect(catalog.metadataEntry(for: "comfy")?.distribution == .officialExternal)
        let appleSpeech = try #require(catalog.metadataEntry(for: "apple-speech"))
        #expect(appleSpeech.nativeRuntimeAvailable)
        #expect(appleSpeech.sdkLocal)
        #expect(catalog.providerMetadataEntries.filter { !$0.sdkLocal }.allSatisfy { !$0.nativeRuntimeAvailable })
    }

    @Test
    func authMetadataMatchesUpstreamManifests() throws {
        let catalog = OpenClawReferenceProviderCatalog.self
        let openAI = try #require(catalog.entry(for: "openai"))
        #expect(openAI.authEnvVars == ["OPENAI_API_KEY"])
        #expect(openAI.usageAuthEnvVars == ["OPENAI_ADMIN_KEY"])
        #expect(openAI.authMethods == ["oauth", "device-code", "api-key"])
        #expect(openAI.discovery == .runtime)
        #expect(openAI.docsPath == "/providers/openai")
        #expect(catalog.entry(for: "github-copilot")?.authEnvVars == ["COPILOT_GITHUB_TOKEN"])
        #expect(catalog.entry(for: "zai")?.authEnvVars == ["ZAI_API_KEY", "Z_AI_API_KEY"])
        #expect(catalog.entry(for: "apple-fm")?.authMethods == ["local"])
        #expect(catalog.entry(for: "apple-fm")?.authEnvVars.isEmpty == true)
        #expect(catalog.entry(for: "amazon-bedrock")?.authEnvVars.isEmpty == true)
        #expect(catalog.entry(for: "volcengine")?.auxiliaryAuthEnvVars["volcengine-tts"]?.first == "VOLCENGINE_TTS_API_KEY")
        #expect(catalog.entry(for: "kimi")?.discovery == .static)
        #expect(catalog.entry(for: "mistral")?.distribution == .officialExternal)
        #expect(catalog.entry(for: "openai")?.distribution == .bundled)
        #expect(catalog.entry(for: "qwen-portal")?.status == .deprecated)
        #expect(catalog.entry(for: "qwen-portal")?.replacedBy == "qwen")
        #expect(catalog.entry(for: "google-antigravity")?.status == .deprecated)
        #expect(catalog.entry(for: "openai-compatible")?.sdkLocal == true)
        #expect(catalog.entry(for: "local")?.sdkLocal == true)
    }

    @Test
    func mediaUnderstandingMetadataOrdersCandidatesByPriority() throws {
        let catalog = OpenClawReferenceProviderCatalog.self
        let google = try #require(catalog.mediaUnderstandingMetadata(for: "gemini"))
        #expect(google.capabilities == [.image, .audio, .video])
        #expect(google.defaultModels[.video] == "gemini-3-flash-preview")
        #expect(google.autoPriority[.video] == 10)
        #expect(google.nativeDocumentInputs == ["pdf"])
        #expect(catalog.mediaUnderstandingMetadata(for: "minimax")?.documentModels["pdf"]?.textExtraction == "MiniMax-M2.7")

        let video = catalog.mediaUnderstandingCandidates(for: .video).map(\.providerID)
        #expect(video.first == "google")
        #expect(video.contains("qwen"))

        let audio = catalog.mediaUnderstandingCandidates(for: .audio, availableProviderIDs: ["groq", "deepgram", "mistral"])
        #expect(audio.map(\.providerID) == ["groq", "deepgram", "mistral"])

        let manual = catalog.mediaUnderstandingCandidates(for: .image, availableProviderIDs: ["opencode"], includeManualOnly: true)
        #expect(manual.map(\.providerID) == ["opencode"])
        #expect(catalog.mediaUnderstandingCandidates(for: .image, availableProviderIDs: ["opencode"]).isEmpty)
    }
}
