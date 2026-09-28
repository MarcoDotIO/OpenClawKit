import Foundation
import OpenClawProtocol

// Cross-platform value types for the CoreAI `.aimodel` runtime adapter. CoreAI itself exists only on
// the Apple 27 SDKs (see CoreAIModelRuntime.swift); these DTOs, the executor protocol, and the decode
// and embedding adapters compile everywhere, so hosts can test with fakes and Linux builds stay clean.

// MARK: - Scalar types and compute units

/// Byte-aligned tensor scalar types that ``CoreAITensor`` can carry.
///
/// CoreAI also has sub-byte and 8-bit float types (int4, float8e4m3fn, ...); those appear in
/// descriptors by name but cannot be passed in or read out through ``CoreAITensor``.
public enum CoreAIScalarType: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// Boolean, one byte per element.
    case bool
    /// Signed 8-bit integer.
    case int8
    /// Signed 16-bit integer.
    case int16
    /// Signed 32-bit integer.
    case int32
    /// Signed 64-bit integer.
    case int64
    /// Unsigned 8-bit integer.
    case uint8
    /// Unsigned 16-bit integer.
    case uint16
    /// Unsigned 32-bit integer.
    case uint32
    /// Unsigned 64-bit integer.
    case uint64
    /// IEEE 754 half precision.
    case float16
    /// bfloat16 (8-bit exponent, 7-bit mantissa).
    case bfloat16
    /// IEEE 754 single precision.
    case float32
    /// IEEE 754 double precision.
    case float64

    /// Bytes per element.
    public var byteWidth: Int {
        switch self {
        case .bool, .int8, .uint8: return 1
        case .int16, .uint16, .float16, .bfloat16: return 2
        case .int32, .uint32, .float32: return 4
        case .int64, .uint64, .float64: return 8
        }
    }

    /// Whether the type is a floating-point type.
    public var isFloatingPoint: Bool {
        switch self {
        case .float16, .bfloat16, .float32, .float64: return true
        default: return false
        }
    }
}

/// Preferred compute unit used when CoreAI specializes a model for this device.
public enum CoreAIComputeUnit: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// Let CoreAI choose (`SpecializationOptions.default`).
    case automatic
    /// Restrict execution to the CPU (`SpecializationOptions.cpuOnly`).
    case cpuOnly
    /// Prefer the CPU.
    case cpu
    /// Prefer the GPU.
    case gpu
    /// Prefer the Neural Engine.
    case neuralEngine

    /// Parses a configuration value (`auto`, `cpu-only`, `ane`, `neural-engine`, ...).
    /// - Parameter value: Raw configuration value.
    public init?(normalizing value: String) {
        let compact = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        switch compact {
        case "automatic", "auto", "default", "all": self = .automatic
        case "cpuonly": self = .cpuOnly
        case "cpu": self = .cpu
        case "gpu": self = .gpu
        case "neuralengine", "ane", "npu": self = .neuralEngine
        default: return nil
        }
    }
}

// MARK: - Tensors

/// Dense, row-major, little-endian tensor exchanged with a CoreAI inference function.
public struct CoreAITensor: Codable, Sendable, Equatable {
    /// Dimensions, outermost first.
    public var shape: [Int]
    /// Element type.
    public var scalarType: CoreAIScalarType
    /// Packed element bytes (`elementCount * scalarType.byteWidth` bytes).
    public var data: Data

    /// Creates a tensor from packed bytes.
    /// - Parameters:
    ///   - shape: Dimensions; every dimension must be non-negative.
    ///   - scalarType: Element type.
    ///   - data: Packed row-major bytes.
    /// - Throws: ``CoreAIRuntimeError/invalidTensor(_:)`` when the byte count does not match the shape.
    public init(shape: [Int], scalarType: CoreAIScalarType, data: Data) throws {
        guard shape.allSatisfy({ $0 >= 0 }) else {
            throw CoreAIRuntimeError.invalidTensor("shape \(shape) has a negative dimension")
        }
        let count = Self.elementCount(of: shape)
        let (expected, overflow) = count.multipliedReportingOverflow(by: scalarType.byteWidth)
        guard !overflow, data.count == expected else {
            throw CoreAIRuntimeError.invalidTensor(
                "shape \(shape) of \(scalarType.rawValue) needs \(overflow ? "too many" : String(expected)) bytes, got \(data.count)"
            )
        }
        self.shape = shape
        self.scalarType = scalarType
        self.data = data
    }

