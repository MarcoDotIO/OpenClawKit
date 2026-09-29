import Foundation
import OpenClawCore
import OpenClawProtocol

// In-process port of upstream apple-fm `run()` (no helper binary, no JSON IPC), plus the
// FoundationModels 27 surface.
//
// Paths:
// - OS 26.x, iOS/macOS/visionOS: `SystemLanguageModel` with `GenerationOptions`, tool boundary,
//   structured output and `tokenCount` usage (26.4+).
// - OS 27, every platform but tvOS: one path generic over `some LanguageModel`, used for the
//   on-device model (not on watchOS, where `SystemLanguageModel` is unavailable) and for
//   `PrivateCloudComputeLanguageModel`, with `ContextOptions` (reasoning level, schema-in-prompt),
//   tool-calling modes, image attachments, `Response.usage`, reasoning transcript entries and
//   Vision/Spotlight tools.
#if canImport(FoundationModels) && !os(tvOS) && (!os(watchOS) || compiler(>=6.4))
import FoundationModels
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Runs Foundation Models requests for ``FoundationModelsProvider``.
struct AppleFoundationModelsEngine: Sendable {
    let providerID: String
    let options: FoundationModelsProviderOptions

    func run(
        _ request: ModelGenerationRequest,
        target: AppleFoundationModelTarget,
        sink: FoundationModelsTextSink?
    ) async throws -> FoundationModelsGenerationResult {
        // One recorder spans every attempt (including an on-device fallback), so in-process tool
        // executions are never forgotten when a request fails after running them.
        let recorder = FoundationModelsToolCallRecorder()
        do {
            switch target {
            case .system:
                return try await self.runSystem(request, sink: sink, recorder: recorder)
            case .privateCloudCompute:
                return try await self.runPrivateCloud(request, sink: sink, recorder: recorder)
            }
        } catch {
            throw await Self.failure(error, recorder: recorder)
        }
    }

    /// Maps a failure and attaches in-process tool calls that already ran (the error then becomes
    /// non-retryable, see ``FoundationModelsError/executedToolCalls``).
    static func failure(_ error: any Error, recorder: FoundationModelsToolCallRecorder) async -> any Error {
        let mapped = FoundationModelsErrorMapper.map(error)
        guard let modelError = mapped as? FoundationModelsError else {
            return mapped
        }
        return modelError.recordingExecutedToolCalls(await recorder.executed)
    }

    /// Private Cloud Compute error codes that may fall back to the on-device model.
    static let fallbackCodes: Set<FoundationModelsError.Code> = [.rateLimited, .networkFailure, .serviceUnavailable, .unavailable]

    /// Runs `attempt` and, when it fails with a transient Private Cloud Compute error before emitting
    /// text or running any in-process tool, runs `fallback` instead.
    ///
    /// A fallback after in-process tools ran would execute their side effects a second time (the
    /// fallback replays the original request, which does not contain the first attempt's calls), so
    /// such failures are rethrown with the executed calls attached by ``run(_:target:sink:)``.
    /// - Parameters:
    ///   - recorder: Recorder shared by the attempt and the fallback.
    ///   - sink: Streaming sink of the attempt.
    ///   - attempt: The Private Cloud Compute attempt.
    ///   - fallback: The on-device fallback (or a throw when it is unavailable).
    /// - Returns: The attempt's or the fallback's result.
    static func attemptWithFallback(
        recorder: FoundationModelsToolCallRecorder,
        sink: FoundationModelsTextSink?,
        attempt: () async throws -> FoundationModelsGenerationResult,
        fallback: (FoundationModelsError) async throws -> FoundationModelsGenerationResult
    ) async throws -> FoundationModelsGenerationResult {
        do {
            return try await attempt()
        } catch {
            let mapped = FoundationModelsErrorMapper.map(error)
            guard let modelError = mapped as? FoundationModelsError,
                  Self.fallbackCodes.contains(modelError.code),
                  sink?.didEmit != true,
                  !Task.isCancelled,
                  await recorder.executed.isEmpty
            else {
                throw mapped
            }
            // Proposed calls have no side effects; drop them so the fallback reports only its own.
            await recorder.discardProposed()
            return try await fallback(modelError)
        }
    }

