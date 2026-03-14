import Foundation
import Testing
@testable import OpenClawCore

@Suite("Auth profile parity")
struct AuthProfileStoreParityTests {
    @Test
    func authProfileStorePersistsRefBackedCredentialsAndRicherSnapshotMetadata() async throws {
        let root = try makeAuthProfileRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let credentialStore = FileCredentialStore(fileURL: root.appendingPathComponent("credentials.json"))
        let store = AuthProfileStore(
            fileURL: root.appendingPathComponent("auth-profiles.json"),
            credentialStore: credentialStore
        )

        let keyRef = SecretRef(source: .env, id: "OPENAI_API_KEY")
        try await store.setCredential(
            .apiKey(
                APIKeyAuthProfileCredential(
                    provider: "openai",
                    keyRef: keyRef,
                    email: "dev@example.com",
                    metadata: ["account": "work"]
                )
            ),
            for: "openai:default"
        )

        let snapshot = await store.snapshot()
        let metadata = snapshot.profiles["openai:default"]
        #expect(metadata?.mode == .apiKey)
        #expect(metadata?.keyRef == keyRef)
        #expect(metadata?.metadata["account"] == "work")

        let persisted = try String(contentsOf: root.appendingPathComponent("auth-profiles.json"))
        #expect(persisted.contains(#""keyRef""#))
        #expect(persisted.contains(#""key":""#) == false)

        let resolved = try await store.resolvedCredential(for: "openai:default")
        if case .apiKey(let credential)? = resolved {
            #expect(credential.key == nil)
            #expect(credential.keyRef == keyRef)
            #expect(credential.metadata["account"] == "work")
        } else {
            Issue.record("Expected ref-backed api_key credential")
        }
    }

    @Test
    func authProfileStoreBridgesLegacyInlineSecretsIntoCredentialStore() async throws {
        let root = try makeAuthProfileRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let authFileURL = root.appendingPathComponent("auth-profiles.json")
        let legacyJSON = #"""
        {
          "version": 1,
          "profiles": {
            "anthropic:default": {
              "provider": "anthropic",
              "mode": "token",
              "email": "ops@example.com",
              "expires": 4102444800000,
              "token": "legacy-anthropic-token"
            }
          },
          "order": {},
          "lastGood": {},
          "usageStats": {}
        }
        """#
        try legacyJSON.write(to: authFileURL, atomically: true, encoding: .utf8)

        let credentialStore = FileCredentialStore(fileURL: root.appendingPathComponent("credentials.json"))
        let store = AuthProfileStore(fileURL: authFileURL, credentialStore: credentialStore)
        try await store.load()

        let resolved = try await store.resolvedCredential(for: "anthropic:default")
        if case .token(let credential)? = resolved {
            #expect(credential.token == "legacy-anthropic-token")
            #expect(credential.email == "ops@example.com")
        } else {
            Issue.record("Expected bridged token credential")
        }

        let migratedPersisted = try String(contentsOf: authFileURL)
        #expect(migratedPersisted.contains("legacy-anthropic-token") == false)
        let bridgedSecret = try await credentialStore.loadSecret(for: "auth.profiles.anthropic:default.token")
        #expect(bridgedSecret == "legacy-anthropic-token")
    }

    @Test
    func authProfileStoreTracksLastGoodAndFailureStateForRefBackedProfiles() async throws {
        let root = try makeAuthProfileRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let credentialStore = FileCredentialStore(fileURL: root.appendingPathComponent("credentials.json"))
        let store = AuthProfileStore(
            fileURL: root.appendingPathComponent("auth-profiles.json"),
            credentialStore: credentialStore
        )

        try await store.setCredential(
            .token(
                TokenAuthProfileCredential(
                    provider: "github-copilot",
                    tokenRef: SecretRef(source: .env, id: "GITHUB_TOKEN"),
                    expires: 4_102_444_800_000,
                    email: "dev@example.com"
                )
            ),
            for: "github-copilot:default"
        )

        try await store.recordFailure(
            profileID: "github-copilot:default",
            provider: "github-copilot",
            reason: .billing,
            cooldowns: AuthCooldownConfig(
                billingBackoffHours: 1,
                billingBackoffHoursByProvider: ["github-copilot": 2],
                billingMaxHours: 6,
                failureWindowHours: 24
            )
        )

        let afterFailure = await store.snapshot()
        #expect(afterFailure.profiles["github-copilot:default"]?.tokenRef == SecretRef(source: .env, id: "GITHUB_TOKEN"))
        #expect(afterFailure.usageStats["github-copilot:default"]?.errorCount == 1)
        #expect(afterFailure.usageStats["github-copilot:default"]?.cooldownUntil != nil)

        try await store.recordSuccess(profileID: "github-copilot:default", provider: "github-copilot")

        let afterSuccess = await store.snapshot()
        #expect(afterSuccess.lastGood["github-copilot"] == "github-copilot:default")
        #expect(afterSuccess.usageStats["github-copilot:default"]?.errorCount == 0)
        #expect(afterSuccess.usageStats["github-copilot:default"]?.cooldownUntil == nil)
    }

    private func makeAuthProfileRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclawkit-auth-profile-parity-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
