import Foundation
import OpenClawProtocol

// Forward-compatible coding primitives shared by every upstream-shaped config document type.
//
// Rules (mirroring upstream's strict-but-evolving zod schemas):
// - Decoding never throws for unknown keys, unknown enum strings, or a mistyped optional leaf. Only
//   malformed JSON/JSON5 throws. Problems are reported to a `ConfigDecodeIssueCollector`.
// - Encoding reproduces the input tree for everything the SDK did not change: unknown keys, and known
//   keys whose value failed to decode, round-trip through `additionalProperties`.
// - Nothing is synthesized: absent keys stay absent.

/// Dynamic string coding key used by lossless config document types.
public struct ConfigCodingKey: CodingKey, Hashable, Sendable {
    /// Key string.
    public var stringValue: String
    /// Integer value for array-index keys.
    public var intValue: Int?

    /// Creates a key from a string.
    /// - Parameter stringValue: Key string.
    public init(_ stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    /// Creates a key from a string.
    /// - Parameter stringValue: Key string.
    public init?(stringValue: String) {
        self.init(stringValue)
    }

    /// Creates an array-index key.
    /// - Parameter intValue: Index value.
    public init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

// MARK: - Open enums

/// A string vocabulary that keeps unknown values instead of failing to decode.
///
/// Conforming types are small structs with static constants (for example
/// `OpenClawConfigDocument.Session.DMScope.perPeer`). Unknown strings decode into a value whose
/// ``isKnown`` is `false`, are recorded as a ``ConfigDecodeIssue/Kind/unknownEnumValue`` issue, and
/// encode back unchanged, so adding upstream values later is not source-breaking.
public protocol ConfigOpenEnum: RawRepresentable, Codable, Sendable, Hashable, CustomStringConvertible,
    ExpressibleByStringLiteral where RawValue == String
{
    /// Creates a value from its raw string without validation.
    /// - Parameter rawValue: Raw config string.
    init(rawValue: String)

    /// Every value the pinned upstream schema accepts.
    static var known: [Self] { get }

    /// Whether decoding lowercases the trimmed string (only where upstream lowercases).
    static var normalizesToLowercase: Bool { get }
}

extension ConfigOpenEnum {
    /// Defaults to `false`: upstream compares most vocabularies case-sensitively.
    public static var normalizesToLowercase: Bool { false }

    /// Whether the value belongs to ``known``.
    public var isKnown: Bool { Self.known.contains(self) }

    /// The raw config string.
    public var description: String { self.rawValue }

    /// Creates a value from a string literal.
    /// - Parameter value: Raw config string.
    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    /// Decodes a trimmed (and optionally lowercased) string, recording unknown values as issues.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        var normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.normalizesToLowercase {
            normalized = normalized.lowercased()
        }
        self.init(rawValue: normalized)
        if !self.isKnown {
            ConfigDecodeIssueReporting.record(
                "Unknown value \"\(normalized)\"; expected one of \(Self.known.map(\.rawValue).joined(separator: ", ")).",
                kind: .unknownEnumValue,
                decoder: decoder
            )
        }
    }

    /// Encodes the raw string.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }
}

// MARK: - Lossless objects

/// A lossless, upstream-shaped config object: typed optional fields plus passthrough of every other key.
///
/// Conforming types list their typed fields once in ``configFields``; the default `Codable`
/// implementation decodes each field leniently, keeps unknown keys (and known keys whose value failed
/// to decode) in ``additionalProperties``, and writes only keys that are present.
public protocol ConfigDocumentObject: Codable, Sendable, Equatable {
    /// Creates an empty object (every field `nil`).
    init()

    /// Keys this type does not type, plus known keys whose values failed to decode.
    var additionalProperties: [String: AnyCodable] { get set }

    /// The typed fields of this object, in upstream key order.
    static var configFields: [ConfigField<Self>] { get }
}

