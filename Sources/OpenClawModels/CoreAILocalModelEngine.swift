import Foundation
import OpenClawCore

/// Names of the tensors a decoder-only language model exported to CoreAI exposes.
///
/// CoreAI has no LLM contract, so these follow the common Hugging Face export conventions and must match
/// the model: `input_ids` (int32 `[1, T]`) in, `logits` (`[1, T, vocab]` or `[1, vocab]`, any float type)
/// out. Stateful exports (KV caches as function states) feed the whole prompt once and then one token per
/// step; stateless exports re-run the last ``maxContextTokens`` tokens every step.
public struct CoreAIDecoderSignature: Sendable, Equatable {
    /// Inference function name.
    public var functionName: String
    /// Token-ID input name (int32 `[1, T]`).
    public var inputIDsName: String
    /// Logits output name.
    public var logitsName: String
    /// Optional attention-mask input name (int32 ones, `[1, T]`).
    public var attentionMaskName: String?
    /// Optional position-ID input name (int32 `[1, T]`, absolute positions).
    public var positionIDsName: String?
    /// Maximum tokens kept in context (prompt plus generated).
    public var maxContextTokens: Int

    /// Creates a decoder signature.
    /// - Parameters:
    ///   - functionName: Inference function name.
    ///   - inputIDsName: Token-ID input name.
    ///   - logitsName: Logits output name.
    ///   - attentionMaskName: Optional attention-mask input name.
    ///   - positionIDsName: Optional position-ID input name.
    ///   - maxContextTokens: Context size in tokens.
    public init(
        functionName: String = "main",
        inputIDsName: String = "input_ids",
        logitsName: String = "logits",
        attentionMaskName: String? = nil,
        positionIDsName: String? = nil,
        maxContextTokens: Int = 2048
    ) {
        self.functionName = functionName
        self.inputIDsName = inputIDsName
        self.logitsName = logitsName
        self.attentionMaskName = attentionMaskName
        self.positionIDsName = positionIDsName
        self.maxContextTokens = Swift.max(1, maxContextTokens)
    }
}

/// Greedy / temperature / top-k / top-p token sampler used by ``CoreAILocalModelEngine``.
public struct CoreAITokenSampler: Sendable {
    /// Sampling temperature; `0` or less selects the arg-max token (greedy decoding).
    public var temperature: Double
    /// Keep only the `topK` most likely tokens (`0` or less keeps all).
    public var topK: Int
    /// Keep the smallest set of tokens whose probability mass reaches `topP` (`1` keeps all).
    public var topP: Double

    /// Creates a sampler.
    /// - Parameters:
    ///   - temperature: Sampling temperature.
    ///   - topK: Top-k cutoff.
    ///   - topP: Nucleus cutoff.
    public init(temperature: Double = 0, topK: Int = 0, topP: Double = 1) {
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
    }

    /// Picks the next token from a row of logits.
    /// - Parameters:
    ///   - logits: One logit per vocabulary entry.
    ///   - generator: Random source used when sampling.
    /// - Returns: Selected token identifier, or `nil` for an empty or non-finite row.
    public func sample(_ logits: [Float], using generator: inout some RandomNumberGenerator) -> Int32? {
        let finite = logits.enumerated().filter { $0.element.isFinite }
        guard !finite.isEmpty else {
            return nil
        }
        guard self.temperature > 0 else {
            return finite.max { $0.element < $1.element }.map { Int32(truncatingIfNeeded: $0.offset) }
        }
        var candidates = finite.sorted { $0.element > $1.element }
        if self.topK > 0, candidates.count > self.topK {
            candidates = Array(candidates.prefix(self.topK))
        }
        let maxLogit = Double(candidates[0].element)
        var weights = candidates.map { exp((Double($0.element) - maxLogit) / self.temperature) }
        let total = weights.reduce(0, +)
        guard total > 0, total.isFinite else {
            return Int32(truncatingIfNeeded: candidates[0].offset)
        }
        weights = weights.map { $0 / total }
        if self.topP < 1, self.topP > 0 {
            var cumulative = 0.0
            var keep = 0
            for weight in weights {
                cumulative += weight
                keep += 1
                if cumulative >= self.topP {
                    break
                }
            }
            candidates = Array(candidates.prefix(keep))
            weights = Array(weights.prefix(keep))
            let kept = weights.reduce(0, +)
            weights = weights.map { $0 / kept }
        }
        var threshold = Double.random(in: 0..<1, using: &generator)
        for (index, weight) in weights.enumerated() {
            threshold -= weight
            if threshold < 0 {
                return Int32(truncatingIfNeeded: candidates[index].offset)
            }
        }
        return candidates.last.map { Int32(truncatingIfNeeded: $0.offset) }
    }
}

