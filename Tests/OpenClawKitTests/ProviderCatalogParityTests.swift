import Testing
@testable import OpenClawModels

@Suite("Provider catalog parity")
struct ProviderCatalogParityTests {
    @Test
    func providerCatalogReferenceCommitMatchesFixture() {
        #expect(OpenClawReferenceProviderCatalog.referenceCommit == ProviderCatalogReferenceFixture.referenceCommit)
        #expect(OpenClawReferenceProviderCatalog.generatedSourceCommit == OpenClawReferenceProviderCatalog.referenceCommit)
    }

    @Test
    func providerCatalogSnapshotMatchesFixture() {
        let expected = ProviderCatalogReferenceFixture.entries
        let actual = OpenClawReferenceProviderCatalog.entries.map { entry in
            ProviderCatalogSnapshotEntry(
                providerID: entry.providerID,
                auth: entry.config.auth,
                api: entry.config.defaultModel?.api ?? entry.config.api ?? .openAICompletions,
                baseURL: entry.config.baseURL,
                defaultModelID: entry.config.defaultModel?.id ?? "",
                capabilities: entry.capabilities
            )
        }

        #expect(actual.map(\.providerID) == expected.map(\.providerID))
        for (actualEntry, expectedEntry) in zip(actual, expected) {
            #expect(actualEntry == expectedEntry, "\(expectedEntry.providerID)")
        }
    }

    @Test
    func providerMetadataCoversNonTextPluginCapabilities() {
        let metadata = Dictionary(
            uniqueKeysWithValues: OpenClawReferenceProviderCatalog.providerMetadataEntries.map { entry in
                (entry.providerID, entry)
            }
        )

        #expect(metadata["fal"]?.capabilities.contains(.imageGeneration) == true)
        #expect(metadata["fal"]?.capabilities.contains(.musicGeneration) == true)
        #expect(metadata["runway"]?.capabilities.contains(.videoGeneration) == true)
        #expect(metadata["elevenlabs"]?.capabilities.contains(.speech) == true)
        #expect(metadata["elevenlabs"]?.capabilities.contains(.mediaUnderstanding) == true)
        #expect(metadata["voyage"]?.capabilities.contains(.embedding) == true)
        #expect(metadata["firecrawl"]?.capabilities.contains(.webSearch) == true)
        #expect(metadata["firecrawl"]?.capabilities.contains(.webFetch) == true)
        #expect(metadata["firecrawl"]?.aliases == ["firecrawl-free"])
        #expect(metadata["fal"]?.nativeRuntimeAvailable == false)
        #expect(OpenClawReferenceProviderCatalog.entry(for: "tencent")?.providerID == "tencent-tokenhub")
    }
}