    // MARK: On-device system model

    private func runSystem(
        _ request: ModelGenerationRequest,
        sink: FoundationModelsTextSink?,
        recorder: FoundationModelsToolCallRecorder
    ) async throws -> FoundationModelsGenerationResult {
        #if os(watchOS)
        throw OpenClawCoreError.unavailable(
            FoundationModelsRuntimeAvailability.unavailable(.systemModelUnsupportedOnPlatform).message
        )
        #else
        let availability = FoundationModelsProvider.runtimeAvailability(
            target: .system,
            treatSimulatorAsUnavailable: self.options.treatSimulatorAsUnavailable
        )
        guard availability.isAvailable else {
            throw OpenClawCoreError.unavailable(availability.message)
        }
        #if compiler(>=6.4)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            let model = AppleFMSystemModel.make(self.options)
            let context = AppleFMRunContext(
                request: request,
                options: self.options,
                providerID: self.providerID,
                target: .system,
                sink: sink,
                recorder: recorder
            )
            return try await AppleFMGeneration27.run(model: model, context: context, tokenCounter: AppleFMTokenCounter.system(model))
        }
        #endif
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            let context = AppleFMRunContext(
                request: request,
                options: self.options,
                providerID: self.providerID,
                target: .system,
                sink: sink,
                recorder: recorder
            )
            return try await AppleFMSystem26.run(context: context)
        }
        throw OpenClawCoreError.unavailable(FoundationModelsRuntimeAvailability.unavailable(.unsupportedOS).message)
        #endif
    }

    // MARK: Private Cloud Compute

    private func runPrivateCloud(
        _ request: ModelGenerationRequest,
        sink: FoundationModelsTextSink?,
        recorder: FoundationModelsToolCallRecorder
    ) async throws -> FoundationModelsGenerationResult {
        #if compiler(>=6.4)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) {
            let model = PrivateCloudComputeLanguageModel()
            let preflight: FoundationModelsError?
            let availability = FoundationModelsProvider.runtimeAvailability(
                target: .privateCloudCompute,
                treatSimulatorAsUnavailable: self.options.treatSimulatorAsUnavailable
            )
            if !availability.isAvailable {
                preflight = FoundationModelsError(code: .unavailable, message: availability.message)
            } else if model.quotaUsage.isLimitReached {
                preflight = FoundationModelsError(
                    code: .rateLimited,
                    message: "Private Cloud Compute quota limit reached; retry after the quota resets.",
                    retryable: true,
                    resetDate: model.quotaUsage.resetDate
                )
            } else {
                preflight = nil
            }
            if let preflight {
                return try await self.fallBackOrThrow(preflight, request: request, sink: sink, recorder: recorder)
            }
            let context = AppleFMRunContext(
                request: request,
                options: self.options,
                providerID: self.providerID,
                target: .privateCloudCompute,
                sink: sink,
                recorder: recorder
            )
            return try await Self.attemptWithFallback(recorder: recorder, sink: sink) {
                try await AppleFMGeneration27.run(model: model, context: context, tokenCounter: nil)
            } fallback: { modelError in
                try await self.fallBackOrThrow(modelError, request: request, sink: sink, recorder: recorder)
            }
        }
        #endif
        throw FoundationModelsError(code: .unavailable, message: "Private Cloud Compute requires Apple OS 27 or later.")
    }

    private func fallBackOrThrow(
        _ error: FoundationModelsError,
        request: ModelGenerationRequest,
        sink: FoundationModelsTextSink?,
        recorder: FoundationModelsToolCallRecorder
    ) async throws -> FoundationModelsGenerationResult {
        guard self.options.fallbackToOnDevice,
              FoundationModelsProvider.runtimeAvailability(
                  target: .system,
                  treatSimulatorAsUnavailable: self.options.treatSimulatorAsUnavailable
              ).isAvailable
        else {
            throw error
        }
        var result = try await self.runSystem(request, sink: sink, recorder: recorder)
        result.fellBackToOnDevice = true
        return result
    }
}