extension ConfigDocumentObject {
    /// Decodes typed fields leniently and keeps every other key.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        self.init()
        var reader = try ConfigObjectReader(decoder: decoder)
        for field in Self.configFields {
            field.decodeInto(&self, &reader)
        }
        self.additionalProperties = reader.remainingProperties()
    }

    /// Encodes present typed fields followed by the passthrough keys.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var writer = ConfigObjectWriter(encoder: encoder)
        for field in Self.configFields {
            try field.encodeFrom(self, &writer)
        }
        try writer.finish(additional: self.additionalProperties)
    }

    /// Creates an object from a JSON object tree.
    /// - Parameters:
    ///   - jsonObject: JSON object.
    ///   - issues: Optional issue sink.
    /// - Throws: Only when the tree cannot be serialized.
    public init(jsonObject: [String: AnyCodable], issues: ConfigDecodeIssueCollector? = nil) throws {
        self = try ConfigTreeCoding.decode(Self.self, from: AnyCodable(.object(jsonObject)), issues: issues)
    }

    /// The object as a JSON object tree.
    public var jsonObject: [String: AnyCodable] {
        ConfigTreeCoding.encodeObject(self)
    }

    /// Whether no typed field and no passthrough key is set.
    public var isEmpty: Bool {
        self.jsonObject.isEmpty
    }
}

/// One typed field of a ``ConfigDocumentObject``.
public struct ConfigField<Root> {
    /// JSON key of the field.
    public let key: String
    let decodeInto: (inout Root, inout ConfigObjectReader) -> Void
    let encodeFrom: (Root, inout ConfigObjectWriter) throws -> Void

    /// Declares an optional field stored at `keyPath` under the JSON key `key`.
    /// - Parameters:
    ///   - key: JSON key.
    ///   - keyPath: Writable key path of the optional stored property.
    public init<Value: Codable>(_ key: String, _ keyPath: WritableKeyPath<Root, Value?>) {
        self.key = key
        self.decodeInto = { root, reader in
            root[keyPath: keyPath] = reader.decode(Value.self, forKey: key)
        }
        self.encodeFrom = { root, writer in
            try writer.encode(root[keyPath: keyPath], forKey: key)
        }
    }
}

/// Lenient keyed reader used by ``ConfigDocumentObject`` decoding.
struct ConfigObjectReader {
    let container: KeyedDecodingContainer<ConfigCodingKey>
    let collector: ConfigDecodeIssueCollector?
    let codingPath: [CodingKey]
    private var consumed: Set<String> = []
    private var preserved: [String: AnyCodable] = [:]

    init(decoder: Decoder) throws {
        self.container = try decoder.container(keyedBy: ConfigCodingKey.self)
        self.collector = decoder.userInfo[.openClawConfigIssues] as? ConfigDecodeIssueCollector
        self.codingPath = decoder.codingPath
    }

    /// Decodes one optional leaf; failures and explicit nulls are preserved for re-encoding.
    mutating func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        self.consumed.insert(key)
        let codingKey = ConfigCodingKey(key)
        guard self.container.contains(codingKey) else {
            return nil
        }
        do {
            if let value = try self.container.decodeIfPresent(T.self, forKey: codingKey) {
                return value
            }
            self.preserved[key] = AnyCodable(.null)
            return nil
        } catch {
            self.collector?.record(
                ConfigDecodeIssueReporting.issue(for: error, decoding: T.self, fallbackPath: self.codingPath + [codingKey])
            )
            self.preserved[key] = try? self.container.decode(AnyCodable.self, forKey: codingKey)
            return nil
        }
    }

    /// Every key not consumed by a typed field, plus preserved raw values of failed fields.
    func remainingProperties() -> [String: AnyCodable] {
        var result = self.preserved
        for key in self.container.allKeys where !self.consumed.contains(key.stringValue) {
            if let value = try? self.container.decode(AnyCodable.self, forKey: key) {
                result[key.stringValue] = value
            }
        }
        return result
    }
}

/// Keyed writer used by ``ConfigDocumentObject`` encoding.
struct ConfigObjectWriter {
    private var container: KeyedEncodingContainer<ConfigCodingKey>
    private var written: Set<String> = []

    init(encoder: Encoder) {
        self.container = encoder.container(keyedBy: ConfigCodingKey.self)
    }

