import Foundation
import Testing
import OpenClawCore
import OpenClawProtocol
@testable import OpenClawModels

// Platform-neutral parity tests for the apple-fm provider (upstream extensions/apple-fm:
// defaults.ts, native.ts facts, setup.ts eligibility, AppleFoundationModels.swift schema and replay
// rules, stream.ts structured-output validation). They run on Linux and Apple platforms alike.

private func json(_ text: String) throws -> [String: AnyCodable] {
    try JSONDecoder().decode([String: AnyCodable].self, from: Data(text.utf8))
}

private func expectFoundationModelsError(
    _ expected: String,
    code: FoundationModelsError.Code? = nil,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () throws -> Void
) {
    do {
        try body()
        Issue.record("Expected error '\(expected)'", sourceLocation: sourceLocation)
    } catch let error as FoundationModelsError {
        #expect(error.message.contains(expected), "\(error.message)", sourceLocation: sourceLocation)
        if let code {
            #expect(error.code == code, sourceLocation: sourceLocation)
        }
    } catch {
        Issue.record("Unexpected error \(error)", sourceLocation: sourceLocation)
    }
}

@Suite("Apple FM identity and facts")
struct AppleFoundationModelsIdentityTests {
    @Test
    func identityMatchesUpstreamDefaults() {
        #expect(FoundationModelsProvider.providerID == "apple-fm")
        #expect(FoundationModelsProvider.legacyProviderID == "foundation")
        #expect(FoundationModelsProvider.systemModelID == "system")
        #expect(FoundationModelsProvider.systemModelRef == "apple-fm/system")
        #expect(FoundationModelsProvider.privateCloudComputeModelRef == "apple-fm/private-cloud-compute")
        #expect(FoundationModelsProvider.localAuthMarker == "apple-fm-local")
        #expect(FoundationModelsProvider.minimumUtilityContextWindow == 8_192)
        #expect(FoundationModelsProvider.defaultMaxTokens == 1_024)
        #expect(FoundationModelsProvider().id == "apple-fm")
    }

    @Test
    func providerAliasesAndAuthMarker() {
        for alias in ["apple-fm", "foundation", "apple-foundation", " APPLE-FM "] {
            #expect(FoundationModelsProvider.handles(providerID: alias), "\(alias)")
        }
        #expect(!FoundationModelsProvider.handles(providerID: "openai"))
        #expect(FoundationModelsProvider.isNonSecretAuthMarker("apple-fm-local"))
        #expect(!FoundationModelsProvider.isNonSecretAuthMarker("sk-real"))
        #expect(!FoundationModelsProvider.isNonSecretAuthMarker(nil))
    }

    @Test
    func modelTargetsResolveAliasesAndRefs() {
        let system: [String] = ["system", "default", "apple-foundation-default", "apple-fm/system", "foundation/system", " SYSTEM "]
        for raw in system {
            #expect(AppleFoundationModelTarget(modelID: raw) == .system, "\(raw)")
        }
        for raw in ["private-cloud-compute", "pcc", "apple-fm/pcc", "apple-fm/private-cloud-compute"] {
            #expect(AppleFoundationModelTarget(modelID: raw) == .privateCloudCompute, "\(raw)")
        }
        #expect(AppleFoundationModelTarget(modelID: "gpt-4.1") == nil)
        #expect(AppleFoundationModelTarget.privateCloudCompute.modelRef == "apple-fm/private-cloud-compute")
        // Unknown model IDs (for example another provider's model during fallback) use the default target.
        #expect(FoundationModelsProvider.resolveTarget(modelID: "gpt-4.1") == .system)
        #expect(FoundationModelsProvider.resolveTarget(modelID: nil, defaultTarget: .privateCloudCompute) == .privateCloudCompute)
        #expect(FoundationModelsProvider.resolveTarget(modelID: "pcc") == .privateCloudCompute)
    }

