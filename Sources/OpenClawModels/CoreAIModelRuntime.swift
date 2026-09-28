import Foundation
import OpenClawProtocol

/// CoreAI `.aimodel` runtime: inspects model assets, specializes them for this device through
/// `AIModelCache`, and runs their inference functions with ``CoreAITensor`` inputs and outputs.
///
/// CoreAI is a low-level tensor runtime (iOS, macOS, tvOS, watchOS and visionOS 27). It has no
/// tokenizer, chat template, or language-model contract; ``CoreAILocalModelEngine`` and
/// ``CoreAIEmbeddingProvider`` layer those conventions on top with a caller-supplied tokenizer. On Linux
/// and earlier OS versions ``isSupported`` is `false` and every call throws
/// ``CoreAIRuntimeError/unavailable(_:)``.
///
/// Stateful functions (for example KV caches) keep their state between ``run(function:inputs:)`` calls,
/// up to ``maxSupportedStates`` states per function; call ``resetStates(function:)`` to start over.
/// Only byte-aligned scalar types (see ``CoreAIScalarType``) can be passed in or read out; image
/// (pixel-buffer) values are not bridged.
public actor CoreAIModelRuntime: CoreAITensorExecuting {
    /// Maximum number of mutable states per function the runtime can bind.
    public static let maxSupportedStates = 4

    // Holds a `CoreAILoadedModel` on OS 27; typed as `any Sendable` so the actor itself carries no
    // 27-only types (the CoreAI framework stays weak-linked).
    private var storage: (any Sendable)?
    private var runningStatefulFunctions: Set<String> = []

    /// Creates an empty runtime; call ``load(url:computeUnit:appGroup:persistentCache:)`` next.
    public init() {}

    /// Whether CoreAI is available on the running OS.
    public static var isSupported: Bool {
        #if compiler(>=6.4) && canImport(CoreAI)
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) {
            return true
        }
        #endif
        return false
    }

    /// Compute units available on this device (empty when CoreAI is unavailable).
    public static var availableComputeUnits: [CoreAIComputeUnit] {
        #if compiler(>=6.4) && canImport(CoreAI)
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) {
            return CoreAIBridge.availableComputeUnits()
        }
        #endif
        return []
    }

    /// Device architecture name CoreAI specializes for (for example `h15m`), when available.
    public static var deviceArchitectureName: String? {
        #if compiler(>=6.4) && canImport(CoreAI)
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) {
            return CoreAIBridge.deviceArchitectureName()
        }
        #endif
        return nil
    }

    /// Returns whether `url` points at a valid `.aimodel` bundle (always `false` without CoreAI).
    /// - Parameter url: Candidate bundle URL.
    /// - Returns: `true` when CoreAI accepts the bundle.
    public static func isValidModel(at url: URL) -> Bool {
        #if compiler(>=6.4) && canImport(CoreAI)
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) {
            return CoreAIBridge.isValidModel(at: url)
        }
        #endif
        return false
    }

    /// Inspects a `.aimodel` bundle without loading it: functions, value types, metadata, and statistics.
    /// - Parameter url: Model bundle URL.
    /// - Returns: Model descriptor.
    /// - Throws: ``CoreAIRuntimeError`` when CoreAI is unavailable or the bundle is invalid.
    public static func inspect(url: URL) throws -> CoreAIModelDescriptor {
        #if compiler(>=6.4) && canImport(CoreAI)
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) {
            return try CoreAIBridge.inspect(url: url)
        }
        #endif
        throw Self.unavailableError
    }

    /// Deletes cached specializations of one model, or of every model when `url` is `nil`.
    /// - Parameters:
    ///   - url: Model bundle URL, or `nil` to clear the whole cache.
    ///   - appGroup: App group whose shared cache to purge; `nil` uses the default cache.
    /// - Throws: ``CoreAIRuntimeError`` when CoreAI is unavailable or the cache cannot be opened.
    public static func purgeCache(for url: URL?, appGroup: String? = nil) throws {
        #if compiler(>=6.4) && canImport(CoreAI)
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) {
            try CoreAIBridge.purgeCache(for: url, appGroup: appGroup)
            return
        }
        #endif
        throw Self.unavailableError
    }

    /// Loads a `.aimodel` bundle, specializing it for this device (results are cached by CoreAI).
    ///
    /// A previously loaded model is replaced.
    /// - Parameters:
    ///   - url: Model bundle URL.
    ///   - computeUnit: Preferred compute unit.
    ///   - appGroup: App group whose shared cache stores the specialization; `nil` uses the default cache.
    ///   - persistentCache: Keep the specialization under storage pressure (`AIModelCache.Policy.persistent`;
    ///     ignored on tvOS, where that policy is unavailable).
    /// - Returns: Descriptor of the loaded model.
    /// - Throws: ``CoreAIRuntimeError`` when CoreAI is unavailable or specialization fails.
    @discardableResult
    public func load(
        url: URL,
        computeUnit: CoreAIComputeUnit = .automatic,
        appGroup: String? = nil,
        persistentCache: Bool = false
    ) async throws -> CoreAIModelDescriptor {
        #if compiler(>=6.4) && canImport(CoreAI)
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) {
            let loaded = try await CoreAIBridge.load(
                url: url,
                computeUnit: computeUnit,
                appGroup: appGroup,
                persistentCache: persistentCache
            )
            self.storage = loaded
            self.runningStatefulFunctions = []
            return loaded.descriptor
        }
        #endif
        throw Self.unavailableError
    }

    /// Whether a model is loaded.
    public func isLoaded() -> Bool {
        self.storage != nil
    }

    /// Releases the loaded model and its states.
    public func unload() {
        self.storage = nil
        self.runningStatefulFunctions = []
    }

    /// Describes the loaded model.
    /// - Returns: Model descriptor.
    /// - Throws: ``CoreAIRuntimeError/notLoaded`` when no model is loaded.
    public func describe() throws -> CoreAIModelDescriptor {
        #if compiler(>=6.4) && canImport(CoreAI)
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) {
            guard let loaded = self.storage as? CoreAILoadedModel else {
                throw CoreAIRuntimeError.notLoaded
            }
            return loaded.descriptor
        }
        #endif
        throw Self.unavailableError
    }

    /// Runs one inference function.
    /// - Parameters:
    ///   - function: Function name.
    ///   - inputs: Input tensors by name.
    /// - Returns: Output tensors by name (image outputs are skipped).
    /// - Throws: ``CoreAIRuntimeError`` for missing models/functions, bad tensors, or runtime failures.
    public func run(function: String, inputs: [String: CoreAITensor]) async throws -> [String: CoreAITensor] {
        #if compiler(>=6.4) && canImport(CoreAI)
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) {
            guard var loaded = self.storage as? CoreAILoadedModel else {
                throw CoreAIRuntimeError.notLoaded
            }
            let inferenceFunction = try loaded.function(named: function)
            self.storage = loaded
            let stateNames = inferenceFunction.descriptor.stateNames
            guard stateNames.count <= Self.maxSupportedStates else {
                throw CoreAIRuntimeError.unsupportedStates(
                    "function '\(function)' has \(stateNames.count) states; at most \(Self.maxSupportedStates) are supported"
                )
            }
            let arrays = try inputs.mapValues(CoreAIBridge.ndArray(from:))
            guard !stateNames.isEmpty else {
                var noStates: [NDArray] = []
                return try await CoreAIBridge.invoke(inferenceFunction, inputs: arrays, stateNames: [], states: &noStates)
            }
            guard !self.runningStatefulFunctions.contains(function) else {
                throw CoreAIRuntimeError.executionFailed("stateful function '\(function)' is already running")
            }
            self.runningStatefulFunctions.insert(function)
            defer { self.runningStatefulFunctions.remove(function) }
            var states = try loaded.states[function] ?? CoreAIBridge.makeStates(for: inferenceFunction)
            let outputs = try await CoreAIBridge.invoke(inferenceFunction, inputs: arrays, stateNames: stateNames, states: &states)
            if var current = self.storage as? CoreAILoadedModel, current.id == loaded.id {
                current.states[function] = states
                self.storage = current
            }
            return outputs
        }
        #endif
        throw Self.unavailableError
    }

    /// Clears the mutable state of one function, or of every function when `function` is `nil`.
    /// - Parameter function: Function name, or `nil` for all.
    public func resetStates(function: String?) {
        #if compiler(>=6.4) && canImport(CoreAI)
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) {
            guard var loaded = self.storage as? CoreAILoadedModel else {
                return
            }
            if let function {
                loaded.states[function] = nil
            } else {
                loaded.states = [:]
            }
            self.storage = loaded
        }
        #endif
    }

    private static var unavailableError: CoreAIRuntimeError {
        .unavailable("CoreAI needs iOS, macOS, tvOS, watchOS, or visionOS 27")
    }
}

