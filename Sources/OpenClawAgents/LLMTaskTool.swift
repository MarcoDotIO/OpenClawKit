import Foundation
import OpenClawCore
import OpenClawModels
import OpenClawProtocol

/// Configuration for the built-in `llm-task` tool.
public struct LLMTaskToolConfiguration: Sendable, Equatable {
    /// Default provider identifier used when a call omits `provider`.
    public let defaultProviderID: String?
    /// Default model identifier used when a call omits `model`.
    public let defaultModelID: String?
    /// Default auth-profile identifier used when a call omits `authProfileId`.
    public let defaultAuthProfileID: String?
    /// Default execution timeout in milliseconds.
    public let defaultTimeoutMs: Int
    /// Optional allowlist of permitted provider identifiers.
    public let allowedProviderIDs: Set<String>
    /// Optional allowlist of permitted model identifiers.
    public let allowedModelIDs: Set<String>

    /// Creates `llm-task` configuration.
    public init(
        defaultProviderID: String? = nil,
        defaultModelID: String? = nil,
        defaultAuthProfileID: String? = nil,
        defaultTimeoutMs: Int = 30_000,
        allowedProviderIDs: Set<String> = [],
        allowedModelIDs: Set<String> = []
    ) {
        self.defaultProviderID = Self.normalize(defaultProviderID)
        self.defaultModelID = Self.normalize(defaultModelID)
        self.defaultAuthProfileID = Self.normalize(defaultAuthProfileID)
        self.defaultTimeoutMs = max(1, defaultTimeoutMs)
        self.allowedProviderIDs = Set(allowedProviderIDs.compactMap(Self.normalize))
        self.allowedModelIDs = Set(allowedModelIDs.compactMap(Self.normalize))
    }

    private static func normalize(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

/// Errors thrown by the built-in `llm-task` tool.
public enum LLMTaskToolError: Error, LocalizedError, Sendable, Equatable {
    case missingPrompt
    case invalidArgument(String)
    case unsupportedProvider(String)
    case unsupportedModel(String)
    case timedOut(Int)
    case invalidJSONOutput
    case schemaValidationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingPrompt:
            return "llm-task requires a non-empty prompt"
        case .invalidArgument(let name):
            return "llm-task argument is invalid: \(name)"
        case .unsupportedProvider(let providerID):
            return "llm-task provider is not allowed: \(providerID)"
        case .unsupportedModel(let modelID):
            return "llm-task model is not allowed: \(modelID)"
        case .timedOut(let timeoutMs):
            return "llm-task timed out after \(timeoutMs)ms"
        case .invalidJSONOutput:
            return "llm-task model output was not valid JSON"
        case .schemaValidationFailed(let detail):
            return "llm-task schema validation failed: \(detail)"
        }
    }
}

/// First-party JSON-only tool backed by the current model router.
public struct LLMTaskTool: AgentTool {
    public let name: String

    /// JSON Schema of the `llm-task` arguments (upstream `llmTaskToolDefinition.parameters`).
    public static let parametersSchema: [String: AnyCodable] = [
        "type": AnyCodable("object"),
        "properties": AnyCodable([
            "prompt": Self.property(type: "string", description: "Task instruction for the LLM."),
            "input": Self.property(type: nil, description: "Optional input payload for the task."),
            "schema": Self.property(type: nil, description: "Optional JSON Schema to validate the returned JSON."),
            "provider": Self.property(type: "string", description: "Provider override (e.g. openai, anthropic)."),
            "model": Self.property(type: "string", description: "Model id override."),
            "thinking": Self.property(type: "string", description: "Thinking level override."),
            "authProfileId": Self.property(type: "string", description: "Auth profile override."),
            "temperature": Self.property(type: "number", description: "Best-effort temperature override."),
            "maxTokens": Self.property(type: "integer", description: "Best-effort maxTokens override.", minimum: 1),
            "timeoutMs": Self.property(type: "integer", description: "Timeout for the LLM run.", minimum: 1, maximum: Self.maxTimeoutMs),
        ] as [String: AnyCodable]),
        "required": AnyCodable(["prompt"]),
    ]

    /// Model-facing description of the tool (upstream `llmTaskToolDefinition`).
    public var descriptor: AgentToolDescriptor {
        AgentToolDescriptor(
            name: self.name,
            label: "LLM Task",
            description: "Run a generic JSON-only LLM task and return schema-validated JSON. "
                + "Designed for orchestration from Lobster workflows via openclaw.invoke.",
            parameters: Self.parametersSchema,
            source: .core
        )
    }

