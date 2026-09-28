import Foundation
import Testing
@testable import OpenClawKit
@testable import OpenClawModels

@Suite("CoreAI model runtime adapters")
struct CoreAIModelRuntimeTests {
    // MARK: Fakes

    /// Character-level tokenizer: token = Unicode scalar value; `~` (126) ends generation.
    struct ScalarTokenizer: CoreAITokenizer {
        let eosTokenIDs: Set<Int32> = [126]

        func encode(_ text: String) -> [Int32] {
            text.unicodeScalars.map { Int32($0.value) }
        }

        func decode(_ tokens: [Int32]) -> String {
            String(String.UnicodeScalarView(tokens.compactMap { UnicodeScalar(UInt32($0)) }))
        }
    }

    /// Fake decoder that emits a scripted continuation: logits peak at `script[step]`.
    actor ScriptedExecutor: CoreAITensorExecuting {
        let script: [Int32]
        let vocabulary: Int
        let stateful: Bool
        let perTokenLogits: Bool
        private(set) var inputs: [[String: CoreAITensor]] = []
        private(set) var resets = 0
        private var step = 0

        init(script: String, vocabulary: Int = 128, stateful: Bool = false, perTokenLogits: Bool = true) {
            self.script = script.unicodeScalars.map { Int32($0.value) }
            self.vocabulary = vocabulary
            self.stateful = stateful
            self.perTokenLogits = perTokenLogits
        }

        func describe() async throws -> CoreAIModelDescriptor {
            CoreAIModelDescriptor(
                path: "/models/fake.aimodel",
                functions: [
                    CoreAIFunctionDescriptor(
                        name: "main",
                        inputs: [CoreAIValueDescriptor(name: "input_ids"), CoreAIValueDescriptor(name: "position_ids")],
                        states: self.stateful ? [CoreAIValueDescriptor(name: "kv_cache")] : [],
                        outputs: [CoreAIValueDescriptor(name: "logits")]
                    ),
                ]
            )
        }

        func run(function: String, inputs: [String: CoreAITensor]) async throws -> [String: CoreAITensor] {
            guard function == "main" else {
                throw CoreAIRuntimeError.functionNotFound(function)
            }
            self.inputs.append(inputs)
            let target = self.step < self.script.count ? self.script[self.step] : 126
            self.step += 1
            let tokens = inputs["input_ids"]?.shape.last ?? 1
            let rows = self.perTokenLogits ? tokens : 1
            var logits = [Float](repeating: -5, count: rows * self.vocabulary)
            // Earlier rows peak elsewhere so only the last row decides.
            for row in 0..<(rows - 1) {
                logits[row * self.vocabulary + 65] = 10
            }
            logits[(rows - 1) * self.vocabulary + Int(target)] = 8
            let shape = self.perTokenLogits ? [1, rows, self.vocabulary] : [1, self.vocabulary]
            return ["logits": try CoreAITensor(float32: logits, shape: shape)]
        }

        func resetStates(function _: String?) async {
            self.resets += 1
        }
    }

    struct EmbeddingExecutor: CoreAITensorExecuting {
        let perToken: Bool

        func describe() async throws -> CoreAIModelDescriptor {
            CoreAIModelDescriptor(path: "/models/embed.aimodel")
        }

        func run(function: String, inputs: [String: CoreAITensor]) async throws -> [String: CoreAITensor] {
            let count = inputs["input_ids"]?.elementCount ?? 0
            if self.perToken {
                // Token t contributes [t, 0]; mean over tokens 0..<count is [(count-1)/2, 0] before normalization.
                var values: [Float] = []
                for token in 0..<count {
                    values.append(Float(token))
                    values.append(0)
                }
                return ["embedding": try CoreAITensor(float32: values, shape: [1, count, 2])]
            }
            return ["embedding": try CoreAITensor(float32: [3, 4], shape: [1, 2])]
        }
    }

    // MARK: Tensors

