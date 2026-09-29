import Foundation
import OpenClawProtocol

/// Tool Search exposure mode (upstream `ToolSearchMode`).
public enum ToolSearchMode: String, Codable, Sendable, Equatable, CaseIterable {
    /// Code-mode search (`tool_search_code`). The Swift runtime has no isolated code child, so this
    /// falls back to ``tools``.
    case code
    /// Structured `tool_search` / `tool_describe` / `tool_call` control tools.
    case tools
    /// Structured control tools plus a cache-stable prompt directory of trusted tool names.
    case directory
}

/// Resolved Tool Search configuration (upstream `resolveToolSearchConfig`, SDK-adapted).
///
/// Wire/config shape: `false` disables; `true` or an object without `mode` requests `code` (which
/// resolves to `tools` here); an unset value is the upstream embedded default `{enabled: true,
/// mode: "tools"}`. Limits: `searchDefaultLimit` defaults to 8 (clamped to `maxSearchLimit`),
/// `maxSearchLimit` defaults to 20 (clamped to `1...50`). ``minCatalogSize`` is an SDK addition:
/// below it, tools keep their direct schemas.
public struct ToolSearchConfiguration: Codable, Sendable, Equatable {
    /// Upper bound of results in one model-visible response (upstream `MAX_TOOL_SEARCH_RESULTS`).
    public static let maxResults = 50
    /// Maximum queries in one batch (upstream `MAX_TOOL_SEARCH_BATCH_QUERIES`).
    public static let maxBatchQueries = 16
    /// Maximum graphemes per batch query.
    public static let maxBatchQueryGraphemes = 512
    /// Maximum total UTF-8 bytes of batch queries.
    public static let maxBatchQueryBytes = 512
    /// Maximum characters of a batch response.
    public static let maxBatchResponseChars = 4_000
    /// Maximum characters of the directory prompt section.
    public static let maxDirectoryChars = 18_000

    /// Whether Tool Search is enabled.
    public var enabled: Bool
    /// Effective mode (never `code`).
    public var mode: ToolSearchMode
    /// Default result limit.
    public var searchDefaultLimit: Int
    /// Maximum result limit.
    public var maxSearchLimit: Int
    /// Minimum catalog size before tools move behind search (SDK addition).
    public var minCatalogSize: Int

    /// Upstream default for embedded runs: enabled, `tools` mode.
    public static let embeddedDefault = ToolSearchConfiguration()

    /// Creates a configuration.
    /// - Parameters:
    ///   - enabled: Whether Tool Search is enabled.
    ///   - mode: Requested mode (`code` resolves to `tools`).
    ///   - searchDefaultLimit: Default result limit.
    ///   - maxSearchLimit: Maximum result limit.
    ///   - minCatalogSize: Minimum catalog size before tools move behind search.
    public init(
        enabled: Bool = true,
        mode: ToolSearchMode = .tools,
        searchDefaultLimit: Int = 8,
        maxSearchLimit: Int = 20,
        minCatalogSize: Int = 12
    ) {
        let maxLimit = Swift.max(1, Swift.min(Self.maxResults, maxSearchLimit))
        self.enabled = enabled
        self.mode = mode == .code ? .tools : mode
        self.maxSearchLimit = maxLimit
        self.searchDefaultLimit = Swift.max(1, Swift.min(maxLimit, searchDefaultLimit))
        self.minCatalogSize = Swift.max(0, minCatalogSize)
    }

    /// Resolves a raw config value (`true`, `false`, object, or `nil`).
    /// - Parameter raw: Raw `tools.toolSearch` value.
    /// - Returns: The resolved configuration.
    public static func resolve(_ raw: AnyCodable?) -> ToolSearchConfiguration {
        guard let raw, !raw.isNull else {
            return .embeddedDefault
        }
        if let flag = raw.boolValue {
            return ToolSearchConfiguration(enabled: flag, mode: .code)
        }
        guard let object = raw.dictionaryValue else {
            return ToolSearchConfiguration(enabled: false)
        }
        let configured = object.keys.contains { $0 != "enabled" }
        let mode = object["mode"]?.stringValue.flatMap(ToolSearchMode.init(rawValue:)) ?? .code
        func positive(_ key: String) -> Int? {
            guard let value = object[key]?.intValue, value > 0 else { return nil }
            return value
        }
        return ToolSearchConfiguration(
            enabled: object["enabled"]?.boolValue ?? configured,
            mode: mode,
            searchDefaultLimit: positive("searchDefaultLimit") ?? 8,
            maxSearchLimit: positive("maxSearchLimit") ?? 20,
            minCatalogSize: object["minCatalogSize"]?.intValue ?? 12
        )
    }
}
