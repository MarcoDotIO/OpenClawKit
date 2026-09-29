import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OpenClawCore
@testable import OpenClawModels

#if !canImport(FoundationNetworking)
/// URL protocol that accepts a request and never sends a response head (a proxy holding headers).
private final class HangingHeadURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var startedCount = 0
    nonisolated(unsafe) private static var stoppedCount = 0

    static var started: Int {
        self.lock.withLock { self.startedCount }
    }

    static var stopped: Int {
        self.lock.withLock { self.stoppedCount }
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.withLock { Self.startedCount += 1 }
    }

    override func stopLoading() {
        Self.lock.withLock { Self.stoppedCount += 1 }
    }
}

/// Cancelling a streaming consumer before the response head arrives must cancel the HTTP request
/// promptly, not after the request timeout.
@Suite("Provider streaming cancellation", .serialized)
struct ProviderStreamingCancellationTests {
    private static func waitUntil(seconds: Double, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() {
                return true
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    @Test
    func cancellingBeforeResponseHeadCancelsTheRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HangingHeadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let provider = ProviderServiceOpenAIModelProvider(
            id: "hanging",
            configuration: ProviderServiceConfig(enabled: true, modelID: "m", apiKey: "k", baseURL: "https://hanging.fx4a.test/v1"),
            transport: ModelStreamingHTTPClient(session: session)
        )
        let startedBefore = HangingHeadURLProtocol.started
        let stoppedBefore = HangingHeadURLProtocol.stopped
        let stream = await provider.generateStream(
            ModelGenerationRequest(sessionKey: "s", prompt: "hi", policy: ModelGenerationPolicy(requestTimeoutMs: 60_000))
        )
        let consumer = Task {
            for try await _ in stream {}
        }
        #expect(try await Self.waitUntil(seconds: 5) { HangingHeadURLProtocol.started > startedBefore })
        consumer.cancel()
        #expect(try await Self.waitUntil(seconds: 5) { HangingHeadURLProtocol.stopped > stoppedBefore })
        session.invalidateAndCancel()
    }
}
#endif