/// ``LocalModelEngine`` that decodes a CoreAI-exported language model token by token.
///
/// CoreAI is a tensor runtime without a tokenizer or chat template, so the caller supplies a
/// ``CoreAITokenizer``, the tensor names (``CoreAIDecoderSignature``), and how system and user prompts
/// are combined. Register it with the local provider:
///
/// ```swift
/// let engine = CoreAILocalModelEngine(tokenizer: myTokenizer)
/// let provider = LocalModelProvider(
///     configuration: LocalModelConfig(enabled: true, runtime: CoreAILocalModelEngine.runtimeID, modelPath: "/path/model.aimodel"),
///     engine: engine
/// )
/// ```
///
/// `LocalModelConfig.runtimeOptions` may set `computeUnit` (`automatic`, `cpuOnly`, `cpu`, `gpu`,
/// `neuralEngine`) and `appGroup` (shared specialization cache). Decoding honors `maxTokens`,
/// `temperature` (0 = greedy), `topK`, `topP`, the token callback's stop signal, and cancellation.
public actor CoreAILocalModelEngine: LocalModelEngine {
    /// Runtime identifier for `LocalModelConfig.runtime`.
    public static let runtimeID = "coreai"
    /// Default maximum new tokens when `LocalModelConfig.maxTokens` is not positive.
    public static let defaultMaxNewTokens = 256

    /// Creates the tensor executor for a model path (the default loads a ``CoreAIModelRuntime``).
    public typealias ExecutorFactory = @Sendable (_ modelURL: URL, _ configuration: LocalModelConfig) async throws -> any CoreAITensorExecuting
    /// Builds the prompt text from an optional system prompt and the user prompt.
    public typealias PromptFormatter = @Sendable (_ systemPrompt: String?, _ prompt: String) -> String

    private let tokenizer: any CoreAITokenizer
    private let signature: CoreAIDecoderSignature
    private let promptFormatter: PromptFormatter
    private let executorFactory: ExecutorFactory
    private var executor: (any CoreAITensorExecuting)?
    private var isStateful = false
    // Generations run one at a time (FIFO): a stateful model has one KV cache, so interleaved steps
    // of two generations would decode against each other's state.
    private var generationActive = false
    private var generationWaiters: [CheckedContinuation<Void, Never>] = []
    private var activeGeneration: UInt64 = 0
    private var cancelledGeneration: UInt64?

    /// Creates a CoreAI decoding engine.
    /// - Parameters:
    ///   - tokenizer: Tokenizer matching the model.
    ///   - signature: Tensor names and context size.
    ///   - promptFormatter: Combines system and user prompts; the default joins them with a blank line.
    ///   - executorFactory: Creates the executor; defaults to loading a ``CoreAIModelRuntime``.
    public init(
        tokenizer: any CoreAITokenizer,
        signature: CoreAIDecoderSignature = CoreAIDecoderSignature(),
        promptFormatter: PromptFormatter? = nil,
        executorFactory: ExecutorFactory? = nil
    ) {
        self.tokenizer = tokenizer
        self.signature = signature
        self.promptFormatter = promptFormatter ?? CoreAILocalModelEngine.defaultPromptFormatter
        self.executorFactory = executorFactory ?? CoreAILocalModelEngine.defaultExecutorFactory
    }

    /// Default prompt formatter: `system + "\n\n" + prompt`, or the prompt alone.
    public static let defaultPromptFormatter: PromptFormatter = { systemPrompt, prompt in
        guard let systemPrompt = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !systemPrompt.isEmpty else {
            return prompt
        }
        return systemPrompt + "\n\n" + prompt
    }

    /// Default executor factory: loads the model into a new ``CoreAIModelRuntime`` using the
    /// `computeUnit` and `appGroup` runtime options.
    public static let defaultExecutorFactory: ExecutorFactory = { modelURL, configuration in
        let runtime = CoreAIModelRuntime()
        let computeUnit = configuration.runtimeOptions["computeUnit"].flatMap(CoreAIComputeUnit.init(normalizing:)) ?? .automatic
        try await runtime.load(url: modelURL, computeUnit: computeUnit, appGroup: configuration.runtimeOptions["appGroup"])
        return runtime
    }

    /// Loads the model and checks that the decoder function and tensors exist.
    /// - Parameters:
    ///   - path: `.aimodel` bundle path (a `file://` URL string is accepted).
    ///   - configuration: Local model configuration.
    public func loadModel(path: String, configuration: LocalModelConfig) async throws {
        let url = Self.modelURL(from: path)
        let executor = try await self.executorFactory(url, configuration)
        let descriptor = try await executor.describe()
        if !descriptor.functions.isEmpty {
            guard let function = descriptor.function(named: self.signature.functionName) else {
                throw CoreAIRuntimeError.functionNotFound(self.signature.functionName)
            }
            if !function.inputs.isEmpty, !function.inputs.contains(where: { $0.name == self.signature.inputIDsName }) {
                throw CoreAIRuntimeError.invalidModel(
                    "function '\(function.name)' has no input '\(self.signature.inputIDsName)'; inputs: \(function.inputs.map(\.name))"
                )
            }
            if !function.outputs.isEmpty, !function.outputs.contains(where: { $0.name == self.signature.logitsName }) {
                throw CoreAIRuntimeError.invalidModel(
                    "function '\(function.name)' has no output '\(self.signature.logitsName)'; outputs: \(function.outputs.map(\.name))"
                )
            }
            self.isStateful = !function.states.isEmpty
        } else {
            self.isStateful = false
        }
        self.executor = executor
    }

    /// Releases the model.
    public func unloadModel() async {
        if let runtime = self.executor as? CoreAIModelRuntime {
            await runtime.unload()
        }
        self.executor = nil
        self.isStateful = false
    }

    /// Whether a model is loaded.
    public func isModelLoaded() async -> Bool {
        self.executor != nil
    }

    /// Requests cancellation of the running generation; queued generations are not affected.
    /// - Parameter token: Ignored; the engine runs one generation at a time.
    public func cancelGeneration(token _: String?) async {
        if self.generationActive {
            self.cancelledGeneration = self.activeGeneration
        }
    }

    /// Waits for earlier generations to finish, then marks a new one active and returns its identifier.
    private func beginGeneration() async -> UInt64 {
        if self.generationActive {
            // `endGeneration` hands the slot over without clearing `generationActive`, keeping FIFO order.
            await withCheckedContinuation { continuation in
                self.generationWaiters.append(continuation)
            }
        }
        self.generationActive = true
        self.activeGeneration &+= 1
        return self.activeGeneration
    }

    /// Releases the slot to the next queued generation.
    private func endGeneration() {
        if self.cancelledGeneration == self.activeGeneration {
            self.cancelledGeneration = nil
        }
        if self.generationWaiters.isEmpty {
            self.generationActive = false
        } else {
            self.generationWaiters.removeFirst().resume()
        }
    }

    /// Generates text token by token.
    ///
    /// Concurrent calls are queued and run one at a time, so a stateful model's state (reset at the
    /// start of each generation) is never shared between them.
    /// - Parameters:
    ///   - prompt: User prompt.
    ///   - systemPrompt: Optional system prompt.
    ///   - configuration: Sampling and length settings.
    ///   - onToken: Streaming callback receiving text deltas; return `false` to stop.
    /// - Returns: Generated text.
    public func generate(
        prompt: String,
        systemPrompt: String?,
        configuration: LocalModelConfig,
        onToken: (@Sendable (String) -> Bool)?
    ) async throws -> String {
        let generation = await self.beginGeneration()
        defer { self.endGeneration() }
        try Task.checkCancellation()
        guard let executor = self.executor else {
            throw CoreAIRuntimeError.notLoaded
        }
        let promptTokens = self.tokenizer.encode(self.promptFormatter(systemPrompt, prompt))
        guard !promptTokens.isEmpty else {
            throw CoreAIRuntimeError.emptyPrompt
        }
        let contextLimit = Swift.min(
            self.signature.maxContextTokens,
            configuration.contextWindow > 0 ? configuration.contextWindow : self.signature.maxContextTokens
        )
        let maxNewTokens = configuration.maxTokens > 0 ? configuration.maxTokens : Self.defaultMaxNewTokens
        let sampler = CoreAITokenSampler(temperature: configuration.temperature, topK: configuration.topK, topP: configuration.topP)
        var random = SystemRandomNumberGenerator()
        let eosTokens = self.tokenizer.eosTokenIDs
        let stateful = self.isStateful

        var context = Array(promptTokens.suffix(contextLimit))
        var generated: [Int32] = []
        var emitted = ""
        var consumed = 0
        if stateful {
            await executor.resetStates(function: self.signature.functionName)
        }

        for _ in 0..<maxNewTokens {
            try Task.checkCancellation()
            if self.cancelledGeneration == generation {
                throw CoreAIRuntimeError.cancelled
            }
            if stateful, consumed >= contextLimit {
                break
            }
            let window: [Int32]
            let startPosition: Int
            if stateful {
                window = Array(context[consumed...])
                startPosition = consumed
            } else {
                window = Array(context.suffix(contextLimit))
                startPosition = 0
            }
            let outputs = try await executor.run(
                function: self.signature.functionName,
                inputs: try self.inputs(for: window, startPosition: startPosition)
            )
            guard let logits = outputs[self.signature.logitsName] else {
                throw CoreAIRuntimeError.missingOutput(self.signature.logitsName)
            }
            consumed = context.count
            guard let next = sampler.sample(try logits.lastRowFloats(), using: &random), !eosTokens.contains(next) else {
                break
            }
            generated.append(next)
            context.append(next)
            if !stateful, context.count > contextLimit {
                context.removeFirst(context.count - contextLimit)
            }

            let text = self.tokenizer.decode(generated)
            let delta = text.hasPrefix(emitted) ? String(text.dropFirst(emitted.count)) : text
            emitted = text
            if let onToken, !delta.isEmpty, onToken(delta) == false {
                break
            }
        }
        return self.tokenizer.decode(generated)
    }

    private func inputs(for window: [Int32], startPosition: Int) throws -> [String: CoreAITensor] {
        var inputs = [self.signature.inputIDsName: try CoreAITensor(int32: window, shape: [1, window.count])]
        if let attentionMaskName = self.signature.attentionMaskName {
            let length = startPosition + window.count
            inputs[attentionMaskName] = try CoreAITensor(int32: [Int32](repeating: 1, count: length), shape: [1, length])
        }
        if let positionIDsName = self.signature.positionIDsName {
            let positions = (startPosition..<(startPosition + window.count)).map { Int32(truncatingIfNeeded: $0) }
            inputs[positionIDsName] = try CoreAITensor(int32: positions, shape: [1, positions.count])
        }
        return inputs
    }

    static func modelURL(from path: String) -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed) {
            return url
        }
        return URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath)
    }
}