    /// Creates an `int32` tensor.
    /// - Parameters:
    ///   - values: Elements in row-major order.
    ///   - shape: Dimensions; defaults to `[values.count]`.
    /// - Throws: ``CoreAIRuntimeError/invalidTensor(_:)`` when the element count does not match the shape.
    public init(int32 values: [Int32], shape: [Int]? = nil) throws {
        try self.init(shape: shape ?? [values.count], scalarType: .int32, data: Self.packed(values))
    }

    /// Creates a `float32` tensor.
    /// - Parameters:
    ///   - values: Elements in row-major order.
    ///   - shape: Dimensions; defaults to `[values.count]`.
    /// - Throws: ``CoreAIRuntimeError/invalidTensor(_:)`` when the element count does not match the shape.
    public init(float32 values: [Float], shape: [Int]? = nil) throws {
        try self.init(shape: shape ?? [values.count], scalarType: .float32, data: Self.packed(values))
    }

    /// Number of elements.
    public var elementCount: Int {
        Self.elementCount(of: self.shape)
    }

    /// Elements as `Int32` (for `int32` tensors), otherwise `nil`.
    public func int32Values() -> [Int32]? {
        guard self.scalarType == .int32 else {
            return nil
        }
        return self.load(Int32.self)
    }

    /// Elements converted to `Float` for floating-point and integer tensors (`bool` becomes 0/1).
    public func floatValues() -> [Float] {
        switch self.scalarType {
        case .float32:
            return self.load(Float.self)
        case .float64:
            return self.load(Double.self).map { Float($0) }
        case .float16:
            return self.load(UInt16.self).map(CoreAIHalfPrecision.float(fromHalfBits:))
        case .bfloat16:
            return self.load(UInt16.self).map(CoreAIHalfPrecision.float(fromBFloat16Bits:))
        case .bool, .uint8:
            return self.load(UInt8.self).map { Float($0) }
        case .int8:
            return self.load(Int8.self).map { Float($0) }
        case .int16:
            return self.load(Int16.self).map { Float($0) }
        case .uint16:
            return self.load(UInt16.self).map { Float($0) }
        case .int32:
            return self.load(Int32.self).map { Float($0) }
        case .uint32:
            return self.load(UInt32.self).map { Float($0) }
        case .int64:
            return self.load(Int64.self).map { Float($0) }
        case .uint64:
            return self.load(UInt64.self).map { Float($0) }
        }
    }

    /// The last row along the innermost dimension as `Float` (for logits shaped `[..., vocab]`).
    /// - Throws: ``CoreAIRuntimeError/invalidTensor(_:)`` for scalar or empty tensors.
    public func lastRowFloats() throws -> [Float] {
        guard let width = self.shape.last, width > 0, self.elementCount >= width else {
            throw CoreAIRuntimeError.invalidTensor("expected a tensor shaped [..., n] with n > 0, got \(self.shape)")
        }
        return Array(self.floatValues().suffix(width))
    }

    static func elementCount(of shape: [Int]) -> Int {
        shape.reduce(1) { partial, dimension in
            let (product, overflow) = partial.multipliedReportingOverflow(by: Swift.max(0, dimension))
            return overflow ? Int.max : product
        }
    }

    static func packed<T: BitwiseCopyable>(_ values: [T]) -> Data {
        values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func load<T: BitwiseCopyable>(_: T.Type) -> [T] {
        let stride = MemoryLayout<T>.size
        let count = self.data.count / stride
        return self.data.withUnsafeBytes { raw in
            (0..<count).map { raw.loadUnaligned(fromByteOffset: $0 * stride, as: T.self) }
        }
    }
}

/// Bit-level half-precision conversions (portable: `Float16` is unavailable on Intel macOS).
enum CoreAIHalfPrecision {
    static func float(fromHalfBits bits: UInt16) -> Float {
        let sign = UInt32(bits & 0x8000) << 16
        let exponent = UInt32(bits >> 10) & 0x1F
        let mantissa = UInt32(bits & 0x03FF)
        let result: UInt32
        if exponent == 0 {
            if mantissa == 0 {
                result = sign
            } else {
                // Subnormal half: normalize into a float.
                var shifted = mantissa
                var adjustedExponent: UInt32 = 127 - 15 + 1
                while shifted & 0x0400 == 0 {
                    shifted <<= 1
                    adjustedExponent -= 1
                }
                result = sign | (adjustedExponent << 23) | ((shifted & 0x03FF) << 13)
            }
        } else if exponent == 0x1F {
            result = sign | 0x7F80_0000 | (mantissa << 13)
        } else {
            result = sign | ((exponent + 127 - 15) << 23) | (mantissa << 13)
        }
        return Float(bitPattern: result)
    }

