import Foundation
import OpenClawAgents
import OpenClawCore

/// Convenience registration for the memory tools and the Apple system search tool.
public enum MemoryToolRegistration {
    /// Registers `memory_search` and `memory_get` for an engine.
    /// - Parameters:
    ///   - registry: Tool registry.
    ///   - engine: Memory engine.
    ///   - configuration: Engine settings.
    ///   - sessionSearch: Optional session transcript search.
    public static func registerMemoryTools(
        into registry: AgentToolRegistry,
        engine: MemoryEngine,
        configuration: MemoryEngineConfiguration = MemoryEngineConfiguration(),
        sessionSearch: (any MemorySessionSearching)? = nil
    ) async {
        await registry.register(MemorySearchTool(engine: engine, configuration: configuration, sessionSearch: sessionSearch))
        await registry.register(MemoryGetTool(engine: engine, configuration: configuration))
    }

    /// Registers `spotlight_search` when the platform supports it (iOS, macOS and visionOS 27+ on Apple silicon).
    ///
    /// Apps must opt in: Spotlight results can include the user's personal data. The default searches
    /// the app's own CoreSpotlight items only; pass `includeSystemFiles: true` to also search files.
    /// - Parameters:
    ///   - registry: Tool registry.
    ///   - includeSystemFiles: Also search the user's files.
    /// - Returns: `true` when the tool was registered.
    @discardableResult
    public static func registerSpotlightSearch(into registry: AgentToolRegistry, includeSystemFiles: Bool = false) async -> Bool {
        #if compiler(>=6.4) && canImport(CoreSpotlight) && canImport(FoundationModels) && !os(tvOS) && !os(watchOS) && arch(arm64)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            let tool = includeSystemFiles
                ? SpotlightSearchAgentTool(fetchAttributes: [.title, .textContent, .path], includeFiles: true)
                : SpotlightSearchAgentTool()
            await registry.register(tool)
            return true
        }
        #endif
        return false
    }
}
