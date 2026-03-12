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
            try JSONSchemaValidator.validate(instance: decoded, against: schema)
        }
        return decoded
    }

    private func generate(
        _ request: ModelGenerationRequest,
        timeoutMs: Int
    ) async throws -> ModelGenerationResponse {
        let timeoutNs = UInt64(timeoutMs) * 1_000_000
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
            self.timeoutMs = max(1, requestedTimeout ?? configuration.defaultTimeoutMs)
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
                policy: ModelGenerationPolicy(
                    maxTokens: self.maxTokens,
                    temperature: self.temperature,
                    requestTimeoutMs: self.timeoutMs,
                    reasoningEffort: Self.reasoningEffort(
                        from: self.thinkingLevel,
                        reasoningLevel: reasoningLevel
                    ),
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
                return thinkingLevel
            }
            if ThinkLevel.supportsXHighThinking(providerID: providerID, modelID: modelID) {
                return .xhigh
            }
            return .high
        }

        private static func reasoningEffort(
            from thinkingLevel: ThinkLevel?,
            reasoningLevel: ReasoningLevel?
        ) -> ModelReasoningEffort? {
            if reasoningLevel == .off {
                return nil
            }
            switch thinkingLevel {
            case .minimal, .low:
                return .low
            case .medium:
                return .medium
            case .high, .xhigh:
                return .high
            case .off, .adaptive, nil:
                return nil
            }
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
                return Int(number)
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

    enum JSONSchemaValidator {
        static func validate(instance: AnyCodable, against schema: [String: AnyCodable]) throws {
            try self.validate(instance: instance, against: schema, path: "$")
        }

        private static func validate(
            instance: AnyCodable,
            against schema: [String: AnyCodable],
            path: String
        ) throws {
            if let allowedTypes = self.stringArray(schema["type"]) {
                let actualType = self.typeName(for: instance)
                let acceptsActualType = allowedTypes.contains(actualType)
                    || (actualType == "integer" && allowedTypes.contains("number"))
                if acceptsActualType == false {
                    throw LLMTaskToolError.schemaValidationFailed("\(path) expected \(allowedTypes.joined(separator: "|")) but received \(actualType)")
                }
            }

            if let enumValues = self.anyArray(schema["enum"]),
               enumValues.contains(instance) == false
            {
                throw LLMTaskToolError.schemaValidationFailed("\(path) value is not in enum set")
            }

            switch instance.value {
            case .object(let object):
                try self.validateObject(object, schema: schema, path: path)
            case .array(let array):
                try self.validateArray(array, schema: schema, path: path)
            case .int(let number):
                try self.validateNumber(Double(number), schema: schema, path: path)
            case .double(let number):
                try self.validateNumber(number, schema: schema, path: path)
            case .null, .bool, .string:
                break
            }
        }

        private static func validateObject(
            _ object: [String: AnyCodable],
            schema: [String: AnyCodable],
            path: String
        ) throws {
            let required = Set(self.stringArray(schema["required"]) ?? [])
            for key in required where object[key] == nil {
                throw LLMTaskToolError.schemaValidationFailed("\(path).\(key) is required")
            }
            let propertySchemas = self.object(schema["properties"]) ?? [:]
            for (key, value) in object {
                if let propertySchema = self.object(propertySchemas[key]) {
                    try self.validate(instance: value, against: propertySchema, path: "\(path).\(key)")
                    continue
                }

                if let additionalSchema = self.object(schema["additionalProperties"]) {
                    try self.validate(instance: value, against: additionalSchema, path: "\(path).\(key)")
                    continue
                }

                if self.bool(schema["additionalProperties"]) == false, propertySchemas[key] == nil {
                    throw LLMTaskToolError.schemaValidationFailed("\(path).\(key) is not allowed")
                }
            }
        }

        private static func validateArray(
            _ array: [AnyCodable],
            schema: [String: AnyCodable],
            path: String
        ) throws {
            if let minItems = self.int(schema["minItems"]), array.count < minItems {
                throw LLMTaskToolError.schemaValidationFailed("\(path) requires at least \(minItems) items")
            }
            if let maxItems = self.int(schema["maxItems"]), array.count > maxItems {
                throw LLMTaskToolError.schemaValidationFailed("\(path) allows at most \(maxItems) items")
            }
            if let itemSchema = self.object(schema["items"]) {
                for (index, item) in array.enumerated() {
                    try self.validate(instance: item, against: itemSchema, path: "\(path)[\(index)]")
                }
            }
        }

        private static func validateNumber(
            _ number: Double,
            schema: [String: AnyCodable],
            path: String
        ) throws {
            if let minimum = self.double(schema["minimum"]), number < minimum {
                throw LLMTaskToolError.schemaValidationFailed("\(path) must be >= \(minimum)")
            }
            if let maximum = self.double(schema["maximum"]), number > maximum {
                throw LLMTaskToolError.schemaValidationFailed("\(path) must be <= \(maximum)")
            }
        }

        private static func typeName(for value: AnyCodable) -> String {
            switch value.value {
            case .null:
                return "null"
            case .bool:
                return "boolean"
            case .int:
                return "integer"
            case .double:
                return "number"
            case .string:
                return "string"
            case .object:
                return "object"
            case .array:
                return "array"
            }
        }

        private static func object(_ value: AnyCodable?) -> [String: AnyCodable]? {
            guard let value else {
                return nil
            }
            if case .object(let object) = value.value {
                return object
            }
            return nil
        }

        private static func anyArray(_ value: AnyCodable?) -> [AnyCodable]? {
            guard let value else {
                return nil
            }
            if case .array(let array) = value.value {
                return array
            }
            return nil
        }

        private static func stringArray(_ value: AnyCodable?) -> [String]? {
            guard let value else {
                return nil
            }
            switch value.value {
            case .string(let string):
                return [string]
            case .array(let array):
                return array.compactMap { item in
                    if case .string(let string) = item.value {
                        return string
                    }
                    return nil
                }
            default:
                return nil
            }
        }

        private static func bool(_ value: AnyCodable?) -> Bool? {
            guard let value else {
                return nil
            }
            if case .bool(let bool) = value.value {
                return bool
            }
            return nil
        }

        private static func int(_ value: AnyCodable?) -> Int? {
            guard let value else {
                return nil
            }
            if case .int(let int) = value.value {
                return int
            }
            return nil
        }

        private static func double(_ value: AnyCodable?) -> Double? {
            guard let value else {
                return nil
            }
            switch value.value {
            case .int(let int):
                return Double(int)
            case .double(let double):
                return double
            default:
                return nil
            }
        }
    }
}
