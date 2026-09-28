import Foundation
import Testing
import OpenClawCore
import OpenClawModels
import OpenClawProtocol
@testable import OpenClawAgents

@Suite("AgentTool contract v2")
struct AgentToolContractTests {
    struct LegacyEchoTool: AgentTool {
        let name = "echo"

        func execute(arguments: [String: AnyCodable]) async throws -> AnyCodable {
            arguments["value"] ?? AnyCodable("")
        }
    }

    struct StructuredTool: AgentTool {
        let name = "lookup"

        var descriptor: AgentToolDescriptor {
            AgentToolDescriptor(
                name: self.name,
                label: "Lookup",
                description: "Looks things up.",
                parameters: [
                    "type": AnyCodable("object"),
                    "properties": AnyCodable(["q": AnyCodable(["type": AnyCodable("string")])]),
                    "required": AnyCodable(["q"]),
                ],
                executionMode: .parallel
            )
        }

        func invoke(_ invocation: AgentToolInvocation, update: AgentToolUpdateHandler?) async throws -> AgentToolOutput {
            await update?(AgentToolOutput(progress: AgentToolProgress(message: "searching", fraction: 0.5)))
            let query = invocation.arguments["q"] ?? AnyCodable("")
            if query == AnyCodable("fail") {
                return .error("no results")
            }
            return AgentToolOutput(
                content: [.text("found"), .image(data: Data([7, 8]).base64EncodedString(), mimeType: "image/png")],
                details: AnyCodable(["query": query, "callID": AnyCodable(invocation.toolCallID)])
            )
        }
    }

    struct EntryPointlessTool: AgentTool {
        let name = "broken"
    }

    struct ThrowingTool: AgentTool {
        let name = "thrower"

        func execute(arguments _: [String: AnyCodable]) async throws -> AnyCodable {
            throw OpenClawCoreError.unavailable("disk offline")
        }
    }

    struct SlowTool: AgentTool {
        let name = "slow"

        func execute(arguments _: [String: AnyCodable]) async throws -> AnyCodable {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return AnyCodable("late")
        }
    }

    actor UpdateRecorder {
        private(set) var updates: [AgentToolOutput] = []

        func record(_ output: AgentToolOutput) {
            self.updates.append(output)
        }
    }

    @Test
    func legacyToolsGetADefaultDescriptorAndInvokeBridge() async throws {
        let tool = LegacyEchoTool()
        #expect(tool.descriptor == AgentToolDescriptor(name: "echo"))
        #expect(tool.descriptor.label == "echo")
        #expect(tool.descriptor.parameters == AgentToolDescriptor.emptyParametersSchema)

        let text = try await tool.invoke(AgentToolInvocation(arguments: ["value": AnyCodable("ok")]), update: nil)
        #expect(text.content == [.text("ok")])
        #expect(text.details == AnyCodable("ok"))
        #expect(text.isError == false)

        let object = try await tool.invoke(
            AgentToolInvocation(arguments: ["value": AnyCodable(["b": AnyCodable(1), "a": AnyCodable(true)])]),
            update: nil
        )
        #expect(object.text == #"{"a":true,"b":1}"#)
    }