// MARK: - Shared request preparation

/// Inputs shared by the engine paths.
struct AppleFMRunContext: Sendable {
    let request: ModelGenerationRequest
    let options: FoundationModelsProviderOptions
    let providerID: String
    let target: AppleFoundationModelTarget
    let sink: FoundationModelsTextSink?
    /// Records proposed and executed tool calls; shared across a request's attempts.
    var recorder = FoundationModelsToolCallRecorder()

    var modelID: String {
        self.target.modelID
    }
}

/// Transcript, prompt, tools and schema for one response.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, watchOS 27.0, *)
struct AppleFMPrepared {
    let plan: FoundationModelsTranscriptPlan
    let transcript: Transcript
    let prompt: Prompt
    let hostToolCount: Int
    let tools: [any Tool]
    let recorder: FoundationModelsToolCallRecorder
    let schema: GenerationSchema?
    let callerSchema: [String: AnyCodable]?

    /// Whether text can stream as it is generated (no tools and no schema, like upstream's
    /// requirement that structured output and tool calls publish only after validation).
    func canStream(_ context: AppleFMRunContext) -> Bool {
        context.sink != nil && self.hostToolCount == 0 && self.schema == nil
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, watchOS 27.0, *)
enum AppleFMPreparation {
    /// Builds the plan, host tools, transcript, prompt and schema.
    /// - Parameters:
    ///   - context: Run inputs.
    ///   - allowImages: Whether the model accepts image attachments.
    ///   - allowReasoning: Whether reasoning entries can be replayed.
    ///   - keepToolsWhenDisallowed: Keep host tools for `toolChoice: .none` (OS 27 `.disallowed` mode).
    ///   - nativeTools: Extra framework-executed tools for the plan (Vision, Spotlight).
    static func prepare(
        _ context: AppleFMRunContext,
        allowImages: Bool,
        allowReasoning: Bool,
        keepToolsWhenDisallowed: Bool,
        nativeTools: (FoundationModelsTranscriptPlan) -> [any Tool] = { _ in [] }
    ) throws -> AppleFMPrepared {
        let request = context.request
        try FoundationModelsTranscriptPlanner.validateToolNames(request.tools)
        var systemPrompt = request.systemPrompt
        if case .jsonObject = request.responseFormat {
            systemPrompt = [systemPrompt, "Respond with a single JSON object and no other text."]
                .compactMap { $0 }
                .joined(separator: "\n\n")
        }
        let plan = try FoundationModelsTranscriptPlanner.plan(
            systemPrompt: systemPrompt,
            messages: request.resolvedMessages,
            allowImages: allowImages,
            allowReasoning: allowReasoning
        )
        var definitions = request.tools
        switch request.toolChoice {
        case .named(let name):
            definitions = definitions.filter { $0.name == name }
            if definitions.isEmpty {
                throw FoundationModelsError.invalidRequest("Tool choice names unknown tool \(name)")
            }
        case .none where !keepToolsWhenDisallowed:
            definitions = []
        default:
            break
        }
        let recorder = context.recorder
        let executor: (any FoundationModelsToolExecuting)?
        if case .executeInProcess(let inProcess) = context.options.tools.execution {
            executor = inProcess
        } else {
            executor = nil
        }
        let hostTools = try definitions.map { definition in
            try FoundationModelsHostTool(definition: definition, recorder: recorder, executor: executor)
        }
        let hostNames = Set(hostTools.map(\.name))
        // Framework-executed tools (Vision, Spotlight) are offered only with `toolChoice: .auto`: OS 27
        // emulates `.named`/`.required` with `ToolCallingMode.required` over the whole tool set, so a
        // native tool could satisfy it and the forced host tool would never be proposed.
        let extras: [any Tool]
        if case .auto = request.toolChoice {
            extras = nativeTools(plan).filter { !hostNames.contains($0.name) }
        } else {
            extras = []
        }
        let tools: [any Tool] = hostTools + extras
        let callerSchema = request.responseFormatJSONSchema
        let schema = try callerSchema.map {
            try FoundationModelsSchemaConverter.generationSchema($0, name: FoundationModelsSchemaConverter.responseSchemaName)
        }
        return AppleFMPrepared(
            plan: plan,
            transcript: try AppleFMTranscriptBuilder.transcript(plan, tools: tools),
            prompt: try AppleFMTranscriptBuilder.prompt(plan),
            hostToolCount: hostTools.count,
            tools: tools,
            recorder: recorder,
            schema: schema,
            callerSchema: callerSchema
        )
    }

