import Foundation
import Testing
import OpenClawProtocol
@testable import OpenClawAgents

@Suite("Core tool catalog and policy")
struct CoreToolCatalogPolicyTests {
    private struct Fixture: Decodable {
        struct Section: Decodable {
            let id: String
            let label: String
        }

        struct Tool: Decodable {
            let id: String
            let section: String
            let profiles: [String]
            let openclawGroup: Bool
        }

        let commit: String
        let sections: [Section]
        let tools: [Tool]
    }

    private func fixture() throws -> Fixture {
        try JSONDecoder().decode(Fixture.self, from: Data(UpstreamToolCatalogFixture.json.utf8))
    }

    @Test
    func catalogMatchesUpstreamFixture() throws {
        let fixture = try self.fixture()
        #expect(CoreToolCatalog.sections.map(\.id) == fixture.sections.map(\.id))
        #expect(CoreToolCatalog.sections.map(\.label) == fixture.sections.map(\.label))
        #expect(CoreToolCatalog.definitions.map(\.id) == fixture.tools.map(\.id))
        for tool in fixture.tools {
            let definition = try #require(CoreToolCatalog.definition(for: tool.id))
            #expect(definition.sectionID == tool.section, "section of \(tool.id)")
            #expect(definition.profiles.map(\.rawValue) == tool.profiles, "profiles of \(tool.id)")
            #expect(definition.includeInOpenClawGroup == tool.openclawGroup, "group:openclaw of \(tool.id)")
        }
    }

    @Test
    func profilesAndGroupsExpandLikeUpstream() {
        #expect(CoreToolCatalog.profileAllowList(.minimal) == ["session_status", "gateway"])
        #expect(CoreToolCatalog.profileAllowList(.full) == ["*"])
        #expect(CoreToolCatalog.profileAllowList(.coding)?.last == "bundle-mcp")
        #expect(CoreToolCatalog.profileAllowList("custom") == nil)
        #expect(CoreToolCatalog.groups["group:fs"] == ["ls", "read", "write", "edit", "apply_patch"])
        #expect(CoreToolCatalog.groups["group:openclaw"]?.contains("read") == false)
        #expect(CoreToolCatalog.groups["group:openclaw"]?.contains("ask_user") == true)
        #expect(CoreToolCatalog.expandGroups(["group:memory", "Bash", "cron", "image"]) == ["memory_search", "memory_get", "exec", "automations", "view_image"])
        #expect(CoreToolCatalog.definition(for: "cron")?.id == "automations")
        #expect(CoreToolCatalog.isKnownCoreTool("update_plan") == false)
        let visible = CoreToolCatalog.visibleSections().flatMap(\.tools).map(\.id)
        #expect(visible.contains("agents_wait") == false)
        #expect(visible.contains("github_publish") == false)
        #expect(CoreToolCatalog.visibleSections(swarmEnabled: true, githubPublicationAvailable: true).flatMap(\.tools).map(\.id).contains("github_publish"))
    }

    @Test
    func policyMatcherRules() {
        #expect(ToolPolicy().allows("anything"))
        #expect(ToolPolicy(deny: ["exec"]).allows("bash") == false)
        #expect(ToolPolicy(allow: ["read", "write"]).allows("apply_patch"))
        #expect(ToolPolicy(allow: ["read"]).allows("apply_patch") == false)
        #expect(ToolPolicy(allow: ["group:fs"], deny: ["write"]).allows("write") == false)
        #expect(ToolPolicy(allow: ["sessions_*"]).allows("sessions_list"))
        #expect(ToolPolicy(allow: ["sessions_*"]).allows("session_status") == false)
        #expect(ToolPolicy(profile: .minimal).allows("read") == false)
        #expect(ToolPolicy(profile: .minimal, alsoAllow: ["read"]).allows("read"))
        #expect(ToolPolicy(profile: .full).allows("custom_client_tool"))
        #expect(ToolPolicy(allow: ["image"]).allows("view_image"))

        let mcp = AgentToolSource.mcp(server: "docs", toolName: "search")
        #expect(ToolPolicy(profile: .coding).allows("docs__search", source: mcp))
        #expect(ToolPolicy(profile: .minimal).allows("docs__search", source: mcp) == false)
        #expect(ToolPolicy(deny: ["bundle-mcp"]).allows("docs__search", source: mcp) == false)
        #expect(ToolPolicy(deny: ["group:plugins"]).allows("docs__search", source: mcp) == false)
        #expect(ToolPolicy(deny: ["docs__*"]).allows("docs__search", source: mcp) == false)
        #expect(ToolPolicy(deny: ["docs__*"]).allows("wiki__search", source: .mcp(server: "wiki", toolName: "search")))
        #expect(ToolPolicy(deny: ["group:plugins"]).allows("plug", source: .plugin(id: "p")) == false)
        #expect(ToolPolicy(allow: ["group:plugins"]).allows("plug", source: .plugin(id: "p")))
    }

    @Test
    func policyDecodesTolerantly() throws {
        let json = #"{"profile":"coding","allow":"read","deny":["exec"],"unknown":true}"#
        let policy = try JSONDecoder().decode(ToolPolicy.self, from: Data(json.utf8))
        #expect(policy.profile == .coding)
        #expect(policy.allow == ["read"])
        #expect(policy.deny == ["exec"])
    }

    @Test
    func toolSearchConfigurationResolvesUpstreamShapes() {
        #expect(ToolSearchConfiguration.resolve(nil) == .embeddedDefault)
        #expect(ToolSearchConfiguration.resolve(AnyCodable(false)).enabled == false)
        let shorthand = ToolSearchConfiguration.resolve(AnyCodable(true))
        #expect(shorthand.enabled && shorthand.mode == .tools)
        let raw: [String: AnyCodable] = ["mode": AnyCodable("directory"), "maxSearchLimit": AnyCodable(90), "searchDefaultLimit": AnyCodable(70)]
        let object = ToolSearchConfiguration.resolve(AnyCodable(raw))
        #expect(object.mode == .directory)
        #expect(object.maxSearchLimit == 50)
        #expect(object.searchDefaultLimit == 50)
    }
}