#if compiler(>=6.4) && canImport(CoreAI)
import CoreAI

/// Loaded CoreAI model plus cached functions and per-function states.
@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
struct CoreAILoadedModel: Sendable {
    let id = UUID()
    let model: AIModel
    let descriptor: CoreAIModelDescriptor
    var functions: [String: InferenceFunction] = [:]
    var states: [String: [NDArray]] = [:]

    mutating func function(named name: String) throws -> InferenceFunction {
        if let cached = self.functions[name] {
            return cached
        }
        let loaded: InferenceFunction?
        do {
            loaded = try self.model.loadFunction(named: name)
        } catch {
            throw CoreAIRuntimeError.executionFailed("loading function '\(name)' failed: \(error.localizedDescription)")
        }
        guard let loaded else {
            throw CoreAIRuntimeError.functionNotFound(name)
        }
        self.functions[name] = loaded
        return loaded
    }
}

/// CoreAI calls, all availability-gated so the framework is weak-linked.
@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
enum CoreAIBridge {
    static func availableComputeUnits() -> [CoreAIComputeUnit] {
        let kinds = ComputeUnitKind.availableKinds
        var units: [CoreAIComputeUnit] = []
        if kinds.contains(.cpu) { units.append(.cpu) }
        if kinds.contains(.gpu) { units.append(.gpu) }
        if kinds.contains(.neuralEngine) { units.append(.neuralEngine) }
        return units
    }

