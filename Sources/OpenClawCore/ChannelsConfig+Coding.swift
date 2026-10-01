import Foundation
import OpenClawProtocol

/// String coding key used by the upstream-shaped channel config decoders.
struct ChannelConfigKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// One allowlist entry that upstream accepts as a string or a number (`Array<string | number>`).
struct ChannelLooseStringEntry: Decodable {
    let value: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self.value = string
        } else if let integer = try? container.decode(Int64.self) {
            self.value = String(integer)
        } else if let double = try? container.decode(Double.self) {
            self.value = double.rounded() == double && abs(double) < 1e15 ? String(Int64(double)) : String(double)
        } else {
            self.value = nil
        }
    }
}

/// Lenient reader over one upstream-shaped channel config object.
///
/// Every read accepts several key spellings (the SDK name first, then upstream aliases), never
/// throws for a bad leaf (it records a ``ConfigDecodeIssue`` instead) and remembers which keys it
/// consumed so the remaining keys can be preserved as passthrough data.
struct ChannelConfigReader {
    let container: KeyedDecodingContainer<ChannelConfigKey>
    private(set) var consumed: Set<String> = []

    init(decoder: Decoder) throws {
        self.container = try decoder.container(keyedBy: ChannelConfigKey.self)
    }

    /// Whether any of the keys is present.
    func contains(_ keys: [String]) -> Bool {
        keys.contains { self.container.contains(ChannelConfigKey($0)) }
    }

    /// First present key among `keys`.
    func presentKey(_ keys: [String]) -> ChannelConfigKey? {
        keys.lazy.map(ChannelConfigKey.init).first { self.container.contains($0) }
    }

    mutating func consume(_ keys: [String]) {
        self.consumed.formUnion(keys)
    }

    /// Decodes the first present key leniently; absent or invalid values return `nil`.
    mutating func value<T: Decodable>(_ type: T.Type, _ keys: String...) -> T? {
        self.value(type, keys: keys)
    }

    mutating func value<T: Decodable>(_ type: T.Type, keys: [String]) -> T? {
        self.consume(keys)
        for key in keys.map(ChannelConfigKey.init) where self.container.contains(key) {
            if let decoded = self.container.decodeLenient(type, forKey: key) {
                if key.stringValue != keys[0] {
                    self.container.recordConfigIssue(
                        "Accepted upstream key `\(key.stringValue)` for `\(keys[0])`.",
                        kind: .legacyKey,
                        forKey: key
                    )
                }
                return decoded
            }
        }
        return nil
    }

    /// Decodes a typed channel section into heap storage; absent or invalid sections use `fallback`.
    ///
    /// Out of line on purpose: a section's temporaries live in this frame only while that section
    /// decodes, instead of every section's temporaries sharing the caller's frame.
    @inline(never)
    mutating func section<T: ChannelSectionConfig>(_ keys: String..., fallback: @autoclosure () -> T) -> ConfigBoxed<T> {
        ConfigBoxed(wrappedValue: self.value(T.self, keys: keys) ?? fallback())
    }