    /// Upstream-style `GenerationOptions`: temperature, sampling mode and maximum response tokens
    /// (policy `maxTokens`, else the provider default of 1024).
    static func sampling(_ policy: ModelGenerationPolicy) -> GenerationOptions.SamplingMode? {
        let seed = policy.localRuntimeHints["seed"].flatMap { UInt64($0.trimmingCharacters(in: .whitespaces)) }
        if let topK = policy.topK {
            return topK <= 1 ? .greedy : .random(top: topK, seed: seed)
        }
        if let topP = policy.topP {
            return .random(probabilityThreshold: topP, seed: seed)
        }
        if policy.temperature == 0 {
            return .greedy
        }
        return nil
    }

    static func maximumTokens(_ context: AppleFMRunContext) -> Int {
        context.request.policy.maxTokens ?? context.options.defaultMaxTokens
    }

    /// Validates structured output against the caller's schema and returns the unchanged text.
    static func structuredText(_ content: GeneratedContent, callerSchema: [String: AnyCodable]) throws -> String {
        let text = content.jsonString
        try FoundationModelsStructuredOutputValidator.validate(text, against: callerSchema)
        return text
    }

    /// Response for a propose-only tool boundary (upstream: text `""`, stop reason `toolUse`).
    static func boundaryResponse(
        _ context: AppleFMRunContext,
        calls: [ModelToolCall],
        usage: ModelUsage?
    ) throws -> ModelGenerationResponse {
        guard !calls.isEmpty else {
            throw FoundationModelsError.invalidRequest("Native tool boundary had no call")
        }
        return ModelGenerationResponse(
            text: "",
            providerID: context.providerID,
            modelID: context.modelID,
            toolCalls: calls,
            usage: usage,
            stopReason: .toolUse
        )
    }

    /// Streams cumulative snapshots as deltas and returns the final text.
    static func streamText<Snapshots: AsyncSequence>(
        _ snapshots: Snapshots,
        sink: FoundationModelsTextSink,
        text: (Snapshots.Element) -> String
    ) async throws -> (String, Snapshots.Element?) {
        var emitted = ""
        var last: Snapshots.Element?
        for try await snapshot in snapshots {
            let full = text(snapshot)
            // Snapshots are cumulative; emit only the new suffix (or the whole text if it was rewritten).
            let delta = full.hasPrefix(emitted) ? String(full.dropFirst(emitted.count)) : full
            sink.send(text: delta)
            emitted = full
            last = snapshot
        }
        return (emitted, last)
    }
}

/// Converts plans into framework transcripts and prompts (upstream `replay()` emission).
@available(iOS 26.0, macOS 26.0, visionOS 26.0, watchOS 27.0, *)
enum AppleFMTranscriptBuilder {
    static func transcript(_ plan: FoundationModelsTranscriptPlan, tools: [any Tool]) throws -> Transcript {
        let instructions = plan.instructions.isEmpty ? [] : [Transcript.Segment.text(Transcript.TextSegment(content: plan.instructions))]
        var entries: [Transcript.Entry] = [
            .instructions(Transcript.Instructions(segments: instructions, toolDefinitions: tools.map { Transcript.ToolDefinition(tool: $0) })),
        ]
        for entry in plan.entries {
            switch entry {
            case .prompt(let parts):
                entries.append(.prompt(Transcript.Prompt(segments: try Self.segments(parts))))
            case .response(let text):
                entries.append(.response(Transcript.Response(assetIDs: [], segments: [.text(Transcript.TextSegment(content: text))])))
            case .reasoning(let text):
                #if compiler(>=6.4)
                if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
                    // Upstream replays reasoning text only; foreign signatures are opaque to the framework.
                    entries.append(.reasoning(Transcript.Reasoning(segments: [.text(Transcript.TextSegment(content: text))])))
                }
                #else
                _ = text
                #endif
            case .toolCall(let call):
                let arguments = try GeneratedContent(json: call.argumentsJSON)
                entries.append(.toolCalls(Transcript.ToolCalls([Transcript.ToolCall(id: call.id, toolName: call.name, arguments: arguments)])))
            case .toolOutput(let id, let toolName, let parts):
                entries.append(.toolOutput(Transcript.ToolOutput(id: id, toolName: toolName, segments: try Self.segments(parts))))
            }
        }
        return Transcript(entries: entries)
    }

