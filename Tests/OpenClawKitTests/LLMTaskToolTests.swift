import Foundation
import Testing
@testable import OpenClawKit

@Suite("llm-task tool")
struct LLMTaskToolTests {
    actor CapturingProvider: ModelProvider {
        let id: String
        let responseText: String
        let delayNs: UInt64
        private(set) var lastRequest: ModelGenerationRequest?

        init(
            id: String = "openai-codex",
            responseText: String,
            delayNs: UInt64 = 0
        ) {
            self.id = id
            self.responseText = responseText
            self.delayNs = delayNs
        }

        func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
            self.lastRequest = request
            if self.delayNs > 0 {
                try await Task.sleep(nanoseconds: self.delayNs)
            }
            return ModelGenerationResponse(text: self.responseText, providerID: self.id, modelID: request.modelID)
        }

        func snapshot() -> ModelGenerationRequest? {
            self.lastRequest
        }
    }

    @Test
    func returnsValidatedJSONAndThreadsControlsIntoModelRequest() async throws {
        let provider = CapturingProvider(
            responseText: """
            <thinking>private scratchpad</thinking>
            ```json
            {"summary":"done","score":3}
            ```
            """
        )
        let router = ModelRouter()
        await router.register(provider)
        let tool = LLMTaskTool(
            modelRouter: router,
            configuration: LLMTaskToolConfiguration(
                defaultProviderID: "openai-codex",
                defaultModelID: "gpt-5.3-codex",
                defaultAuthProfileID: "work-profile",
                defaultTimeoutMs: 4_000
            )
        )

        let result = try await tool.execute(arguments: [
            "prompt": AnyCodable("Summarize the incident"),
            "input": AnyCodable([
                "ticket": AnyCodable("INC-42"),
                "severity": AnyCodable(2),
            ]),
            "schema": AnyCodable([
                "type": AnyCodable("object"),
                "required": AnyCodable([AnyCodable("summary"), AnyCodable("score")]),
                "additionalProperties": AnyCodable(false),
                "properties": AnyCodable([
                    "summary": AnyCodable(["type": AnyCodable("string")]),
                    "score": AnyCodable([
                        "type": AnyCodable("integer"),
                        "minimum": AnyCodable(1),
                        "maximum": AnyCodable(5),
                    ]),
                ]),
            ]),
            "thinking": AnyCodable("adaptive"),
            "temperature": AnyCodable(0.25),
            "maxTokens": AnyCodable(120),
        ])

        let object = try #require(self.object(result))
        #expect(object["summary"] == AnyCodable("done"))
        #expect(object["score"] == AnyCodable(3))

        let request = try #require(await provider.snapshot())
        #expect(request.providerID == "openai-codex")
        #expect(request.modelID == "gpt-5.3-codex")
        #expect(request.preferredAuthProfileID == "work-profile")
        #expect(request.policy.temperature == 0.25)
        #expect(request.policy.maxTokens == 120)
        #expect(request.policy.requestTimeoutMs == 4_000)
        #expect(request.policy.thinkingLevel == .xhigh)
        #expect(request.policy.reasoningEffort == .high)
        #expect(request.metadata["thinkingLevel"] == "xhigh")
        #expect(request.systemPrompt?.contains("Return exactly one JSON value") == true)
        #expect(request.prompt.contains("## Input JSON"))
        #expect(request.prompt.contains("INC-42"))
        #expect(request.prompt.contains("## JSON Schema"))
    }

    @Test
    func rejectsInvalidJSONOutput() async throws {
        let provider = CapturingProvider(responseText: "definitely not json")
        let router = ModelRouter()
        await router.register(provider)
        let tool = LLMTaskTool(modelRouter: router)

        do {
            _ = try await tool.execute(arguments: [
                "prompt": AnyCodable("Return JSON"),
                "provider": AnyCodable("openai-codex"),
            ])
            Issue.record("Expected invalid JSON failure")
        } catch {
            let typed = error as? LLMTaskToolError
            #expect(typed == .invalidJSONOutput)
        }
    }

    @Test
    func rejectsSchemaViolationsIncludingAdditionalProperties() async throws {
        let provider = CapturingProvider(responseText: #"{"summary":"done","extra":true}"#)
        let router = ModelRouter()
        await router.register(provider)
        let tool = LLMTaskTool(modelRouter: router)

        do {
            _ = try await tool.execute(arguments: [
                "prompt": AnyCodable("Return JSON"),
                "provider": AnyCodable("openai-codex"),
                "schema": AnyCodable([
                    "type": AnyCodable("object"),
                    "required": AnyCodable([AnyCodable("summary")]),
                    "additionalProperties": AnyCodable(false),
                    "properties": AnyCodable([
                        "summary": AnyCodable(["type": AnyCodable("string")]),
                    ]),
                ]),
            ])
            Issue.record("Expected schema failure")
        } catch {
            #expect(String(describing: error).contains("not allowed"))
        }
    }

    @Test
    func validatesArraySchemasAndItemTypes() async throws {
        let provider = CapturingProvider(responseText: #"[1,2,3]"#)
        let router = ModelRouter()
        await router.register(provider)
        let tool = LLMTaskTool(modelRouter: router)

        let result = try await tool.execute(arguments: [
            "prompt": AnyCodable("Return JSON array"),
            "provider": AnyCodable("openai-codex"),
            "schema": AnyCodable([
                "type": AnyCodable("array"),
                "minItems": AnyCodable(2),
                "maxItems": AnyCodable(4),
                "items": AnyCodable(["type": AnyCodable("integer")]),
            ]),
        ])

        let array = try #require(self.array(result))
        #expect(array.count == 3)
        #expect(array[0] == AnyCodable(1))
    }

    @Test
    func validatesNumericBoundsAndEnumValues() async throws {
        let enumProvider = CapturingProvider(id: "enum-provider", responseText: #""approved""#)
        let enumRouter = ModelRouter()
        await enumRouter.register(enumProvider)
        let enumTool = LLMTaskTool(modelRouter: enumRouter)

        let enumResult = try await enumTool.execute(arguments: [
            "prompt": AnyCodable("Return JSON string"),
            "provider": AnyCodable("enum-provider"),
            "schema": AnyCodable([
                "type": AnyCodable([AnyCodable("string"), AnyCodable("null")]),
                "enum": AnyCodable([AnyCodable("approved"), AnyCodable("denied")]),
            ]),
        ])
        #expect(enumResult == AnyCodable("approved"))

        let numericProvider = CapturingProvider(id: "numeric-provider", responseText: #"7"#)
        let numericRouter = ModelRouter()
        await numericRouter.register(numericProvider)
        let numericTool = LLMTaskTool(modelRouter: numericRouter)
        do {
            _ = try await numericTool.execute(arguments: [
                "prompt": AnyCodable("Return JSON number"),
                "provider": AnyCodable("numeric-provider"),
                "schema": AnyCodable([
                    "type": AnyCodable("number"),
                    "maximum": AnyCodable(5),
                ]),
            ])
            Issue.record("Expected numeric schema failure")
        } catch {
            #expect(String(describing: error).contains("<= 5"))
        }
    }

    @Test
    func timesOutSlowModelGeneration() async throws {
        let provider = CapturingProvider(responseText: #"{"ok":true}"#, delayNs: 120_000_000)
        let router = ModelRouter()
        await router.register(provider)
        let tool = LLMTaskTool(modelRouter: router)

        do {
            _ = try await tool.execute(arguments: [
                "prompt": AnyCodable("Return JSON"),
                "provider": AnyCodable("openai-codex"),
                "timeoutMs": AnyCodable(25),
            ])
            Issue.record("Expected timeout")
        } catch {
            #expect(error as? LLMTaskToolError == .timedOut(25))
        }
    }

    @Test
    func rejectsDisallowedProviderAndModel() async throws {
        let provider = CapturingProvider(responseText: #"{"ok":true}"#)
        let router = ModelRouter()
        await router.register(provider)
        let tool = LLMTaskTool(
            modelRouter: router,
            configuration: LLMTaskToolConfiguration(
                allowedProviderIDs: ["openai-codex"],
                allowedModelIDs: ["gpt-5.3-codex"]
            )
        )

        do {
            _ = try await tool.execute(arguments: [
                "prompt": AnyCodable("Return JSON"),
                "provider": AnyCodable("github-copilot"),
            ])
            Issue.record("Expected provider allowlist failure")
        } catch {
            #expect(error as? LLMTaskToolError == .unsupportedProvider("github-copilot"))
        }

        do {
            _ = try await tool.execute(arguments: [
                "prompt": AnyCodable("Return JSON"),
                "provider": AnyCodable("openai-codex"),
                "model": AnyCodable("gpt-5.4"),
            ])
            Issue.record("Expected model allowlist failure")
        } catch {
            #expect(error as? LLMTaskToolError == .unsupportedModel("gpt-5.4"))
        }
    }

    @Test
    func surfacesDescriptionsAndRejectsMissingPrompt() async throws {
        #expect(LLMTaskToolError.missingPrompt.errorDescription == "llm-task requires a non-empty prompt")
        #expect(LLMTaskToolError.invalidArgument("temperature").errorDescription == "llm-task argument is invalid: temperature")
        #expect(LLMTaskToolError.unsupportedProvider("github-copilot").errorDescription == "llm-task provider is not allowed: github-copilot")
        #expect(LLMTaskToolError.unsupportedModel("gpt-5.4").errorDescription == "llm-task model is not allowed: gpt-5.4")
        #expect(LLMTaskToolError.timedOut(250).errorDescription == "llm-task timed out after 250ms")
        #expect(LLMTaskToolError.invalidJSONOutput.errorDescription == "llm-task model output was not valid JSON")
        #expect(
            LLMTaskToolError.schemaValidationFailed("$.value is required").errorDescription
                == "llm-task schema validation failed: $.value is required"
        )

        let tool = LLMTaskTool(modelRouter: ModelRouter())

        do {
            _ = try await tool.execute(arguments: ["prompt": AnyCodable("   ")])
            Issue.record("Expected missing prompt failure")
        } catch {
            #expect(error as? LLMTaskToolError == .missingPrompt)
        }
    }

    @Test
    func rejectsInvalidArgumentShapesBeforeGeneration() async throws {
        let tool = LLMTaskTool(modelRouter: ModelRouter())

        do {
            _ = try await tool.execute(arguments: [
                "prompt": AnyCodable("Return JSON"),
                "thinking": AnyCodable("impossible"),
            ])
            Issue.record("Expected invalid thinking failure")
        } catch {
            #expect(error as? LLMTaskToolError == .invalidArgument("thinking"))
        }

        do {
            _ = try await tool.execute(arguments: [
                "prompt": AnyCodable("Return JSON"),
                "schema": AnyCodable([AnyCodable("object")]),
            ])
            Issue.record("Expected invalid schema shape failure")
        } catch {
            #expect(error as? LLMTaskToolError == .invalidArgument("schema"))
        }

        do {
            _ = try await tool.execute(arguments: [
                "prompt": AnyCodable("Return JSON"),
                "schema": AnyCodable("not-json"),
            ])
            Issue.record("Expected invalid schema string failure")
        } catch {
            #expect(error as? LLMTaskToolError == .invalidArgument("schema"))
        }

        do {
            _ = try await tool.execute(arguments: [
                "prompt": AnyCodable("Return JSON"),
                "temperature": AnyCodable("hot"),
            ])
            Issue.record("Expected invalid temperature failure")
        } catch {
            #expect(error as? LLMTaskToolError == .invalidArgument("temperature"))
        }

        do {
            _ = try await tool.execute(arguments: [
                "prompt": AnyCodable("Return JSON"),
                "maxTokens": AnyCodable("many"),
            ])
            Issue.record("Expected invalid maxTokens failure")
        } catch {
            #expect(error as? LLMTaskToolError == .invalidArgument("maxTokens"))
        }

        do {
            _ = try await tool.execute(arguments: [
                "prompt": AnyCodable("Return JSON"),
                "timeoutMs": AnyCodable("soon"),
            ])
            Issue.record("Expected invalid timeout failure")
        } catch {
            #expect(error as? LLMTaskToolError == .invalidArgument("timeoutMs"))
        }
    }

    @Test
    func parsesSchemaStringsAndNormalizesNumericArguments() async throws {
        let provider = CapturingProvider(id: "openai-codex", responseText: #"{"ok":true}"#)
        let router = ModelRouter()
        await router.register(provider)
        let tool = LLMTaskTool(
            modelRouter: router,
            configuration: LLMTaskToolConfiguration(
                defaultProviderID: "openai-codex",
                defaultModelID: "gpt-4o",
                defaultTimeoutMs: 99
            )
        )

        _ = try await tool.execute(arguments: [
            "prompt": AnyCodable("Return JSON"),
            "provider": AnyCodable(42),
            "thinking": AnyCodable("adaptive"),
            "temperature": AnyCodable(1),
            "maxTokens": AnyCodable(12.9),
            "timeoutMs": AnyCodable(7.0),
            "schema": AnyCodable(
                """
                ```json
                {"type":"object","required":["ok"],"properties":{"ok":{"type":"boolean"}}}
                ```
                """
            ),
        ])

        let request = try #require(await provider.snapshot())
        #expect(request.providerID == "openai-codex")
        #expect(request.modelID == "gpt-4o")
        #expect(request.policy.temperature == 1.0)
        #expect(request.policy.maxTokens == 12)
        #expect(request.policy.requestTimeoutMs == 7)
        #expect(request.policy.thinkingLevel == .high)
        #expect(request.policy.reasoningEffort == .high)
    }

    @Test
    func mapsReasoningEffortAcrossThinkingLevels() async throws {
        let provider = CapturingProvider(id: "openai-codex", responseText: #"{"ok":true}"#)
        let router = ModelRouter()
        await router.register(provider)
        let tool = LLMTaskTool(
            modelRouter: router,
            configuration: LLMTaskToolConfiguration(defaultProviderID: "openai-codex")
        )

        _ = try await tool.execute(arguments: [
            "prompt": AnyCodable("Return JSON"),
            "thinking": AnyCodable("low"),
        ])
        let low = try #require(await provider.snapshot())
        #expect(low.policy.thinkingLevel == .low)
        #expect(low.policy.reasoningEffort == .low)

        _ = try await tool.execute(arguments: [
            "prompt": AnyCodable("Return JSON"),
            "thinking": AnyCodable("medium"),
        ])
        let medium = try #require(await provider.snapshot())
        #expect(medium.policy.thinkingLevel == .medium)
        #expect(medium.policy.reasoningEffort == .medium)

        _ = try await tool.execute(arguments: [
            "prompt": AnyCodable("Return JSON"),
            "thinking": AnyCodable("off"),
        ])
        let off = try #require(await provider.snapshot())
        #expect(off.policy.thinkingLevel == .off)
        #expect(off.policy.reasoningLevel == .off)
        #expect(off.policy.reasoningEffort == nil)
    }

    @Test
    func validatesBooleanNullAndFloatingPointSchemas() async throws {
        let booleanProvider = CapturingProvider(id: "bool-provider", responseText: "true")
        let booleanRouter = ModelRouter()
        await booleanRouter.register(booleanProvider)
        let booleanTool = LLMTaskTool(modelRouter: booleanRouter)
        let booleanResult = try await booleanTool.execute(arguments: [
            "prompt": AnyCodable("Return bool"),
            "provider": AnyCodable("bool-provider"),
            "schema": AnyCodable(["type": AnyCodable("boolean")]),
        ])
        #expect(booleanResult == AnyCodable(true))

        let nullProvider = CapturingProvider(id: "null-provider", responseText: "null")
        let nullRouter = ModelRouter()
        await nullRouter.register(nullProvider)
        let nullTool = LLMTaskTool(modelRouter: nullRouter)
        let nullResult = try await nullTool.execute(arguments: [
            "prompt": AnyCodable("Return null"),
            "provider": AnyCodable("null-provider"),
            "schema": AnyCodable(["type": AnyCodable("null")]),
        ])
        if case .null = nullResult.value {
            #expect(true)
        } else {
            Issue.record("Expected null AnyCodable")
        }

        let numberProvider = CapturingProvider(id: "number-provider", responseText: "1.5")
        let numberRouter = ModelRouter()
        await numberRouter.register(numberProvider)
        let numberTool = LLMTaskTool(modelRouter: numberRouter)
        let numberResult = try await numberTool.execute(arguments: [
            "prompt": AnyCodable("Return number"),
            "provider": AnyCodable("number-provider"),
            "schema": AnyCodable([
                "type": AnyCodable("number"),
                "minimum": AnyCodable(1.0),
            ]),
        ])
        #expect(numberResult == AnyCodable(1.5))
    }

    @Test
    func rejectsSchemaTypeEnumArrayAndMinimumFailures() async throws {
        let mismatchProvider = CapturingProvider(id: "mismatch-provider", responseText: "true")
        let mismatchRouter = ModelRouter()
        await mismatchRouter.register(mismatchProvider)
        let mismatchTool = LLMTaskTool(modelRouter: mismatchRouter)
        do {
            _ = try await mismatchTool.execute(arguments: [
                "prompt": AnyCodable("Return bool"),
                "provider": AnyCodable("mismatch-provider"),
                "schema": AnyCodable(["type": AnyCodable("string")]),
            ])
            Issue.record("Expected type mismatch")
        } catch {
            #expect(String(describing: error).contains("expected string but received boolean"))
        }

        let enumProvider = CapturingProvider(id: "enum-provider", responseText: #""maybe""#)
        let enumRouter = ModelRouter()
        await enumRouter.register(enumProvider)
        let enumTool = LLMTaskTool(modelRouter: enumRouter)
        do {
            _ = try await enumTool.execute(arguments: [
                "prompt": AnyCodable("Return enum"),
                "provider": AnyCodable("enum-provider"),
                "schema": AnyCodable([
                    "enum": AnyCodable([AnyCodable("approved"), AnyCodable("denied")]),
                ]),
            ])
            Issue.record("Expected enum failure")
        } catch {
            #expect(String(describing: error).contains("enum set"))
        }

        let minItemsProvider = CapturingProvider(id: "min-items-provider", responseText: "[1]")
        let minItemsRouter = ModelRouter()
        await minItemsRouter.register(minItemsProvider)
        let minItemsTool = LLMTaskTool(modelRouter: minItemsRouter)
        do {
            _ = try await minItemsTool.execute(arguments: [
                "prompt": AnyCodable("Return array"),
                "provider": AnyCodable("min-items-provider"),
                "schema": AnyCodable([
                    "type": AnyCodable("array"),
                    "minItems": AnyCodable(2),
                ]),
            ])
            Issue.record("Expected minItems failure")
        } catch {
            #expect(String(describing: error).contains("at least 2 items"))
        }

        let maxItemsProvider = CapturingProvider(id: "max-items-provider", responseText: "[1,2,3]")
        let maxItemsRouter = ModelRouter()
        await maxItemsRouter.register(maxItemsProvider)
        let maxItemsTool = LLMTaskTool(modelRouter: maxItemsRouter)
        do {
            _ = try await maxItemsTool.execute(arguments: [
                "prompt": AnyCodable("Return array"),
                "provider": AnyCodable("max-items-provider"),
                "schema": AnyCodable([
                    "type": AnyCodable("array"),
                    "maxItems": AnyCodable(2),
                ]),
            ])
            Issue.record("Expected maxItems failure")
        } catch {
            #expect(String(describing: error).contains("at most 2 items"))
        }

        let minimumProvider = CapturingProvider(id: "minimum-provider", responseText: "0")
        let minimumRouter = ModelRouter()
        await minimumRouter.register(minimumProvider)
        let minimumTool = LLMTaskTool(modelRouter: minimumRouter)
        do {
            _ = try await minimumTool.execute(arguments: [
                "prompt": AnyCodable("Return number"),
                "provider": AnyCodable("minimum-provider"),
                "schema": AnyCodable([
                    "type": AnyCodable("number"),
                    "minimum": AnyCodable(1),
                ]),
            ])
            Issue.record("Expected minimum failure")
        } catch {
            #expect(String(describing: error).contains(">= 1.0"))
        }
    }

    @Test
    func supportsAdditionalPropertySchemasAndLooseValidatorInputs() async throws {
        let additionalProvider = CapturingProvider(id: "additional-provider", responseText: #"{"flag":"yes"}"#)
        let additionalRouter = ModelRouter()
        await additionalRouter.register(additionalProvider)
        let additionalTool = LLMTaskTool(modelRouter: additionalRouter)
        let additionalResult = try await additionalTool.execute(arguments: [
            "prompt": AnyCodable("Return object"),
            "provider": AnyCodable("additional-provider"),
            "schema": AnyCodable([
                "type": AnyCodable("object"),
                "additionalProperties": AnyCodable([
                    "type": AnyCodable("string"),
                ]),
            ]),
        ])
        let additionalObject = try #require(self.object(additionalResult))
        #expect(additionalObject["flag"] == AnyCodable("yes"))

        let looseEnumProvider = CapturingProvider(id: "loose-enum-provider", responseText: #""approved""#)
        let looseEnumRouter = ModelRouter()
        await looseEnumRouter.register(looseEnumProvider)
        let looseEnumTool = LLMTaskTool(modelRouter: looseEnumRouter)
        let looseEnumResult = try await looseEnumTool.execute(arguments: [
            "prompt": AnyCodable("Return string"),
            "provider": AnyCodable("loose-enum-provider"),
            "schema": AnyCodable([
                "enum": AnyCodable("approved"),
            ]),
        ])
        #expect(looseEnumResult == AnyCodable("approved"))

        let looseTypeProvider = CapturingProvider(id: "loose-type-provider", responseText: #""approved""#)
        let looseTypeRouter = ModelRouter()
        await looseTypeRouter.register(looseTypeProvider)
        let looseTypeTool = LLMTaskTool(modelRouter: looseTypeRouter)
        let looseTypeResult = try await looseTypeTool.execute(arguments: [
            "prompt": AnyCodable("Return string"),
            "provider": AnyCodable("loose-type-provider"),
            "schema": AnyCodable([
                "type": AnyCodable(42),
            ]),
        ])
        #expect(looseTypeResult == AnyCodable("approved"))

        let compactTypeProvider = CapturingProvider(id: "compact-type-provider", responseText: #""approved""#)
        let compactTypeRouter = ModelRouter()
        await compactTypeRouter.register(compactTypeProvider)
        let compactTypeTool = LLMTaskTool(modelRouter: compactTypeRouter)
        let compactTypeResult = try await compactTypeTool.execute(arguments: [
            "prompt": AnyCodable("Return string"),
            "provider": AnyCodable("compact-type-provider"),
            "schema": AnyCodable([
                "type": AnyCodable([AnyCodable("string"), AnyCodable(99)]),
            ]),
        ])
        #expect(compactTypeResult == AnyCodable("approved"))
    }

    @Test
    func toleratesLooseSchemaMetadataThatCannotBeNormalized() async throws {
        let noFlagProvider = CapturingProvider(id: "no-flag-provider", responseText: #"{"extra":1}"#)
        let noFlagRouter = ModelRouter()
        await noFlagRouter.register(noFlagProvider)
        let noFlagTool = LLMTaskTool(modelRouter: noFlagRouter)
        let noFlagResult = try await noFlagTool.execute(arguments: [
            "prompt": AnyCodable("Return object"),
            "provider": AnyCodable("no-flag-provider"),
            "schema": AnyCodable([
                "type": AnyCodable("object"),
            ]),
        ])
        let noFlagObject = try #require(self.object(noFlagResult))
        #expect(noFlagObject["extra"] == AnyCodable(1))

        let nonBoolProvider = CapturingProvider(id: "non-bool-provider", responseText: #"{"extra":1}"#)
        let nonBoolRouter = ModelRouter()
        await nonBoolRouter.register(nonBoolProvider)
        let nonBoolTool = LLMTaskTool(modelRouter: nonBoolRouter)
        let nonBoolResult = try await nonBoolTool.execute(arguments: [
            "prompt": AnyCodable("Return object"),
            "provider": AnyCodable("non-bool-provider"),
            "schema": AnyCodable([
                "type": AnyCodable("object"),
                "additionalProperties": AnyCodable("sometimes"),
            ]),
        ])
        let nonBoolObject = try #require(self.object(nonBoolResult))
        #expect(nonBoolObject["extra"] == AnyCodable(1))

        let nonIntProvider = CapturingProvider(id: "non-int-provider", responseText: "[1]")
        let nonIntRouter = ModelRouter()
        await nonIntRouter.register(nonIntProvider)
        let nonIntTool = LLMTaskTool(modelRouter: nonIntRouter)
        let nonIntResult = try await nonIntTool.execute(arguments: [
            "prompt": AnyCodable("Return array"),
            "provider": AnyCodable("non-int-provider"),
            "schema": AnyCodable([
                "type": AnyCodable("array"),
                "minItems": AnyCodable(1.5),
            ]),
        ])
        let nonIntArray = try #require(self.array(nonIntResult))
        #expect(nonIntArray == [AnyCodable(1)])

        let nonDoubleProvider = CapturingProvider(id: "non-double-provider", responseText: "3")
        let nonDoubleRouter = ModelRouter()
        await nonDoubleRouter.register(nonDoubleProvider)
        let nonDoubleTool = LLMTaskTool(modelRouter: nonDoubleRouter)
        let nonDoubleResult = try await nonDoubleTool.execute(arguments: [
            "prompt": AnyCodable("Return number"),
            "provider": AnyCodable("non-double-provider"),
            "schema": AnyCodable([
                "type": AnyCodable("number"),
                "minimum": AnyCodable("soon"),
            ]),
        ])
        #expect(nonDoubleResult == AnyCodable(3))
    }

    @Test
    func fallsBackToEmptyJSONObjectWhenPromptJSONCannotEncode() async throws {
        let provider = CapturingProvider(id: "openai-codex", responseText: #"{"ok":true}"#)
        let router = ModelRouter()
        await router.register(provider)
        let tool = LLMTaskTool(
            modelRouter: router,
            configuration: LLMTaskToolConfiguration(defaultProviderID: "openai-codex")
        )

        _ = try await tool.execute(arguments: [
            "prompt": AnyCodable("Return JSON"),
            "input": AnyCodable(Double.nan),
        ])

        let request = try #require(await provider.snapshot())
        #expect(request.prompt.contains("## Input JSON"))
        #expect(request.prompt.contains("{}"))
    }

    private func object(_ value: AnyCodable) -> [String: AnyCodable]? {
        if case .object(let object) = value.value {
            return object
        }
        return nil
    }

    private func array(_ value: AnyCodable) -> [AnyCodable]? {
        if case .array(let array) = value.value {
            return array
        }
        return nil
    }
}
