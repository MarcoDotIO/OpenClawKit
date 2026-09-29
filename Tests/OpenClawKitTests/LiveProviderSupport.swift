import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OpenClawKit
import OpenClawCore
import OpenClawModels
import OpenClawProtocol

// Shared support for the live provider end-to-end suites (`LiveProvider*Tests`).
//
// Every live suite is disabled unless `OPENCLAW_LIVE_PROVIDER_TESTS=1` AND the provider key is set
// in the test process environment, so CI and normal `swift test` runs never call a provider API.
// Run them with (keys are loaded into the test process only, never printed):
//
//     set -a; . ./.env; set +a
//     OPENCLAW_LIVE_PROVIDER_TESTS=1 swift test --filter LiveProvider
//
// Spend is kept tiny: the cheapest models by default, short prompts, small output limits and no
// retries. Override models with OPENCLAW_LIVE_OPENAI_MODEL / OPENCLAW_LIVE_ANTHROPIC_MODEL /
// OPENCLAW_LIVE_XAI_MODEL. Anthropic keys that are not scoped to a workspace also need
// ANTHROPIC_WORKSPACE_ID (sent as the `anthropic-workspace-id` header).

/// Live provider under test.
enum LiveProviderKind: String, CaseIterable, Sendable {
    case openAI = "openai"
    case anthropic
    case xai

    /// Environment variable holding the API key.
    var keyVariable: String {
        switch self {
        case .openAI:
            return "OPENAI_API_KEY"
        case .anthropic:
            return "ANTHROPIC_API_KEY"
        case .xai:
            return "XAI_API_KEY"
        }
    }

    /// Environment variable overriding the model.
    var modelVariable: String {
        "OPENCLAW_LIVE_\(self.rawValue.uppercased())_MODEL"
    }

    /// Cheapest suitable model (see the GET /v1/models listings and catalog prices).
    var defaultModel: String {
        switch self {
        case .openAI:
            // $0.10 / $0.50 per 1M tokens; reasoning can be switched off (effort `none`).
            return "gpt-6-luna"
        case .anthropic:
            return "claude-haiku-4-5"
        case .xai:
            // Non-reasoning variant: no hidden reasoning tokens eat the small output budget.
            return "grok-4.20-0309-non-reasoning"
        }
    }

    /// Deliberately wrong key used by the invalid-key tests (rejected before any billing).
    var invalidKey: String {
        switch self {
        case .openAI:
            return "sk-openclaw-live-invalid-key-000000000000"
        case .anthropic:
            return "sk-ant-api03-openclaw-live-invalid-key-000000000000"
        case .xai:
            return "xai-openclaw-live-invalid-key-000000000000"
        }
    }
}

/// Gating, credentials and model selection for the live suites.
enum LiveProviderEnvironment {
    static let flagVariable = "OPENCLAW_LIVE_PROVIDER_TESTS"
    static let anthropicWorkspaceVariables = ["ANTHROPIC_WORKSPACE_ID", "OPENCLAW_LIVE_ANTHROPIC_WORKSPACE_ID"]

    private static var environment: [String: String] {
        ProcessInfo.processInfo.environment
    }

    private static func value(_ name: String) -> String? {
        guard let raw = self.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw
    }

    /// Whether the live flag is set.
    static var isFlagSet: Bool {
        self.value(self.flagVariable) == "1"
    }

    /// Whether live tests for `kind` may run (flag set and key present).
    static func isEnabled(_ kind: LiveProviderKind) -> Bool {
        self.isFlagSet && self.apiKey(kind) != nil
    }

    /// API key for `kind`; never print or log it.
    static func apiKey(_ kind: LiveProviderKind) -> String? {
        self.value(kind.keyVariable)
    }

    /// Model for `kind` (override or cheapest default).
    static func model(_ kind: LiveProviderKind) -> String {
        self.value(kind.modelVariable) ?? kind.defaultModel
    }

    /// Anthropic workspace id for keys that are not scoped to a workspace.
    static var anthropicWorkspaceID: String? {
        self.anthropicWorkspaceVariables.lazy.compactMap { self.value($0) }.first
    }

    /// Extra headers Anthropic requests need in this environment.
    static var anthropicHeaders: [String: String] {
        self.anthropicWorkspaceID.map { ["anthropic-workspace-id": $0] } ?? [:]
    }