    mutating func encode<T: Encodable>(_ value: T?, forKey key: String) throws {
        guard let value else {
            return
        }
        try self.container.encode(value, forKey: ConfigCodingKey(key))
        self.written.insert(key)
    }

    mutating func finish(additional: [String: AnyCodable]) throws {
        for key in additional.keys.sorted() where !self.written.contains(key) {
            if let value = additional[key] {
                try self.container.encode(value, forKey: ConfigCodingKey(key))
            }
        }
    }
}

/// Passthrough helpers for config types that implement `Codable` by hand.
public enum ConfigObjectCoding {
    /// Returns every key of the decoder's object that is not in `knownKeys`.
    /// - Parameters:
    ///   - decoder: Source decoder positioned at a JSON object.
    ///   - knownKeys: Keys the caller decodes itself.
    /// - Returns: The remaining keys and their raw values.
    public static func decodeAdditional(from decoder: Decoder, knownKeys: Set<String>) throws -> [String: AnyCodable] {
        let container = try decoder.container(keyedBy: ConfigCodingKey.self)
        var result: [String: AnyCodable] = [:]
        for key in container.allKeys where !knownKeys.contains(key.stringValue) {
            if let value = try? container.decode(AnyCodable.self, forKey: key) {
                result[key.stringValue] = value
            }
        }
        return result
    }

    /// Writes passthrough keys after the caller's known keys.
    /// - Parameters:
    ///   - values: Passthrough keys and values.
    ///   - container: Target keyed container.
    ///   - excluding: Keys already written by the caller.
    public static func encodeAdditional(
        _ values: [String: AnyCodable],
        to container: inout KeyedEncodingContainer<ConfigCodingKey>,
        excluding: Set<String> = []
    ) throws {
        for key in values.keys.sorted() where !excluding.contains(key) {
            if let value = values[key] {
                try container.encode(value, forKey: ConfigCodingKey(key))
            }
        }
    }
}

extension CodingUserInfoKey {
    /// When set to `true` in an encoder's `userInfo`, SDK-native config types omit SDK-only and
    /// upstream-retired keys so the output validates against the strict upstream schema.
    public static let openClawUpstreamProjection = CodingUserInfoKey(rawValue: "openclaw.config.upstreamProjection")!
}

/// Converts between JSON trees and typed config values.
enum ConfigTreeCoding {
    static func makeEncoder(projection: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        if projection {
            encoder.userInfo[.openClawUpstreamProjection] = true
        }
        return encoder
    }

    static func decode<T: Decodable>(_ type: T.Type, from tree: AnyCodable, issues: ConfigDecodeIssueCollector?) throws -> T {
        let data = try self.makeEncoder().encode(tree)
        let decoder = JSONDecoder()
        if let issues {
            decoder.userInfo[.openClawConfigIssues] = issues
        }
        return try decoder.decode(T.self, from: data)
    }

    static func encode(_ value: some Encodable, projection: Bool = false) -> AnyCodable {
        guard let data = try? self.makeEncoder(projection: projection).encode(value),
              let tree = try? JSONDecoder().decode(AnyCodable.self, from: data)
        else {
            return AnyCodable(.null)
        }
        return tree
    }

    static func encodeObject(_ value: some Encodable) -> [String: AnyCodable] {
        self.encode(value).dictionaryValue ?? [:]
    }
}

/// Heap-backed optional storage for large config sections.
///
/// Document types nest many optional sections; storing them inline makes the root value several
/// kilobytes, which is expensive to copy and can exhaust small (for example cooperative-thread)
/// stacks. This wrapper keeps value semantics (every write stores a new immutable box).
@propertyWrapper
public struct ConfigIndirect<Wrapped: Sendable & Equatable>: Sendable, Equatable {
    private final class Storage: Sendable {
        let value: Wrapped

        init(_ value: Wrapped) {
            self.value = value
        }
    }

    private var storage: Storage?

    /// Creates empty (`nil`) storage.
    public init() {
        self.storage = nil
    }

    /// Creates storage holding `wrappedValue`.
    /// - Parameter wrappedValue: Initial value.
    public init(wrappedValue: Wrapped?) {
        self.storage = wrappedValue.map(Storage.init)
    }