    static func float(fromBFloat16Bits bits: UInt16) -> Float {
        Float(bitPattern: UInt32(bits) << 16)
    }
}

// MARK: - Descriptors

/// Input, state, or output of a CoreAI function.
public struct CoreAIValueDescriptor: Codable, Sendable, Equatable {
    /// Value name.
    public var name: String
    /// Type name reported by the model asset (for example `tensor<fp16, [1, 128]>`).
    public var typeName: String
    /// Value kind (`ndArray` or `image`), when the model is loaded.
    public var kind: String?
    /// Scalar type name (for example `float16`, `int4`), when known.
    public var scalarType: String?
    /// Static shape; dynamic dimensions are reported as `-1` or by the runtime's convention.
    public var shape: [Int]?
    /// Whether the shape has dynamic dimensions.
    public var hasDynamicShape: Bool?

    /// Creates a value descriptor.
    /// - Parameters:
    ///   - name: Value name.
    ///   - typeName: Asset type name.
    ///   - kind: Value kind.
    ///   - scalarType: Scalar type name.
    ///   - shape: Static shape.
    ///   - hasDynamicShape: Whether the shape is dynamic.
    public init(
        name: String,
        typeName: String = "",
        kind: String? = nil,
        scalarType: String? = nil,
        shape: [Int]? = nil,
        hasDynamicShape: Bool? = nil
    ) {
        self.name = name
        self.typeName = typeName
        self.kind = kind
        self.scalarType = scalarType
        self.shape = shape
        self.hasDynamicShape = hasDynamicShape
    }
}

/// One inference function of a CoreAI model.
public struct CoreAIFunctionDescriptor: Codable, Sendable, Equatable {
    /// Function name (for example `main`).
    public var name: String
    /// Inputs.
    public var inputs: [CoreAIValueDescriptor]
    /// Mutable states (for example KV caches).
    public var states: [CoreAIValueDescriptor]
    /// Outputs.
    public var outputs: [CoreAIValueDescriptor]

    /// Creates a function descriptor.
    /// - Parameters:
    ///   - name: Function name.
    ///   - inputs: Inputs.
    ///   - states: States.
    ///   - outputs: Outputs.
    public init(
        name: String,
        inputs: [CoreAIValueDescriptor] = [],
        states: [CoreAIValueDescriptor] = [],
        outputs: [CoreAIValueDescriptor] = []
    ) {
        self.name = name
        self.inputs = inputs
        self.states = states
        self.outputs = outputs
    }
}

/// Author-supplied metadata of a `.aimodel` asset.
public struct CoreAIModelMetadata: Codable, Sendable, Equatable {
    /// Model author.
    public var author: String
    /// Model license.
    public var license: String
    /// Model description.
    public var description: String
    /// Creation date, when recorded.
    public var creationDate: Date?
    /// Creator-defined metadata values.
    public var creatorDefined: [String: AnyCodable]

    /// Creates model metadata.
    /// - Parameters:
    ///   - author: Author.
    ///   - license: License.
    ///   - description: Description.
    ///   - creationDate: Creation date.
    ///   - creatorDefined: Creator-defined values.
    public init(
        author: String = "",
        license: String = "",
        description: String = "",
        creationDate: Date? = nil,
        creatorDefined: [String: AnyCodable] = [:]
    ) {
        self.author = author
        self.license = license
        self.description = description
        self.creationDate = creationDate
        self.creatorDefined = creatorDefined
    }
}

/// Sendable description of a CoreAI model: functions, metadata, and storage/compute statistics.
public struct CoreAIModelDescriptor: Codable, Sendable, Equatable {
    /// Path of the `.aimodel` bundle.
    public var path: String
    /// Inference functions.
    public var functions: [CoreAIFunctionDescriptor]
    /// Asset metadata.
    public var metadata: CoreAIModelMetadata
    /// Weight storage type counts (type name to count).
    public var storageTypes: [String: Int]
    /// Compute type names used by the model.
    public var computeTypes: [String]
    /// Compute unit the model was specialized for, when loaded.
    public var computeUnit: CoreAIComputeUnit?
    /// Device architecture name reported by CoreAI (for example `h15m`), when available.
    public var deviceArchitecture: String?

