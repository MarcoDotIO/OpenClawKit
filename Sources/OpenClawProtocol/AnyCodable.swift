import Foundation

/// Type-erased `Codable` wrapper restricted to Sendable JSON-compatible values.
///
/// Unlike upstream OpenClaw's `Any`-backed wrapper, this type stores a Sendable
/// ``AnySendableValue`` enum. Read wrapped values through the typed accessors in
/// `AnyCodable+Accessors.swift` (`stringValue`, `boolValue`, `intValue`, ...) instead of
/// casting `value` (a `value as? String` cast always fails).
public struct AnyCodable: Codable, Sendable, Equatable, Hashable {
    /// Wrapped type-erased value.
    public let value: AnySendableValue

    /// Creates a wrapper from an explicit internal representation.
    /// - Parameter value: Pre-normalized type-erased JSON value.
    public init(_ value: AnySendableValue) {
        self.value = value
    }

    /// Creates a wrapper from a Sendable value.
    ///
    /// JSON primitives, Foundation containers (`NSNull`, `NSNumber`, `NSArray`, `NSDictionary`),
    /// Swift collections, and `Encodable` values are mapped structurally; see ``AnySendableValue/init(_:)``.
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

    /// Creates a wrapper by JSON-encoding an `Encodable` value.
    ///
    /// Use this initializer for typed payload structs when encoding failures must surface
    /// instead of falling back to a lossy representation.
    /// - Parameter value: Encodable value to convert into a JSON tree.
    /// - Throws: Any error thrown by `JSONEncoder` or when the output is not valid JSON.
    public init(encoding value: some Encodable) throws {
        let data = try JSONEncoder().encode(value)
        self = try JSONDecoder().decode(AnyCodable.self, from: data)
    }

