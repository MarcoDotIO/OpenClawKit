import Foundation
import Testing
import OpenClawCore
import OpenClawGateway
import OpenClawProtocol
@testable import OpenClawPlugins

@Suite("Plugin change events", .timeLimit(.minutes(1)))
struct PluginChangeEventTests {
    struct QuietPlugin: OpenClawPlugin {
        let id: String
        func register(api _: PluginAPI) async throws {}
    }

    actor Generations {
        private(set) var values: [Int] = []
        func append(_ value: Int) { self.values.append(value) }
    }

    @Test
    func listenersSeeEveryPluginSetChange() async throws {
        let registry = PluginRegistry()
        let seen = Generations()
        let token = await registry.addChangeListener { generation in await seen.append(generation) }
        try await registry.load(plugin: QuietPlugin(id: "a"))
        try await registry.setEnabled(false, for: "a")
        try await registry.setEnabled(false, for: "a")
        await registry.unload(pluginID: "a")
        #expect(await seen.values == [1, 2, 3])
        await registry.removeChangeListener(token)
        try await registry.load(plugin: QuietPlugin(id: "b"))
        #expect(await seen.values == [1, 2, 3])
        #expect(await registry.catalogGeneration == 4)
    }

    @Test
    func attachedGatewayBroadcastsPluginsChanged() async throws {
        let root = try RuntimeExtTestSupport.temporaryDirectory("plugins-changed")
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = PluginRegistry()
        try await registry.load(plugin: QuietPlugin(id: "acme"))
        let server = RuntimeExtTestSupport.makeGatewayServer(root: root)
        await attachPluginRegistry(registry, to: server)
        let events = await server.events()
        try await registry.setEnabled(false, for: "acme")
        var iterator = events.makeAsyncIterator()
        var frame = await iterator.next()
        while let current = frame, current.event != GatewayEventName.pluginsChanged.rawValue {
            frame = await iterator.next()
        }
        #expect(frame?.payload?.dictionaryValue?["generation"]?.intValue == 2)
    }
}
