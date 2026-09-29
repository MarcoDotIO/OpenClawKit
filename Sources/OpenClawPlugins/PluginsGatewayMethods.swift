import Foundation
import OpenClawCore
import OpenClawGateway
import OpenClawProtocol

/// Registers the in-process plugin control methods.
///
/// - `plugins.list {}` → `{generation, plugins, diagnostics: [], mutationAllowed: false}`
/// - `plugins.setEnabled {pluginId, enabled}` → `{ok, plugin, restartRequired: false}`
/// - `hooks.status {agentId?}` → registered hooks with owners and counts (SDK shape)
/// - `plugins.install`, `plugins.uninstall`, `plugins.search`, `plugins.refresh`, `plugins.reload`,
///   `plugins.inspect` and `plugins.catalog.*` → `UNAVAILABLE` (static Swift plugins only)
/// - Parameters:
///   - registrar: Gateway server or registrar.
///   - registry: Plugin registry.
public func registerPluginGatewayMethods(on registrar: some GatewayMethodRegistrar, registry: PluginRegistry) async {
    await registrar.register(method: "plugins.list") { _ in
        let result = PluginsListResult(
            generation: await registry.catalogGeneration,
            plugins: await registry.catalogEntries(),
            diagnostics: [],
            mutationallowed: false
        )
        return try GatewayPayloadCodec.encode(result)
    }
    await registrar.register(method: "plugins.setEnabled") { request in
        let params = try request.decodeParams(PluginsSetEnabledParams.self)
        do {
            try await registry.setEnabled(params.enabled, for: params.pluginid)
        } catch let error as OpenClawCoreError {
            throw GatewayMethodError.invalidRequest(error.localizedDescription)
        }
        guard let entry = await registry.catalogEntries().first(where: { $0.id == params.pluginid }) else {
            throw GatewayMethodError.invalidRequest("Unknown plugin: \(params.pluginid)")
        }
        return try GatewayPayloadCodec.encode(PluginsSetEnabledResult(ok: true, plugin: entry, restartrequired: false))
    }
    await registrar.register(method: "hooks.status") { _ in
        await registry.hooksStatus()
    }
    for method in [
        "plugins.install", "plugins.uninstall", "plugins.search", "plugins.refresh", "plugins.reload", "plugins.inspect",
        "plugins.catalog.browse", "plugins.catalog.categories", "plugins.catalog.get",
    ] {
        await registrar.register(method: method) { request in
            throw GatewayMethodError.unavailable("\(request.method) is not available: the embedded runtime only loads static Swift plugins")
        }
    }
}

/// Attaches a plugin registry to a gateway server: registers the control methods, adds the plugin
/// method resolver, so plugin gateway methods dispatch after core methods (upstream order), and
/// broadcasts `plugins.changed {generation}` whenever the plugin set changes.
/// - Parameters:
///   - registry: Plugin registry.
///   - server: Gateway server.
public func attachPluginRegistry(_ registry: PluginRegistry, to server: GatewayServer) async {
    await registerPluginGatewayMethods(on: server, registry: registry)
    await server.addMethodResolver(registry.gatewayMethodResolver())
    await registry.addChangeListener { [weak server] generation in
        await server?.emit(.pluginsChanged, payload: AnyCodable(["generation": AnyCodable(generation)]))
    }
}
