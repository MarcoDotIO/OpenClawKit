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
@Suite("Provider streaming cancellation", .serialized, .timeLimit(.minutes(1)))
struct ProviderStreamingCancellationTests {
    @Test
    func cancellingBeforeResponseHeadCancelsTheRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HangingHeadURLProtocol.self]
        // This timeout and the policy's below are past the suite's time limit, so a cancellation that
        // never reaches the request fails as a hang instead of passing once the request times out.
        configuration.timeoutIntervalForRequest = 3_600
        let session = URLSession(configuration: configuration)
        let provider = ProviderServiceOpenAIModelProvider(
            id: "hanging",
            configuration: ProviderServiceConfig(enabled: true, modelID: "m", apiKey: "k", baseURL: "https://hanging.fx4a.test/v1"),
            transport: ModelStreamingHTTPClient(session: session)
        )
        let startedBefore = HangingHeadURLProtocol.started
        let stoppedBefore = HangingHeadURLProtocol.stopped
        let stream = await provider.generateStream(
            ModelGenerationRequest(sessionKey: "s", prompt: "hi", policy: ModelGenerationPolicy(requestTimeoutMs: 3_600_000))
        )
        let consumer = Task {
            for try await _ in stream {}
        }
        try await waitUntil("request started") { HangingHeadURLProtocol.started > startedBefore }
        consumer.cancel()
        try await waitUntil("request stopped after cancellation") { HangingHeadURLProtocol.stopped > stoppedBefore }
        session.invalidateAndCancel()
    }
}
#endif
