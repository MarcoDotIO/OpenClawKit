import Foundation
import Testing
import OpenClawCore
import OpenClawProtocol
@testable import OpenClawAgents

/// Layered tool policies: per-agent lists restrict the global lists instead of replacing them.
@Suite("Tool policy layering")
struct ToolPolicyLayeringTests {
    @Test
    func agentAllowListsIntersectWithTheGlobalAllowList() throws {
        let document = try OpenClawConfigDocument.decode(Data(
            """
            {"tools": {"allow": ["read", "write"]},
             "agents": {"entries": {"ops": {"tools": {"allow": ["exec"]}}, "reader": {"tools": {"allow": ["read", "exec"]}}}}}
            """.utf8
        ))
        let ops = ToolPolicy.resolve(from: document, agentID: "ops")
        for name in ["read", "write", "exec"] {
            #expect(!ops.allows(name), "\(name) must need both the global and the agent allow list")
        }
        let reader = ToolPolicy.resolve(from: document, agentID: "reader")
        #expect(reader.allows("read"))
        #expect(!reader.allows("exec"))
        #expect(!reader.allows("write"))
        let global = ToolPolicy.resolve(from: document)
        #expect(global == ToolPolicy(allow: ["read", "write"]))
    }

    @Test
    func agentProfileOverridesButGlobalDeniesStay() throws {
        let document = try OpenClawConfigDocument.decode(Data(
            """
            {"tools": {"profile": "minimal", "deny": ["exec", "process"]},
             "agents": {"entries": {"coder": {"tools": {"profile": "coding", "deny": ["browser"]}}}}}
            """.utf8
        ))
        let coder = ToolPolicy.resolve(from: document, agentID: "coder")
        #expect(coder.profile == .coding)
        #expect(coder.deny == ["exec", "process", "browser"])
        #expect(!coder.allows("exec"))
        #expect(!coder.allows("process"))
        #expect(coder.allows("write"))
    }

    @Test
    func intersectedPoliciesRoundTripAndFilter() throws {
        let policy = ToolPolicy(allow: ["read", "write", "exec"]).intersecting(ToolPolicy(deny: ["write"])).intersecting(ToolPolicy(allow: ["read", "write"]))
        #expect(policy.allows("read"))
        #expect(!policy.allows("write"))
        #expect(!policy.allows("exec"))
        #expect(!policy.isUnrestricted)
        #expect(ToolPolicy.allowAll.intersecting(.allowAll) == .allowAll)
        let decoded = try JSONDecoder().decode(ToolPolicy.self, from: JSONEncoder().encode(policy))
        #expect(decoded == policy)
        let names = policy.filter([AgentToolDescriptor(name: "read"), AgentToolDescriptor(name: "write"), AgentToolDescriptor(name: "exec")]).map(\.name)
        #expect(names == ["read"])
    }
}