    /// Final prompt: text, then labeled image attachments and the label list (OS 27), or an empty
    /// prompt that resumes after tool output.
    static func prompt(_ plan: FoundationModelsTranscriptPlan) throws -> Prompt {
        let text = plan.promptText
        #if compiler(>=6.4)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            let images = try plan.prompt.compactMap { part -> Attachment<ImageAttachmentContent>? in
                guard case .image(let attachment, let label) = part else { return nil }
                return try AppleFMImages.attachment(attachment, label: label)
            }
            if !images.isEmpty {
                let labels = "Attached images: \(plan.promptImageLabels.joined(separator: ", "))"
                return Prompt {
                    text
                    images
                    labels
                }
            }
        }
        #endif
        if text.isEmpty {
            // An empty prompt resumes after tool output without adding synthetic user instructions.
            return Prompt {}
        }
        return Prompt(text)
    }

    private static func segments(_ parts: [FoundationModelsTranscriptPlan.Part]) throws -> [Transcript.Segment] {
        try parts.map { part in
            switch part {
            case .text(let text):
                return .text(Transcript.TextSegment(content: text))
            case .image(let attachment, let label):
                #if compiler(>=6.4)
                if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
                    let image = try AppleFMImages.transcriptImage(attachment)
                    return .attachment(Transcript.AttachmentSegment(content: .image(image), label: label))
                }
                #endif
                _ = (attachment, label)
                throw FoundationModelsError.invalidRequest(FoundationModelsTranscriptPlanner.textOnlyMessage)
            }
        }
    }
}

/// Image decoding for OS 27 attachments.
enum AppleFMImages {
    #if canImport(ImageIO) && canImport(CoreGraphics)
    static func decode(_ attachment: MediaAttachment) throws -> (CGImage, CGImagePropertyOrientation?) {
        guard let source = CGImageSourceCreateWithData(attachment.data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw FoundationModelsError.invalidRequest("Image attachment \(MultimodalAttachmentUtilities.displayName(for: attachment)) could not be decoded")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? UInt32).flatMap(CGImagePropertyOrientation.init(rawValue:))
        return (image, orientation)
    }
    #endif

    #if compiler(>=6.4)
    @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
    static func attachment(_ attachment: MediaAttachment, label: String) throws -> Attachment<ImageAttachmentContent> {
        #if canImport(ImageIO) && canImport(CoreGraphics)
        let (image, orientation) = try Self.decode(attachment)
        return Attachment(image, orientation: orientation).label(label)
        #else
        throw FoundationModelsError.invalidRequest(FoundationModelsTranscriptPlanner.textOnlyMessage)
        #endif
    }

    @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
    static func transcriptImage(_ attachment: MediaAttachment) throws -> Transcript.ImageAttachment {
        #if canImport(ImageIO) && canImport(CoreGraphics)
        let (image, orientation) = try Self.decode(attachment)
        return Transcript.ImageAttachment(image, orientation: orientation)
        #else
        throw FoundationModelsError.invalidRequest(FoundationModelsTranscriptPlanner.textOnlyMessage)
        #endif
    }
    #endif
}

