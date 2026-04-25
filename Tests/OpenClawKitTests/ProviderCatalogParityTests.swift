import Testing
@testable import OpenClawModels

@Suite("Provider catalog parity")
struct ProviderCatalogParityTests {
    @Test
    func providerCatalogReferenceCommitMatchesFixture() {
        #expect(OpenClawReferenceProviderCatalog.referenceCommit == ProviderCatalogReferenceFixture.referenceCommit)
    }

    @Test
    func providerCatalogSnapshotMatchesFixture() {
        let expected = Dictionary(
            uniqueKeysWithValues: ProviderCatalogReferenceFixture.entries.map { entry in
                (entry.providerID, entry)
            }
        )
        let actual = Dictionary(
            uniqueKeysWithValues: OpenClawReferenceProviderCatalog.entries.map { entry in
                (
                    entry.providerID,
                    ProviderCatalogSnapshotEntry(
                        providerID: entry.providerID,
                        auth: entry.config.auth,
                        api: entry.config.defaultModel?.api ?? entry.config.api ?? .openAICompletions,
                        baseURL: entry.config.baseURL,
                        defaultModelID: entry.config.defaultModel?.id ?? "",
                        capabilities: entry.capabilities
                    )
                )
            }
        )

        #expect(actual == expected)
    }

    @Test
    func providerMetadataCoversNonTextPluginCapabilities() {
        let metadata = Dictionary(
            uniqueKeysWithValues: OpenClawReferenceProviderCatalog.providerMetadataEntries.map { entry in
                (entry.providerID, entry)
            }
        )

        #expect(metadata["fal"]?.capabilities.contains(.imageGeneration) == true)
        #expect(metadata["runway"]?.capabilities.contains(.videoGeneration) == true)
        #expect(metadata["elevenlabs"]?.capabilities.contains(.speech) == true)
        #expect(metadata["voyage"]?.capabilities.contains(.memoryEmbedding) == true)
        #expect(metadata["firecrawl"]?.capabilities.contains(.webSearch) == true)
        #expect(metadata["fal"]?.nativeRuntimeAvailable == false)
        #expect(OpenClawReferenceProviderCatalog.entry(for: "tencent")?.providerID == "tencent-tokenhub")
    }
}
