import Foundation
import Testing
@testable import OpenClawKit

@Suite("Plugin system")
struct PluginSystemTests {
    actor TestService: PluginService {
        let id = "svc.test"
        private(set) var started = false
        private(set) var stopped = false

        func start() async throws {
            self.started = true
        }

        func stop() async {
            self.stopped = true
        }
    }

    struct TestPlugin: OpenClawPlugin {
        let id = "plugin.test"
        let service: TestService

        func register(api: PluginAPI) async throws {
            await api.registerToolName(pluginID: self.id, toolName: "echo")
            await api.registerHook(.gatewayStart) { payload in
                PluginHookResult(metadata: ["runID": AnyCodable(payload.runID ?? "")])
            }
            await api.registerGatewayMethod("plugin.echo") { params in
                params["value"] ?? AnyCodable("missing")
            }
            await api.registerService(self.service)
        }
    }

    @Test
    func pluginRegistersToolsHooksMethodsAndServices() async throws {
        let registry = PluginRegistry()
        let service = TestService()
        let plugin = TestPlugin(service: service)
        try await registry.load(plugin: plugin)

        #expect(await registry.contains(id: "plugin.test"))
        #expect(await registry.toolNames(pluginID: "plugin.test") == ["echo"])

        let hookResults = try await registry.emitHook(
            .gatewayStart,
            payload: PluginHookPayload(runID: "run-1", sessionKey: "main")
        )
        #expect(hookResults.count == 1)

        let methodResult = try await registry.invokeGatewayMethod(
            "plugin.echo",
            params: ["value": AnyCodable("ok")]
        )
        #expect(methodResult == AnyCodable("ok"))

        try await registry.startServices()
        #expect(await service.started == true)
        await registry.stopServices()
        #expect(await service.stopped == true)
    }
}
