import Testing
@testable import OpenClawCore
@testable import OpenClawModels

@Suite("Provider catalog generated data")
struct ProviderCatalogGeneratedDataTests {
    @Test
    func embeddedDocumentDecodesAndMatchesTheReferenceCommit() {
        let store = ProviderCatalogStore.shared
        #expect(store.decodeError == nil)
        #expect(store.schemaVersion == 1)
        #expect(ProviderCatalogGeneratedData.sourceCommit == OpenClawReferenceProviderCatalog.referenceCommit)
        #expect(ProviderCatalogGeneratedData.sourceVersion == OpenClawReferenceProviderCatalog.referenceVersion)
        #expect(store.sourceCommit == OpenClawReferenceProviderCatalog.referenceCommit)
        #expect(store.generatedAt == OpenClawReferenceProviderCatalog.referenceGeneratedAt)
    }

    @Test
    func catalogCoversUpstreamProvidersAndModelRows() {
        let entries = OpenClawReferenceProviderCatalog.entries
        #expect(entries.count >= 70)
        #expect(entries.reduce(0) { $0 + $1.models.count } >= 350)
        #expect(Set(entries.map(\.providerID)).count == entries.count)
        #expect(OpenClawReferenceProviderCatalog.providerMetadataEntries.count >= 27)
        #expect(OpenClawReferenceProviderCatalog.suppressions.count >= 100)
    }

    @Test
    func everyEntryIsInternallyConsistent() {
        for entry in OpenClawReferenceProviderCatalog.entries {
            #expect(entry.capabilities.first == .text, "\(entry.providerID)")
            #expect(!entry.config.baseURL.isEmpty, "\(entry.providerID)")
            #expect(entry.config.api != nil, "\(entry.providerID)")
            #expect(entry.config.models.count == entry.models.count, "\(entry.providerID)")
            if let defaultModelID = entry.defaultModelID {
                #expect(entry.config.defaultModel?.id == defaultModelID, "\(entry.providerID)")
                #expect(entry.catalog.model(id: defaultModelID) != nil, "\(entry.providerID)")
            } else {
                #expect(entry.requiresDiscovery, "\(entry.providerID)")
            }
            if let utility = entry.defaultUtilityModelID {
                #expect(entry.catalog.model(id: utility) != nil, "\(entry.providerID)")
            }
            for alias in entry.aliases {
                #expect(OpenClawReferenceProviderCatalog.normalize(providerID: alias) == entry.providerID, "\(alias)")
                #expect(OpenClawReferenceProviderCatalog.entry(for: alias)?.providerID == entry.providerID, "\(alias)")
            }
            if entry.status == .deprecated {
                #expect(entry.replacedBy.flatMap(OpenClawReferenceProviderCatalog.entry(for:)) != nil, "\(entry.providerID)")
            }
        }
    }

    @Test
    func fallbackEntriesStayUsableWhenTheDocumentCannotBeDecoded() {
        let store = ProviderCatalogStore(json: "{ not json")
        #expect(store.decodeError != nil)
        #expect(store.entries.map(\.providerID) == ["openai-compatible", "apple-fm", "local"])
        #expect(store.aliases["foundation"]?.provider == "apple-fm")
    }

    @Test
    func configModelsListTheDefaultModelFirstAndKeepEveryRow() throws {
        let openAI = try #require(OpenClawReferenceProviderCatalog.entry(for: "openai"))
        #expect(openAI.config.models.first?.id == "gpt-6-astra")
        #expect(openAI.config.models.map(\.id).contains("gpt-5.4-nano"))
        #expect(openAI.defaultUtilityModelID == "gpt-5.6-luna")

        let google = try #require(OpenClawReferenceProviderCatalog.entry(for: "google"))
        #expect(google.config.models.first?.id == "gemini-3.1-pro-preview")
        #expect(google.config.models.count == 10)
        #expect(google.config.models.allSatisfy { $0.contextWindow == 1_048_576 && $0.maxTokens == 65_536 })
    }
}
