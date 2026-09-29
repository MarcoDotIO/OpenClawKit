import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore

/// HTTP transport that never follows redirects: a 3xx response is returned to the caller as-is.
///
/// `URLSession.shared` follows redirects before returning, re-sending a POST body (for example an
/// A2A task) to the redirect target. This transport refuses redirects with a session-level
/// delegate (honored on Apple platforms and by swift-corelibs-foundation on Linux) and, as a
/// second guard, rejects any response whose final URL differs from the requested endpoint.
public actor ChannelNoRedirectHTTPTransport: ChannelHTTPTransport {
    private static let sharedSession = URLSession(
        configuration: .ephemeral,
        delegate: ChannelNoRedirectDelegate(),
        delegateQueue: nil
    )

    private let session: URLSession

    /// Creates a transport backed by a shared ephemeral, redirect-refusing session.
    public init() {
        self.session = Self.sharedSession
    }

    /// Creates a transport with its own redirect-refusing session.
    /// - Parameter configuration: Session configuration (for example with custom protocol classes).
    public init(configuration: URLSessionConfiguration) {
        self.session = URLSession(configuration: configuration, delegate: ChannelNoRedirectDelegate(), delegateQueue: nil)
    }

    /// Executes a request without following redirects.
    /// - Parameter request: Configured URL request.
    /// - Returns: Normalized response (3xx responses are returned unchanged).
    /// - Throws: ``ChannelSendError/rejected(status:detail:)`` when the response came from another endpoint.
    public func data(for request: URLRequest) async throws -> HTTPResponseData {
        let (data, response) = try await self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenClawCoreError.unavailable("Response was not HTTPURLResponse")
        }
        if let requested = request.url, let final = http.url, !Self.sameEndpoint(requested, final) {
            throw ChannelSendError.rejected(status: 0, detail: "request was redirected to another endpoint; redirects are refused")
        }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { partialResult, entry in
            partialResult[String(describing: entry.key)] = String(describing: entry.value)
        }
        return HTTPResponseData(statusCode: http.statusCode, headers: headers, body: data)
    }

    static func sameEndpoint(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && Self.effectivePort(lhs) == Self.effectivePort(rhs)
            && lhs.path == rhs.path
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}

/// Session delegate that refuses every HTTP redirect.
final class ChannelNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
