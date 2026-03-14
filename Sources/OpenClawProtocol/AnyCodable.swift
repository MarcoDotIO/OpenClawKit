import Foundation

/// Type-erased `Codable` wrapper restricted to Sendable JSON-compatible values.
public struct AnyCodable: Codable, Sendable, Equatable, Hashable {
    /// Wrapped type-erased value.
    public let value: AnySendableValue

    /// Creates a wrapper from an explicit internal representation.
    /// - Parameter value: Pre-normalized type-erased JSON value.
    public init(_ value: AnySendableValue) {
        self.value = value
    }

    /// Creates a wrapper from a Sendable value.
    /// - Parameter value: Value to wrap.
    public init(_ value: some Sendable) {
        self.value = AnySendableValue(value)
    }

    /// Creates a wrapper from an optional Sendable value, preserving `nil` as JSON null.
    /// - Parameter value: Optional value to wrap.
    public init<T>(_ value: T?) where T: Sendable {
        if let value {
            self.value = AnySendableValue(value)
        } else {
            self.value = .null
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = AnySendableValue.null
        } else if let v = try? container.decode(Bool.self) {
            self.value = AnySendableValue(v)
        } else if let v = try? container.decode(Int.self) {
            self.value = AnySendableValue(v)
        } else if let v = try? container.decode(Double.self) {
            self.value = AnySendableValue(v)
        } else if let v = try? container.decode(String.self) {
            self.value = AnySendableValue(v)
        } else if let v = try? container.decode([String: AnyCodable].self) {
            self.value = AnySendableValue(v)
        } else if let v = try? container.decode([AnyCodable].self) {
            self.value = AnySendableValue(v)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON type")
        }
    }

    /// Encodes wrapped value to a single-value container.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self.value {
        case .null:
            try container.encodeNil()
        case .bool(let v):
            try container.encode(v)
        case .int(let v):
            try container.encode(v)
        case .double(let v):
            try container.encode(v)
        case .string(let v):
            try container.encode(v)
        case .object(let v):
            try container.encode(v)
        case .array(let v):
            try container.encode(v)
        }
    }
}

/// Internal representation for type-erased JSON values.
public enum AnySendableValue: Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case object([String: AnyCodable])
    case array([AnyCodable])

    /// Creates a type-erased value from common Sendable primitives.
    /// - Parameter value: Input value.
    public init(_ value: some Sendable) {
        switch value {
        case let v as Bool:
            self = .bool(v)
        case let v as Int:
            self = .int(v)
        case let v as Double:
            self = .double(v)
        case let v as String:
            self = .string(v)
        case let v as [Bool]:
            self = .array(v.map(AnyCodable.init))
        case let v as [Int]:
            self = .array(v.map(AnyCodable.init))
        case let v as [Double]:
            self = .array(v.map(AnyCodable.init))
        case let v as [String]:
            self = .array(v.map(AnyCodable.init))
        case let v as [String: AnyCodable]:
            self = .object(v)
        case let v as [AnyCodable]:
            self = .array(v)
        case let v as [String: Bool]:
            self = .object(v.mapValues(AnyCodable.init))
        case let v as [String: Int]:
            self = .object(v.mapValues(AnyCodable.init))
        case let v as [String: Double]:
            self = .object(v.mapValues(AnyCodable.init))
        case let v as [String: String]:
            self = .object(v.mapValues(AnyCodable.init))
        default:
            self = .string(String(describing: value))
        }
    }
}
