import Foundation

/// Media kind a media-understanding provider can describe.
public enum MediaUnderstandingKind: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// Still images.
    case image
    /// Audio (transcription).
    case audio
    /// Video.
    case video
}

/// Document handling declared by a media-understanding provider (upstream `documentModels.<kind>`).
public struct MediaUnderstandingDocumentModel: Codable, Sendable, Equatable {
    /// Model used to extract text from the document.
    public var textExtraction: String?
    /// Whether document pages are sent as images.
    public var image: Bool?

    /// Creates document handling metadata.
    public init(textExtraction: String? = nil, image: Bool? = nil) {
        self.textExtraction = textExtraction
        self.image = image
    }
}

/// Media-understanding metadata for one provider (upstream `mediaUnderstandingProviderMetadata`).
///
/// OpenClawMedia (or a host) can use this to pick an image, audio or video describer among providers the host has
/// credentials for: lower ``autoPriority`` values win.
public struct MediaUnderstandingProviderMetadata: Decodable, Sendable, Equatable {
    /// Provider id the metadata belongs to.
    public var providerID: String
    /// Owning upstream plugin id.
    public var pluginID: String?
    /// Media kinds the provider can describe.
    public var capabilities: [MediaUnderstandingKind]
    /// Default model per media kind.
    public var defaultModels: [MediaUnderstandingKind: String]
    /// Automatic selection priority per media kind (lower wins; kinds without a priority are never auto-selected).
    public var autoPriority: [MediaUnderstandingKind: Int]
    /// Document types the provider accepts natively (for example `pdf`).
    public var nativeDocumentInputs: [String]
    /// Document handling keyed by document type.
    public var documentModels: [String: MediaUnderstandingDocumentModel]

    /// Creates media-understanding metadata.
    public init(
        providerID: String,
        pluginID: String? = nil,
        capabilities: [MediaUnderstandingKind],
        defaultModels: [MediaUnderstandingKind: String] = [:],
        autoPriority: [MediaUnderstandingKind: Int] = [:],
        nativeDocumentInputs: [String] = [],
        documentModels: [String: MediaUnderstandingDocumentModel] = [:]
    ) {
        self.providerID = providerID
        self.pluginID = pluginID
        self.capabilities = capabilities
        self.defaultModels = defaultModels
        self.autoPriority = autoPriority
        self.nativeDocumentInputs = nativeDocumentInputs
        self.documentModels = documentModels
    }

    private enum CodingKeys: String, CodingKey {
        case providerID = "providerId"
        case pluginID = "pluginId"
        case capabilities
        case defaultModels
        case autoPriority
        case nativeDocumentInputs
        case documentModels
    }

    /// Decodes metadata leniently, dropping unknown media kinds.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.providerID = (try? container.decodeIfPresent(String.self, forKey: .providerID)) ?? ""
        self.pluginID = try? container.decodeIfPresent(String.self, forKey: .pluginID)
        let rawCapabilities = (try? container.decodeIfPresent([String].self, forKey: .capabilities)) ?? []
        self.capabilities = rawCapabilities.compactMap(MediaUnderstandingKind.init(rawValue:))
        let rawDefaults = (try? container.decodeIfPresent([String: String].self, forKey: .defaultModels)) ?? [:]
        self.defaultModels = Self.keyed(rawDefaults)
        let rawPriority = (try? container.decodeIfPresent([String: Int].self, forKey: .autoPriority)) ?? [:]
        self.autoPriority = Self.keyed(rawPriority)
        self.nativeDocumentInputs = (try? container.decodeIfPresent([String].self, forKey: .nativeDocumentInputs)) ?? []
        self.documentModels = (try? container.decodeIfPresent([String: MediaUnderstandingDocumentModel].self, forKey: .documentModels))
            ?? [:]
    }

    /// Returns whether the provider can describe a media kind.
    public func supports(_ kind: MediaUnderstandingKind) -> Bool {
        self.capabilities.contains(kind)
    }

    private static func keyed<Value>(_ raw: [String: Value]) -> [MediaUnderstandingKind: Value] {
        raw.reduce(into: [:]) { partial, pair in
            if let kind = MediaUnderstandingKind(rawValue: pair.key) {
                partial[kind] = pair.value
            }
        }
    }
}

extension OpenClawReferenceProviderCatalog {
    /// Media-understanding metadata keyed by provider id.
    public static var mediaUnderstandingMetadata: [String: MediaUnderstandingProviderMetadata] {
        ProviderCatalogStore.shared.mediaUnderstanding
    }

    /// Returns media-understanding metadata for a provider id or alias.
    public static func mediaUnderstandingMetadata(for providerID: String) -> MediaUnderstandingProviderMetadata? {
        let written = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let store = ProviderCatalogStore.shared
        return store.mediaUnderstanding[written] ?? store.mediaUnderstanding[self.normalize(providerID: written)]
    }

    /// Providers that can describe a media kind, ordered by automatic priority (lower first).
    /// - Parameters:
    ///   - kind: Media kind.
    ///   - availableProviderIDs: When set, only these providers (for example those the host has credentials for).
    ///   - includeManualOnly: Whether providers without an auto priority are included (after prioritized ones).
    /// - Returns: Matching metadata, best candidate first.
    public static func mediaUnderstandingCandidates(
        for kind: MediaUnderstandingKind,
        availableProviderIDs: Set<String>? = nil,
        includeManualOnly: Bool = false
    ) -> [MediaUnderstandingProviderMetadata] {
        let available = availableProviderIDs.map { Set($0.map { self.normalize(providerID: $0) }) }
        return ProviderCatalogStore.shared.mediaUnderstanding.values
            .filter { metadata in
                metadata.supports(kind)
                    && (includeManualOnly || metadata.autoPriority[kind] != nil)
                    && (available?.contains(self.normalize(providerID: metadata.providerID)) ?? true)
            }
            .sorted { lhs, rhs in
                let lhsPriority = lhs.autoPriority[kind] ?? Int.max
                let rhsPriority = rhs.autoPriority[kind] ?? Int.max
                return lhsPriority == rhsPriority ? lhs.providerID < rhs.providerID : lhsPriority < rhsPriority
            }
    }
}