    /// The stored value.
    public var wrappedValue: Wrapped? {
        get { self.storage?.value }
        set { self.storage = newValue.map(Storage.init) }
    }

    /// Compares the stored values.
    public static func == (lhs: ConfigIndirect, rhs: ConfigIndirect) -> Bool {
        lhs.wrappedValue == rhs.wrappedValue
    }
}

/// Stored hint that never affects equality (for example the authored order of map keys).
public struct ConfigOrderHint: Sendable, Equatable, Hashable {
    /// Keys in authored order.
    public var keys: [String]

    /// Creates an order hint.
    /// - Parameter keys: Keys in authored order.
    public init(_ keys: [String] = []) {
        self.keys = keys
    }

    /// Order hints are presentation metadata; they never make two values unequal.
    public static func == (lhs: ConfigOrderHint, rhs: ConfigOrderHint) -> Bool {
        true
    }

    /// Hashes nothing, consistent with ``==(_:_:)``.
    public func hash(into hasher: inout Hasher) {}

    /// Orders `present` keys by the hint first, then the rest alphabetically.
    func ordered(_ present: some Collection<String>) -> [String] {
        let presentSet = Set(present)
        var seen: Set<String> = []
        var result: [String] = []
        for key in self.keys where presentSet.contains(key) && seen.insert(key).inserted {
            result.append(key)
        }
        result.append(contentsOf: presentSet.subtracting(seen).sorted())
        return result
    }
}

// MARK: - Union values

/// `Bool | "auto"` (for example `fastModeDefault`, `commands.native`, `tools.codeMode.enabled`).
public enum ConfigBoolOrAuto: Codable, Sendable, Hashable {
    /// Explicit boolean.
    case bool(Bool)
    /// The literal `"auto"`.
    case auto

    /// The boolean value, or `nil` for ``auto``.
    public var boolValue: Bool? {
        if case .bool(let value) = self {
            return value
        }
        return nil
    }

    /// Whether the value is ``auto``.
    public var isAuto: Bool {
        self == .auto
    }

    /// Decodes a boolean or the string `"auto"`.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(String.self),
           value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "auto"
        {
            self = .auto
            return
        }
        throw DecodingError.typeMismatch(
            ConfigBoolOrAuto.self,
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected a boolean or \"auto\".")
        )
    }

    /// Encodes the boolean or `"auto"`.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value):
            try container.encode(value)
        case .auto:
            try container.encode("auto")
        }
    }
}

/// `string | {primary?, fallbacks?}` model selection (for example `agents.defaults.model`).
public enum ConfigModelSelection: Codable, Sendable, Equatable {
    /// A single `provider/model` reference.
    case ref(String)
    /// A primary model with ordered fallbacks.
    case selection(Selection)

    /// Object form of a model selection.
    public struct Selection: ConfigDocumentObject {
        /// Primary `provider/model` reference.
        public var primary: String?
        /// Ordered fallback references.
        public var fallbacks: [String]?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]

        /// Creates an empty selection.
        public init() {}

        /// Typed fields in upstream order.
        public static var configFields: [ConfigField<Self>] {
            [.init("primary", \.primary), .init("fallbacks", \.fallbacks)]
        }
    }

    /// Creates a model selection.
    /// - Parameters:
    ///   - primary: Primary reference.
    ///   - fallbacks: Fallback references; when empty the string form is used.
    public init(primary: String, fallbacks: [String] = []) {
        if fallbacks.isEmpty {
            self = .ref(primary)
        } else {
            var selection = Selection()
            selection.primary = primary
            selection.fallbacks = fallbacks
            self = .selection(selection)
        }
    }

    /// The primary model reference, when set.
    public var primary: String? {
        switch self {
        case .ref(let value):
            return ConfigValueSupport.nonEmpty(value)
        case .selection(let selection):
            return ConfigValueSupport.nonEmpty(selection.primary)
        }
    }

    /// Ordered fallback references (empty for the string form).
    public var fallbacks: [String] {
        switch self {
        case .ref:
            return []
        case .selection(let selection):
            return selection.fallbacks ?? []
        }
    }

    /// Decodes a string or a selection object.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .ref(value)
        } else {
            self = .selection(try container.decode(Selection.self))
        }
    }

    /// Encodes the string or object form.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .ref(let value):
            try container.encode(value)
        case .selection(let selection):
            try container.encode(selection)
        }
    }
}