/// Text embeddings from a CoreAI embedding model, for vector memory search backends.
///
/// Runs `functionName` with `input_ids` (int32 `[1, T]`, plus an optional attention mask) and reads
/// `outputName`, either pooled (`[1, D]`) or per token (`[1, T, D]`, mean-pooled). Vectors are
/// L2-normalized by default.
public struct CoreAIEmbeddingProvider: Sendable {
    /// Tensor executor holding the embedding model.
    public let executor: any CoreAITensorExecuting
    /// Tokenizer matching the model.
    public let tokenizer: any CoreAITokenizer
    /// Inference function name.
    public var functionName: String
    /// Token-ID input name.
    public var inputIDsName: String
    /// Optional attention-mask input name.
    public var attentionMaskName: String?
    /// Embedding output name.
    public var outputName: String
    /// Maximum tokens per input (longer inputs are truncated).
    public var maxTokens: Int
    /// Whether vectors are L2-normalized.
    public var normalizes: Bool

    /// Creates an embedding provider.
    /// - Parameters:
    ///   - executor: Tensor executor with the model loaded.
    ///   - tokenizer: Tokenizer matching the model.
    ///   - functionName: Inference function name (default `embed`).
    ///   - inputIDsName: Token-ID input name.
    ///   - attentionMaskName: Optional attention-mask input name.
    ///   - outputName: Embedding output name.
    ///   - maxTokens: Maximum tokens per input.
    ///   - normalizes: L2-normalize vectors.
    public init(
        executor: any CoreAITensorExecuting,
        tokenizer: any CoreAITokenizer,
        functionName: String = "embed",
        inputIDsName: String = "input_ids",
        attentionMaskName: String? = nil,
        outputName: String = "embedding",
        maxTokens: Int = 512,
        normalizes: Bool = true
    ) {
        self.executor = executor
        self.tokenizer = tokenizer
        self.functionName = functionName
        self.inputIDsName = inputIDsName
        self.attentionMaskName = attentionMaskName
        self.outputName = outputName
        self.maxTokens = Swift.max(1, maxTokens)
        self.normalizes = normalizes
    }

