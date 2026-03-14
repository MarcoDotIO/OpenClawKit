import OpenClawProtocol
import Foundation

/// JSON bridge helpers for gateway payload values.
public enum GatewayPayloadDecoding {
    /// Decodes an `AnyCodable` payload into a concrete decodable type.
    public static func decode<T: Decodable>(
        _ payload: AnyCodable,
        as _: T.Type = T.self) throws -> T
    {
        let data = try JSONEncoder().encode(payload)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Decodes an optional `AnyCodable` payload when it is present.
    public static func decodeIfPresent<T: Decodable>(
        _ payload: AnyCodable?,
        as _: T.Type = T.self) throws -> T?
    {
        guard let payload else { return nil }
        return try self.decode(payload, as: T.self)
    }
}