/// `string | {primary?, fallbacks?, timeoutMs?}` tool model selection (for example `imageModel`).
public enum ConfigToolModelSelection: Codable, Sendable, Equatable {
    /// A single `provider/model` reference.
    case ref(String)
    /// A primary model with fallbacks and an optional timeout.
    case selection(Selection)

    /// Object form of a tool model selection.
    public struct Selection: ConfigDocumentObject {
        /// Primary `provider/model` reference.
        public var primary: String?
        /// Ordered fallback references.
        public var fallbacks: [String]?
        /// Per-call timeout in milliseconds.
        public var timeoutMs: Int?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]

        /// Creates an empty selection.
        public init() {}

        /// Typed fields in upstream order.
        public static var configFields: [ConfigField<Self>] {
            [.init("primary", \.primary), .init("fallbacks", \.fallbacks), .init("timeoutMs", \.timeoutMs)]
        }
    }

    /// The primary model reference, when set.
    public var primary: String? {
        switch self {
        case .ref(let value):
            return ConfigValueSupport.nonEmpty(value)
        case .selection(let selection):
            return ConfigValueSupport.nonEmpty(selection.primary)
        }
    }

    /// Ordered fallback references (empty for the string form).
    public var fallbacks: [String] {
        if case .selection(let selection) = self {
            return selection.fallbacks ?? []
        }
        return []
    }

    /// Per-call timeout in milliseconds, when set.
    public var timeoutMs: Int? {
        if case .selection(let selection) = self {
            return selection.timeoutMs
        }
        return nil
    }

    /// Decodes a string or a selection object.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .ref(value)
        } else {
            self = .selection(try container.decode(Selection.self))
        }
    }

    /// Encodes the string or object form.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .ref(let value):
            try container.encode(value)
        case .selection(let selection):
            try container.encode(selection)
        }
    }
}

/// `Bool | Value` (for example `tools.toolSearch`, `tools.swarm`, `gateway.nodes.pairing.sshVerify`).
public enum ConfigFlagOr<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    /// Boolean shorthand.
    case flag(Bool)
    /// Detailed object form.
    case value(Value)

    /// The boolean shorthand, or `nil` for the object form.
    public var flagValue: Bool? {
        if case .flag(let value) = self {
            return value
        }
        return nil
    }

    /// The object form, or `nil` for the boolean shorthand.
    public var objectValue: Value? {
        if case .value(let value) = self {
            return value
        }
        return nil
    }

    /// Decodes a boolean, else the object form.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
            self = .flag(flag)
        } else {
            self = .value(try container.decode(Value.self))
        }
    }

    /// Encodes the boolean or the object form.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .flag(let flag):
            try container.encode(flag)
        case .value(let value):
            try container.encode(value)
        }
    }
}

/// `string | false` (for example `cron.sessionRetention`, `http.securityHeaders.strictTransportSecurity`).
public enum ConfigStringOrFalse: Codable, Sendable, Hashable {
    /// A string value.
    case string(String)
    /// The literal `false` (explicitly disabled).
    case disabled

    /// The string value, or `nil` when disabled.
    public var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }

    /// Decodes a string or `false`.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let flag = try? container.decode(Bool.self), flag == false {
            self = .disabled
            return
        }
        throw DecodingError.typeMismatch(
            ConfigStringOrFalse.self,
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected a string or false.")
        )
    }

    /// Encodes the string or `false`.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .disabled:
            try container.encode(false)
        }
    }
}

/// Unit applied to bare duration numbers.
public enum ConfigDurationUnit: String, Sendable, Hashable, CaseIterable {
    /// Milliseconds.
    case milliseconds = "ms"
    /// Seconds.
    case seconds = "s"
    /// Minutes.
    case minutes = "m"
    /// Hours.
    case hours = "h"
    /// Days.
    case days = "d"