    /// Embeds one text.
    /// - Parameter text: Input text.
    /// - Returns: Embedding vector.
    /// - Throws: ``CoreAIRuntimeError`` for empty input or execution failures.
    public func embed(_ text: String) async throws -> [Float] {
        let tokens = Array(self.tokenizer.encode(text).prefix(self.maxTokens))
        guard !tokens.isEmpty else {
            throw CoreAIRuntimeError.emptyPrompt
        }
        var inputs = [self.inputIDsName: try CoreAITensor(int32: tokens, shape: [1, tokens.count])]
        if let attentionMaskName {
            inputs[attentionMaskName] = try CoreAITensor(int32: [Int32](repeating: 1, count: tokens.count), shape: [1, tokens.count])
        }
        let outputs = try await self.executor.run(function: self.functionName, inputs: inputs)
        guard let output = outputs[self.outputName] else {
            throw CoreAIRuntimeError.missingOutput(self.outputName)
        }
        var vector = try Self.pool(output)
        if self.normalizes {
            vector = Self.normalized(vector)
        }
        return vector
    }

    /// Embeds several texts in order.
    /// - Parameter texts: Input texts.
    /// - Returns: One vector per text.
    public func embed(_ texts: [String]) async throws -> [[Float]] {
        var vectors: [[Float]] = []
        vectors.reserveCapacity(texts.count)
        for text in texts {
            vectors.append(try await self.embed(text))
        }
        return vectors
    }