    /// Replaces every configured secret in `text` with `<redacted>`.
    static func redact(_ text: String) -> String {
        var result = text
        let secrets = LiveProviderKind.allCases.compactMap { self.apiKey($0) } + [self.anthropicWorkspaceID].compactMap { $0 }
        for secret in secrets where secret.count >= 8 {
            result = result.replacingOccurrences(of: secret, with: "<redacted>")
        }
        return result
    }
}

/// Error wrapper whose description never contains a configured secret.
struct LiveProviderRedactedError: Error, CustomStringConvertible {
    let description: String
}

/// Runs a live call, rethrowing failures with secrets redacted from their description.
func liveCall<T: Sendable>(_ body: () async throws -> T) async throws -> T {
    do {
        return try await body()
    } catch {
        throw LiveProviderRedactedError(description: LiveProviderEnvironment.redact(String(describing: error)))
    }
}

/// Collects token usage per live call and prints one line per call (never prompts, keys or bodies).
enum LiveUsageLedger {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var rows: [(label: String, usage: ModelUsage)] = []

    /// Records and prints the usage of one call.
    static func record(_ label: String, model: String?, usage: ModelUsage?) {
        let usage = usage ?? .zero
        self.lock.lock()
        self.rows.append((label, usage))
        self.lock.unlock()
        print(
            "[live-usage] \(label) model=\(model ?? "?") input=\(usage.inputTokens) output=\(usage.outputTokens) "
                + "cacheRead=\(usage.cacheReadTokens) cacheWrite=\(usage.cacheWriteTokens) "
                + "reasoning=\(usage.reasoningTokens) total=\(usage.totalTokens)"
        )
    }

    /// Records and prints the usage of an agent run.
    static func record(_ label: String, model: String?, agentUsage: AgentTokenUsage, iterations: Int) {
        self.record(
            "\(label) iterations=\(iterations)",
            model: model,
            usage: ModelUsage(
                inputTokens: agentUsage.input,
                outputTokens: agentUsage.output,
                cacheReadTokens: agentUsage.cacheRead,
                cacheWriteTokens: agentUsage.cacheWrite,
                totalTokens: agentUsage.totalTokens
            )
        )
    }
}

/// Result of consuming a provider stream.
struct LiveStreamCapture: Sendable {
    var chunks: [ModelStreamChunk] = []

    /// Concatenated visible text deltas (`.text` chunks plus trailing final text).
    var text: String {
        self.chunks.map(\.text).joined()
    }

    /// Concatenated reasoning deltas.
    var reasoning: String {
        self.chunks.compactMap(\.reasoningText).joined()
    }

    /// Number of `.text` chunks.
    var textChunkCount: Int {
        self.chunks.filter { $0.kind == .text }.count
    }

    /// Tool-call fragments.
    var toolCallDeltas: [ModelToolCallDelta] {
        self.chunks.compactMap(\.toolCallDelta)
    }

    /// The `.final` chunk, when present.
    var final: ModelStreamChunk? {
        self.chunks.last(where: \.isFinal)
    }

    /// Usage from the final chunk, else the last usage chunk.
    var usage: ModelUsage? {
        self.final?.usage ?? self.chunks.last(where: { $0.usage != nil })?.usage
    }
}

/// Consumes a stream into a capture (redacting failures).
func liveCollect(_ stream: AsyncThrowingStream<ModelStreamChunk, Error>) async throws -> LiveStreamCapture {
    try await liveCall {
        var capture = LiveStreamCapture()
        for try await chunk in stream {
            capture.chunks.append(chunk)
        }
        return capture
    }
}

/// Prompts, tools and schemas shared by the live suites.
enum LiveProviderFixtures {
    /// Output limit for plain calls.
    static let smallOutput = 64
    /// Output limit for tool-calling and structured-output turns.
    static let toolOutput = 160

    static let pongPrompt = "Reply with exactly one lowercase word: pong"
    static let toolPrompt = "Use the add_numbers tool to add 17 and 25. Do not compute it yourself."
    static let toolSystemPrompt = "You are a terse assistant. When a tool result arrives, answer with just the number."

    /// `{"type": type}` property schema.
    static func property(_ type: String, description: String? = nil) -> AnyCodable {
        var schema: [String: AnyCodable] = ["type": AnyCodable(type)]
        if let description {
            schema["description"] = AnyCodable(description)
        }
        return AnyCodable(schema)
    }