/// Token counting for usage when the framework reports none (OS 26.4+ `SystemLanguageModel.tokenCount`).
@available(iOS 26.0, macOS 26.0, visionOS 26.0, watchOS 27.0, *)
struct AppleFMTokenCounter: Sendable {
    let input: @Sendable (Transcript, Prompt) async -> Int?
    let output: @Sendable (String, [ModelToolCall]) async -> Int?

    #if !os(watchOS)
    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    static func system(_ model: SystemLanguageModel) -> AppleFMTokenCounter? {
        #if compiler(>=6.4)
        guard #available(iOS 26.4, macOS 26.4, visionOS 26.4, *) else { return nil }
        return AppleFMTokenCounter(
            input: { transcript, prompt in
                guard let transcriptTokens = try? await model.tokenCount(for: transcript),
                      let promptTokens = try? await model.tokenCount(for: prompt)
                else {
                    return nil
                }
                return transcriptTokens + promptTokens
            },
            output: { text, calls in
                if !calls.isEmpty {
                    // A throwing tool rolls back native transcript additions, so count the emitted calls directly.
                    let emitted = calls.compactMap { call in
                        (try? GeneratedContent(json: call.argumentsJSON)).map {
                            Transcript.ToolCall(id: call.id, toolName: call.name, arguments: $0)
                        }
                    }
                    return try? await model.tokenCount(for: [Transcript.Entry.toolCalls(Transcript.ToolCalls(emitted))])
                }
                return try? await model.tokenCount(for: text)
            }
        )
        #else
        _ = model
        return nil
        #endif
    }
    #endif

    func usage(transcript: Transcript, prompt: Prompt, text: String, calls: [ModelToolCall]) async -> ModelUsage? {
        guard let input = await self.input(transcript, prompt), let output = await self.output(text, calls) else {
            return nil
        }
        return ModelUsage(inputTokens: input, outputTokens: output)
    }
}

#if !os(watchOS)
/// On-device model construction from provider options.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
enum AppleFMSystemModel {
    static func make(_ options: FoundationModelsProviderOptions) -> SystemLanguageModel {
        if options.useCase == .general, options.guardrails == .standard {
            return SystemLanguageModel.default
        }
        let useCase: SystemLanguageModel.UseCase = options.useCase == .contentTagging ? .contentTagging : .general
        let guardrails: SystemLanguageModel.Guardrails = options.guardrails == .permissiveContentTransformations
            ? .permissiveContentTransformations
            : .default
        return SystemLanguageModel(useCase: useCase, guardrails: guardrails)
    }
}

// MARK: - OS 26 on-device path

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
enum AppleFMSystem26 {
    static func run(context: AppleFMRunContext) async throws -> FoundationModelsGenerationResult {
        let model = AppleFMSystemModel.make(context.options)
        let prepared = try AppleFMPreparation.prepare(context, allowImages: false, allowReasoning: false, keepToolsWhenDisallowed: false)
        let session = LanguageModelSession(model: model, tools: prepared.tools, transcript: prepared.transcript)
        let options = Self.options(context)
        let counter = AppleFMTokenCounter.system(model)
        do {
            let text: String
            if let schema = prepared.schema, let callerSchema = prepared.callerSchema {
                let response = try await session.respond(
                    to: prepared.prompt,
                    schema: schema,
                    includeSchemaInPrompt: context.options.includeSchemaInPrompt,
                    options: options
                )
                text = try AppleFMPreparation.structuredText(response.content, callerSchema: callerSchema)
            } else if prepared.canStream(context), let sink = context.sink {
                (text, _) = try await AppleFMPreparation.streamText(
                    session.streamResponse(to: prepared.prompt, options: options),
                    sink: sink,
                    text: { $0.content }
                )
            } else {
                text = try await session.respond(to: prepared.prompt, options: options).content
            }
            try Task.checkCancellation()
            let usage = await counter?.usage(transcript: prepared.transcript, prompt: prepared.prompt, text: text, calls: [])
            return FoundationModelsGenerationResult(
                response: ModelGenerationResponse(text: text, providerID: context.providerID, modelID: context.modelID, usage: usage),
                target: context.target,
                executedToolCalls: await prepared.recorder.executed
            )
        } catch {
            let calls = await prepared.recorder.proposed
            guard FoundationModelsToolBoundaryDetector.isBoundary(error, recordedCalls: calls.count) else {
                throw error
            }
            // A cancelled request must not publish tool calls (upstream stream.test.ts).
            try Task.checkCancellation()
            let usage = await counter?.usage(transcript: prepared.transcript, prompt: prepared.prompt, text: "", calls: calls)
            return FoundationModelsGenerationResult(
                response: try AppleFMPreparation.boundaryResponse(context, calls: calls, usage: usage),
                target: context.target
            )
        }
    }

