import Foundation

/// Decoded result of the `sessions.compact` gateway RPC.
public struct OpenClawSessionsCompactResponse: Decodable, Sendable {
    /// Whether compaction succeeded.
    public let ok: Bool
    /// Failure reason when ``ok`` is `false`.
    public let reason: String?

    /// Decodes a `sessions.compact` payload and throws a localized error unless it reports success;
    /// the error text is the gateway's reason or "Thread compaction failed".
    public static func requireSuccess(from data: Data) throws {
        let response = try JSONDecoder().decode(Self.self, from: data)
        guard response.ok else {
            throw OpenClawSessionsCompactError(reason: response.reason)
        }
    }
}

struct OpenClawSessionsCompactError: Error, LocalizedError, Sendable {
    let reason: String?

    var errorDescription: String? {
        let detail = self.reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail?.isEmpty == false ? detail : "Thread compaction failed"
    }
}