    /// Longest `timeoutMs` a call may request (24 hours); larger values are clamped.
    public static let maxTimeoutMs = 86_400_000

    private static func property(type: String?, description: String, minimum: Int? = nil, maximum: Int? = nil) -> AnyCodable {
        var schema: [String: AnyCodable] = ["description": AnyCodable(description)]
        if let type {
            schema["type"] = AnyCodable(type)
        }
        if let minimum {
            schema["minimum"] = AnyCodable(minimum)
        }
        if let maximum {
            schema["maximum"] = AnyCodable(maximum)
        }
        return AnyCodable(schema)
    }

    private let modelRouter: ModelRouter
    private let configuration: LLMTaskToolConfiguration

    /// Creates the built-in `llm-task` tool.
    public init(
        name: String = "llm-task",
        modelRouter: ModelRouter,
        configuration: LLMTaskToolConfiguration = LLMTaskToolConfiguration()
    ) {
        self.name = name
        self.modelRouter = modelRouter
        self.configuration = configuration
    }

    /// Executes a JSON-only task using the model router.
    public func execute(arguments: [String: AnyCodable]) async throws -> AnyCodable {
        let invocation = try Invocation(arguments: arguments, configuration: self.configuration)
        let request = invocation.makeRequest()
        let response = try await self.generate(request, timeoutMs: invocation.timeoutMs)
        let payload = ProviderVisibleTextSanitizer.extractJSONPayload(response.text)
        guard let data = payload.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(AnyCodable.self, from: data)
        else {
            throw LLMTaskToolError.invalidJSONOutput
        }
        if let schema = invocation.schema {
            do {
                try JSONSchemaValidator.validate(instance: decoded, against: schema)
            } catch let error as JSONSchemaValidationError {
                throw LLMTaskToolError.schemaValidationFailed(error.message)
            }
        }
        return decoded
    }

