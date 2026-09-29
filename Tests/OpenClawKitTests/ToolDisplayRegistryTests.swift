import OpenClawKit
import Foundation
import Testing

@Suite struct ToolDisplayRegistryTests {
    @Test func resolvesKnownToolFromConfig() {
        let summary = ToolDisplayRegistry.resolve(name: "exec", args: nil)
        #expect(summary.emoji == "🛠️")
        #expect(summary.title == "Exec")
    }

    @Test func sdkRuntimeToolsHaveDisplayEntries() {
        let spotlight = ToolDisplayRegistry.resolve(name: "spotlight_search", args: AnyCodable(["query": AnyCodable("q3 plan")]))
        #expect(spotlight.title == "Spotlight")
        #expect(spotlight.detail == "q3 plan")
        let automations = ToolDisplayRegistry.resolve(name: "automations", args: AnyCodable(["action": AnyCodable("list")]))
        #expect(automations.title == "Cron")
        #expect(automations.verb == "list")
        let search = ToolDisplayRegistry.resolve(name: "memory_search", args: AnyCodable(["query": AnyCodable("deploy")]))
        #expect(search.title == "Memory Search")
        #expect(search.detail == "deploy")
        let get = ToolDisplayRegistry.resolve(name: "memory_get", args: AnyCodable(["path": AnyCodable("MEMORY.md")]))
        #expect(get.title == "Memory Get")
        #expect(get.detail == "MEMORY.md")
    }
}