    /// Decodes one JSON value, preserving integer fidelity.
    ///
    /// Decoding order is null, Bool, Int64, UInt64, Double, String, object, array. Integers that do
    /// not fit the platform `Int` (for example millisecond timestamps on 32-bit watchOS) are stored
    /// as `.double` so they are never rejected.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = .null
        } else if let v = try? container.decode(Bool.self) {
            self.value = .bool(v)
        } else if let v = try? container.decode(Int64.self) {
            if let int = Int(exactly: v) {
                self.value = .int(int)
            } else {
                self.value = .double(Double(v))
            }
        } else if let v = try? container.decode(UInt64.self) {
            if let int = Int(exactly: v) {
                self.value = .int(int)
            } else {
                self.value = .double(Double(v))
            }
        } else if let v = try? container.decode(Double.self) {
            self.value = .double(v)
        } else if let v = try? container.decode(String.self) {
            self.value = .string(v)
        } else if let v = try? container.decode([String: AnyCodable].self) {
            self.value = .object(v)
        } else if let v = try? container.decode([AnyCodable].self) {
            self.value = .array(v)
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
    /// JSON `null`.
    case null
    /// JSON boolean.
    case bool(Bool)
    /// JSON integer that fits the platform `Int`.
    case int(Int)
    /// JSON number that is fractional or does not fit the platform `Int`.
    case double(Double)
    /// JSON string.
    case string(String)
    /// JSON object.
    case object([String: AnyCodable])
    /// JSON array.
    case array([AnyCodable])

    /// Creates a type-erased value from a Sendable value.
    ///
    /// Mapping rules:
    /// - `AnyCodable`/`AnySendableValue` pass through unchanged, `nil` optionals and `NSNull` become `.null`.
    /// - `NSNumber` values are classified before Swift casts so JSON `0`/`1` never become booleans:
    ///   `CFBoolean` becomes `.bool`, integral numbers `.int` (or `.double` when they exceed `Int`),
    ///   everything else `.double`.
    /// - Every `BinaryInteger` and `BinaryFloatingPoint` type maps to `.int`/`.double`.
    /// - Arrays and dictionaries (Swift and Foundation) are converted recursively.
    /// - Other `Encodable` values are JSON-encoded and decoded back into a JSON tree.
    /// - Anything else falls back to `String(describing:)` and trips an assertion in debug builds.
    /// - Parameter value: Input value.
    public init(_ value: some Sendable) {
        self = AnySendableValue.normalize(value)
    }

    /// Converts an arbitrary (possibly Foundation-bridged) value into a JSON value.
    /// - Parameters:
    ///   - raw: Value to convert.
    ///   - strict: When `true`, unsupported values trip an assertion in debug builds.
    /// - Returns: The converted value; unsupported values fall back to `String(describing:)`.
    static func normalize(_ raw: Any, strict: Bool = true) -> AnySendableValue {
        if let converted = self.convert(raw, strict: strict) {
            return converted
        }
        if strict {
            assertionFailure("AnyCodable: unsupported value \(type(of: raw))")
        }
        return .string(String(describing: raw))
    }

    /// Structural conversion shared by ``init(_:)`` and `AnyCodable.fromFoundation(_:)`.
    /// - Parameters:
    ///   - raw: Value to convert.
    ///   - strict: Forwarded to nested ``normalize(_:strict:)`` calls.
    /// - Returns: The converted value, or `nil` when the value has no JSON representation.
    static func convert(_ raw: Any, strict: Bool) -> AnySendableValue? {
        // NSNumber must be classified first: on Darwin `NSNumber(1) as? Bool` succeeds.
        if type(of: raw) is NSNumber.Type, let number = raw as? NSNumber {
            return self.classify(number)
        }
        switch raw {
        case let value as AnySendableValue:
            return value
        case let value as AnyCodable:
            return value.value
        case let value as OptionalBox:
            guard let wrapped = value.wrappedAny else { return .null }
            return self.convert(wrapped, strict: strict)
        case is NSNull:
            return .null
        case let value as Bool:
            return .bool(value)
        case let value as String:
            return .string(value)
        case let value as Substring:
            return .string(String(value))
        case let value as Int:
            return .int(value)
        case let value as Double:
            return .double(value)
        case let value as any BinaryInteger:
            if let int = Int(exactly: value) {
                return .int(int)
            }
            return .double(Double(value))
        case let value as any BinaryFloatingPoint:
            return .double(Double(value))
        case let value as [String: AnyCodable]:
            return .object(value)
        case let value as [AnyCodable]:
            return .array(value)
        case let value as [String: Any]:
            return .object(value.mapValues { AnyCodable(self.normalize($0, strict: strict)) })
        case let value as [Any]:
            return .array(value.map { AnyCodable(self.normalize($0, strict: strict)) })
        case let value as NSDictionary:
            var converted: [String: AnyCodable] = [:]
            for case let (key as String, element) in value {
                converted[key] = AnyCodable(self.normalize(element, strict: strict))
            }
            return .object(converted)
        case let value as NSArray:
            return .array(value.map { AnyCodable(self.normalize($0, strict: strict)) })
        case let value as any Encodable:
            return try? AnyCodable(encoding: value).value
        default:
            return nil
        }
    }

    private static func classify(_ number: NSNumber) -> AnySendableValue {
        #if canImport(Darwin)
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return .bool(number.boolValue)
        }
        #else
        // swift-corelibs-foundation boxes booleans with the `c`/`B` Objective-C type encoding.
        let boolEncoding = String(cString: number.objCType)
        if boolEncoding == "c" || boolEncoding == "B" {
            return .bool(number.boolValue)
        }
        #endif
        let encoding = String(cString: number.objCType)
        if !(number is NSDecimalNumber), encoding == "f" || encoding == "d" {
            // NSNumber's integer casts can saturate binary floats, so convert exactly from Double.
            let double = number.doubleValue
            if let int = Int(exactly: double) {
                return .int(int)
            }
            return .double(double)
        }
        if let int = Int(exactly: number) {
            return .int(int)
        }
        if let int64 = Int64(exactly: number) {
            return .double(Double(int64))
        }
        if let uint64 = UInt64(exactly: number) {
            return .double(Double(uint64))
        }
        return .double(number.doubleValue)
    }
}

/// Lets `convert` unwrap `Optional` values that arrive type-erased inside `Any`.
private protocol OptionalBox {
    var wrappedAny: Any? { get }
}

extension Optional: OptionalBox {
    fileprivate var wrappedAny: Any? {
        switch self {
        case .some(let wrapped):
            return wrapped
        case .none:
            return nil
        }
    }
}