    private func generate(
        _ request: ModelGenerationRequest,
        timeoutMs: Int
    ) async throws -> ModelGenerationResponse {
        let timeoutNs = RuntimeTime.sleepNanoseconds(milliseconds: timeoutMs)
        return try await withThrowingTaskGroup(of: ModelGenerationResponse.self) { group in
            group.addTask {
                try await self.modelRouter.generate(request)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNs)
                throw LLMTaskToolError.timedOut(timeoutMs)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

private extension LLMTaskTool {
    struct Invocation: Sendable {
        let prompt: String
        let input: AnyCodable?
        let schema: [String: AnyCodable]?
        let providerID: String?
        let modelID: String?
        let authProfileID: String?
        let thinkingLevel: ThinkLevel?
        let temperature: Double?
        let maxTokens: Int?
        let timeoutMs: Int

        init(
            arguments: [String: AnyCodable],
            configuration: LLMTaskToolConfiguration
        ) throws {
            guard let prompt = Self.string(arguments["prompt"])?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !prompt.isEmpty
            else {
                throw LLMTaskToolError.missingPrompt
            }
            self.prompt = prompt
            self.input = arguments["input"]
            self.schema = try Self.schema(arguments["schema"])

            let providerID = Self.string(arguments["provider"]) ?? configuration.defaultProviderID
            if let providerID,
               configuration.allowedProviderIDs.isEmpty == false,
               configuration.allowedProviderIDs.contains(providerID) == false
            {
                throw LLMTaskToolError.unsupportedProvider(providerID)
            }
            self.providerID = providerID

            let modelID = Self.string(arguments["model"]) ?? configuration.defaultModelID
            if let modelID,
               configuration.allowedModelIDs.isEmpty == false,
               configuration.allowedModelIDs.contains(modelID) == false
            {
                throw LLMTaskToolError.unsupportedModel(modelID)
            }
            self.modelID = modelID
            self.authProfileID = Self.string(arguments["authProfileId"]) ?? configuration.defaultAuthProfileID

            if let rawThinking = Self.string(arguments["thinking"]) {
                guard let normalized = ThinkLevel.normalize(rawThinking) else {
                    throw LLMTaskToolError.invalidArgument("thinking")
                }
                self.thinkingLevel = Self.resolveThinkingLevel(
                    normalized,
                    providerID: providerID,
                    modelID: modelID
                )
            } else {
                self.thinkingLevel = nil
            }

            self.temperature = try Self.double(arguments["temperature"], name: "temperature")
            self.maxTokens = try Self.int(arguments["maxTokens"], name: "maxTokens")
            let requestedTimeout = try Self.int(arguments["timeoutMs"], name: "timeoutMs")
            self.timeoutMs = min(LLMTaskTool.maxTimeoutMs, max(1, requestedTimeout ?? configuration.defaultTimeoutMs))
        }

        func makeRequest() -> ModelGenerationRequest {
            let renderedPrompt = Self.renderPrompt(
                task: self.prompt,
                input: self.input,
                schema: self.schema
            )
            let reasoningLevel: ReasoningLevel? = self.thinkingLevel == .off ? .off : .on
            return ModelGenerationRequest(
                sessionKey: "llm-task",
                prompt: renderedPrompt,
                systemPrompt: Self.systemPrompt,
                providerID: self.providerID,
                modelID: self.modelID,
                preferredAuthProfileID: self.authProfileID,
                metadata: Self.metadata(for: self.thinkingLevel),
                // Providers resolve the native reasoning effort from `thinkingLevel`
                // (ReasoningEffortResolver); no lossy effort mapping happens here.
                policy: ModelGenerationPolicy(
                    maxTokens: self.maxTokens,
                    temperature: self.temperature,
                    requestTimeoutMs: self.timeoutMs,
                    thinkingLevel: self.thinkingLevel,
                    reasoningLevel: reasoningLevel
                )
            )
        }

        private static let systemPrompt = """
        You are executing the OpenClaw llm-task tool.
        Return exactly one JSON value and nothing else.
        Do not emit markdown fences, commentary, or tool calls.
        """

        private static func renderPrompt(
            task: String,
            input: AnyCodable?,
            schema: [String: AnyCodable]?
        ) -> String {
            var sections = [
                "## Task",
                task,
            ]
            if let input {
                sections.append("## Input JSON")
                sections.append(Self.renderJSON(input))
            }
            if let schema {
                sections.append("## JSON Schema")
                sections.append(Self.renderJSON(AnyCodable(schema)))
            }
            sections.append("## Output Contract")
            sections.append("Return exactly one JSON value that satisfies the schema when provided.")
            return sections.joined(separator: "\n")
        }

        private static func metadata(for thinkingLevel: ThinkLevel?) -> [String: String] {
            guard let thinkingLevel else {
                return [:]
            }
            return ["thinkingLevel": thinkingLevel.rawValue]
        }

        private static func resolveThinkingLevel(
            _ thinkingLevel: ThinkLevel,
            providerID: String?,
            modelID: String?
        ) -> ThinkLevel {
            guard thinkingLevel == .adaptive else {
                // A single llm-task call has no runtime orchestration, so `ultra` becomes `max`.
                return thinkingLevel.providerTransportLevel
            }
            if ThinkLevel.supportsXHighThinking(providerID: providerID, modelID: modelID) {
                return .xhigh
            }
            return .high
        }

        private static func schema(_ value: AnyCodable?) throws -> [String: AnyCodable]? {
            guard let value else {
                return nil
            }
            switch value.value {
            case .object(let schema):
                return schema
            case .string(let raw):
                let payload = ProviderVisibleTextSanitizer.extractJSONPayload(raw)
                guard let data = payload.data(using: .utf8),
                      let decoded = try? JSONDecoder().decode([String: AnyCodable].self, from: data)
                else {
                    throw LLMTaskToolError.invalidArgument("schema")
                }
                return decoded
            default:
                throw LLMTaskToolError.invalidArgument("schema")
            }
        }

        private static func string(_ value: AnyCodable?) -> String? {
            guard let value else {
                return nil
            }
            switch value.value {
            case .string(let raw):
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            default:
                return nil
            }
        }

        private static func int(_ value: AnyCodable?, name: String) throws -> Int? {
            guard let value else {
                return nil
            }
            switch value.value {
            case .int(let number):
                return number
            case .double(let number):
                // Out-of-range or non-finite numbers (and anything above Int32.max on watchOS) are
                // invalid instead of trapping in `Int(_:)`.
                guard number.isFinite, let value = Int(exactly: number.rounded(.towardZero)) else {
                    throw LLMTaskToolError.invalidArgument(name)
                }
                return value
            default:
                throw LLMTaskToolError.invalidArgument(name)
            }
        }

        private static func double(_ value: AnyCodable?, name: String) throws -> Double? {
            guard let value else {
                return nil
            }
            switch value.value {
            case .int(let number):
                return Double(number)
            case .double(let number):
                return number
            default:
                throw LLMTaskToolError.invalidArgument(name)
            }
        }

        private static func renderJSON(_ value: AnyCodable) -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(value),
                  let string = String(data: data, encoding: .utf8)
            else {
                return "{}"
            }
            return string
        }
    }
}
