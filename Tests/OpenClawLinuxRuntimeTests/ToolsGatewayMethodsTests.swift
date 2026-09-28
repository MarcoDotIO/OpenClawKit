import Foundation
import Testing
import OpenClawCore
import OpenClawGateway
import OpenClawModels
import OpenClawProtocol
@testable import OpenClawAgents

/// `tools.catalog`, `tools.effective` and `tools.invoke` over the runtime tool registry and policy.
@Suite("Tools gateway methods")
struct ToolsGatewayMethodsTests {
    private typealias Harness = GatewayServerTestHarness

    private static let tools: [any AgentTool] = [
        EchoArgumentTool(),
        SourcedEchoTool(name: "lookup", source: .plugin(id: "acme"), risk: .medium),
        SourcedEchoTool(name: "docs__search", source: .mcp(server: "docs", toolName: "search")),
    ]

    @Test
    func catalogListsCoreSectionsRuntimeAndPluginGroups() async throws {
        let stack = await Harness.runtimeStack("tools-catalog", turns: [], tools: Self.tools)
        let response = await Harness.call(stack.server, "tools.catalog", ["agentId": AnyCodable("ops")])
        let payload = try Harness.payload(response)
        let result = try GatewayPayloadCodec.decode(ToolsCatalogResult.self, from: AnyCodable(payload))
        #expect(result.agentid == "ops")
        #expect(result.profiles.compactMap { $0.id.stringValue } == ["minimal", "coding", "messaging", "full"])
        let groupIDs = result.groups.map(\.id)
        for section in CoreToolCatalog.visibleSections().map(\.section.id) {
            #expect(groupIDs.contains(section))
        }
        let sdk = try #require(result.groups.first { $0.id == "sdk" })
        #expect(sdk.tools.map(\.id) == ["echo"])
        let plugin = try #require(result.groups.first { $0.id == "plugin:acme" })
        #expect(plugin.source == AnyCodable("plugin"))
        #expect(plugin.pluginid == "acme")
        #expect(plugin.tools.first?.risk == AnyCodable("medium"))
        #expect(plugin.tools.first?.description == "Sourced echo lookup.")
        #expect(plugin.tools.first?.fulldescription?.contains("Second line") == true)
        #expect(groupIDs.contains { $0.contains("docs") } == false)

        let noPlugins = try Harness.payload(await Harness.call(stack.server, "tools.catalog", ["includePlugins": AnyCodable(false)]))
        #expect(noPlugins["groups"]?.arrayValue?.contains { $0.dictionaryValue?["id"] == AnyCodable("plugin:acme") } == false)
    }

    @Test
    func effectiveAppliesSessionOverridesAndReportsNotices() async throws {
        let stack = await Harness.runtimeStack("tools-effective", turns: [], tools: Self.tools)
        await stack.runtime.registerToolGatewayMethods(
            on: stack.server,
            options: AgentToolGatewayOptions(notices: {
                [AgentToolInventoryNotice(id: "mcp-not-yet-connected", severity: "warning", message: "calendar is offline", servers: ["calendar"])]
            })
        )
        _ = await Harness.call(stack.server, "sessions.patch", [
            "key": AnyCodable("agent:main:main"),
            "toolOverrides": AnyCodable(["mcpServers": AnyCodable(["docs": AnyCodable(false)])]),
        ])
        let payload = try Harness.payload(await Harness.call(stack.server, "tools.effective", ["sessionKey": AnyCodable("agent:main:main")]))
        let result = try GatewayPayloadCodec.decode(ToolsEffectiveResult.self, from: AnyCodable(payload))
        #expect(result.agentid == "main")
        #expect(result.profile == "full")
        #expect(result.groups.compactMap { $0.id.stringValue } == ["core", "plugin", "mcp"])
        let mcp = try #require(result.groups.first { $0.id == AnyCodable("mcp") }?.tools.first)
        #expect(mcp.mcpserver == "docs")
        #expect(mcp.mcptoolname == "search")
        #expect(mcp.deniedbysession == true)
        let plugin = try #require(result.groups.first { $0.id == AnyCodable("plugin") }?.tools.first)
        #expect(plugin.pluginid == "acme")
        #expect(plugin.deniedbysession == nil)
        #expect(result.notices?.first?.servers == ["calendar"])

        await stack.runtime.setToolsConfiguration(AgentToolsConfiguration(policy: ToolPolicy(deny: ["lookup"])))
        let denied = try Harness.payload(await Harness.call(stack.server, "tools.effective", ["sessionKey": AnyCodable("agent:main:main")]))
        let deniedResult = try GatewayPayloadCodec.decode(ToolsEffectiveResult.self, from: AnyCodable(denied))
        #expect(deniedResult.groups.flatMap(\.tools).map(\.id).contains("lookup") == false)
        #expect(await Harness.call(stack.server, "tools.effective").error?.errorCode == .invalidRequest)
    }

