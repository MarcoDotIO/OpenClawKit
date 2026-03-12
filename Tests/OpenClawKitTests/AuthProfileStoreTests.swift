import Foundation
import Testing
@testable import OpenClawCore

@Suite("Auth profile store")
struct AuthProfileStoreTests {
    @Test
    func authProfileStorePersistsSecretsOutsideMetadataFile() async throws {
        let fileManager = FileManager()
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("openclawkit-auth-profile-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let credentialStore = FileCredentialStore(fileURL: root.appendingPathComponent("credentials.json"))
        let store = AuthProfileStore(
            fileURL: root.appendingPathComponent("auth-profiles.json"),
            credentialStore: credentialStore
        )

        try await store.setCredential(
            .oauth(
                OAuthAuthProfileCredential(
                    provider: "openai-codex",
                    accessToken: "access-123",
                    refreshToken: "refresh-456",
                    expires: 4_102_444_800_000,
                    clientID: "codex-client"
                )
            ),
            for: "openai-codex:work"
        )

        let persisted = try JSONDecoder().decode(
            PersistedProfileFileView.self,
            from: Data(contentsOf: root.appendingPathComponent("auth-profiles.json"))
        )
        #expect(persisted.profiles["openai-codex:work"]?.provider == "openai-codex")
        #expect(persisted.profiles["openai-codex:work"]?.clientID == "codex-client")
        let persistedString = try String(contentsOf: root.appendingPathComponent("auth-profiles.json"))
        #expect(persistedString.contains("access-123") == false)
        #expect(persistedString.contains("refresh-456") == false)

        let snapshot = await store.snapshot()
        #expect(snapshot.profiles["openai-codex:work"]?.mode == .oauth)

        let resolved = try await store.resolvedCredential(for: "openai-codex:work")
        if case .oauth(let credential) = resolved {
            #expect(credential.accessToken == "access-123")
            #expect(credential.refreshToken == "refresh-456")
            #expect(credential.clientID == "codex-client")
        } else {
            Issue.record("Expected oauth credential")
        }
    }

    @Test
    func authProfileResolverPrefersOauthThenRoundRobinThenCooldown() async throws {
        let snapshot = AuthProfileStoreSnapshot(
            profiles: [
                "provider:oauth": .init(provider: "openai-codex", mode: .oauth, expires: 4_102_444_800_000),
                "provider:token": .init(provider: "openai-codex", mode: .token, expires: 4_102_444_800_000),
                "provider:key": .init(provider: "openai-codex", mode: .apiKey),
            ],
            usageStats: [
                "provider:oauth": AuthProfileUsageStats(lastUsed: 300),
                "provider:token": AuthProfileUsageStats(lastUsed: 100),
                "provider:key": AuthProfileUsageStats(lastUsed: 0, cooldownUntil: Int(Date().timeIntervalSince1970 * 1000) + 60_000),
            ]
        )

        let ordered = AuthProfileResolver.resolveProfileOrder(
            provider: "openai-codex",
            snapshot: snapshot
        )

        #expect(ordered == ["provider:oauth", "provider:token", "provider:key"])
    }

    @Test
    func authProfileResolverRespectsConfiguredOrderAndPreferredProfile() {
        let snapshot = AuthProfileStoreSnapshot(
            profiles: [
                "copilot:default": .init(provider: "github-copilot", mode: .token, expires: 4_102_444_800_000),
                "copilot:work": .init(provider: "github-copilot", mode: .token, expires: 4_102_444_800_000),
            ]
        )

        let ordered = AuthProfileResolver.resolveProfileOrder(
            provider: "github-copilot",
            preferredProfileID: "copilot:work",
            config: AuthConfig(
                order: [
                    "github-copilot": ["copilot:default", "copilot:work"],
                ]
            ),
            snapshot: snapshot
        )

        #expect(ordered == ["copilot:work", "copilot:default"])
    }
}

private struct PersistedProfileFileView: Decodable {
    struct Profile: Decodable {
        let provider: String
        let mode: AuthProfileMode
        let email: String?
        let expires: Int?
        let clientID: String?
        let metadata: [String: String]
    }

    let version: Int
    let profiles: [String: Profile]
    let order: [String: [String]]
    let lastGood: [String: String]
    let usageStats: [String: AuthProfileUsageStats]
}
