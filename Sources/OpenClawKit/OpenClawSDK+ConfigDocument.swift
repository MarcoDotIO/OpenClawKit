import Foundation

extension OpenClawSDK {
    /// Loads an upstream `openclaw.json` (JSON or JSON5) as an ``OpenClawConfigDocument``.
    ///
    /// The SDK-native config (``loadConfig(from:cacheTTLms:)``) and the upstream document are separate
    /// files; use this for the file an OpenClaw gateway loads.
    /// - Parameter url: Config file URL; defaults to `OPENCLAW_CONFIG_PATH` or `~/.openclaw/openclaw.json`.
    /// - Returns: The loaded document with its hash, issues and migration changes.
    public func loadGatewayConfigDocument(
        from url: URL? = nil
    ) async throws -> OpenClawConfigDocumentStore.LoadedConfigDocument {
        let store = OpenClawConfigDocumentStore(fileURL: url)
        return try await store.load()
    }

    /// Imports an upstream `openclaw.json` into an SDK-native ``OpenClawConfig``.
    /// - Parameters:
    ///   - url: `openclaw.json` URL.
    ///   - base: SDK-native values used where the document has no equivalent.
    /// - Returns: The imported config and every decode, migration and mapping issue.
    public func importConfig(
        fromOpenClawJSON url: URL,
        base: OpenClawConfig = OpenClawConfig()
    ) async throws -> (config: OpenClawConfig, issues: [ConfigDecodeIssue]) {
        let loaded = try await OpenClawConfigDocumentStore(fileURL: url).load()
        let collector = ConfigDecodeIssueCollector()
        let config = OpenClawConfig(document: loaded.document, base: base, issues: collector)
        return (config, loaded.issues + loaded.legacyIssues + collector.issues)
    }
}

extension GatewayChannelActor: ConfigRPCRequestSending {}
