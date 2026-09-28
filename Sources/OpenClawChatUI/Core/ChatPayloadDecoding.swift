import Foundation
import OpenClawProtocol

/// JSON bridge used by the chat core to turn type-erased gateway payloads into typed models.
///
/// This is the chat-core copy of `GatewayPayloadDecoding` so the core files only depend on
/// Foundation and OpenClawProtocol (they are laid out to move into an `OpenClawChatCore` target).
package enum ChatPayloadDecoding {
    /// Decodes an `AnyCodable` payload into a concrete decodable type.
    package static func decode<T: Decodable>(_ payload: AnyCodable, as _: T.Type = T.self) throws -> T {
        let data = try JSONEncoder().encode(payload)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Decodes an optional payload, returning `nil` when it is absent.
    package static func decodeIfPresent<T: Decodable>(_ payload: AnyCodable?, as _: T.Type = T.self) throws -> T? {
        guard let payload else { return nil }
        return try self.decode(payload, as: T.self)
    }

    /// Trims whitespace and returns `nil` for empty strings.
    package static func trimmedNonEmptyString(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