    @Test
    func tensorsValidateShapesAndConvertScalarTypes() throws {
        let ids = try CoreAITensor(int32: [1, 2, 3, 4, 5, 6], shape: [2, 3])
        #expect(ids.elementCount == 6)
        #expect(ids.data.count == 24)
        #expect(ids.int32Values() == [1, 2, 3, 4, 5, 6])
        #expect(ids.floatValues() == [1, 2, 3, 4, 5, 6])
        #expect(try ids.lastRowFloats() == [4, 5, 6])

        #expect(throws: CoreAIRuntimeError.self) { _ = try CoreAITensor(int32: [1, 2, 3], shape: [2, 2]) }
        #expect(throws: CoreAIRuntimeError.self) { _ = try CoreAITensor(shape: [-1], scalarType: .int8, data: Data()) }
        #expect(throws: CoreAIRuntimeError.self) { _ = try CoreAITensor(float32: [], shape: [0]).lastRowFloats() }

        // IEEE half: 1.0 = 0x3C00, -2.0 = 0xC000, 65504 = 0x7BFF, smallest subnormal = 0x0001, +inf = 0x7C00.
        let halfBits: [UInt16] = [0x3C00, 0xC000, 0x7BFF, 0x0001, 0x7C00, 0x0000]
        let half = try CoreAITensor(shape: [6], scalarType: .float16, data: halfBits.withUnsafeBufferPointer { Data(buffer: $0) })
        let halfValues = half.floatValues()
        #expect(halfValues[0] == 1)
        #expect(halfValues[1] == -2)
        #expect(halfValues[2] == 65504)
        #expect(halfValues[3] == Float(sign: .plus, exponent: -24, significand: 1))
        #expect(halfValues[4] == .infinity)
        #expect(halfValues[5] == 0)

        // bfloat16 is the top half of a float32: 1.5 = 0x3FC0.
        let bf16 = try CoreAITensor(shape: [1], scalarType: .bfloat16, data: [UInt16(0x3FC0)].withUnsafeBufferPointer { Data(buffer: $0) })
        #expect(bf16.floatValues() == [1.5])

        #expect(CoreAIScalarType.allCases.map(\.byteWidth) == [1, 1, 2, 4, 8, 1, 2, 4, 8, 2, 2, 4, 8])
        let decoded = try JSONDecoder().decode(CoreAITensor.self, from: JSONEncoder().encode(ids))
        #expect(decoded == ids)
    }

    @Test
    func stridedCopiesGatherAndScatterPaddedLayouts() {
        // Shape [2, 3] stored with a row stride of 4 elements (one padding element per row).
        let padded: [Int32] = [1, 2, 3, -1, 4, 5, 6, -1]
        var dense = [Int32](repeating: 0, count: 6)
        padded.withUnsafeBytes { source in
            dense.withUnsafeMutableBytes { destination in
                CoreAIStridedCopy.gather(
                    from: source.baseAddress!, into: destination.baseAddress!, shape: [2, 3], strides: [4, 1], elementWidth: 4
                )
            }
        }
        #expect(dense == [1, 2, 3, 4, 5, 6])

        var restored = [Int32](repeating: 0, count: 8)
        dense.withUnsafeBytes { source in
            restored.withUnsafeMutableBytes { destination in
                CoreAIStridedCopy.scatter(
                    from: source.baseAddress!, into: destination.baseAddress!, shape: [2, 3], strides: [4, 1], elementWidth: 4
                )
            }
        }
        #expect(restored == [1, 2, 3, 0, 4, 5, 6, 0])
        #expect(CoreAIStridedCopy.contiguousStrides(for: [2, 3, 4]) == [12, 4, 1])
    }

    @Test
    func samplerIsGreedyAtZeroTemperatureAndRespectsTopK() {
        var generator = SystemRandomNumberGenerator()
        let logits: [Float] = [0.1, 3, -1, 2.9, .nan]
        #expect(CoreAITokenSampler().sample(logits, using: &generator) == 1)
        #expect(CoreAITokenSampler().sample([], using: &generator) == nil)
        let topOne = CoreAITokenSampler(temperature: 1.5, topK: 1)
        for _ in 0..<20 {
            #expect(topOne.sample(logits, using: &generator) == 1)
        }
        let nucleus = CoreAITokenSampler(temperature: 1, topK: 0, topP: 0.5)
        for _ in 0..<20 {
            let token = nucleus.sample(logits, using: &generator)
            #expect(token == 1 || token == 3)
        }
        #expect(CoreAIComputeUnit(normalizing: "ANE") == .neuralEngine)
        #expect(CoreAIComputeUnit(normalizing: "cpu-only") == .cpuOnly)
        #expect(CoreAIComputeUnit(normalizing: "tpu") == nil)
    }

    // MARK: Decode engine

