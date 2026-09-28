import Foundation
import Testing
import OpenClawProtocol
@testable import OpenClawCore

@Suite("Hook registry parity")
struct HookRegistryParityTests {
    actor Recorder {
        private(set) var values: [String] = []
        func append(_ value: String) { self.values.append(value) }
    }

    struct Failure: Error {}

    @Test
    func hookNamesMatchUpstreamList() {
        #expect(HookName.allCases.map(\.rawValue) == UpstreamRuntimeExtFixtures.hookNames)
        #expect(HookName.allCases.count == 42)
        #expect(HookName(rawValue: "before_agent_start")?.isDeprecatedAlias == true)
        #expect(HookName.legacyBeforeAgentStart.rawValue == "before_agent_start")
        #expect(!HookName.allCases.contains(HookName.legacyBeforeAgentStart))
    }

    @Test
    func higherPriorityRunsFirstAndTiesKeepRegistrationOrder() async throws {
        let hooks = HookRegistry()
        let recorder = Recorder()
        await hooks.register(.gatewayStart, priority: 0) { _ in await recorder.append("low-a"); return nil }
        await hooks.register(.gatewayStart, priority: 10) { _ in await recorder.append("high"); return nil }
        await hooks.register(.gatewayStart, priority: 0) { _ in await recorder.append("low-b"); return nil }
        _ = try await hooks.emit(.gatewayStart, context: HookContext())
        #expect(await recorder.values == ["high", "low-a", "low-b"])
    }

    @Test
    func blockShortCircuitsLowerPriorityHandlers() async {
        let hooks = HookRegistry()
        let recorder = Recorder()
        await hooks.register(.beforeToolCall, priority: 5, event: BeforeToolCallEvent.self) { _, _ in
            await recorder.append("blocker")
            return BeforeToolCallDecision(block: true, blockReason: "nope")
        }
        await hooks.register(.beforeToolCall, priority: 1, event: BeforeToolCallEvent.self) { _, _ in
            await recorder.append("never")
            return BeforeToolCallDecision(params: ["x": AnyCodable(1)])
        }
        let decision = await hooks.runBeforeToolCall(BeforeToolCallEvent(toolName: "exec", params: [:]))
        #expect(decision?.block == true)
        #expect(decision?.blockReason == "nope")
        #expect(await recorder.values == ["blocker"])
    }

    @Test
    func blockFalseIsNoOpAndRewritesChain() async {
        let hooks = HookRegistry()
        await hooks.register(.beforeToolCall, priority: 2, event: BeforeToolCallEvent.self) { event, _ in
            var params = event.params
            params["step"] = AnyCodable("one")
            return BeforeToolCallDecision(params: params, block: false)
        }
        await hooks.register(.beforeToolCall, priority: 1, event: BeforeToolCallEvent.self) { event, _ in
            // Sees the previous rewrite.
            let previous = event.params["step"]?.stringValue ?? "missing"
            return BeforeToolCallDecision(params: ["step": AnyCodable(previous + "+two")])
        }
        let decision = await hooks.runBeforeToolCall(BeforeToolCallEvent(toolName: "read", params: ["path": AnyCodable("a")]))
        #expect(decision?.block == nil)
        #expect(decision?.params?["step"]?.stringValue == "one+two")
    }

    @Test
    func approvalFreezesParams() async {
        let hooks = HookRegistry()
        await hooks.register(.beforeToolCall, priority: 2, event: BeforeToolCallEvent.self) { _, _ in
            BeforeToolCallDecision(params: ["v": AnyCodable(1)], requireApproval: HookApprovalRequest(title: "t", description: "d"))
        }
        await hooks.register(.beforeToolCall, priority: 1, event: BeforeToolCallEvent.self) { _, _ in
            BeforeToolCallDecision(params: ["v": AnyCodable(2)])
        }
        let decision = await hooks.runBeforeToolCall(BeforeToolCallEvent(toolName: "exec"))
        #expect(decision?.params?["v"]?.intValue == 1)
        #expect(decision?.requireApproval?.title == "t")
    }