    @Test
    func factsDecodeUpstreamHelperJSONAndEncodeUpstreamKeys() throws {
        let upstream = #"{"available":true,"modelName":"AFM 3 Core Advanced","contextWindow":8192}"#
        let facts = try JSONDecoder().decode(AppleFoundationModelFacts.self, from: Data(upstream.utf8))
        #expect(facts.available)
        #expect(facts.modelName == "AFM 3 Core Advanced")
        #expect(facts.contextWindow == 8_192)
        #expect(facts.target == .system)
        #expect(facts.reason == nil)
        #expect(facts.supportsToolCalling)

        let encoded = try JSONDecoder().decode([String: AnyCodable].self, from: JSONEncoder().encode(facts))
        #expect(encoded["available"]?.boolValue == true)
        #expect(encoded["modelName"]?.stringValue == "AFM 3 Core Advanced")
        #expect(encoded["contextWindow"]?.intValue == 8_192)
        #expect(encoded["reason"] == nil)

        let unavailable = AppleFoundationModelFacts.unavailable(reason: "Enable Apple Intelligence in System Settings, then retry setup.")
        let unavailableJSON = try JSONDecoder().decode([String: AnyCodable].self, from: JSONEncoder().encode(unavailable))
        #expect(unavailableJSON["available"]?.boolValue == false)
        #expect(unavailableJSON["contextWindow"]?.intValue == 0)
        #expect(unavailableJSON["modelName"]?.stringValue == "Apple Foundation Models")
        #expect(unavailableJSON["reason"]?.stringValue == "Enable Apple Intelligence in System Settings, then retry setup.")
    }

    @Test
    func utilityEligibilityRequiresEightThousandContextTokens() throws {
        let small = AppleFoundationModelFacts(available: true, modelName: "AFM 3 Core", contextWindow: 4_096)
        #expect(!small.isEligibleUtilityModel)
        #expect(!FoundationModelsProvider.eligibleForUtilityRole(facts: small))
        #expect(
            small.utilityEligibilityError == "AFM 3 Core provides 4096 context tokens. OpenClaw's Apple setup option requires at least 8192. "
                + "Choose another local or cloud model on this device."
        )
        #expect(throws: OpenClawCoreError.self) {
            try FoundationModelsProvider.requireUsableUtilityModel(facts: small)
        }
        // Upstream index.test.ts: "retains a larger context window".
        let large = AppleFoundationModelFacts(available: true, modelName: "AFM 3 Core Advanced", contextWindow: 16_384)
        #expect(large.isEligibleUtilityModel)
        #expect(large.utilityEligibilityError == nil)
        try FoundationModelsProvider.requireUsableUtilityModel(facts: large)
        let unavailable = AppleFoundationModelFacts.unavailable(reason: "Wait for Apple Intelligence to finish downloading its model, then retry setup.")
        #expect(unavailable.utilityEligibilityError == "Wait for Apple Intelligence to finish downloading its model, then retry setup.")
    }

    @Test
    func providerConfigMatchesUpstreamBuildAppleFmProviderConfig() throws {
        let facts = AppleFoundationModelFacts(available: true, modelName: "AFM 3 Core Advanced", contextWindow: 8_192, supportsVision: true)
        let config = FoundationModelsProvider.buildProviderConfig(facts: facts)
        #expect(config.baseURL == "http://127.0.0.1")
        #expect(config.api == .openAICompletions)
        #expect(config.authHeader == false)
        #expect(config.auth == nil)
        let model = try #require(config.models.first)
        #expect(config.models.count == 1)
        #expect(model.id == "system")
        #expect(model.name == "AFM 3 Core Advanced")
        #expect(model.reasoning == false)
        #expect(model.input == [.text])
        #expect(model.cost == ModelCostConfig())
        #expect(model.contextWindow == 8_192)
        #expect(model.maxTokens == 1_024)
        #expect(model.compat?.supportsTools == true)
        #expect(model.compat?.supportsDeveloperRole == false)
        #expect(model.compat?.supportsUsageInStreaming == true)

        let upstream = try json(
            """
            {"baseUrl":"http://127.0.0.1","api":"openai-completions","authHeader":false,"timeoutSeconds":120,
             "models":[{"id":"system","name":"AFM 3 Core Advanced","reasoning":false,"input":["text"],
             "cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0},"contextWindow":8192,"maxTokens":1024,
             "compat":{"supportsTools":true,"supportsJsonSchemaResponseFormat":true,"supportsDeveloperRole":false,
             "supportsUsageInStreaming":true}}]}
            """
        )
        #expect(FoundationModelsProvider.upstreamProviderConfigJSON(facts: facts) == upstream)
    }

    @Test
    func catalogModelDefinitionUsesTwentySevenCapabilities() {
        let facts = AppleFoundationModelFacts(
            target: .privateCloudCompute,
            available: true,
            modelName: "Apple Foundation Models (Private Cloud Compute)",
            contextWindow: 32_768,
            supportsVision: true,
            supportsReasoning: true
        )
        let definition = FoundationModelsProvider.modelDefinition(facts: facts)
        #expect(definition.id == "private-cloud-compute")
        #expect(definition.input == [.text, .image])
        #expect(definition.reasoning)
        #expect(definition.contextWindow == 32_768)
        #expect(definition.maxTokens == 1_024)
    }

    @Test
    func availabilityMessagesUseUpstreamSetupCopy() {
        typealias Availability = FoundationModelsRuntimeAvailability
        #expect(Availability.unavailable(.appleIntelligenceNotEnabled).message == "Enable Apple Intelligence in System Settings, then retry setup.")
        #expect(
            Availability.unavailable(.modelNotReady).message
                == "Wait for Apple Intelligence to finish downloading its model, then retry setup."
        )
        #expect(Availability.unavailable(.deviceNotEligible).message == "This device is not eligible for Apple Intelligence. Choose another model.")
        #expect(Availability.unavailable(.unknown).message == "Apple Intelligence is unavailable. Check System Settings, then retry setup.")
        #expect(Availability.unavailable(.unsupportedOS).message == "Foundation Models require Apple OS 26 or later.")
        #expect(Availability.unavailable(.contextWindowTooSmall(4_096)).message.contains("provides 4096 context tokens"))
        #expect(Availability.unavailable(.systemModelUnsupportedOnPlatform).message.contains("apple-fm/private-cloud-compute"))
        #expect(Availability.Reason.privateCloudSystemNotReady.code == "private_cloud_system_not_ready")
        #expect(!Availability.unavailable(.frameworkUnavailable).isAvailable)
        #expect(Availability.available.isAvailable)
    }

    @Test
    func providerDeclaresContractV2Capabilities() {
        let capabilities = FoundationModelsProvider().capabilities
        #expect(capabilities.supportsStreaming)
        #expect(capabilities.supportsTools)
        #expect(capabilities.supportsJSONSchema)
        #expect(capabilities.supportsTranscript)
        #expect(FoundationModelsProvider(options: FoundationModelsProviderOptions(defaultTarget: .privateCloudCompute)).capabilities.supportsReasoning)
    }
}