    static func deviceArchitectureName() -> String {
        AIModel.deviceArchitectureName
    }

    static func isValidModel(at url: URL) -> Bool {
        AIModelAsset.isValid(at: url)
    }

    static func specializationOptions(for unit: CoreAIComputeUnit) -> SpecializationOptions {
        switch unit {
        case .automatic: return .default
        case .cpuOnly: return .cpuOnly
        case .cpu: return SpecializationOptions(preferredComputeUnitKind: .cpu)
        case .gpu: return SpecializationOptions(preferredComputeUnitKind: .gpu)
        case .neuralEngine: return SpecializationOptions(preferredComputeUnitKind: .neuralEngine)
        }
    }

    static func cache(appGroup: String?) throws -> AIModelCache {
        guard let appGroup = appGroup?.trimmingCharacters(in: .whitespacesAndNewlines), !appGroup.isEmpty else {
            return .default
        }
        guard let cache = AIModelCache(appGroup: appGroup) else {
            throw CoreAIRuntimeError.invalidModel("the CoreAI cache for app group '\(appGroup)' is not accessible")
        }
        return cache
    }

    static func inspect(url: URL) throws -> CoreAIModelDescriptor {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CoreAIRuntimeError.invalidModel("no model at \(url.path)")
        }
        let asset: AIModelAsset
        let summary: AIModelAsset.Summary?
        do {
            asset = try AIModelAsset(contentsOf: url)
            summary = try asset.summary(includingStatistics: true)
        } catch {
            throw CoreAIRuntimeError.invalidModel("\(url.lastPathComponent): \(error.localizedDescription)")
        }
        let functions = (summary?.functions ?? []).map { function in
            CoreAIFunctionDescriptor(
                name: function.name,
                inputs: function.inputs.map { CoreAIValueDescriptor(name: $0.name, typeName: $0.typeName) },
                states: function.states.map { CoreAIValueDescriptor(name: $0.name, typeName: $0.typeName) },
                outputs: function.outputs.map { CoreAIValueDescriptor(name: $0.name, typeName: $0.typeName) }
            )
        }
        var storageTypes: [String: Int] = [:]
        for storage in summary?.storageTypes ?? [] {
            storageTypes[storage.typeName, default: 0] += storage.count
        }
        return CoreAIModelDescriptor(
            path: url.path,
            functions: functions,
            metadata: Self.metadata(asset.metadata),
            storageTypes: storageTypes,
            computeTypes: summary?.computeTypes ?? [],
            computeUnit: nil,
            deviceArchitecture: AIModel.deviceArchitectureName
        )
    }

    static func load(
        url: URL,
        computeUnit: CoreAIComputeUnit,
        appGroup: String?,
        persistentCache: Bool
    ) async throws -> CoreAILoadedModel {
        var descriptor = try Self.inspect(url: url)
        let cache = try Self.cache(appGroup: appGroup)
        #if os(tvOS)
        // `AIModelCache.Policy.persistent` is unavailable on tvOS; the default policy applies.
        let cachePolicy = AIModelCache.Policy.default
        #else
        let cachePolicy: AIModelCache.Policy = persistentCache ? .persistent : .default
        #endif
        let model: AIModel
        do {
            model = try await AIModel.specialize(
                contentsOf: url,
                options: Self.specializationOptions(for: computeUnit),
                cache: cache,
                cachePolicy: cachePolicy
            )
        } catch {
            throw CoreAIRuntimeError.invalidModel("specializing \(url.lastPathComponent) failed: \(error.localizedDescription)")
        }
        descriptor.computeUnit = computeUnit
        descriptor.functions = Self.enrich(descriptor.functions, with: model)
        return CoreAILoadedModel(model: model, descriptor: descriptor)
    }

    static func purgeCache(for url: URL?, appGroup: String?) throws {
        let cache = try Self.cache(appGroup: appGroup)
        do {
            if let url {
                try cache.deleteEntries(for: url)
            } else {
                try cache.deleteAll()
            }
        } catch {
            throw CoreAIRuntimeError.executionFailed("purging the CoreAI cache failed: \(error.localizedDescription)")
        }
    }

    /// Adds runtime value descriptors (kind, scalar type, shape) from the specialized model.
    static func enrich(_ functions: [CoreAIFunctionDescriptor], with model: AIModel) -> [CoreAIFunctionDescriptor] {
        var byName = Dictionary(functions.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var order = functions.map(\.name)
        for name in model.functionNames where byName[name] == nil {
            byName[name] = CoreAIFunctionDescriptor(name: name)
            order.append(name)
        }
        return order.compactMap { name -> CoreAIFunctionDescriptor? in
            guard var function = byName[name] else {
                return nil
            }
            guard let runtime = model.functionDescriptor(for: name) else {
                return function
            }
            function.inputs = Self.merge(function.inputs, names: runtime.inputNames) { runtime.inputDescriptor(of: $0) }
            function.states = Self.merge(function.states, names: runtime.stateNames) { runtime.stateDescriptor(of: $0) }
            function.outputs = Self.merge(function.outputs, names: runtime.outputNames) { runtime.outputDescriptor(of: $0) }
            return function
        }
    }

    private static func merge(
        _ values: [CoreAIValueDescriptor],
        names: [String],
        descriptor: (String) -> InferenceValue.Descriptor?
    ) -> [CoreAIValueDescriptor] {
        var merged = values
        for name in names where !merged.contains(where: { $0.name == name }) {
            merged.append(CoreAIValueDescriptor(name: name))
        }
        return merged.map { value in
            var value = value
            guard let runtimeDescriptor = descriptor(value.name) else {
                return value
            }
            switch runtimeDescriptor {
            case .ndArray(let array):
                value.kind = "ndArray"
                value.scalarType = Self.scalarTypeName(array.scalarType)
                value.shape = array.shape
                value.hasDynamicShape = array.hasDynamicShape
            case .image(let image):
                value.kind = "image"
                value.shape = [image.height, image.width]
            @unknown default:
                break
            }
            return value
        }
    }

    static func metadata(_ metadata: AIModelAsset.Metadata) -> CoreAIModelMetadata {
        CoreAIModelMetadata(
            author: metadata.author,
            license: metadata.license,
            description: metadata.description,
            creationDate: metadata.creationDate,
            creatorDefined: metadata.creatorDefinedMetadata.mapValues(Self.anyCodable)
        )
    }

    static func anyCodable(_ value: AIModelAsset.Metadata.CreatorDefinedValue) -> AnyCodable {
        switch value {
        case .string(let string): return AnyCodable(.string(string))
        case .integer(let integer): return AnyCodable(.int(integer))
        case .number(let number): return AnyCodable(.double(number))
        case .bool(let bool): return AnyCodable(.bool(bool))
        case .array(let array): return AnyCodable(.array(array.map(Self.anyCodable)))
        case .dictionary(let dictionary): return AnyCodable(.object(dictionary.mapValues(Self.anyCodable)))
        @unknown default: return AnyCodable(.string(String(describing: value)))
        }
    }

    // MARK: Scalar types

    static func coreAIScalarType(_ type: NDArray.ScalarType) -> CoreAIScalarType? {
        switch type {
        case .bool: return .bool
        case .int8: return .int8
        case .int16: return .int16
        case .int32: return .int32
        case .int64: return .int64
        case .uint8: return .uint8
        case .uint16: return .uint16
        case .uint32: return .uint32
        case .uint64: return .uint64
        case .float16: return .float16
        case .bfloat16: return .bfloat16
        case .float32: return .float32
        case .float64: return .float64
        default: return nil
        }
    }

    static func ndScalarType(_ type: CoreAIScalarType) -> NDArray.ScalarType {
        switch type {
        case .bool: return .bool
        case .int8: return .int8
        case .int16: return .int16
        case .int32: return .int32
        case .int64: return .int64
        case .uint8: return .uint8
        case .uint16: return .uint16
        case .uint32: return .uint32
        case .uint64: return .uint64
        case .float16: return .float16
        case .bfloat16: return .bfloat16
        case .float32: return .float32
        case .float64: return .float64
        }
    }

    static func scalarTypeName(_ type: NDArray.ScalarType) -> String {
        Self.coreAIScalarType(type)?.rawValue ?? String(describing: type)
    }

    // MARK: Tensor conversion

    static func ndArray(from tensor: CoreAITensor) throws -> NDArray {
        guard tensor.data.count == tensor.elementCount * tensor.scalarType.byteWidth else {
            throw CoreAIRuntimeError.invalidTensor("tensor bytes do not match shape \(tensor.shape)")
        }
        var array = NDArray(shape: tensor.shape, scalarType: Self.ndScalarType(tensor.scalarType))
        let width = tensor.scalarType.byteWidth
        let shape = tensor.shape
        tensor.data.withUnsafeBytes { source in
            array.mutableRawView().withUnsafeMutableBytes { base, _, stridesSpan in
                guard let sourceBase = source.baseAddress else {
                    return
                }
                var strides: [Int] = []
                for index in 0..<stridesSpan.count {
                    strides.append(stridesSpan[index])
                }
                CoreAIStridedCopy.scatter(
                    from: sourceBase,
                    into: base,
                    shape: shape,
                    strides: strides,
                    elementWidth: width
                )
            }
        }
        return array
    }

    static func tensor(from array: NDArray) throws -> CoreAITensor {
        guard let type = Self.coreAIScalarType(array.scalarType) else {
            throw CoreAIRuntimeError.unsupportedScalarType(String(describing: array.scalarType))
        }
        let shape = array.shape
        let width = type.byteWidth
        let count = CoreAITensor.elementCount(of: shape)
        var data = Data(count: count * width)
        let raw = array.rawView()
        raw.withUnsafeBytes { base, _, stridesSpan in
            var strides: [Int] = []
            for index in 0..<stridesSpan.count {
                strides.append(stridesSpan[index])
            }
            data.withUnsafeMutableBytes { destination in
                guard let destinationBase = destination.baseAddress else {
                    return
                }
                CoreAIStridedCopy.gather(
                    from: base,
                    into: destinationBase,
                    shape: shape,
                    strides: strides,
                    elementWidth: width
                )
            }
        }
        return try CoreAITensor(shape: shape, scalarType: type, data: data)
    }

    static func makeStates(for function: InferenceFunction) throws -> [NDArray] {
        try function.descriptor.stateNames.map { name in
            guard case .ndArray(let descriptor)? = function.descriptor.stateDescriptor(of: name) else {
                throw CoreAIRuntimeError.unsupportedStates("state '\(name)' is not an NDArray")
            }
            var array = NDArray(descriptor: descriptor)
            let byteCount = descriptor.minimumByteCount
            array.mutableRawView().withUnsafeMutableBytes { base, _, _ in
                base.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
                return ()
            }
            return array
        }
    }

    // MARK: Execution

    /// Runs `function`, binding up to four states (mutable views must be bound from distinct locals).
    static func invoke(
        _ function: InferenceFunction,
        inputs: [String: NDArray],
        stateNames: [String],
        states: inout [NDArray]
    ) async throws -> [String: CoreAITensor] {
        let outputNames = function.descriptor.outputNames
        do {
            switch stateNames.count {
            case 0:
                var outputs = try await function.run(inputs: inputs)
                return try Self.collect(&outputs, names: outputNames)
            case 1:
                var state0 = states[0]
                var views = InferenceFunction.MutableViews()
                views.insert(&state0, for: stateNames[0])
                var outputs = try await function.run(inputs: inputs, states: views)
                states[0] = state0
                return try Self.collect(&outputs, names: outputNames)
            case 2:
                var state0 = states[0]
                var state1 = states[1]
                var views = InferenceFunction.MutableViews()
                views.insert(&state0, for: stateNames[0])
                views.insert(&state1, for: stateNames[1])
                var outputs = try await function.run(inputs: inputs, states: views)
                states[0] = state0
                states[1] = state1
                return try Self.collect(&outputs, names: outputNames)
            case 3:
                var state0 = states[0]
                var state1 = states[1]
                var state2 = states[2]
                var views = InferenceFunction.MutableViews()
                views.insert(&state0, for: stateNames[0])
                views.insert(&state1, for: stateNames[1])
                views.insert(&state2, for: stateNames[2])
                var outputs = try await function.run(inputs: inputs, states: views)
                states[0] = state0
                states[1] = state1
                states[2] = state2
                return try Self.collect(&outputs, names: outputNames)
            case 4:
                var state0 = states[0]
                var state1 = states[1]
                var state2 = states[2]
                var state3 = states[3]
                var views = InferenceFunction.MutableViews()
                views.insert(&state0, for: stateNames[0])
                views.insert(&state1, for: stateNames[1])
                views.insert(&state2, for: stateNames[2])
                views.insert(&state3, for: stateNames[3])
                var outputs = try await function.run(inputs: inputs, states: views)
                states[0] = state0
                states[1] = state1
                states[2] = state2
                states[3] = state3
                return try Self.collect(&outputs, names: outputNames)
            default:
                throw CoreAIRuntimeError.unsupportedStates("\(stateNames.count) states")
            }
        } catch let error as CoreAIRuntimeError {
            throw error
        } catch {
            throw CoreAIRuntimeError.executionFailed(error.localizedDescription)
        }
    }

    private static func collect(_ outputs: inout InferenceFunction.Outputs, names: [String]) throws -> [String: CoreAITensor] {
        var result: [String: CoreAITensor] = [:]
        for name in names {
            guard let value = outputs.remove(name), let array = value.ndArray else {
                continue
            }
            result[name] = try Self.tensor(from: array)
        }
        return result
    }
}
#endif