    @Test
    func statelessEngineStreamsGreedyTokensUntilEOS() async throws {
        let executor = ScriptedExecutor(script: "Hi!~ignored")
        let engine = CoreAILocalModelEngine(
            tokenizer: ScalarTokenizer(),
            signature: CoreAIDecoderSignature(positionIDsName: "position_ids"),
            executorFactory: { _, _ in executor }
        )
        var configuration = LocalModelConfig(enabled: true, runtime: CoreAILocalModelEngine.runtimeID, modelPath: "/models/fake.aimodel")
        configuration.temperature = 0
        try await engine.loadModel(path: "/models/fake.aimodel", configuration: configuration)
        #expect(await engine.isModelLoaded())

        let deltas = DeltaCollector()
        let text = try await engine.generate(prompt: "ab", systemPrompt: "sys", configuration: configuration) { delta in
            deltas.append(delta)
            return true
        }
        #expect(text == "Hi!")
        #expect(deltas.values == ["H", "i", "!"])

        let calls = await executor.inputs
        #expect(calls.count == 4)
        // Stateless: every step re-feeds the whole context ("sys\n\nab" + generated tokens).
        #expect(calls[0]["input_ids"]?.int32Values() == ScalarTokenizer().encode("sys\n\nab"))
        #expect(calls[1]["input_ids"]?.int32Values() == ScalarTokenizer().encode("sys\n\nabH"))
        #expect(calls[1]["position_ids"]?.int32Values() == (0..<8).map { Int32($0) })
        #expect(await executor.resets == 0)

        await engine.unloadModel()
        #expect(await engine.isModelLoaded() == false)
        await #expect(throws: CoreAIRuntimeError.notLoaded) {
            _ = try await engine.generate(prompt: "x", systemPrompt: nil, configuration: configuration, onToken: nil)
        }
    }

    @Test
    func statefulEngineFeedsPromptOnceThenOneTokenPerStep() async throws {
        let executor = ScriptedExecutor(script: "abcdef", stateful: true, perTokenLogits: false)
        let engine = CoreAILocalModelEngine(
            tokenizer: ScalarTokenizer(),
            signature: CoreAIDecoderSignature(attentionMaskName: "attention_mask", positionIDsName: "position_ids"),
            executorFactory: { _, _ in executor }
        )
        var configuration = LocalModelConfig(enabled: true, runtime: CoreAILocalModelEngine.runtimeID, modelPath: "/m")
        configuration.temperature = 0
        configuration.maxTokens = 3
        try await engine.loadModel(path: "file:///m", configuration: configuration)

        let text = try await engine.generate(prompt: "xyz", systemPrompt: nil, configuration: configuration, onToken: nil)
        #expect(text == "abc")
        let calls = await executor.inputs
        #expect(calls.count == 3)
        #expect(calls[0]["input_ids"]?.int32Values() == ScalarTokenizer().encode("xyz"))
        #expect(calls[1]["input_ids"]?.int32Values() == ScalarTokenizer().encode("a"))
        #expect(calls[1]["position_ids"]?.int32Values() == [3])
        #expect(calls[2]["position_ids"]?.int32Values() == [4])
        #expect(calls[2]["attention_mask"]?.shape == [1, 5])
        #expect(await executor.resets == 1)
    }

    @Test
    func engineStopsOnCallbackAndValidatesTheModel() async throws {
        let executor = ScriptedExecutor(script: "abcdef")
        let engine = CoreAILocalModelEngine(tokenizer: ScalarTokenizer(), executorFactory: { _, _ in executor })
        var configuration = LocalModelConfig(enabled: true, runtime: "coreai", modelPath: "/m")
        configuration.temperature = 0
        try await engine.loadModel(path: "/m", configuration: configuration)
        let text = try await engine.generate(prompt: "q", systemPrompt: nil, configuration: configuration) { delta in
            delta != "b"
        }
        #expect(text == "ab")

        let wrongFunction = CoreAILocalModelEngine(
            tokenizer: ScalarTokenizer(),
            signature: CoreAIDecoderSignature(functionName: "decode"),
            executorFactory: { _, _ in executor }
        )
        await #expect(throws: CoreAIRuntimeError.functionNotFound("decode")) {
            try await wrongFunction.loadModel(path: "/m", configuration: configuration)
        }
        let wrongOutput = CoreAILocalModelEngine(
            tokenizer: ScalarTokenizer(),
            signature: CoreAIDecoderSignature(logitsName: "scores"),
            executorFactory: { _, _ in executor }
        )
        await #expect(throws: CoreAIRuntimeError.self) {
            try await wrongOutput.loadModel(path: "/m", configuration: configuration)
        }
        await #expect(throws: CoreAIRuntimeError.emptyPrompt) {
            _ = try await engine.generate(prompt: "", systemPrompt: nil, configuration: configuration, onToken: nil)
        }
    }

    @Test
    func localModelProviderRoutesToTheCoreAIEngine() async throws {
        let executor = ScriptedExecutor(script: "ok~")
        let engine = CoreAILocalModelEngine(tokenizer: ScalarTokenizer(), executorFactory: { _, _ in executor })
        var configuration = LocalModelConfig(enabled: true, runtime: CoreAILocalModelEngine.runtimeID, modelPath: "/models/fake.aimodel")
        configuration.temperature = 0
        let provider = LocalModelProvider(configuration: configuration, engine: engine)
        let response = try await provider.generate(ModelGenerationRequest(sessionKey: "s", prompt: "hello"))
        #expect(response.text == "ok")
        #expect(response.modelID == "fake.aimodel")

        var streamed = ""
        for try await chunk in await provider.generateStream(ModelGenerationRequest(sessionKey: "s", prompt: "again")) {
            streamed += chunk.text
        }
        // The scripted executor has finished its script, so the second run ends at EOS immediately.
        #expect(streamed.isEmpty)
    }

    @Test
    func embeddingProviderPoolsAndNormalizes() async throws {
        let pooled = CoreAIEmbeddingProvider(executor: EmbeddingExecutor(perToken: false), tokenizer: ScalarTokenizer())
        #expect(try await pooled.embed("abc") == [0.6, 0.8])

        let perToken = CoreAIEmbeddingProvider(
            executor: EmbeddingExecutor(perToken: true),
            tokenizer: ScalarTokenizer(),
            attentionMaskName: "attention_mask",
            normalizes: false
        )
        #expect(try await perToken.embed("abcde") == [2, 0])
        let batch = try await pooled.embed(["a", "b"])
        #expect(batch.count == 2)
        #expect(abs(CoreAIEmbeddingProvider.cosineSimilarity([1, 0], [1, 0]) - 1) < 1e-6)
        #expect(CoreAIEmbeddingProvider.cosineSimilarity([1, 0], [0, 1]) == 0)
        #expect(CoreAIEmbeddingProvider.cosineSimilarity([1], [1, 2]) == 0)
        await #expect(throws: CoreAIRuntimeError.emptyPrompt) {
            _ = try await pooled.embed("")
        }
    }

    // MARK: Runtime (CoreAI framework)

    @Test
    func runtimeReportsAvailabilityAndRejectsMissingModels() async throws {
        let runtime = CoreAIModelRuntime()
        #expect(await runtime.isLoaded() == false)
        guard CoreAIModelRuntime.isSupported else {
            await #expect(throws: CoreAIRuntimeError.self) {
                _ = try await runtime.load(url: URL(fileURLWithPath: "/nope.aimodel"))
            }
            #expect(CoreAIModelRuntime.availableComputeUnits.isEmpty)
            return
        }
        #expect(!CoreAIModelRuntime.availableComputeUnits.isEmpty)
        #expect(CoreAIModelRuntime.deviceArchitectureName?.isEmpty == false)
        let missing = URL(fileURLWithPath: "/tmp/openclaw-missing-\(UUID().uuidString).aimodel")
        #expect(CoreAIModelRuntime.isValidModel(at: missing) == false)
        #expect(throws: CoreAIRuntimeError.self) { _ = try CoreAIModelRuntime.inspect(url: missing) }
        await #expect(throws: CoreAIRuntimeError.self) { _ = try await runtime.load(url: missing) }
        await #expect(throws: CoreAIRuntimeError.notLoaded) {
            _ = try await runtime.run(function: "main", inputs: [:])
        }
        await #expect(throws: CoreAIRuntimeError.notLoaded) { _ = try await runtime.describe() }
    }

    /// Live check against a real `.aimodel` bundle: set `OPENCLAW_COREAI_MODEL_PATH`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENCLAW_COREAI_MODEL_PATH"] != nil))
    func liveModelInspectLoadAndRun() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["OPENCLAW_COREAI_MODEL_PATH"])
        let url = URL(fileURLWithPath: path)
        let inspected = try CoreAIModelRuntime.inspect(url: url)
        #expect(!inspected.functions.isEmpty)
        let runtime = CoreAIModelRuntime()
        let loaded = try await runtime.load(url: url, computeUnit: .cpuOnly)
        let function = try #require(loaded.functions.first)
        var inputs: [String: CoreAITensor] = [:]
        for input in function.inputs {
            guard let typeName = input.scalarType, let type = CoreAIScalarType(rawValue: typeName),
                  let shape = input.shape, input.hasDynamicShape != true
            else {
                return
            }
            let count = shape.reduce(1, *)
            inputs[input.name] = try CoreAITensor(shape: shape, scalarType: type, data: Data(count: count * type.byteWidth))
        }
        let outputs = try await runtime.run(function: function.name, inputs: inputs)
        #expect(!outputs.isEmpty)
    }
}

/// Thread-safe collector for streamed deltas.
final class DeltaCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ value: String) {
        self.lock.lock()
        self.storage.append(value)
        self.lock.unlock()
    }

    var values: [String] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.storage
    }
}