    private static func options(_ context: AppleFMRunContext) -> GenerationOptions {
        let policy = context.request.policy
        #if compiler(>=6.4)
        return GenerationOptions(
            samplingMode: AppleFMPreparation.sampling(policy),
            temperature: policy.temperature,
            maximumResponseTokens: AppleFMPreparation.maximumTokens(context)
        )
        #else
        return GenerationOptions(
            sampling: AppleFMPreparation.sampling(policy),
            temperature: policy.temperature,
            maximumResponseTokens: AppleFMPreparation.maximumTokens(context)
        )
        #endif
    }
}
#endif

// MARK: - OS 27 path (any LanguageModel)

#if compiler(>=6.4)
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
enum AppleFMGeneration27 {
    static func run<Model: LanguageModel>(
        model: Model,
        context: AppleFMRunContext,
        tokenCounter: AppleFMTokenCounter?
    ) async throws -> FoundationModelsGenerationResult {
        let capabilities = model.capabilities
        let supportsTools = capabilities.contains(.toolCalling)
        try context.request.validateToolSupport(supportsTools: supportsTools, providerID: context.providerID)
        if context.request.responseFormatJSONSchema != nil, !capabilities.contains(.guidedGeneration) {
            throw FoundationModelsError(
                code: .unsupportedCapability,
                message: "The selected Apple Foundation Models model does not support guided generation.",
                capability: "guidedGeneration"
            )
        }
        let vision = capabilities.contains(.vision)
        let prepared = try AppleFMPreparation.prepare(
            context,
            allowImages: vision,
            allowReasoning: true,
            keepToolsWhenDisallowed: true,
            nativeTools: { plan in
                guard supportsTools else { return [] }
                return AppleIntelligenceTools.nativeTools(for: plan, target: context.target, options: context.options.tools, vision: vision)
            }
        )
        let session = LanguageModelSession(model: model, tools: prepared.tools, transcript: prepared.transcript)
        session.transcriptErrorHandlingPolicy = .revertTranscript
        let options = GenerationOptions(
            samplingMode: AppleFMPreparation.sampling(context.request.policy),
            temperature: context.request.policy.temperature,
            maximumResponseTokens: AppleFMPreparation.maximumTokens(context),
            toolCallingMode: prepared.tools.isEmpty ? nil : Self.toolCallingMode(context.request.toolChoice)
        )
        let contextOptions = ContextOptions(
            includeSchemaInPrompt: prepared.schema == nil ? nil : context.options.includeSchemaInPrompt,
            reasoningLevel: capabilities.contains(.reasoning) ? Self.reasoningLevel(context.request.policy) : nil
        )
        do {
            let text: String
            let usage: LanguageModelSession.Usage?
            let entries: ArraySlice<Transcript.Entry>
            if let schema = prepared.schema, let callerSchema = prepared.callerSchema {
                let response = try await session.respond(
                    to: prepared.prompt,
                    schema: schema,
                    options: options,
                    contextOptions: contextOptions,
                    metadata: [:]
                )
                text = try AppleFMPreparation.structuredText(response.content, callerSchema: callerSchema)
                usage = response.usage
                entries = response.transcriptEntries
            } else if prepared.canStream(context), let sink = context.sink {
                let (streamed, last) = try await AppleFMPreparation.streamText(
                    session.streamResponse(to: prepared.prompt, options: options, contextOptions: contextOptions, metadata: [:]),
                    sink: sink,
                    text: { $0.content }
                )
                text = streamed
                usage = last?.usage
                entries = last?.transcriptEntries ?? []
            } else {
                let response = try await session.respond(
                    to: prepared.prompt,
                    options: options,
                    contextOptions: contextOptions,
                    metadata: [:]
                )
                text = response.content
                usage = response.usage
                entries = response.transcriptEntries
            }
            try Task.checkCancellation()
            var modelUsage = usage.map(Self.usage)
            if modelUsage == nil || modelUsage == .zero, let tokenCounter {
                modelUsage = await tokenCounter.usage(transcript: prepared.transcript, prompt: prepared.prompt, text: text, calls: [])
            }
            let reasoning = context.request.policy.reasoningLevel == .off ? nil : Self.reasoningText(entries)
            return FoundationModelsGenerationResult(
                response: ModelGenerationResponse(
                    text: text,
                    providerID: context.providerID,
                    modelID: context.modelID,
                    usage: modelUsage,
                    reasoningText: reasoning
                ),
                target: context.target,
                executedToolCalls: await prepared.recorder.executed
            )
        } catch {
            let calls = await prepared.recorder.proposed
            guard FoundationModelsToolBoundaryDetector.isBoundary(error, recordedCalls: calls.count) else {
                throw error
            }
            // A cancelled request must not publish tool calls (upstream stream.test.ts).
            try Task.checkCancellation()
            var modelUsage: ModelUsage?
            if let tokenCounter {
                modelUsage = await tokenCounter.usage(transcript: prepared.transcript, prompt: prepared.prompt, text: "", calls: calls)
            }
            return FoundationModelsGenerationResult(
                response: try AppleFMPreparation.boundaryResponse(context, calls: calls, usage: modelUsage),
                target: context.target
            )
        }
    }