    /// Closed object schema with every property required.
    static func objectSchema(_ properties: [String: AnyCodable]) -> [String: AnyCodable] {
        let required: [AnyCodable] = properties.keys.sorted().map { AnyCodable($0) }
        return [
            "type": AnyCodable("object"),
            "properties": AnyCodable(properties),
            "required": AnyCodable(required),
            "additionalProperties": AnyCodable(false),
        ]
    }

    /// Deterministic addition tool.
    static let addTool = ModelToolDefinition(
        name: "add_numbers",
        description: "Adds two integers and returns their sum.",
        parameters: objectSchema([
            "a": property("integer", description: "First addend"),
            "b": property("integer", description: "Second addend"),
        ])
    )

    /// Strict JSON schema for the structured-output tests.
    static let citySchema: [String: AnyCodable] = objectSchema([
        "city": property("string"),
        "country": property("string"),
        "population_millions": property("number"),
    ])

    static let cityFormat = ModelResponseFormat.jsonSchema(name: "city_facts", schema: citySchema, strict: true)
    static let cityPrompt = "Give facts about Paris: the city name, its country, and its approximate population in millions."

    /// Parses `text` as a JSON object and checks it against ``citySchema``.
    /// - Returns: The decoded object, or `nil` when it does not validate.
    static func validateCityJSON(_ text: String) -> [String: AnyCodable]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let decoded: AnyCodable? = try? JSONDecoder().decode(AnyCodable.self, from: Data(trimmed.utf8))
        guard let object = decoded?.dictionaryValue else {
            return nil
        }
        let expectedKeys: Set<String> = ["city", "country", "population_millions"]
        guard Set(object.keys) == expectedKeys else {
            return nil
        }
        let city = object["city"]?.stringValue?.lowercased() ?? ""
        let country = object["country"]?.stringValue?.lowercased() ?? ""
        let population = object["population_millions"]?.doubleValue ?? 0
        guard city.contains("paris"), country.contains("france"), population > 0, population < 100 else {
            return nil
        }
        return object
    }

    /// Prompt that needs two independent `add_numbers` calls in one turn.
    static let parallelToolPrompt = "Call the add_numbers tool twice in parallel: once for 2 + 3 and once for 10 + 20. Do not compute it yourself."

    /// Checks that `calls` are two `add_numbers` calls summing to 5 and 30 with distinct ids.
    static func isParallelAddPair(_ calls: [ModelToolCall]) -> Bool {
        let sums = calls.filter { $0.name == "add_numbers" }.compactMap { self.addArguments($0).map { $0.a + $0.b } }
        return sums.sorted() == [5, 30] && Set(calls.map(\.id)).count == calls.count && calls.allSatisfy { !$0.id.isEmpty }
    }

    /// 64x64 solid pure-red PNG.
    static let redSquarePNG = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAS0lEQVR42u3PQQkAAAgAsetfWiP4FgYrsKZeS0BAQEBAQEBAQEBAQEBA"
            + "QEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEDgsqnc8OJg6Ln3AAAAAElFTkSuQmCC"
    ) ?? Data()

    /// Image attachment for the multimodal tests.
    static var redSquare: MediaAttachment {
        MediaAttachment(mimeType: "image/png", data: self.redSquarePNG, fileName: "square.png")
    }

    static let colorPrompt = "The attached image is one solid color: red, green, blue or gray? Answer with that one lowercase word."

    /// Integer arguments `a`/`b` of an `add_numbers` call.
    static func addArguments(_ call: ModelToolCall) -> (a: Int, b: Int)? {
        guard let arguments = call.arguments,
              let a = arguments["a"]?.intValue ?? arguments["a"]?.stringValue.flatMap(Int.init),
              let b = arguments["b"]?.intValue ?? arguments["b"]?.stringValue.flatMap(Int.init)
        else {
            return nil
        }
        return (a, b)
    }

    /// Tool result answering an `add_numbers` call.
    static func addResult(for call: ModelToolCall) -> ModelToolResult {
        let sum = self.addArguments(call).map { $0.a + $0.b } ?? 0
        return ModelToolResult(toolCallID: call.id, toolName: call.name, content: [.text(String(sum))])
    }
}

