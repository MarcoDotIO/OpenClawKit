import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Normalized HTTP response payload used by transport layers.
public struct HTTPResponseData: Sendable {
    /// HTTP status code.
    public let statusCode: Int
    /// Response headers normalized to string pairs.
    public let headers: [String: String]
    /// Raw response body bytes.
    public let body: Data

    /// Creates a normalized HTTP response payload.
    /// - Parameters:
    ///   - statusCode: HTTP status code.
    ///   - headers: Normalized response headers.
    ///   - body: Raw body payload.
    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

/// Actor-isolated HTTP client wrapper with Sendable-safe boundaries.
public actor HTTPClient {
    private let session: URLSession

    /// Creates an HTTP client.
    /// - Parameter session: Backing URL session (defaults to `.shared`).
    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Executes an HTTP request and returns normalized response data.
    /// - Parameter request: Configured URL request.
    /// - Returns: Response metadata and body.
    public func data(for request: URLRequest) async throws -> HTTPResponseData {
        let (data, response) = try await self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenClawCoreError.unavailable("Response was not HTTPURLResponse")
        }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { partialResult, entry in
            partialResult[String(describing: entry.key)] = String(describing: entry.value)
        }
        return HTTPResponseData(statusCode: http.statusCode, headers: headers, body: data)
    }
}
