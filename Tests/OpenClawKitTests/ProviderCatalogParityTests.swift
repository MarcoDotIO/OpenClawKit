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
                        defaultModelID: entry.config.defaultModel?.id ?? ""
                    )
                )
            }
        )

        #expect(actual == expected)
    }
}
