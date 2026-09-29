import Foundation
import OpenClawMCP
import OpenClawSkills
import Testing
@testable import OpenClawKit

private actor SkillsTestCredentialStore: CredentialStore {
    private var secrets: [String: String] = [:]

    func saveSecret(_ value: String, for key: String) async throws {
        self.secrets[key] = value
    }

    func loadSecret(for key: String) async throws -> String? {
        self.secrets[key]
    }

    func deleteSecret(for key: String) async throws {
        self.secrets[key] = nil
    }
}

@Suite("Skills status client compatibility")
struct SkillsStatusCompatibilityTests {
    @Test
    func clientReportDecodesTheServerSideReport() throws {
        let entry = SkillStatusEntry(
            name: "weather",
            description: "Forecasts",
            source: "workspace",
            bundled: false,
            filePath: "/w/skills/weather/SKILL.md",
            baseDir: "/w/skills/weather",
            skillKey: "weather",
            primaryEnv: "WEATHER_KEY",
            emoji: "🌦️",
            homepage: nil,
            always: false,
            disabled: false,
            blockedByAllowlist: false,
            blockedByAgentFilter: true,
            eligible: false,
            platformIncompatible: false,
            modelVisible: true,
            userInvocable: false,
            commandVisible: true,
            requirements: SkillStatusRequirements(bins: ["curl"], env: ["WEATHER_KEY"]),
            missing: SkillStatusRequirements(env: ["WEATHER_KEY"]),
            configChecks: [SkillRequirementConfigCheck(path: "skills.weather.units", satisfied: true)],
            install: [SkillStatusInstallOption(id: "brew-0", kind: "brew", label: "Install curl", bins: ["curl"])],
            clawhub: ClawHubSkillStatusLink(status: "linked", valid: true, slug: "@acme/weather"))
        let server = SkillStatusReport(
            workspaceDir: "/w",
            managedSkillsDir: "/m",
            agentId: "ops",
            agentSkillFilter: ["weather"],
            skills: [entry])
        let data = try JSONEncoder().encode(server)

        let client = try JSONDecoder().decode(SkillsStatusReport.self, from: data)
        #expect(client.workspaceDir == "/w")
        #expect(client.agentId == "ops")
        #expect(client.agentSkillFilter == ["weather"])
        let skill = try #require(client.skills.first)
        #expect(skill.id == "weather")
        #expect(skill.blockedByAgentFilter == true)
        #expect(skill.modelVisible == true)
        #expect(skill.userInvocable == false)
        #expect(skill.commandVisible == true)
        #expect(skill.requirements.bins == ["curl"])
        #expect(skill.missing.env == ["WEATHER_KEY"])
        #expect(skill.missing.anyBins.isEmpty)
        #expect(skill.install.first?.kind == "brew")
        #expect(skill.clawhub?.slug == "@acme/weather")
    }

    @Test
    func sparseRowsFromOlderGatewaysDecodeWithDefaults() throws {
        let json = #"{"skills":[{"name":"legacy"}]}"#
        let client = try JSONDecoder().decode(SkillsStatusReport.self, from: Data(json.utf8))
        let server = try JSONDecoder().decode(SkillStatusReport.self, from: Data(json.utf8))
        #expect(client.workspaceDir == server.workspaceDir)
        let skill = try #require(client.skills.first)
        #expect(skill.skillKey == server.skills.first?.skillKey)
        #expect(skill.eligible == false)
        #expect(skill.requirements.bins.isEmpty)
        #expect(skill.configChecks.isEmpty)
        #expect(skill.modelVisible == nil)
    }

    @Test
    func sdkToolsResolveTheirDisplayEntries() {
        let spotlight = ToolDisplayRegistry.resolve(
            name: "spotlight_search",
            args: AnyCodable(["query": AnyCodable("trip notes")]))
        #expect(spotlight.title == "Spotlight")
        #expect(spotlight.detail == "trip notes")
        #expect(ToolDisplayRegistry.sdkToolNames == ["spotlight_search"])
        #expect(!ToolDisplayRegistry.knownToolNames.contains("spotlight_search"))
        #expect(ToolDisplayRegistry.resolve(name: "automations", args: nil).title == "Cron")
        #expect(ToolDisplayRegistry.resolve(name: "memory_search", args: nil).title == "Memory Search")
        #expect(ToolDisplayRegistry.resolve(name: "memory_get", args: nil).title == "Memory Get")
    }

    #if canImport(AuthenticationServices) && !os(tvOS) && !os(watchOS)
    @Test
    func appleDefaultMCPOAuthClientStartsSignedOut() async throws {
        let client = try MCPOAuthClient.appleDefault(
            serverName: "docs",
            serverURL: try #require(URL(string: "https://mcp.example.com/mcp")),
            config: MCPOAuthConfig(redirectUrl: "myapp://mcp/oauth"),
            credentialStore: SkillsTestCredentialStore())
        #expect(await client.status() == .required)
        #expect(throws: MCPOAuthError.self) {
            _ = try MCPOAuthClient.appleDefault(
                serverName: "docs",
                serverURL: try #require(URL(string: "https://mcp.example.com/mcp")),
                config: MCPOAuthConfig(identity: "per-requester"),
                credentialStore: SkillsTestCredentialStore())
        }
    }
    #endif
}
