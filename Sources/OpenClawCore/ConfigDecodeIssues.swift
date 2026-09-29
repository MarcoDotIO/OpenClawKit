import Foundation

/// A recoverable problem found while decoding configuration.
///
/// Config decoders never fail a whole document because of one unknown enum value or one
/// mistyped optional leaf. They fall back to `nil` (or the field default) and report the problem
/// as an issue to the ``ConfigDecodeIssueCollector`` registered under
/// ``Swift/CodingUserInfoKey/openClawConfigIssues`` in the decoder's `userInfo`.
public struct ConfigDecodeIssue: Codable, Sendable, Equatable {
    /// Classification of a config decode issue.
    public enum Kind: String, Codable, Sendable, Equatable, CaseIterable {
        /// A string did not match any value of a closed vocabulary.
        case unknownEnumValue
        /// A value had the wrong JSON type.
        case typeMismatch
        /// A legacy key or value was accepted and mapped to its canonical replacement.
        case legacyKey
        /// A key that upstream retired was found and ignored.
        case retiredKey
        /// A value was structurally invalid for another reason.
        case invalidValue
    }

    /// Dotted coding path of the offending value (array indices render as `[n]`).
    public var path: String
    /// Human-readable description of the problem.
    public var message: String
    /// Issue classification.
    public var kind: Kind

    /// Creates a decode issue.
    /// - Parameters:
    ///   - path: Dotted coding path of the offending value.
    ///   - message: Human-readable description.
    ///   - kind: Issue classification.
    public init(path: String, message: String, kind: Kind) {
        self.path = path
        self.message = message
        self.kind = kind
    }
}

/// Thread-safe sink that collects ``ConfigDecodeIssue`` values while a config is decoded.
///
/// Register an instance in a decoder's `userInfo` under
/// ``Swift/CodingUserInfoKey/openClawConfigIssues`` (or use ``decode(_:from:)``) to receive the
/// issues that lenient config decoders record instead of throwing.
public final class ConfigDecodeIssueCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ConfigDecodeIssue] = []

    /// Creates an empty collector.
    public init() {}

    /// Issues recorded so far, in recording order.
    public var issues: [ConfigDecodeIssue] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.storage
    }

    /// Records one issue.
    /// - Parameter issue: Issue to append.
    public func record(_ issue: ConfigDecodeIssue) {
        self.lock.lock()
        self.storage.append(issue)
        self.lock.unlock()
    }

    /// Removes every recorded issue.
    public func removeAll() {
        self.lock.lock()
        self.storage.removeAll()
        self.lock.unlock()
    }

    /// Decodes a JSON config value and returns it with the issues its lenient decoders recorded.
    /// - Parameters:
    ///   - type: Value type to decode, for example `OpenClawConfig.self`.
    ///   - data: JSON payload.
    /// - Returns: The decoded value and the recorded issues.
    /// - Throws: `DecodingError` only for malformed JSON or required fields that cannot be recovered.
    public static func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data
    ) throws -> (value: T, issues: [ConfigDecodeIssue]) {
        let collector = ConfigDecodeIssueCollector()
        let decoder = JSONDecoder()
        decoder.userInfo[.openClawConfigIssues] = collector
        let value = try decoder.decode(type, from: data)
        return (value, collector.issues)
    }
}

extension CodingUserInfoKey {
    /// `userInfo` key under which config decoders look up a ``ConfigDecodeIssueCollector``.
    public static let openClawConfigIssues = CodingUserInfoKey(rawValue: "openclaw.config.issues")!
}

extension KeyedDecodingContainer {
    /// Decodes an optional leaf without throwing.
    ///
    /// Returns `nil` when the key is absent, `null`, or holds a value that fails to decode (for
    /// example an unknown enum string). Failures are recorded as a ``ConfigDecodeIssue`` when a
    /// collector is registered in the decoder's `userInfo`.
    /// - Parameters:
    ///   - type: Leaf type.
    ///   - key: Coding key.
    /// - Returns: The decoded value, or `nil`.
    public func decodeLenient<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        guard self.contains(key) else { return nil }
        do {
            return try self.decodeIfPresent(type, forKey: key)
        } catch {
            ConfigDecodeIssueReporting.report(error, decoding: type, in: self, forKey: key)
            return nil
        }
    }

    /// Decodes an optional array, dropping elements that fail to decode.
    ///
    /// Returns `nil` when the key is absent, `null`, or not an array. Each dropped element (and a
    /// non-array value) is recorded as a ``ConfigDecodeIssue`` when a collector is registered.
    /// - Parameters:
    ///   - type: Element type.
    ///   - key: Coding key.
    /// - Returns: The decodable elements in order, or `nil`.
    public func decodeLossyArrayIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T]? {
        guard self.contains(key) else { return nil }
        do {
            guard let elements = try self.decodeIfPresent([ConfigLossyElement<T>].self, forKey: key) else {
                return nil
            }
            return elements.compactMap(\.value)
        } catch {
            ConfigDecodeIssueReporting.report(error, decoding: [T].self, in: self, forKey: key)
            return nil
        }
    }

    /// Decodes an optional string-keyed dictionary, dropping entries that fail to decode.
    ///
    /// Returns `nil` when the key is absent, `null`, or not an object. Each dropped entry (and a
    /// non-object value) is recorded as a ``ConfigDecodeIssue`` when a collector is registered.
    /// - Parameters:
    ///   - type: Value type.
    ///   - key: Coding key.
    /// - Returns: The decodable entries, or `nil`.
    public func decodeLossyDictionaryIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) -> [String: T]? {
        guard self.contains(key) else { return nil }
        do {
            guard let entries = try self.decodeIfPresent([String: ConfigLossyElement<T>].self, forKey: key) else {
                return nil
            }
            return entries.compactMapValues(\.value)
        } catch {
            ConfigDecodeIssueReporting.report(error, decoding: [String: T].self, in: self, forKey: key)
            return nil
        }
    }

    /// Records a non-throwing issue (for example a legacy value that was mapped) for `key`.
    /// - Parameters:
    ///   - message: Human-readable description.
    ///   - kind: Issue classification.
    ///   - key: Coding key the issue refers to.
    public func recordConfigIssue(_ message: String, kind: ConfigDecodeIssue.Kind, forKey key: Key) {
        guard let collector = ConfigDecodeIssueReporting.collector(in: self, forKey: key) else { return }
        collector.record(
            ConfigDecodeIssue(
                path: ConfigDecodeIssueReporting.render(self.codingPath + [key]),
                message: message,
                kind: kind
            )
        )
    }
}