    /// Milliseconds per unit.
    public var multiplier: Double {
        switch self {
        case .milliseconds:
            return 1
        case .seconds:
            return 1_000
        case .minutes:
            return 60_000
        case .hours:
            return 3_600_000
        case .days:
            return 86_400_000
        }
    }
}

/// `string | number` duration (for example `session.maintenance.pruneAfter`, `heartbeat.every`).
public enum ConfigDurationValue: Codable, Sendable, Equatable {
    /// Duration string such as `"30d"`, `"1h30m"` or `"500ms"`.
    case string(String)
    /// Integer in the field's default unit.
    case integer(Int)
    /// Fractional number in the field's default unit.
    case number(Double)

    /// Parses the value into milliseconds (port of upstream `parseDurationMs`).
    /// - Parameter defaultUnit: Unit applied to bare numbers.
    /// - Returns: Milliseconds, or `nil` when the value is not a valid non-negative duration.
    public func milliseconds(defaultUnit: ConfigDurationUnit) -> Int64? {
        switch self {
        case .string(let value):
            return ConfigDuration.parseMilliseconds(value, defaultUnit: defaultUnit)
        case .integer(let value):
            return ConfigDuration.parseMilliseconds(String(value), defaultUnit: defaultUnit)
        case .number(let value):
            guard value.isFinite, value >= 0 else { return nil }
            return ConfigDuration.roundSafe(value * defaultUnit.multiplier)
        }
    }

    /// Decodes a string or a number.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else {
            self = .number(try container.decode(Double.self))
        }
    }

    /// Encodes the original form.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        }
    }
}

/// Duration parsing shared by config fields (port of upstream `src/cli/parse-duration.ts`).
public enum ConfigDuration {
    /// Parses a non-negative duration such as `"500ms"`, `"30s"`, `"5m"`, `"2h"`, `"7d"` or `"1h30m"`.
    ///
    /// A bare number uses `defaultUnit`; composite forms require a unit on every segment. Zero is valid.
    /// - Parameters:
    ///   - raw: Duration text.
    ///   - defaultUnit: Unit applied to a bare number.
    /// - Returns: Milliseconds, or `nil` when invalid.
    public static func parseMilliseconds(_ raw: String, defaultUnit: ConfigDurationUnit = .milliseconds) -> Int64? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            return nil
        }
        let tokens = self.tokenize(trimmed)
        guard let tokens, !tokens.isEmpty else {
            return nil
        }
        if tokens.count == 1, tokens[0].unit == nil {
            return self.roundSafe(tokens[0].value * defaultUnit.multiplier)
        }
        var total = 0.0
        for token in tokens {
            guard let unit = token.unit else {
                return nil
            }
            total += token.value * unit.multiplier
        }
        return self.roundSafe(total)
    }

    static func roundSafe(_ value: Double) -> Int64? {
        guard value.isFinite, value >= 0 else {
            return nil
        }
        let rounded = value.rounded()
        guard rounded <= 9_007_199_254_740_991 else {
            return nil
        }
        return Int64(rounded)
    }

    private static func tokenize(_ text: String) -> [(value: Double, unit: ConfigDurationUnit?)]? {
        var tokens: [(value: Double, unit: ConfigDurationUnit?)] = []
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            var number = ""
            while index < scalars.count, ("0"..."9").contains(scalars[index]) {
                number.unicodeScalars.append(scalars[index])
                index += 1
            }
            guard !number.isEmpty else {
                return nil
            }
            if index < scalars.count, scalars[index] == "." {
                var fraction = ""
                index += 1
                while index < scalars.count, ("0"..."9").contains(scalars[index]) {
                    fraction.unicodeScalars.append(scalars[index])
                    index += 1
                }
                guard !fraction.isEmpty else {
                    return nil
                }
                number += "." + fraction
            }
            var unit: ConfigDurationUnit?
            if index + 1 < scalars.count, scalars[index] == "m", scalars[index + 1] == "s" {
                unit = .milliseconds
                index += 2
            } else if index < scalars.count, let single = ConfigDurationUnit(rawValue: String(scalars[index])) {
                unit = single
                index += 1
            }
            guard let value = Double(number) else {
                return nil
            }
            tokens.append((value, unit))
            if unit == nil, index < scalars.count {
                return nil
            }
        }
        return tokens
    }
}

