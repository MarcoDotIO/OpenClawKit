import Foundation
@testable import OpenClawAgents
import OpenClawCore
import OpenClawModels
import OpenClawProtocol
import Testing

/// Tool that records every invocation, so tests can prove a gated call never reached the body.
private struct RecordingTool: AgentTool {
    let name = "exec"
    let log: GateInvocationLog

    var descriptor: AgentToolDescriptor {
        AgentToolDescriptor(
            name: self.name,
            description: "Run a command.",
            parameters: [
                "type": AnyCodable("object"),
                "properties": AnyCodable(["command": AnyCodable(["type": AnyCodable("string")])]),
                "required": AnyCodable(["command"]),
            ]
        )
    }

    func invoke(_ invocation: AgentToolInvocation, update _: AgentToolUpdateHandler?) async throws -> AgentToolOutput {
        let command = invocation.arguments["command"]?.stringValue ?? ""
        await self.log.append(command)
        return .text("ran:\(command)")
    }
}

private actor GateInvocationLog {
    private(set) var values: [String] = []

    func append(_ value: String) {
        self.values.append(value)
    }
}

@Suite("Foundation Models agent tool gate")
struct FoundationModelsAgentToolGateTests {
    private static func call(_ command: String) -> AgentToolCall {
        AgentToolCall(id: "c1", name: "exec", arguments: ["command": AnyCodable(command)])
    }

    @Test
    func typedBeforeToolCallBlockStopsTheToolAndAfterHookFires() async throws {
        let log = GateInvocationLog()
        let hooks = HookRegistry()
        let observed = GateInvocationLog()
        await hooks.register(.beforeToolCall, priority: 1, event: BeforeToolCallEvent.self) { event, _ in
            let command = event.params["command"]?.stringValue ?? ""
            return command.hasPrefix("rm") ? BeforeToolCallDecision(block: true, blockReason: "destructive") : nil
        }
        await hooks.register(.afterToolCall) { context in
            await observed.append(context.metadata["source"]?.stringValue ?? "?")
            return nil
        }
        let gate = FoundationModelsAgentToolGate(
            registry: AgentToolRegistry(tools: [RecordingTool(log: log)]),
            context: AgentToolInvocationContext(sessionKey: "agent:main:fm", agentID: "main"),
            hookRegistry: hooks
        )
        let blocked = try await gate.invoke(Self.call("rm -rf /"))
        #expect(blocked.isError)
        #expect(blocked.output.text == "Tool call blocked: destructive")
        #expect(await log.values.isEmpty)

        let allowed = try await gate.invoke(Self.call("ls"))
        #expect(!allowed.isError)
        #expect(allowed.output.text == "ran:ls")
        #expect(await log.values == ["ls"])
        #expect(await observed.values == ["foundation-models", "foundation-models"])
    }

    @Test
    func closureHooksRewriteAndApprovalsFailClosedWithoutABroker() async throws {
        let log = GateInvocationLog()
        let registry = AgentToolRegistry(tools: [RecordingTool(log: log)])
        let rewriting = FoundationModelsAgentToolGate(
            registry: registry,
            hooks: AgentLoopHooks(beforeToolCall: { context in
                .rewrite(["command": AnyCodable("echo safe \(context.arguments["command"]?.stringValue ?? "")")])
            })
        )
        #expect(try await rewriting.invoke(Self.call("x")).output.text == "ran:echo safe x")

        // A rewrite must still satisfy the schema.
        let invalid = FoundationModelsAgentToolGate(registry: registry, hooks: AgentLoopHooks(beforeToolCall: { _ in .rewrite([:]) }))
        let rejected = try await invalid.invoke(Self.call("y"))
        #expect(rejected.isError)
        #expect(rejected.output.text.hasPrefix("Invalid arguments for exec"))

        let hooks = HookRegistry()
        await hooks.register(.beforeToolCall, priority: 1, event: BeforeToolCallEvent.self) { _, _ in
            BeforeToolCallDecision(requireApproval: HookApprovalRequest(title: "Run command?", description: "exec"))
        }
        let unbrokered = FoundationModelsAgentToolGate(registry: registry, hookRegistry: hooks)
        let denied = try await unbrokered.invoke(Self.call("deploy"))
        #expect(denied.isError)
        #expect(denied.output.text.contains("no approval broker"))
        #expect(await log.values == ["echo safe x"])
    }