/// Builds providers the way apps do: from the bundled catalog config through `ModelProviderFactory`.
enum LiveProviderConfigs {
    /// Catalog config for `kind` with the live key, the live model first (the default) and an
    /// output cap in the model params (params win over the catalog's large `maxTokens`).
    static func catalogConfig(
        _ kind: LiveProviderKind,
        apiKey: String? = nil,
        maxTokens: Int = LiveProviderFixtures.toolOutput,
        headers: [String: String] = [:]
    ) throws -> ModelProviderConfig {
        var config = try #require(OpenClawReferenceProviderCatalog.entry(for: kind.rawValue)?.config)
        config.enabled = true
        config.apiKey = apiKey ?? LiveProviderEnvironment.apiKey(kind)
        config.headers.merge(headers) { _, new in new }
        let modelID = LiveProviderEnvironment.model(kind)
        var model = config.models.first(where: { $0.id == modelID }) ?? ModelDefinitionConfig(id: modelID, reasoning: true)
        var params = model.params ?? [:]
        params["maxTokens"] = AnyCodable(maxTokens)
        model.params = params
        config.models.removeAll { $0.id == modelID }
        config.models.insert(model, at: 0)
        return config
    }

    /// Provider built by `ModelProviderFactory` from ``catalogConfig(_:apiKey:maxTokens:headers:)``.
    static func factoryProvider(
        _ kind: LiveProviderKind,
        apiKey: String? = nil,
        maxTokens: Int = LiveProviderFixtures.toolOutput,
        headers: [String: String] = [:]
    ) throws -> any ModelProvider {
        try ModelProviderFactory.makeProvider(
            providerID: kind.rawValue,
            config: self.catalogConfig(kind, apiKey: apiKey, maxTokens: maxTokens, headers: headers)
        )
    }
}

/// Deterministic calculator `AgentTool` for the agent-loop live tests.
struct LiveCalculatorTool: AgentTool {
    let name = "calculator"

    private static let operationSchema: AnyCodable = {
        let operations: [AnyCodable] = ["add", "subtract", "multiply"].map { AnyCodable($0) }
        let schema: [String: AnyCodable] = ["type": AnyCodable("string"), "enum": AnyCodable(operations)]
        return AnyCodable(schema)
    }()

    var descriptor: AgentToolDescriptor {
        AgentToolDescriptor(
            name: self.name,
            description: "Evaluates one arithmetic operation on two integers. Operations: add, subtract, multiply.",
            parameters: LiveProviderFixtures.objectSchema([
                "operation": Self.operationSchema,
                "a": LiveProviderFixtures.property("integer"),
                "b": LiveProviderFixtures.property("integer"),
            ])
        )
    }

    func invoke(_ invocation: AgentToolInvocation, update _: AgentToolUpdateHandler?) async throws -> AgentToolOutput {
        let arguments = invocation.arguments
        guard let a = arguments["a"]?.intValue ?? arguments["a"]?.stringValue.flatMap(Int.init),
              let b = arguments["b"]?.intValue ?? arguments["b"]?.stringValue.flatMap(Int.init)
        else {
            return AgentToolOutput(content: [.text("error: a and b must be integers")], isError: true)
        }
        switch arguments["operation"]?.stringValue {
        case "add"?:
            return .text(String(a + b))
        case "subtract"?:
            return .text(String(a - b))
        case "multiply"?:
            return .text(String(a * b))
        default:
            return AgentToolOutput(content: [.text("error: unknown operation")], isError: true)
        }
    }
}

extension OpenClawCoreError {
    /// Detail string of either case.
    var liveDetail: String {
        switch self {
        case .unavailable(let detail), .invalidConfiguration(let detail):
            return detail
        }
    }
}

/// Asserts that `body` fails with an authentication error (HTTP 401/403) mapped to
/// ``OpenClawCoreError``.
func expectAuthenticationFailure(
    _ label: String,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () async throws -> Void
) async {
    do {
        try await body()
        Issue.record("\(label): expected an authentication failure", sourceLocation: sourceLocation)
    } catch let error as OpenClawCoreError {
        let detail = LiveProviderEnvironment.redact(error.liveDetail)
        print("[live-error] \(label): \(detail.prefix(160))")
        let lowered = detail.lowercased()
        #expect(
            lowered.contains("401") || lowered.contains("403") || lowered.contains("authentication") || lowered.contains("api key"),
            "\(label): unexpected error detail \(detail)",
            sourceLocation: sourceLocation
        )
    } catch {
        Issue.record("\(label): expected OpenClawCoreError, got \(LiveProviderEnvironment.redact(String(describing: error)))", sourceLocation: sourceLocation)
    }
}