    @Test
    func v2ToolsWorkThroughTheV1ExecutePath() async throws {
        let registry = AgentToolRegistry(tools: [StructuredTool()])
        let result = try await registry.execute(AgentToolCall(name: "lookup", arguments: ["q": AnyCodable("swift")]))
        guard case .object(let details) = result.value.value else {
            Issue.record("Expected object details")
            return
        }
        #expect(details["query"] == AnyCodable("swift"))
        guard case .string(let callID)? = details["callID"]?.value else {
            Issue.record("Expected generated call id")
            return
        }
        #expect(callID.hasPrefix("call_"))

        await #expect(throws: OpenClawCoreError.self) {
            _ = try await registry.execute(AgentToolCall(name: "lookup", arguments: ["q": AnyCodable("fail")]))
        }
    }

    @Test
    func toolsWithoutAnEntryPointFailInsteadOfRecursing() async throws {
        let registry = AgentToolRegistry(tools: [EntryPointlessTool()])
        let result = try await registry.invoke(AgentToolCall(name: "broken"))
        #expect(result.isError)
        #expect(result.output.text.contains("must implement"))
        await #expect(throws: OpenClawCoreError.self) {
            _ = try await EntryPointlessTool().execute(arguments: [:])
        }
    }

    @Test
    func registryInvokeReportsFailuresAsResultsAndStreamsUpdates() async throws {
        let registry = AgentToolRegistry(tools: [StructuredTool(), ThrowingTool()])
        let recorder = UpdateRecorder()

        let result = try await registry.invoke(
            AgentToolCall(id: "call_fixed", name: "lookup", arguments: ["q": AnyCodable("swift")]),
            context: AgentToolInvocationContext(runID: "run-1", sessionKey: "s"),
            update: { output in await recorder.record(output) }
        )
        #expect(result.toolCallID == "call_fixed")
        #expect(result.isError == false)
        #expect(result.durationMs != nil)
        #expect(result.output.content.first == .text("found"))
        #expect(await recorder.updates.first?.progress == AgentToolProgress(message: "searching", fraction: 0.5))

        let modelResult = result.modelToolResult
        #expect(modelResult.toolCallID == "call_fixed")
        #expect(modelResult.toolName == "lookup")
        #expect(modelResult.content.first == .text("found"))
        #expect(modelResult.content.last?.mediaAttachment?.data == Data([7, 8]))
        #expect(modelResult.content.last?.mediaAttachment?.mimeType == "image/png")

        let missing = try await registry.invoke(AgentToolCall(name: "nope"))
        #expect(missing.isError)
        #expect(missing.output.text == "Tool not found: nope")
        #expect(missing.toolCallID?.hasPrefix("call_") == true)

        let thrown = try await registry.invoke(AgentToolCall(name: "thrower"))
        #expect(thrown.isError)
        #expect(thrown.output.text.contains("disk offline"))
    }

    @Test
    func registryInvokeRethrowsCancellation() async throws {
        let registry = AgentToolRegistry(tools: [SlowTool()])
        let task = Task {
            try await registry.invoke(AgentToolCall(name: "slow"))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test
    func registryExposesSortedDescriptorsOwnersAndAliases() async throws {
        let registry = AgentToolRegistry(tools: [StructuredTool(), LegacyEchoTool()])
        #expect(await registry.descriptors().map(\.name) == ["echo", "lookup"])
        let definitions = await registry.modelToolDefinitions()
        #expect(definitions.map(\.name) == ["echo", "lookup"])
        #expect(definitions[1].description == "Looks things up.")

        struct ExecTool: AgentTool {
            let name = "exec"
            func execute(arguments _: [String: AnyCodable]) async throws -> AnyCodable { AnyCodable("ran") }
        }
        try await registry.register(ExecTool(), ownerPluginID: "shell-plugin")
        #expect(await registry.ownerPluginID(forTool: "exec") == "shell-plugin")
        #expect(await registry.tool(named: "bash")?.name == "exec")
        let aliased = try await registry.invoke(AgentToolCall(name: "bash"))
        #expect(aliased.name == "bash")
        #expect(aliased.value == AnyCodable("ran"))

        await #expect(throws: OpenClawCoreError.self) {
            try await registry.register(ExecTool(), ownerPluginID: "other")
        }
        try await registry.register(ExecTool(), ownerPluginID: "other", replacing: true)
        #expect(await registry.ownerPluginID(forTool: "exec") == "other")

        struct DottedTool: AgentTool {
            let name = "calendar.lookup"
            func execute(arguments _: [String: AnyCodable]) async throws -> AnyCodable { AnyCodable("") }
        }
        await #expect(throws: OpenClawCoreError.self) {
            try await registry.register(DottedTool(), ownerPluginID: nil)
        }
        await registry.register(DottedTool())
        #expect(await registry.hasTool(named: "calendar.lookup"))
        #expect(await registry.unregister(named: "calendar.lookup"))
        #expect(await registry.hasTool(named: "calendar.lookup") == false)
    }

    @Test(arguments: [
        ("bash", "exec"),
        ("BASH", "exec"),
        ("apply-patch", "apply_patch"),
        ("cron", "automations"),
        (" Read ", "read"),
    ])
    func canonicalNamesApplyUpstreamAliases(raw: String, expected: String) {
        #expect(AgentToolRegistry.canonicalName(raw) == expected)
    }

    @Test
    func toolNamesFollowTheModelFacingGrammar() {
        for valid in ["a", "exec", "llm-task", "apply_patch", "Tool9", String(repeating: "x", count: 64)] {
            #expect(AgentToolDescriptor.isValidName(valid), "\(valid)")
        }
        for invalid in ["", "9tool", "_tool", "calendar.lookup", "tool name", "tööl", String(repeating: "x", count: 65)] {
            #expect(AgentToolDescriptor.isValidName(invalid) == false, "\(invalid)")
        }
    }

    @Test
    func descriptorsRoundTripWithUpstreamKeys() throws {
        let descriptor = AgentToolDescriptor(
            name: "mcp__files__read",
            label: "Read file",
            description: "Reads a file.",
            displaySummary: "read a file",
            display: AgentToolDisplay(title: "Read", emoji: "📖", category: "fs"),
            outputSchema: ["type": AnyCodable("object")],
            source: .mcp(server: "files", toolName: "read"),
            sectionID: "fs",
            defaultProfiles: [.coding, "custom"],
            risk: .medium,
            tags: ["files"],
            executionMode: .sequential,
            replaySafe: true,
            catalogMode: .directOnly,
            hideFromChannelProgress: true,
            resultContentSource: .network
        )
        let data = try JSONEncoder().encode(descriptor)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(#""sectionId":"fs""#))
        #expect(json.contains(#""catalogMode":"direct-only""#))
        #expect(json.contains(#""kind":"mcp""#))
        #expect(json.contains(#""mcpToolName":"read""#))
        #expect(try JSONDecoder().decode(AgentToolDescriptor.self, from: data) == descriptor)

        for source in [AgentToolSource.core, .plugin(id: "p"), .client, .channel(id: "slack")] {
            #expect(try JSONDecoder().decode(AgentToolSource.self, from: try JSONEncoder().encode(source)) == source)
        }

        let minimal = try JSONDecoder().decode(
            AgentToolDescriptor.self,
            from: Data(#"{"name":"t","risk":"extreme","catalogMode":"hidden","source":{"kind":"satellite"}}"#.utf8)
        )
        #expect(minimal == AgentToolDescriptor(name: "t"))
        #expect(descriptor.modelToolDefinition == ModelToolDefinition(
            name: "mcp__files__read",
            description: "Reads a file.",
            parameters: AgentToolDescriptor.emptyParametersSchema
        ))
        #expect(descriptor.modelToolDefinition(strict: true).strict == true)
    }

    @Test
    func contentBlocksUseLLMCoreWireShapes() throws {
        let blocks: [AgentToolContentBlock] = [.text("hi"), .image(data: "AQI=", mimeType: "image/png")]
        let json = String(decoding: try JSONEncoder().encode(blocks), as: UTF8.self)
        #expect(json.contains(#""type":"text""#))
        #expect(json.contains(#""mimeType":"image\/png""#) || json.contains(#""mimeType":"image/png""#))
        #expect(try JSONDecoder().decode([AgentToolContentBlock].self, from: Data(json.utf8)) == blocks)
        #expect(AgentToolContentBlock.image(data: "%%%", mimeType: "image/png").modelContentPart == nil)
    }

    @Test
    func modelToolCallsConvertIntoRegistryCalls() {
        let call = AgentToolCall(ModelToolCall(id: "call_9", name: "lookup", arguments: ["q": AnyCodable("x")]))
        #expect(call.id == "call_9")
        #expect(call.name == "lookup")
        #expect(call.arguments == ["q": AnyCodable("x")])
        #expect(AgentToolCall(ModelToolCall(id: "c", name: "n", argumentsJSON: "{oops")).arguments.isEmpty)
        #expect(AgentToolCall.makeID().hasPrefix("call_"))
    }

    @Test
    func llmTaskPublishesTheUpstreamSchema() throws {
        let descriptor = LLMTaskTool(modelRouter: ModelRouter()).descriptor
        #expect(descriptor.name == "llm-task")
        #expect(descriptor.label == "LLM Task")
        #expect(descriptor.parameters["required"] == AnyCodable(["prompt"]))
        guard case .object(let properties)? = descriptor.parameters["properties"]?.value else {
            Issue.record("Expected properties object")
            return
        }
        #expect(Set(properties.keys) == [
            "prompt", "input", "schema", "provider", "model", "thinking",
            "authProfileId", "temperature", "maxTokens", "timeoutMs",
        ])
        #expect(descriptor.hasValidName)
    }

    @Test
    func legacyResultsKeepValueSemantics() {
        let legacy = AgentToolResult(name: "echo", value: AnyCodable("ok"))
        #expect(legacy.value == AnyCodable("ok"))
        #expect(legacy.toolCallID == nil)
        #expect(legacy.durationMs == nil)
        #expect(legacy == AgentToolResult(name: "echo", value: AnyCodable("ok")))

        let textOnly = AgentToolResult(name: "t", toolCallID: "c", output: .text("plain"))
        #expect(textOnly.value == AnyCodable("plain"))
    }
}