    @Test
    func approvalsRouteThroughTheBroker() async throws {
        let log = GateInvocationLog()
        let broker = ApprovalBroker()
        let gate = FoundationModelsAgentToolGate(
            registry: AgentToolRegistry(tools: [RecordingTool(log: log)]),
            context: AgentToolInvocationContext(sessionKey: "agent:main:fm", agentID: "main"),
            hooks: AgentLoopHooks(beforeToolCall: { _ in
                .requireApproval(AgentToolApprovalRequest(title: "Run?", description: "exec"))
            }),
            approvals: broker
        )
        let updates = await broker.updates()
        let resolver = Task {
            var decisions: [ApprovalDecision] = [.deny, .allowOnce]
            for await approval in updates where approval.state == .pending {
                _ = try? await broker.resolve(id: approval.id, decision: decisions.removeFirst())
                if decisions.isEmpty { break }
            }
        }
        let denied = try await gate.invoke(Self.call("first"))
        #expect(denied.isError)
        #expect(denied.output.text.contains("not approved"))
        let approved = try await gate.invoke(Self.call("second"))
        resolver.cancel()
        #expect(approved.output.text == "ran:second")
        #expect(await log.values == ["second"])
    }

    @Test
    func runtimeSessionsGateToolsWithTheRuntimeHooksAndApprovals() async throws {
        let log = GateInvocationLog()
        let hooks = HookRegistry()
        await hooks.register(.beforeToolCall, priority: 1, event: BeforeToolCallEvent.self) { event, _ in
            event.params["command"]?.stringValue == "rm" ? BeforeToolCallDecision(block: true, blockReason: "plugin veto") : nil
        }
        let runtime = EmbeddedAgentRuntime(
            toolRegistry: AgentToolRegistry(tools: [RecordingTool(log: log)]),
            hookRegistry: hooks,
            mediaUnderstandingServices: .none
        )
        await runtime.setHooks(AgentLoopHooks(beforeToolCall: { context in
            context.arguments["command"]?.stringValue == "send" ? .requireApproval(AgentToolApprovalRequest(title: "Send?", description: "x")) : .proceed
        }))
        let plan = try await runtime.foundationModelsSessionPlan(agentID: nil, sessionKey: "agent:main:fm", workspaceRootPath: nil, modelID: "system")
        let gate = await runtime.foundationModelsToolGate(registry: plan.registry, agentID: nil, sessionKey: "agent:main:fm")
        #expect(gate.approvals === runtime.approvals)

        let vetoed = try await gate.invoke(Self.call("rm"))
        #expect(vetoed.output.text == "Tool call blocked: plugin veto")
        // Approval requests reach the runtime's broker.
        let updates = await runtime.approvals.updates()
        let resolver = Task {
            for await approval in updates where approval.state == .pending {
                #expect(approval.sessionKey == "agent:main:fm")
                _ = try? await runtime.approvals.resolve(id: approval.id, decision: .deny)
                break
            }
        }
        let unapproved = try await gate.invoke(Self.call("send"))
        resolver.cancel()
        #expect(unapproved.output.text.contains("not approved"))
        #expect(try await gate.invoke(Self.call("ls")).output.text == "ran:ls")
        #expect(await log.values == ["ls"])
    }

    @Test
    func policyAndRegistrationAreRechecked() async throws {
        let log = GateInvocationLog()
        let registry = AgentToolRegistry(tools: [RecordingTool(log: log)])
        let gate = FoundationModelsAgentToolGate(registry: registry, policy: ToolPolicy(deny: ["exec"]))
        let forbidden = try await gate.invoke(Self.call("ls"))
        #expect(forbidden.output.text == "Tool exec is not allowed by the current tool policy")
        let missing = try await gate.invoke(AgentToolCall(id: "c2", name: "nope", arguments: [:]))
        #expect(missing.output.text == "Tool not found: nope")
        #expect(await log.values.isEmpty)

        // The in-process executor accepts the gate as its invocation path.
        let executor = FoundationModelsAgentToolExecutor(invoke: { call in try await gate.invoke(call) })
        let output = try await executor.executeTool(ModelToolCall(id: "c3", name: "exec", arguments: ["command": AnyCodable("ls")]))
        #expect(output.isError)
        #expect(await log.values.isEmpty)
    }
}