/// Decodes one collection element without failing the surrounding collection.
struct ConfigLossyElement<Wrapped: Decodable>: Decodable {
    let value: Wrapped?

    init(from decoder: Decoder) throws {
        do {
            self.value = try decoder.singleValueContainer().decode(Wrapped.self)
        } catch {
            ConfigDecodeIssueReporting.report(error, decoding: Wrapped.self, decoder: decoder)
            self.value = nil
        }
    }
}

/// Shared helpers that turn decoding errors into ``ConfigDecodeIssue`` records.
enum ConfigDecodeIssueReporting {
    static func collector<K>(in container: KeyedDecodingContainer<K>, forKey key: K) -> ConfigDecodeIssueCollector? {
        guard let decoder = try? container.superDecoder(forKey: key) else { return nil }
        return decoder.userInfo[.openClawConfigIssues] as? ConfigDecodeIssueCollector
    }

    static func report<K, T>(
        _ error: Error,
        decoding type: T.Type,
        in container: KeyedDecodingContainer<K>,
        forKey key: K
    ) {
        guard let collector = self.collector(in: container, forKey: key) else { return }
        collector.record(self.issue(for: error, decoding: type, fallbackPath: container.codingPath + [key]))
    }

    static func report<T>(_ error: Error, decoding type: T.Type, decoder: Decoder) {
        guard let collector = decoder.userInfo[.openClawConfigIssues] as? ConfigDecodeIssueCollector else { return }
        collector.record(self.issue(for: error, decoding: type, fallbackPath: decoder.codingPath))
    }

    /// Records a non-throwing issue at the decoder's coding path.
    static func record(_ message: String, kind: ConfigDecodeIssue.Kind, decoder: Decoder, extraPath: [String] = []) {
        guard let collector = decoder.userInfo[.openClawConfigIssues] as? ConfigDecodeIssueCollector else { return }
        let base = self.render(decoder.codingPath)
        let path = ([base] + extraPath).filter { !$0.isEmpty }.joined(separator: ".")
        collector.record(ConfigDecodeIssue(path: path, message: message, kind: kind))
    }

    static func issue<T>(for error: Error, decoding type: T.Type, fallbackPath: [CodingKey]) -> ConfigDecodeIssue {
        let isVocabulary = type is any CaseIterable.Type
        switch error {
        case DecodingError.typeMismatch(_, let context):
            return ConfigDecodeIssue(
                path: self.render(context.codingPath.isEmpty ? fallbackPath : context.codingPath),
                message: context.debugDescription,
                kind: .typeMismatch
            )
        case DecodingError.dataCorrupted(let context):
            return ConfigDecodeIssue(
                path: self.render(context.codingPath.isEmpty ? fallbackPath : context.codingPath),
                message: context.debugDescription,
                kind: isVocabulary ? .unknownEnumValue : .invalidValue
            )
        case DecodingError.keyNotFound(let key, let context):
            return ConfigDecodeIssue(
                path: self.render(context.codingPath + [key]),
                message: context.debugDescription,
                kind: .invalidValue
            )
        case DecodingError.valueNotFound(_, let context):
            return ConfigDecodeIssue(
                path: self.render(context.codingPath.isEmpty ? fallbackPath : context.codingPath),
                message: context.debugDescription,
                kind: .typeMismatch
            )
        default:
            return ConfigDecodeIssue(
                path: self.render(fallbackPath),
                message: String(describing: error),
                kind: .invalidValue
            )
        }
    }

    static func render(_ path: [CodingKey]) -> String {
        var rendered = ""
        for key in path {
            if let index = key.intValue {
                rendered += "[\(index)]"
            } else if rendered.isEmpty {
                rendered = key.stringValue
            } else {
                rendered += ".\(key.stringValue)"
            }
        }
        return rendered
    }
}