@Suite("Apple FM errors")
struct AppleFoundationModelsErrorTests {
    @Test
    func codesAreStableAndClassified() {
        #expect(FoundationModelsError.Code.contextOverflow.rawValue == "context_overflow")
        #expect(FoundationModelsError.Code.rateLimited.rawValue == "rate_limited")
        #expect(FoundationModelsError.Code.invalidStructuredOutput.rawValue == "invalid_structured_output")
        let limited = FoundationModelsError(code: .rateLimited, message: "Private Cloud Compute quota limit reached")
        #expect(limited.retryable)
        #expect(limited.description == "rate_limited: Private Cloud Compute quota limit reached")
        #expect(!FoundationModelsError(code: .guardrail, message: "blocked").retryable)
        guard case .invalidConfiguration = FoundationModelsError.invalidRequest("x").coreError else {
            Issue.record("invalid requests map to invalidConfiguration")
            return
        }
        guard case .unavailable = limited.coreError else {
            Issue.record("rate limits map to unavailable")
            return
        }
    }

    @Test
    func mapperPassesThroughKnownErrorsAndSniffsSandboxFailures() {
        let original = OpenClawCoreError.unavailable("x")
        #expect(FoundationModelsErrorMapper.map(original) is OpenClawCoreError)
        struct Sandbox: Error, CustomStringConvertible {
            var description: String { "ModelCatalog lookup failed: sandbox restriction" }
        }
        let mapped = FoundationModelsErrorMapper.map(Sandbox()) as? FoundationModelsError
        #expect(mapped?.code == .unavailable)
        struct Other: Error {}
        #expect(FoundationModelsErrorMapper.map(Other()) is Other)
    }
}

