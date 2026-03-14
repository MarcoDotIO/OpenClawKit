import Foundation

public extension AnyCodable {
    /// Canonical `null` sentinel used by transport and bridge helpers.
    static let nullValue = AnyCodable(.null)

    /// Converts Foundation container values into `AnyCodable`.
    /// - Parameter raw: Foundation-backed value to normalize.
    /// - Returns: A normalized `AnyCodable` value when conversion succeeds.
    static func fromFoundation(_ raw: Any) -> AnyCodable? {
        switch raw {
        case let value as AnyCodable:
            return value
        case is NSNull:
            return self.nullValue
        case let value as Bool:
            return AnyCodable(value)
        case let value as Int:
            return AnyCodable(value)
        case let value as Double:
            return AnyCodable(value)
        case let value as Float:
            return AnyCodable(Double(value))
        case let value as String:
            return AnyCodable(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return AnyCodable(value.boolValue)
            }
            let doubleValue = value.doubleValue
            if
                doubleValue.rounded(.towardZero) == doubleValue,
                doubleValue >= Double(Int.min),
                doubleValue <= Double(Int.max)
            {
                return AnyCodable(Int(doubleValue))
            }
            return AnyCodable(doubleValue)
        case let value as [String: Any]:
            return AnyCodable(value.reduce(into: [String: AnyCodable]()) { acc, entry in
                acc[entry.key] = self.fromFoundation(entry.value) ?? AnyCodable(String(describing: entry.value))
            })
        case let value as [Any]:
            return AnyCodable(value.map { self.fromFoundation($0) ?? AnyCodable(String(describing: $0)) })
        case let value as NSDictionary:
            var converted: [String: AnyCodable] = [:]
            for case let (key as String, rawValue) in value {
                converted[key] = self.fromFoundation(rawValue) ?? AnyCodable(String(describing: rawValue))
            }
            return AnyCodable(converted)
        case let value as NSArray:
            return AnyCodable(value.map { self.fromFoundation($0) ?? AnyCodable(String(describing: $0)) })
        default:
            return AnyCodable(String(describing: raw))
        }
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

    /// Returns the underlying Boolean when the wrapped value is a Boolean.
    var boolValue: Bool? {
        switch self.value {
        case .bool(let value):
            return value
        default:
            return nil
        }
    }

    /// Returns the wrapped integer value, coercing integral doubles when possible.
    var intValue: Int? {
        switch self.value {
        case .int(let value):
            return value
        case .double(let value) where value.rounded(.towardZero) == value && value >= Double(Int.min) && value <= Double(Int.max):
            return Int(value)
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