    @Test
    func beforeAgentRunFailsClosedAndFiresDeprecatedAlias() async {
        let hooks = HookRegistry()
        let recorder = Recorder()
        await hooks.register(HookName.legacyBeforeAgentStart) { context in
            await recorder.append("legacy:\(context.decodeEvent(BeforeAgentRunEvent.self)?.prompt ?? "")")
            return nil
        }
        let passed = await hooks.runBeforeAgentRun(BeforeAgentRunEvent(prompt: "hi"))
        #expect(passed == .pass)
        #expect(await recorder.values == ["legacy:hi"])

        await hooks.register(.beforeAgentRun) { _ in throw Failure() }
        let blocked = await hooks.runBeforeAgentRun(BeforeAgentRunEvent(prompt: "again"))
        #expect(blocked.isBlock)
        #expect(blocked.blockMessage() == "Your message could not be sent: blocked")
        #expect(await recorder.values == ["legacy:hi"])
    }

    @Test
    func gateDecisionWireShape() throws {
        let block = InputGateDecision.block(reason: "internal", message: "Too long")
        let data = try JSONEncoder().encode(block)
        let object = try JSONDecoder().decode([String: String].self, from: data)
        #expect(object["outcome"] == "block")
        #expect(object["message"] == "Too long")
        #expect(try JSONDecoder().decode(InputGateDecision.self, from: Data(#"{"outcome":"pass"}"#.utf8)) == .pass)
        #expect(try JSONDecoder().decode(InputGateDecision.self, from: Data(#"{"outcome":"weird"}"#.utf8)).isBlock)
        #expect(block.blockMessage(blockedBy: "guard") == "Your message could not be sent: Too long (blocked by guard)")
    }

    @Test
    func promptBuildMergesSegmentsAndToolAllowlists() async {
        let hooks = HookRegistry()
        await hooks.register(.beforePromptBuild, priority: 2, event: BeforePromptBuildEvent.self) { _, _ in
            BeforePromptBuildResult(systemPrompt: "first", prependContext: "A", toolsAllow: ["read", "exec", "web_fetch"])
        }
        await hooks.register(.beforePromptBuild, priority: 1, event: BeforePromptBuildEvent.self) { _, _ in
            BeforePromptBuildResult(systemPrompt: "second", prependContext: "B", toolsAllow: ["exec", "read"])
        }
        let result = await hooks.runBeforePromptBuild(BeforePromptBuildEvent(prompt: "p"))
        #expect(result?.systemPrompt == "first")
        #expect(result?.prependContext == "A\n\nB")
        #expect(result?.toolsAllow == ["read", "exec"])
    }

    @Test
    func messageSendingCancelIsTerminalAndPluginUnregisterRemovesHandlers() async {
        let hooks = HookRegistry()
        await hooks.register(.messageSending, priority: 3, pluginID: "p1", event: MessageSendingEvent.self) { event, _ in
            MessageSendingResult(content: event.content.uppercased())
        }
        await hooks.register(.messageSending, priority: 2, pluginID: "p2", event: MessageSendingEvent.self) { _, _ in
            MessageSendingResult(cancel: true, cancelReason: "quiet hours")
        }
        let result = await hooks.runMessageSending(MessageSendingEvent(to: "u", content: "hello"))
        #expect(result?.cancel == true)
        #expect(result?.content == "HELLO")
        #expect(await hooks.unregisterAll(pluginID: "p2") == 1)
        let after = await hooks.runMessageSending(MessageSendingEvent(to: "u", content: "hello"))
        #expect(after?.cancel == nil)
        #expect(await hooks.registrations(for: .messageSending).map(\.pluginID) == ["p1"])
    }

    @Test
    func beforeMessageWriteBlocksAndObservedErrorsAreReported() async {
        let events = Recorder()
        let hooks = HookRegistry { event in await events.append(event.name) }
        await hooks.register(.beforeMessageWrite, event: BeforeMessageWriteEvent.self) { _, _ in
            BeforeMessageWriteResult(block: true)
        }
        let result = await hooks.runBeforeMessageWrite(BeforeMessageWriteEvent(message: AnyCodable(["role": AnyCodable("user")])))
        #expect(result == BeforeMessageWriteResult(block: true))

        await hooks.register(.afterToolCall) { _ in throw Failure() }
        await hooks.emitObserving(.afterToolCall, event: AfterToolCallEvent(toolName: "exec"))
        #expect(await events.values == ["hooks.handler_failed"])
    }
}