    @Test
    func invokeRunsToolsAndMapsFailuresToUpstreamCodes() async throws {
        let stack = await Harness.runtimeStack("tools-invoke", turns: [], tools: Self.tools)
        let ok = try Harness.payload(await Harness.call(stack.server, "tools.invoke", [
            "name": AnyCodable("lookup"), "args": AnyCodable(["text": AnyCodable("x")]), "sessionKey": AnyCodable("agent:main:main"),
        ]))
        let result = try GatewayPayloadCodec.decode(ToolsInvokeResult.self, from: AnyCodable(ok))
        #expect(result.ok)
        #expect(result.toolname == "lookup")
        #expect(result.source == AnyCodable("plugin"))
        #expect(result.output?.dictionaryValue?["echo"] == AnyCodable("x"))

        let echoed = try Harness.payload(await Harness.call(stack.server, "tools.invoke", ["name": AnyCodable("echo"), "args": AnyCodable(["text": AnyCodable("y")])]))
        #expect(echoed["output"]?.arrayValue?.first?.dictionaryValue?["text"] == AnyCodable("echo:y"))

        let missing = try Harness.payload(await Harness.call(stack.server, "tools.invoke", ["name": AnyCodable("nope")]))
        #expect(missing["ok"] == AnyCodable(false))
        #expect(missing["error"]?.dictionaryValue?["code"] == AnyCodable("not_found"))

        let invalid = try Harness.payload(await Harness.call(stack.server, "tools.invoke", ["name": AnyCodable("echo"), "args": AnyCodable(["text": AnyCodable(3)])]))
        #expect(invalid["error"]?.dictionaryValue?["code"] == AnyCodable("validation_error"))

        await stack.runtime.setToolsConfiguration(AgentToolsConfiguration(policy: ToolPolicy(deny: ["echo"])))
        let forbidden = try Harness.payload(await Harness.call(stack.server, "tools.invoke", ["name": AnyCodable("echo"), "args": AnyCodable(["text": AnyCodable("z")])]))
        #expect(forbidden["error"]?.dictionaryValue?["code"] == AnyCodable("forbidden"))

        let badArgs = await Harness.call(stack.server, "tools.invoke", ["name": AnyCodable("echo"), "args": AnyCodable("nope")])
        #expect(badArgs.error?.errorCode == .invalidRequest)
        #expect(await Harness.call(stack.server, "tools.invoke").error?.errorCode == .invalidRequest)
    }

    actor Counter {
        private(set) var value = 0
        func increment() { self.value += 1 }
    }

    struct CountingTool: AgentTool {
        let name = "count"
        let counter: Counter

        func invoke(_ invocation: AgentToolInvocation, update _: AgentToolUpdateHandler?) async throws -> AgentToolOutput {
            await self.counter.increment()
            return .text("counted")
        }
    }

    @Test
    func invokeHandsOffApprovalsAndDedupesByIdempotencyKey() async throws {
        let counter = Counter()
        let stack = await Harness.runtimeStack("tools-approval", turns: [], tools: Self.tools + [CountingTool(counter: counter)])
        await stack.runtime.registerToolGatewayMethods(
            on: stack.server,
            options: AgentToolGatewayOptions(hooks: AgentLoopHooks(beforeToolCall: { context in
                context.toolName == "lookup"
                    ? .requireApproval(AgentToolApprovalRequest(title: "Run lookup?", description: "Queries acme", pluginID: "acme"))
                    : .proceed
            }))
        )
        let pending = try Harness.payload(await Harness.call(stack.server, "tools.invoke", [
            "name": AnyCodable("lookup"), "args": AnyCodable(["text": AnyCodable("q")]), "sessionKey": AnyCodable("agent:main:main"),
        ]))
        #expect(pending["ok"] == AnyCodable(false))
        #expect(pending["requiresApproval"] == AnyCodable(true))
        #expect(pending["error"]?.dictionaryValue?["code"] == AnyCodable("requires_approval"))
        let approvalID = try #require(pending["approvalId"]?.stringValue)
        #expect(await stack.runtime.approvals.get(id: approvalID)?.state == .pending)

        let resolved = await Harness.call(stack.server, "approval.resolve", ["id": AnyCodable(approvalID), "decision": AnyCodable("allow-once")])
        #expect(resolved.ok)
        let confirmed = try Harness.payload(await Harness.call(stack.server, "tools.invoke", [
            "name": AnyCodable("lookup"), "args": AnyCodable(["text": AnyCodable("q")]), "confirm": AnyCodable(true), "approvalId": AnyCodable(approvalID),
        ]))
        #expect(confirmed["ok"] == AnyCodable(true))

        // confirm: true without a prior approval waits for a decision.
        let waiting = Task {
            try Harness.payload(await Harness.call(stack.server, "tools.invoke", [
                "name": AnyCodable("lookup"), "args": AnyCodable(["text": AnyCodable("w")]), "confirm": AnyCodable(true),
            ]))
        }
        var pendingID: String?
        for _ in 0..<200 {
            pendingID = await stack.runtime.approvals.pending().first?.id
            if pendingID != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let waitingID = try #require(pendingID)
        _ = await Harness.call(stack.server, "approval.resolve", ["id": AnyCodable(waitingID), "decision": AnyCodable("deny")])
        let denied = try await waiting.value
        #expect(denied["ok"] == AnyCodable(false))
        #expect(denied["error"]?.dictionaryValue?["code"] == AnyCodable("forbidden"))

        for _ in 0..<2 {
            let counted = try Harness.payload(await Harness.call(stack.server, "tools.invoke", ["name": AnyCodable("count"), "idempotencyKey": AnyCodable("once")]))
            #expect(counted["ok"] == AnyCodable(true))
        }
        #expect(await counter.value == 1)
    }
}