    /// `toolChoice` -> `GenerationOptions.ToolCallingMode`.
    static func toolCallingMode(_ choice: ModelToolChoice) -> GenerationOptions.ToolCallingMode {
        switch choice {
        case .auto:
            return .allowed
        case .none:
            return .disallowed
        case .required, .named:
            return .required
        }
    }

    /// Thinking level / reasoning effort -> `ContextOptions.ReasoningLevel` (`off` -> none;
    /// minimal/low -> light; medium/adaptive -> moderate; high/xhigh/max/ultra -> deep).
    static func reasoningLevel(_ policy: ModelGenerationPolicy) -> ContextOptions.ReasoningLevel? {
        if let level = policy.thinkingLevel {
            switch level.rawValue {
            case "off":
                return nil
            case "minimal", "low":
                return .light
            case "medium", "adaptive":
                return .moderate
            default:
                return .deep
            }
        }
        if let effort = policy.reasoningEffort {
            switch effort.rawValue {
            case "none":
                return nil
            case "minimal", "low":
                return .light
            case "medium":
                return .moderate
            default:
                return .deep
            }
        }
        return nil
    }

    /// `LanguageModelSession.Usage` -> ``ModelUsage`` (input excludes cached tokens, as upstream llm-core).
    static func usage(_ usage: LanguageModelSession.Usage) -> ModelUsage {
        let cached = Swift.min(usage.input.cachedTokenCount, usage.input.totalTokenCount)
        return ModelUsage(
            inputTokens: usage.input.totalTokenCount - cached,
            outputTokens: usage.output.totalTokenCount,
            cacheReadTokens: cached,
            reasoningTokens: usage.output.reasoningTokenCount
        )
    }

    /// Joined text of reasoning entries produced by the response.
    static func reasoningText(_ entries: ArraySlice<Transcript.Entry>) -> String? {
        let text = entries.compactMap { entry -> String? in
            guard case .reasoning(let reasoning) = entry else { return nil }
            return reasoning.segments.compactMap { segment in
                if case .text(let text) = segment { return text.content }
                return nil
            }.joined()
        }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
}
#endif
#endif