    /// Cosine similarity of two vectors (`0` for mismatched or zero vectors).
    /// - Parameters:
    ///   - lhs: First vector.
    ///   - rhs: Second vector.
    /// - Returns: Similarity in `-1...1`.
    public static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else {
            return 0
        }
        var dot: Float = 0
        var lhsNorm: Float = 0
        var rhsNorm: Float = 0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            lhsNorm += lhs[index] * lhs[index]
            rhsNorm += rhs[index] * rhs[index]
        }
        let denominator = lhsNorm.squareRoot() * rhsNorm.squareRoot()
        return denominator > 0 ? dot / denominator : 0
    }

    static func pool(_ tensor: CoreAITensor) throws -> [Float] {
        let values = tensor.floatValues()
        let nonUnit = tensor.shape.filter { $0 != 1 }
        switch nonUnit.count {
        case 0, 1:
            return values
        case 2:
            let tokens = nonUnit[0]
            let width = nonUnit[1]
            guard tokens > 0, width > 0 else {
                throw CoreAIRuntimeError.invalidTensor("empty embedding output \(tensor.shape)")
            }
            var pooled = [Float](repeating: 0, count: width)
            for token in 0..<tokens {
                for column in 0..<width {
                    pooled[column] += values[token * width + column]
                }
            }
            return pooled.map { $0 / Float(tokens) }
        default:
            throw CoreAIRuntimeError.invalidTensor("expected an embedding shaped [1, D] or [1, T, D], got \(tensor.shape)")
        }
    }

    static func normalized(_ vector: [Float]) -> [Float] {
        let norm = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0, norm.isFinite else {
            return vector
        }
        return vector.map { $0 / norm }
    }
}