    /// Creates a model descriptor.
    /// - Parameters:
    ///   - path: Model bundle path.
    ///   - functions: Inference functions.
    ///   - metadata: Asset metadata.
    ///   - storageTypes: Storage type counts.
    ///   - computeTypes: Compute type names.
    ///   - computeUnit: Specialization compute unit.
    ///   - deviceArchitecture: Device architecture name.
    public init(
        path: String,
        functions: [CoreAIFunctionDescriptor] = [],
        metadata: CoreAIModelMetadata = CoreAIModelMetadata(),
        storageTypes: [String: Int] = [:],
        computeTypes: [String] = [],
        computeUnit: CoreAIComputeUnit? = nil,
        deviceArchitecture: String? = nil
    ) {
        self.path = path
        self.functions = functions
        self.metadata = metadata
        self.storageTypes = storageTypes
        self.computeTypes = computeTypes
        self.computeUnit = computeUnit
        self.deviceArchitecture = deviceArchitecture
    }

    /// Function with the given name.
    /// - Parameter name: Function name.
    /// - Returns: The function descriptor, if present.
    public func function(named name: String) -> CoreAIFunctionDescriptor? {
        self.functions.first { $0.name == name }
    }
}

// MARK: - Errors and executor contract

/// Errors reported by the CoreAI adapters.
public enum CoreAIRuntimeError: Error, LocalizedError, Sendable, Equatable {
    /// CoreAI is not available (Linux, or an OS older than 27).
    case unavailable(String)
    /// The model bundle is missing or invalid.
    case invalidModel(String)
    /// No model is loaded.
    case notLoaded
    /// The requested function does not exist.
    case functionNotFound(String)
    /// The function did not produce the expected output.
    case missingOutput(String)
    /// A value uses a scalar type ``CoreAITensor`` cannot represent.
    case unsupportedScalarType(String)
    /// A tensor's shape or bytes are inconsistent.
    case invalidTensor(String)
    /// The function uses more mutable states than the adapter supports.
    case unsupportedStates(String)
    /// Tokenization produced no tokens.
    case emptyPrompt
    /// Generation was cancelled.
    case cancelled
    /// The runtime failed while executing.
    case executionFailed(String)

    /// Human-readable description.
    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail): return "CoreAI is unavailable: \(detail)"
        case .invalidModel(let detail): return "Invalid CoreAI model: \(detail)"
        case .notLoaded: return "No CoreAI model is loaded"
        case .functionNotFound(let name): return "CoreAI function '\(name)' was not found"
        case .missingOutput(let name): return "CoreAI function produced no output named '\(name)'"
        case .unsupportedScalarType(let detail): return "Unsupported CoreAI scalar type: \(detail)"
        case .invalidTensor(let detail): return "Invalid CoreAI tensor: \(detail)"
        case .unsupportedStates(let detail): return "Unsupported CoreAI function states: \(detail)"
        case .emptyPrompt: return "The tokenizer produced no tokens for the prompt"
        case .cancelled: return "CoreAI generation was cancelled"
        case .executionFailed(let detail): return "CoreAI execution failed: \(detail)"
        }
    }
}

/// Executes the functions of one loaded tensor model; ``CoreAIModelRuntime`` is the CoreAI
/// implementation, and tests or other runtimes can supply their own.
public protocol CoreAITensorExecuting: Sendable {
    /// Describes the loaded model.
    /// - Returns: Model descriptor.
    func describe() async throws -> CoreAIModelDescriptor

    /// Runs one function.
    ///
    /// Stateful functions keep their mutable state between calls until ``resetStates(function:)``.
    /// - Parameters:
    ///   - function: Function name.
    ///   - inputs: Input tensors by name.
    /// - Returns: Output tensors by name.
    func run(function: String, inputs: [String: CoreAITensor]) async throws -> [String: CoreAITensor]

    /// Clears the mutable state of one function, or of every function when `function` is `nil`.
    /// - Parameter function: Function name, or `nil` for all.
    func resetStates(function: String?) async
}

public extension CoreAITensorExecuting {
    /// Default no-op for stateless executors.
    func resetStates(function _: String?) async {}
}

/// Caller-supplied tokenizer for CoreAI language models; CoreAI has no tokenizer or LLM API, so token
/// conventions come from the model's own tokenizer files.
public protocol CoreAITokenizer: Sendable {
    /// Encodes text into token identifiers.
    /// - Parameter text: Input text.
    /// - Returns: Token identifiers.
    func encode(_ text: String) -> [Int32]
    /// Decodes token identifiers into text.
    /// - Parameter tokens: Token identifiers.
    /// - Returns: Decoded text.
    func decode(_ tokens: [Int32]) -> String
    /// Tokens that end generation.
    var eosTokenIDs: Set<Int32> { get }
}