/// `number | "2mb"` byte size (for example `session.maintenance.maxDiskBytes`).
public enum ConfigByteSize: Codable, Sendable, Equatable {
    /// Byte count.
    case bytes(Int)
    /// Size string with a `b`, `kb`, `mb`, `gb` or `tb` suffix.
    case string(String)

    /// The size in bytes, or `nil` when the string is not a valid size.
    public var byteCount: Int64? {
        switch self {
        case .bytes(let value):
            return value >= 0 ? Int64(value) : nil
        case .string(let value):
            return Self.parse(value)
        }
    }

    /// Parses `"512"`, `"2mb"`, `"1.5gb"` (binary multiples) into bytes.
    /// - Parameter raw: Size text.
    /// - Returns: Bytes, or `nil` when invalid.
    public static func parse(_ raw: String) -> Int64? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let units: [(suffix: String, multiplier: Double)] = [
            ("tb", 1_099_511_627_776), ("gb", 1_073_741_824), ("mb", 1_048_576), ("kb", 1_024), ("b", 1),
        ]
        var numberText = trimmed
        var multiplier = 1.0
        for unit in units where trimmed.hasSuffix(unit.suffix) {
            numberText = String(trimmed.dropLast(unit.suffix.count)).trimmingCharacters(in: .whitespaces)
            multiplier = unit.multiplier
            break
        }
        guard !numberText.isEmpty,
              numberText.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              let value = Double(numberText)
        else {
            return nil
        }
        return ConfigDuration.roundSafe(value * multiplier)
    }

    /// Decodes an integer or a size string.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .bytes(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    /// Encodes the original form.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bytes(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        }
    }
}

/// `string | number` identifier (for example `allowFrom` entries and approval `threadId`).
public enum ConfigStringOrNumber: Codable, Sendable, Hashable {
    /// String form.
    case string(String)
    /// Integer form.
    case integer(Int)
    /// Fractional number form.
    case number(Double)

    /// The value rendered as a string (numbers use their decimal form).
    public var stringValue: String {
        switch self {
        case .string(let value):
            return value
        case .integer(let value):
            return String(value)
        case .number(let value):
            return String(value)
        }
    }

    /// Decodes a string or a number.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else {
            self = .number(try container.decode(Double.self))
        }
    }

    /// Encodes the original form.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        }
    }
}

// MARK: - Redaction

/// Redaction markers used by `config.get` snapshots (port of `src/config/redact-sentinel.ts`).
public enum ConfigRedaction {
    /// Sentinel the gateway writes in place of secret values.
    public static let sentinel = "__OPENCLAW_REDACTED__"

    /// Display markers that are never credential material (whole-value matches only).
    public static let redactedSecretValues: Set<String> = [
        sentinel,
        "REDACTED",
        "xoxb-REDACTED",
        "xapp-REDACTED",
        "***",
        "[redacted]",
        "[REDACTED]",
        "<redacted>",
        "[REDACTED_PRIVATE_KEY]",
        "[REDACTED CREDENTIAL]",
    ]

    /// Whether `value` (trimmed) is a redaction marker.
    /// - Parameter value: Candidate secret value.
    /// - Returns: `true` for a whole-value redaction marker.
    public static func isRedactedSecretValue(_ value: String?) -> Bool {
        guard let value else {
            return false
        }
        return self.redactedSecretValues.contains(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Whether a JSON value is a string redaction marker.
    /// - Parameter value: Candidate JSON value.
    /// - Returns: `true` for a whole-value redaction marker.
    public static func isRedactedSecretValue(_ value: AnyCodable?) -> Bool {
        self.isRedactedSecretValue(value?.stringValue)
    }
}

/// Small value helpers shared by config document types.
enum ConfigValueSupport {
    static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