@Suite("Apple FM JSON Schema converter")
struct AppleFoundationModelsSchemaConverterTests {
    @Test
    func convertsTheUpstreamSetupToolSchema() throws {
        // stream.test.ts: Type.Object({ action: Type.Literal("connect_channel"), channel: Type.String(),
        // sha256: Type.Optional(Type.String({ pattern })) }).
        let schema = try json(
            """
            {"type":"object","required":["action","channel"],"properties":{
              "action":{"const":"connect_channel","type":"string"},
              "channel":{"type":"string"},
              "sha256":{"type":"string","pattern":"^[a-fA-F0-9]{64}$"}}}
            """
        )
        let node = try FoundationModelsSchemaConverter.parse(schema, name: "openclaw")
        #expect(
            node == .object(
                name: "openclaw",
                properties: [
                    FoundationModelsSchemaProperty(name: "action", schema: .choices(name: "openclaw_action", values: ["connect_channel"]), isOptional: false),
                    FoundationModelsSchemaProperty(name: "channel", schema: .string, isOptional: false),
                    FoundationModelsSchemaProperty(name: "sha256", schema: .string, isOptional: true),
                ]
            )
        )
    }

    @Test
    func typeUnionsAnyOfEnumsAndGuides() throws {
        let union = try FoundationModelsSchemaConverter.parse(try json(#"{"type":["string","null"]}"#), name: "value")
        #expect(union == .anyOf(name: "value", options: [.string, .null]))

        let anyOf = try FoundationModelsSchemaConverter.parse(
            try json(#"{"anyOf":[{"type":"integer","minimum":1,"maximum":5},{"type":"boolean"}],"description":"d"}"#),
            name: "choice"
        )
        #expect(anyOf == .anyOf(name: "choice", options: [.integer(minimum: 1, maximum: 5), .boolean]))

        let choices = try FoundationModelsSchemaConverter.parse(try json(#"{"type":"string","enum":["a","b"]}"#), name: "mode")
        #expect(choices == .choices(name: "mode", values: ["a", "b"]))

        let array = try FoundationModelsSchemaConverter.parse(
            try json(#"{"type":"array","items":{"type":"number","minimum":0.5},"minItems":1,"maxItems":3}"#),
            name: "tags"
        )
        #expect(array == .array(item: .number(minimum: 0.5, maximum: nil), minimumElements: 1, maximumElements: 3))

        let integral = try FoundationModelsSchemaConverter.parse(try json(#"{"type":"integer","minimum":2.0}"#), name: "count")
        #expect(integral == .integer(minimum: 2, maximum: nil))

        let described = try FoundationModelsSchemaConverter.parse(
            try json(#"{"type":"object","properties":{"b":{"type":"string","description":"second"},"a":{"type":"boolean"}},"required":["b"]}"#),
            name: "args"
        )
        #expect(
            described == .object(
                name: "args",
                properties: [
                    FoundationModelsSchemaProperty(name: "a", schema: .boolean, isOptional: true),
                    FoundationModelsSchemaProperty(name: "b", description: "second", schema: .string, isOptional: false),
                ]
            )
        )
        #expect(FoundationModelsSchemaConverter.canConvert(ModelToolDefinition.emptyParametersSchema, name: "empty"))
    }

    @Test
    func rejectsSchemasWithUpstreamMessages() throws {
        let cases: [(String, String)] = [
            (#"{"type":"object","oneOf":[]}"#, "Unsupported schema keyword oneOf in tool"),
            (#"{"type":"string","format":"uri"}"#, "Unsupported schema keyword format in tool"),
            (#"{"type":"string","anyOf":[{"type":"string"}]}"#, "Unsupported combined anyOf schema: tool"),
            (#"{"anyOf":[]}"#, "Unsupported combined anyOf schema: tool"),
            (#"{"type":[]}"#, "Schema type union is empty: tool"),
            (#"{"description":"no type"}"#, "Expected string: tool.type"),
            (#"{"type":"integer","const":1}"#, "Only string literal schemas are supported: tool"),
            (#"{"type":"string","enum":[]}"#, "Only nonempty string enums are supported: tool"),
            (#"{"type":"string","enum":["a",1]}"#, "Only nonempty string enums are supported: tool"),
            (#"{"type":"object","additionalProperties":true}"#, "Additional object properties are unsupported: tool"),
            (#"{"type":"object","additionalProperties":{"type":"string"}}"#, "Additional object properties are unsupported: tool"),
            (#"{"type":"object","properties":{"a":{"type":"string"}},"required":["b"]}"#, "Invalid required properties: tool"),
            (#"{"type":"object","properties":[]}"#, "Expected object: tool.properties"),
            (#"{"type":"object","properties":{"a":true}}"#, "Expected object: tool.a"),
            (#"{"type":"array"}"#, "Expected object: tool.items"),
            (#"{"type":"integer","minimum":1.5}"#, "Expected integer: tool.minimum"),
            (#"{"type":"integer","maximum":true}"#, "Expected integer: tool.maximum"),
            (#"{"type":"number","minimum":"1"}"#, "Expected number: tool.minimum"),
            (#"{"type":"string","minLength":5,"maxLength":2}"#, "Invalid string length bounds: tool"),
            (#"{"type":"string","minLength":-1}"#, "Invalid string length bounds: tool"),
            (#"{"type":"date"}"#, "Unsupported schema type date in tool"),
        ]
        for (schema, message) in cases {
            let parsed = try json(schema)
            expectFoundationModelsError(message, code: .invalidSchema) {
                _ = try FoundationModelsSchemaConverter.parse(parsed, name: "tool")
            }
        }
    }

    @Test
    func sanitizerRewritesAgentToolSchemasIntoTheSupportedSubset() throws {
        let schema = try json(
            """
            {"type":"object","additionalProperties":true,"required":["q","missing"],"properties":{
              "q":{"type":"string","format":"uri"},
              "mode":{"oneOf":[{"type":"string","enum":["a"]},{"type":"integer","const":1}]},
              "limit":{"type":"integer","minimum":1.5},
              "any":{}}}
            """
        )
        #expect(!FoundationModelsSchemaConverter.canConvert(schema, name: "search"))
        let (sanitized, notices) = FoundationModelsSchemaConverter.sanitize(schema, path: "search")
        #expect(!notices.isEmpty)
        #expect(notices.contains("search.q: dropped unsupported keyword format"))
        #expect(notices.contains("search.mode: oneOf treated as anyOf"))
        let node = try FoundationModelsSchemaConverter.parse(sanitized, name: "search")
        guard case .object(_, let properties) = node else {
            Issue.record("expected object")
            return
        }
        #expect(properties.map(\.name) == ["any", "limit", "mode", "q"])
        #expect(properties.first { $0.name == "q" }?.isOptional == false)
    }
}

@Suite("Apple FM structured output validation")
struct AppleFoundationModelsStructuredOutputTests {
    private func wrapped(_ value: String) throws -> [String: AnyCodable] {
        try json(#"{"type":"object","properties":{"value":\#(value)},"required":["value"]}"#)
    }

    @Test
    func rejectsViolationsBeforePublishing() throws {
        // stream.test.ts "rejects a structured response violating $name before publishing it".
        let cases: [(schema: String, text: String)] = [
            (#"{"type":"string","minLength":1}"#, #"{"value":""}"#),
            (#"{"type":"string","maxLength":3}"#, #"{"value":"long"}"#),
            (#"{"type":"string","pattern":"^[a-f0-9]{8}$"}"#, #"{"value":"invalid"}"#),
            (#"{"anyOf":[{"type":"string"},{"type":"null"}]}"#, #"{"value":42}"#),
            (#"{"type":"number","maximum":9007199254740992}"#, #"{"value":9007199254740993}"#),
            (#"{"type":"number","maximum":9007199254740992}"#, #"{"value":9.007199254740993e15}"#),
            (#"{"type":"string"}"#, "Bearer synthetic-private-note-9281"),
        ]
        for (schema, text) in cases {
            let parsed = try self.wrapped(schema)
            do {
                try FoundationModelsStructuredOutputValidator.validate(text, against: parsed)
                Issue.record("Expected rejection of \(text)")
            } catch let error as FoundationModelsError {
                #expect(error.code == .invalidStructuredOutput)
                #expect(error.message.contains("invalid structured response"))
                #expect(!error.message.contains("Bearer"))
                #expect(!error.message.contains("synthetic-private-note"))
            }
        }
    }

    @Test
    func reportsPathsAndUpstreamMessages() throws {
        let schema = try self.wrapped(#"{"type":"string","minLength":1}"#)
        #expect(throws: FoundationModelsError.schemaViolation(paths: ["value"])) {
            try FoundationModelsStructuredOutputValidator.validate(#"{"value":""}"#, against: schema)
        }
        #expect(throws: FoundationModelsError.schemaViolation(paths: ["value"])) {
            try FoundationModelsStructuredOutputValidator.validate("{}", against: schema)
        }
        #expect(throws: FoundationModelsError.malformedJSON) {
            try FoundationModelsStructuredOutputValidator.validate("{\"value\":", against: schema)
        }
        #expect(throws: FoundationModelsError.unsafeNumber) {
            try FoundationModelsStructuredOutputValidator.validate(#"{"value":1e999}"#, against: schema)
        }
        #expect(
            FoundationModelsError.unsafeNumber.message
                == "Apple Foundation Models returned an invalid structured response: an unsafe numeric value cannot be validated without losing precision."
        )
        #expect(FoundationModelsError.malformedJSON.message == "Apple Foundation Models returned an invalid structured response: malformed JSON.")
    }

    @Test
    func unsafeNumericLiteralsAreNeverRevalidatedAsStrings() throws {
        let schema = try self.wrapped(#"{"type":"string"}"#)
        for literal in ["9007199254740993", "-9007199254740993", "9.007199254740993e15", "1e999"] {
            do {
                try FoundationModelsStructuredOutputValidator.validate(#"{"value":\#(literal)}"#, against: schema)
                Issue.record("Expected rejection of \(literal)")
            } catch let error as FoundationModelsError {
                #expect(error.message.contains("invalid structured response"))
            }
        }
    }

    @Test
    func preservesValidResponsesAndNumericRepresentations() throws {
        let annotated = try json(
            """
            {"type":"object","properties":{"value":{"type":"string","minLength":1,"maxLength":5},
             "notes":{"anyOf":[{"type":"string"},{"type":"null"}]},"fallback":{"type":"string","default":"unused"}},
             "required":["value","notes"]}
            """
        )
        try FoundationModelsStructuredOutputValidator.validate("  {\"value\":\"ready\",\"notes\":null}\n", against: annotated)
        let valid: [(schema: String, text: String)] = [
            (#"{"type":"string"}"#, #"{"value":"9007199254740993"}"#),
            (#"{"type":"string"}"#, #"{"value":"9.007199254740993e15"}"#),
            (#"{"type":"integer","const":1000}"#, #"{"value":1e3}"#),
            (#"{"type":"number","const":0.25}"#, #"{"value":0.25}"#),
            (#"{"type":"string","pattern":"^[a-f0-9]{8}$"}"#, #"{"value":"deadbeef"}"#),
            (#"{"type":"array","items":{"type":"integer"},"minItems":1}"#, #"{"value":[1,2,-3]}"#),
            (#"{"type":"string"}"#, #"{"value":"café 😀 \"q\""}"#),
        ]
        for (schema, text) in valid {
            try FoundationModelsStructuredOutputValidator.validate(text, against: try self.wrapped(schema))
        }
    }

    @Test
    func detectsUnsafeIntegerLiteralsOutsideStringsOnly() {
        #expect(FoundationModelsStructuredOutputValidator.containsUnsafeIntegerLiteral(#"{"a":9007199254740992}"#))
        #expect(!FoundationModelsStructuredOutputValidator.containsUnsafeIntegerLiteral(#"{"a":9007199254740991}"#))
        #expect(!FoundationModelsStructuredOutputValidator.containsUnsafeIntegerLiteral(#"{"a":"9007199254740993"}"#))
        #expect(!FoundationModelsStructuredOutputValidator.containsUnsafeIntegerLiteral(#"{"a":1.0000000000000002}"#))
    }
}

@Suite("Apple FM transcript replay")
struct AppleFoundationModelsTranscriptTests {
    private let call = ModelToolCall(
        id: "call-1",
        name: "openclaw",
        arguments: ["action": AnyCodable("connect_channel"), "channel": AnyCodable("telegram")]
    )

    @Test
    func lastUserMessageBecomesThePrompt() throws {
        let plan = try FoundationModelsTranscriptPlanner.plan(
            systemPrompt: "Only propose actions through the supplied tool.",
            messages: [.system("Be brief."), .user("Hi"), .assistant("Hello"), .user("Connect Telegram.")],
            allowImages: false,
            allowReasoning: false
        )
        #expect(plan.instructions == "Only propose actions through the supplied tool.\n\nBe brief.")
        #expect(plan.entries == [.prompt([.text("Hi")]), .response("Hello")])
        #expect(plan.prompt == [.text("Connect Telegram.")])
        #expect(plan.promptText == "Connect Telegram.")
    }

    @Test
    func continuationReplaysTheExactToolCallIdentityAndResumesWithAnEmptyPrompt() throws {
        // stream.test.ts "replays the exact tool call identity and tool result for continuation".
        let plan = try FoundationModelsTranscriptPlanner.plan(
            systemPrompt: nil,
            messages: [
                .user("Connect Telegram."),
                .assistant(content: [.toolCall(self.call)]),
                .toolResult(ModelToolResult(toolCallID: "call-1", toolName: "openclaw", content: [.text("The protected setup form is ready.")])),
            ],
            allowImages: false,
            allowReasoning: false
        )
        #expect(plan.prompt.isEmpty)
        #expect(
            plan.entries == [
                .prompt([.text("Connect Telegram.")]),
                .toolCall(ModelToolCall(id: "call-1", name: "openclaw", argumentsJSON: #"{"action":"connect_channel","channel":"telegram"}"#)),
                .toolOutput(id: "call-1", toolName: "openclaw", parts: [.text("The protected setup form is ready.")]),
            ]
        )
    }

    @Test
    func rejectsInconsistentToolTranscriptsWithUpstreamMessages() {
        let result = ModelMessage.toolResult(ModelToolResult(toolCallID: "call-1", toolName: "openclaw", content: [.text("ok")]))
        expectFoundationModelsError("At least one message is required", code: .invalidRequest) {
            _ = try FoundationModelsTranscriptPlanner.plan(systemPrompt: nil, messages: [], allowImages: false, allowReasoning: false)
        }
        expectFoundationModelsError("Duplicate tool call id") {
            _ = try FoundationModelsTranscriptPlanner.plan(
                systemPrompt: nil,
                messages: [.user("x"), .assistant(content: [.toolCall(self.call), .toolCall(self.call)])],
                allowImages: false,
                allowReasoning: false
            )
        }
        expectFoundationModelsError("Unmatched tool result") {
            _ = try FoundationModelsTranscriptPlanner.plan(systemPrompt: nil, messages: [.user("x"), result], allowImages: false, allowReasoning: false)
        }
        expectFoundationModelsError("Unmatched tool result") {
            let wrongName = ModelMessage.toolResult(ModelToolResult(toolCallID: "call-1", toolName: "other", content: []))
            _ = try FoundationModelsTranscriptPlanner.plan(
                systemPrompt: nil,
                messages: [.user("x"), .assistant(content: [.toolCall(self.call)]), wrongName],
                allowImages: false,
                allowReasoning: false
            )
        }
        expectFoundationModelsError("Tool calls are missing results") {
            _ = try FoundationModelsTranscriptPlanner.plan(
                systemPrompt: nil,
                messages: [.user("x"), .assistant(content: [.toolCall(self.call)]), .user("again")],
                allowImages: false,
                allowReasoning: false
            )
        }
        expectFoundationModelsError("Expected object: toolCall.arguments") {
            _ = try FoundationModelsTranscriptPlanner.plan(
                systemPrompt: nil,
                messages: [.user("x"), .assistant(content: [.toolCall(ModelToolCall(id: "c", name: "t", argumentsJSON: "[1]"))])],
                allowImages: false,
                allowReasoning: false
            )
        }
        expectFoundationModelsError("Duplicate tool name") {
            try FoundationModelsTranscriptPlanner.validateToolNames([ModelToolDefinition(name: "a"), ModelToolDefinition(name: "a")])
        }
    }

    @Test
    func imagesNeedVisionAndGetTranscriptUniqueLabels() throws {
        let image = MediaAttachment(mimeType: "image/png", data: Data([0x89, 0x50]))
        expectFoundationModelsError("Only text content is supported for user and tool-result messages") {
            _ = try FoundationModelsTranscriptPlanner.plan(
                systemPrompt: nil,
                messages: [.user(content: [.text("What color?"), .image(image)])],
                allowImages: false,
                allowReasoning: false
            )
        }
        let plan = try FoundationModelsTranscriptPlanner.plan(
            systemPrompt: nil,
            messages: [.user(content: [.image(image)]), .assistant("Red"), .user(content: [.text("And these?"), .image(image), .image(image)])],
            allowImages: true,
            allowReasoning: false
        )
        #expect(plan.entries.first == .prompt([.image(image, label: "image-1")]))
        #expect(plan.promptImageLabels == ["image-2", "image-3"])
        #expect(plan.containsImages)
    }

    @Test
    func reasoningIsReplayedOnlyWhenSupportedAndTextAttachmentsAreInlined() throws {
        let messages: [ModelMessage] = [
            .user("q"),
            .assistant(content: [.thinking("plan", signature: nil), .text("a")]),
            .user(content: [.attachment(MediaAttachment(mimeType: "text/plain", data: Data("notes".utf8), fileName: "n.txt"))]),
        ]
        let without = try FoundationModelsTranscriptPlanner.plan(systemPrompt: nil, messages: messages, allowImages: false, allowReasoning: false)
        #expect(without.entries == [.prompt([.text("q")]), .response("a")])
        #expect(without.prompt == [.text("[Attachment n.txt]\nnotes")])
        let with = try FoundationModelsTranscriptPlanner.plan(systemPrompt: nil, messages: messages, allowImages: false, allowReasoning: true)
        #expect(with.entries == [.prompt([.text("q")]), .reasoning("plan", signature: nil), .response("a")])
        expectFoundationModelsError("Only text content is supported") {
            _ = try FoundationModelsTranscriptPlanner.plan(
                systemPrompt: nil,
                messages: [.user(content: [.attachment(MediaAttachment(mimeType: "application/zip", data: Data([1])))])],
                allowImages: true,
                allowReasoning: false
            )
        }
    }
}

@Suite("Apple FM provider plumbing")
struct AppleFoundationModelsPlumbingTests {
    @Test
    func executedToolCallsBecomeTranscriptPairs() {
        let call = ModelToolCall(id: "c1", name: "lookup", arguments: ["q": AnyCodable("x")])
        let result = FoundationModelsGenerationResult(
            response: ModelGenerationResponse(text: "done", providerID: "apple-fm", modelID: "system"),
            target: .system,
            executedToolCalls: [FoundationModelsExecutedToolCall(call: call, output: FoundationModelsToolOutput(text: "42"))]
        )
        #expect(
            result.executedToolMessages == [
                .assistant(content: [.toolCall(call)]),
                .toolResult(ModelToolResult(toolCallID: "c1", toolName: "lookup", content: [.text("42")])),
            ]
        )
    }

    @Test
    func cancellationRegistryCancelsByToken() {
        let registry = FoundationModelsCancellationRegistry()
        let counter = LockedCounter()
        let first = registry.register(token: "t") { counter.increment() }
        _ = registry.register(token: "t") { counter.increment() }
        let other = registry.register(token: "u") { counter.increment() }
        registry.unregister(first)
        #expect(registry.cancel(token: "t") == 1)
        #expect(registry.cancel(token: "t") == 0)
        registry.unregister(other)
        #expect(registry.cancel(token: "u") == 0)
        #expect(counter.value == 1)
        _ = registry.register(token: nil) { counter.increment() }
    }

    @Test
    func providerReportsUnavailableWhereTheModelCannotRun() async throws {
        let availability = FoundationModelsProvider.runtimeAvailability()
        guard !availability.isAvailable else { return }
        do {
            _ = try await FoundationModelsProvider().generate(ModelGenerationRequest(sessionKey: "s", prompt: "hello"))
            Issue.record("Expected unavailable")
        } catch {
            #expect(String(describing: error).contains(availability.message))
        }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.count
    }

    func increment() {
        self.lock.lock()
        self.count += 1
        self.lock.unlock()
    }
}