    /// Decodes a string list that may contain numbers (upstream `Array<string | number>`).
    mutating func stringList(_ keys: String...) -> [String]? {
        self.consume(keys)
        for key in keys.map(ChannelConfigKey.init) where self.container.contains(key) {
            if let entries = try? self.container.decode([ChannelLooseStringEntry].self, forKey: key) {
                return entries.compactMap { $0.value?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
            // A single scalar is accepted as a one-element list.
            if let single = (try? self.container.decode(ChannelLooseStringEntry.self, forKey: key))?.value {
                return [single]
            }
            // Record why the value was rejected.
            _ = self.container.decodeLenient([String].self, forKey: key)
        }
        return nil
    }

    /// Decodes a secret that may be a plaintext string, an env template, or a SecretRef object.
    mutating func secret(_ keys: String...) -> SecretInput? {
        self.value(SecretInput.self, keys: keys)
    }

    /// Accepts and ignores keys that upstream retired.
    mutating func retired(_ keys: String..., reason: String) {
        self.consume(keys)
        for key in keys.map(ChannelConfigKey.init) where self.container.contains(key) {
            self.container.recordConfigIssue(
                "`\(key.stringValue)` was retired upstream and is ignored: \(reason)",
                kind: .retiredKey,
                forKey: key
            )
        }
    }

    /// Records an issue for a present key.
    func recordIssue(_ message: String, kind: ConfigDecodeIssue.Kind, forKey key: String) {
        let codingKey = ChannelConfigKey(key)
        guard self.container.contains(codingKey) else { return }
        self.container.recordConfigIssue(message, kind: kind, forKey: codingKey)
    }

    /// Keys that no typed field consumed, preserved losslessly.
    func remaining(excluding extra: Set<String> = []) -> [String: AnyCodable] {
        var result: [String: AnyCodable] = [:]
        for key in self.container.allKeys where !self.consumed.contains(key.stringValue) && !extra.contains(key.stringValue) {
            if let value = try? self.container.decode(AnyCodable.self, forKey: key) {
                result[key.stringValue] = value
            }
        }
        return result
    }
}

/// Writer over one channel config object.
struct ChannelConfigWriter {
    var container: KeyedEncodingContainer<ChannelConfigKey>

    init(encoder: Encoder) {
        self.container = encoder.container(keyedBy: ChannelConfigKey.self)
    }

    mutating func encode<T: Encodable>(_ value: T, _ key: String) throws {
        try self.container.encode(value, forKey: ChannelConfigKey(key))
    }

    mutating func encodeIfPresent<T: Encodable>(_ value: T?, _ key: String) throws {
        try self.container.encodeIfPresent(value, forKey: ChannelConfigKey(key))
    }

    mutating func encodeIfNotEmpty<T: Encodable & Collection>(_ value: T, _ key: String) throws {
        if !value.isEmpty {
            try self.container.encode(value, forKey: ChannelConfigKey(key))
        }
    }

    /// Writes passthrough keys that are not already written by a typed field.
    mutating func encodePassthrough(_ values: [String: AnyCodable], skipping written: Set<String>) throws {
        for (key, value) in values where !written.contains(key) {
            try self.container.encode(value, forKey: ChannelConfigKey(key))
        }
    }
}

/// JSON bridging helpers shared by channel configs.
enum ChannelConfigJSON {
    /// Encodes a value into a JSON object.
    static func object(from value: some Encodable) -> [String: AnyCodable]? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode([String: AnyCodable].self, from: data)
    }

    /// Decodes a value from a JSON object, collecting decode issues when a collector is passed.
    static func decode<T: Decodable>(
        _ type: T.Type,
        from object: [String: AnyCodable],
        issues: ConfigDecodeIssueCollector? = nil
    ) -> T? {
        guard let data = try? JSONEncoder().encode(object) else { return nil }
        let decoder = JSONDecoder()
        if let issues {
            decoder.userInfo[.openClawConfigIssues] = issues
        }
        return try? decoder.decode(type, from: data)
    }

    /// Interprets a raw value as a secret input (a string, an env template, or a SecretRef object).
    static func secretInput(from value: AnyCodable) -> SecretInput? {
        if let string = value.stringValue {
            return SecretRef.parseEnvTemplate(string).map(SecretInput.ref) ?? .string(string)
        }
        guard let object = value.dictionaryValue, object["source"] != nil, object["id"] != nil else {
            return nil
        }
        return Self.decode(SecretRef.self, fromAny: value).map(SecretInput.ref)
    }

    /// Decodes a value from any JSON value.
    static func decode<T: Decodable>(_ type: T.Type, fromAny value: AnyCodable) -> T? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Shallow account merge (upstream `mergeAccountConfig`): account keys win over root keys.
    ///
    /// Keys that belong to the same alias group replace every root spelling of that group, and
    /// the nested `streaming` object is merged one level deep.
    static func mergeAccount(
        root: [String: AnyCodable],
        account: [String: AnyCodable],
        aliasGroups: [[String]]
    ) -> [String: AnyCodable] {
        var merged = root
        merged.removeValue(forKey: "accounts")
        merged.removeValue(forKey: "defaultAccount")
        for (key, value) in account where key != "accounts" && key != "defaultAccount" {
            if key == "streaming",
               let base = merged[key]?.dictionaryValue,
               let overlay = value.dictionaryValue
            {
                merged[key] = AnyCodable(AnySendableValue.object(base.merging(overlay) { _, new in new }))
                continue
            }
            let group = aliasGroups.first { $0.contains(key) } ?? [key]
            for alias in group {
                merged.removeValue(forKey: alias)
            }
            merged[key] = value
        }
        return merged
    }
}
