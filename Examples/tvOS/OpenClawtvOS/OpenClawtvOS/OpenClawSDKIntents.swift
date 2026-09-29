import AppIntents
import Foundation
import OpenClawAppIntents
import OpenClawKit

/// App-level App Intents package that pulls in the SDK's intents, entities and queries.
nonisolated struct OpenClawExampleAppIntentsPackage: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] {
        [OpenClawAppIntentsPackage.self]
    }
}

/// Intent host registered once at launch with `OpenClawAppIntents.configure(host:)`.
///
/// Forwards to the embedded runtime while a deployment is running and reports
/// `hostNotConfigured` otherwise.
actor ExampleIntentHost: OpenClawIntentHost {
    static let shared = ExampleIntentHost()

    private var embedded: EmbeddedOpenClawIntentHost?

    /// Attaches (or detaches, with `nil`) the embedded runtime host of the current deployment.
    func attach(_ host: EmbeddedOpenClawIntentHost?) {
        self.embedded = host
    }

    nonisolated var prefersBackgroundGPU: Bool {
        false
    }

    func sessions(matching query: String?, limit: Int) async throws -> [OpenClawIntentSessionSummary] {
        try await self.current().sessions(matching: query, limit: limit)
    }

    func sessions(forKeys keys: [String]) async throws -> [OpenClawIntentSessionSummary] {
        try await self.current().sessions(forKeys: keys)
    }

    func agents() async throws -> [OpenClawIntentAgentSummary] {
        try await self.current().agents()
    }

    func send(
        prompt: String,
        sessionKey: String?,
        agentId: String?
    ) async throws -> AsyncThrowingStream<OpenClawIntentRunEvent, any Error> {
        try await self.current().send(prompt: prompt, sessionKey: sessionKey, agentId: agentId)
    }

    func abort(sessionKey: String) async {
        await self.embedded?.abort(sessionKey: sessionKey)
    }

    func startTalk(sessionKey: String?) async throws {
        throw OpenClawIntentError.unsupported("Live voice is not available on Apple TV.")
    }

    private func current() throws -> EmbeddedOpenClawIntentHost {
        guard let embedded else {
            throw OpenClawIntentError.hostNotConfigured
        }
        return embedded
    }
}
