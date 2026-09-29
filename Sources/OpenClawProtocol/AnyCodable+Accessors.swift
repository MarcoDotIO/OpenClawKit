import Foundation

// Typed accessors for the enum-backed `AnyCodable`.
//
// These live in OpenClawProtocol (not OpenClawKit) so every platform, including Linux, can read
// generated model fields without casting `value` (which is an `AnySendableValue`, not `Any`).
public extension AnyCodable {
    /// Canonical `null` sentinel used by transport and bridge helpers.
    static let nullValue = AnyCodable(.null)

    /// Converts Foundation container values into `AnyCodable`.
    ///
    /// `NSNumber` values are classified before Swift casts so JSON `0`/`1` stay numbers and
    /// `CFBoolean` values stay booleans. Values without a JSON representation are stringified.
    /// - Parameter raw: Foundation-backed value to normalize.
    /// - Returns: A normalized `AnyCodable` value when conversion succeeds.
    static func fromFoundation(_ raw: Any) -> AnyCodable? {
        AnyCodable(AnySendableValue.normalize(raw, strict: false))
    }

    /// Whether the wrapped value is JSON `null`.
    var isNull: Bool {
        self.value == .null
    }

    /// Returns the underlying string when the wrapped value is a string.
    var stringValue: String? {
        switch self.value {
        case .string(let value):
            return value
        default:
            return nil
        }
    }

    /// Returns the underlying Boolean when the wrapped value is a Boolean (numbers never coerce).
    var boolValue: Bool? {
        switch self.value {
        case .bool(let value):
            return value
        default:
            return nil
        }
    }

    /// Returns the wrapped integer value, converting integral doubles exactly when they fit `Int`.
    var intValue: Int? {
        switch self.value {
        case .int(let value):
            return value
        case .double(let value):
            return Int(exactly: value)
        default:
            return nil
        }
    }

    /// Returns the wrapped integer as `Int64`, converting integral doubles exactly.
    ///
    /// Prefer this accessor for millisecond timestamps: on 32-bit watchOS (`arm64_32`) values above
    /// `Int32.max` decode as `.double` and `intValue` returns `nil`.
    var int64Value: Int64? {
        switch self.value {
        case .int(let value):
            return Int64(value)
        case .double(let value):
            return Int64(exactly: value)
        default:
            return nil
        }
    }

    /// Returns the wrapped number as a double.
    var doubleValue: Double? {
        switch self.value {
        case .double(let value):
            return value
        case .int(let value):
            return Double(value)
        default:
            return nil
        }
    }

    /// Returns the wrapped object dictionary when the value is a JSON object.
    var dictionaryValue: [String: AnyCodable]? {
        switch self.value {
        case .object(let value):
            return value
        default:
            return nil
        }
    }

    /// Returns the wrapped array when the value is a JSON array.
    var arrayValue: [AnyCodable]? {
        switch self.value {
        case .array(let value):
            return value
        default:
            return nil
        }
    }

    /// Converts the wrapped value back to Foundation container types.
    var foundationValue: Any {
        switch self.value {
        case .null:
            return NSNull()
        case .bool(let value):
            return value
        case .int(let value):
            return value
        case .double(let value):
            return value
        case .string(let value):
            return value
        case .object(let dict):
            return dict.mapValues(\.foundationValue)
        case .array(let array):
            return array.map(\.foundationValue)
        }
    }
}