/// Strided element copies between dense buffers and NDArray storage (strides are in elements).
enum CoreAIStridedCopy {
    static func contiguousStrides(for shape: [Int]) -> [Int] {
        var strides = [Int](repeating: 1, count: shape.count)
        var running = 1
        for index in shape.indices.reversed() {
            strides[index] = running
            running *= Swift.max(1, shape[index])
        }
        return strides
    }

    /// Copies strided storage at `source` into dense row-major bytes at `destination`.
    static func gather(
        from source: UnsafeRawPointer,
        into destination: UnsafeMutableRawPointer,
        shape: [Int],
        strides: [Int],
        elementWidth: Int
    ) {
        Self.forEachElement(shape: shape, strides: strides) { linear, offset in
            destination.advanced(by: linear * elementWidth)
                .copyMemory(from: source.advanced(by: offset * elementWidth), byteCount: elementWidth)
        } contiguous: { count in
            destination.copyMemory(from: source, byteCount: count * elementWidth)
        }
    }

    /// Copies dense row-major bytes at `source` into strided storage at `destination`.
    static func scatter(
        from source: UnsafeRawPointer,
        into destination: UnsafeMutableRawPointer,
        shape: [Int],
        strides: [Int],
        elementWidth: Int
    ) {
        Self.forEachElement(shape: shape, strides: strides) { linear, offset in
            destination.advanced(by: offset * elementWidth)
                .copyMemory(from: source.advanced(by: linear * elementWidth), byteCount: elementWidth)
        } contiguous: { count in
            destination.copyMemory(from: source, byteCount: count * elementWidth)
        }
    }

    /// Visits every element as (dense linear index, strided element offset); calls `contiguous` once
    /// instead when the strides are row-major contiguous.
    static func forEachElement(
        shape: [Int],
        strides: [Int],
        _ body: (Int, Int) -> Void,
        contiguous: (Int) -> Void
    ) {
        let count = CoreAITensor.elementCount(of: shape)
        guard count > 0 else {
            return
        }
        let effectiveStrides = strides.count == shape.count ? strides : Self.contiguousStrides(for: shape)
        let isContiguous = zip(shape, zip(effectiveStrides, Self.contiguousStrides(for: shape)))
            .allSatisfy { dimension, pair in dimension <= 1 || pair.0 == pair.1 }
        if isContiguous {
            contiguous(count)
            return
        }
        var index = [Int](repeating: 0, count: shape.count)
        for linear in 0..<count {
            var offset = 0
            for dimension in 0..<shape.count {
                offset += index[dimension] * effectiveStrides[dimension]
            }
            body(linear, offset)
            var dimension = shape.count - 1
            while dimension >= 0 {
                index[dimension] += 1
                if index[dimension] < shape[dimension] {
                    break
                }
                index[dimension] = 0
                dimension -= 1
            }
        }
    }
}
