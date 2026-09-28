import Foundation
import OpenClawProtocol

// Host-owned tool calling for Apple Foundation Models.
//
// Port of upstream apple-fm `HostTool`/`ToolBoundary`/`ToolCalls`: every host tool is registered
// with a JSON-Schema-derived `GenerationSchema`. In propose-only mode (upstream parity) `call`
// records `{id, name, arguments.jsonString}` and throws a private boundary error, which stops the
// native loop before any tool executes; the provider catches it and returns the recorded calls with
// stop reason `toolUse` so OpenClaw's loop owns approval and execution. In-process mode runs the
// call through a ``FoundationModelsToolExecuting`` executor instead.
#if canImport(FoundationModels) && !os(tvOS) && (!os(watchOS) || compiler(>=6.4))
import FoundationModels

/// Thrown by propose-only host tools to stop the framework loop (upstream `ToolBoundary`).
struct FoundationModelsToolBoundary: Error {}

/// Records tool calls made during one Foundation Models response (upstream `ToolCalls`).
actor FoundationModelsToolCallRecorder {
    private(set) var proposed: [ModelToolCall] = []
    private(set) var executed: [FoundationModelsExecutedToolCall] = []

    /// Records a proposed call.
    func record(_ call: ModelToolCall) {
        self.proposed.append(call)
    }

    /// Records an executed call.
    func recordExecuted(_ call: ModelToolCall, output: FoundationModelsToolOutput) {
        self.executed.append(FoundationModelsExecutedToolCall(call: call, output: output))
    }
}

/// Host tool registered with Foundation Models (upstream `HostTool`).
@available(iOS 26.0, macOS 26.0, visionOS 26.0, watchOS 27.0, *)
struct FoundationModelsHostTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema
    let recorder: FoundationModelsToolCallRecorder
    let executor: (any FoundationModelsToolExecuting)?

    init(
        definition: ModelToolDefinition,
        recorder: FoundationModelsToolCallRecorder,
        executor: (any FoundationModelsToolExecuting)?
    ) throws {
        self.name = definition.name
        self.description = definition.description
        self.parameters = try FoundationModelsSchemaConverter.generationSchema(definition.parameters, name: definition.name)
        self.recorder = recorder
        self.executor = executor
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let call = ModelToolCall(id: UUID().uuidString, name: self.name, argumentsJSON: arguments.jsonString)
        guard let executor = self.executor else {
            await self.recorder.record(call)
            // OpenClaw owns execution and approval. Stop the native loop before any tool executes.
            throw FoundationModelsToolBoundary()
        }
        let output = try await executor.executeTool(call)
        await self.recorder.recordExecuted(call, output: output)
        return output.isError ? "Tool error: \(output.text)" : output.text
    }
}

/// A Foundation Models `Tool` whose arguments are described by a JSON Schema and handled by a closure.
///
/// Use it to offer arbitrary JSON-Schema tools to your own `LanguageModelSession`s:
///
/// ```swift
/// let tool = try FoundationModelsDynamicTool(
///     definition: ModelToolDefinition(name: "lookup", description: "Look up a word", parameters: schema)
/// ) { call in "Definition of \(call.arguments?["word"]?.stringValue ?? "?")" }
/// let session = LanguageModelSession(tools: [tool])
/// ```
///
/// The schema is converted with ``FoundationModelsSchemaConverter`` (upstream apple-fm keyword rules);
/// conversion failures throw from the initializer.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, watchOS 27.0, *)
public struct FoundationModelsDynamicTool: Tool {
    /// Framework argument type: the raw generated content.
    public typealias Arguments = GeneratedContent
    /// Framework output type: text handed back to the model.
    public typealias Output = String

    /// Model-facing tool name.
    public let name: String
    /// Model-facing description.
    public let description: String
    /// Converted parameter schema.
    public let parameters: GenerationSchema
    /// Original JSON Schema of the parameters.
    public let jsonSchema: [String: AnyCodable]
    private let handler: @Sendable (ModelToolCall) async throws -> String

    /// Creates a dynamic tool.
    /// - Parameters:
    ///   - definition: Tool declaration with a JSON Schema for its parameters.
    ///   - handler: Runs a call (`argumentsJSON` holds the generated JSON object) and returns text for the model.
    /// - Throws: ``FoundationModelsError`` when the schema cannot be converted.
    public init(
        definition: ModelToolDefinition,
        handler: @escaping @Sendable (ModelToolCall) async throws -> String
    ) throws {
        self.name = definition.name
        self.description = definition.description
        self.jsonSchema = definition.parameters
        self.parameters = try FoundationModelsSchemaConverter.generationSchema(definition.parameters, name: definition.name)
        self.handler = handler
    }

    /// Runs the handler with a freshly identified call.
    /// - Parameter arguments: Generated arguments.
    /// - Returns: Text for the model.
    public func call(arguments: GeneratedContent) async throws -> String {
        try await self.handler(ModelToolCall(id: UUID().uuidString, name: self.name, argumentsJSON: arguments.jsonString))
    }
}

/// Classifies errors thrown out of `respond` after a propose-only tool call.
enum FoundationModelsToolBoundaryDetector {
    /// Whether the error is the propose-only boundary, wrapped in `LanguageModelSession.ToolCallError`
    /// or not.
    ///
    /// `ToolCallError` is unavailable on watchOS, so there any error thrown after a host tool recorded
    /// a proposed call is treated as the boundary as well (the host tool always throws right after
    /// recording).
    /// - Parameters:
    ///   - error: Error thrown by `respond`.
    ///   - recordedCalls: Number of proposed calls the recorder captured.
    @available(iOS 26.0, macOS 26.0, visionOS 26.0, watchOS 27.0, *)
    static func isBoundary(_ error: any Error, recordedCalls: Int) -> Bool {
        if error is FoundationModelsToolBoundary {
            return true
        }
        #if os(watchOS)
        return recordedCalls > 0 && !(error is CancellationError)
        #else
        if let toolError = error as? LanguageModelSession.ToolCallError {
            return toolError.underlyingError is FoundationModelsToolBoundary
        }
        return false
        #endif
    }
}
#endif
