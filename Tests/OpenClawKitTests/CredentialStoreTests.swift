import Foundation
import Testing
@testable import OpenClawCore

@Suite("Credential stores")
struct CredentialStoreTests {
    @Test
    func fileCredentialStoreRoundTripAndDelete() async throws {
        let fileManager = FileManager()
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("openclawkit-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("credentials.json")
        let store = FileCredentialStore(fileURL: storeURL)

        try await store.saveSecret("secret-value", for: "openai")
        let loaded = try await store.loadSecret(for: "openai")
        #expect(loaded == "secret-value")

        try await store.deleteSecret(for: "openai")
        let deleted = try await store.loadSecret(for: "openai")
        #expect(deleted == nil)
    }

    @Test
    func fileCredentialStorePersistsAcrossInstances() async throws {
        let fileManager = FileManager()
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("openclawkit-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("credentials.json")
        let first = FileCredentialStore(fileURL: storeURL)
        try await first.saveSecret("discord-token", for: "discord")

        let second = FileCredentialStore(fileURL: storeURL)
        let loaded = try await second.loadSecret(for: "discord")
        #expect(loaded == "discord-token")
    }

    @Test
    func defaultFactorySelectsExpectedStoreForPlatform() {
        let fallbackURL = FileManager().temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("credentials.json")
        let store = CredentialStoreFactory.makeDefault(
            fallbackFileURL: fallbackURL,
            keychainService: "io.marcodotio.openclawkit.tests.\(UUID().uuidString)"
        )

        #if canImport(Security)
        #expect(store is KeychainCredentialStore)
        #else
        #expect(store is FileCredentialStore)
        #endif
    }

    @Test
    func credentialSecretMigrationBackfillsLegacyWhenSecureStoreMissing() {
        let result = CredentialSecretMigration.resolve(
            secureStoreSecrets: [
                "discord": "secure-discord-token",
                "openai": "",
            ],
            legacySecrets: [
                "discord": "legacy-discord-token",
                "openai": "legacy-openai-token",
                "anthropic": "legacy-anthropic-token",
            ]
        )

        #expect(result.resolvedSecrets["discord"] == "secure-discord-token")
        #expect(result.resolvedSecrets["openai"] == "legacy-openai-token")
        #expect(result.resolvedSecrets["anthropic"] == "legacy-anthropic-token")
        #expect(result.valuesToPersist["openai"] == "legacy-openai-token")
        #expect(result.valuesToPersist["anthropic"] == "legacy-anthropic-token")
        #expect(result.valuesToPersist["discord"] == nil)
    }

    @Test
    func credentialSecretMigrationOmitsEmptyValues() {
        let result = CredentialSecretMigration.resolve(
            secureStoreSecrets: [
                "gemini": "   ",
            ],
            legacySecrets: [
                "gemini": "",
            ]
        )

        #expect(result.resolvedSecrets.isEmpty)
        #expect(result.valuesToPersist.isEmpty)
    }

    @Test
    func replayLedgerSignerUsesCredentialStoreSecret() async throws {
        let fileManager = FileManager()
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("openclawkit-replay-ledger-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let store = FileCredentialStore(fileURL: directory.appendingPathComponent("credentials.json"))
        try await store.saveSecret("ledger-secret", for: "replay-ledger")
        let loadedSecret = try await store.loadSecret(for: "replay-ledger")
        #expect(loadedSecret == "ledger-secret")

        let signer = HMACReplayLedgerSigner(secret: Data((loadedSecret ?? "").utf8), keyID: "replay-ledger")
        let event = ReplayEvent(
            sequenceNumber: 0,
            subsystem: "runtime",
            name: "run.started",
            runID: "cred-test-run",
            sessionKey: "cred-test-session"
        )
        let envelope = try ReplayLedgerVerifier.signedEnvelope(
            for: event,
            previousEventHash: nil,
            signer: signer
        )
        let verification = ReplayLedgerVerifier.verify(
            envelopes: [envelope],
            signer: signer,
            requireSignatureVerification: true
        )
        #expect(verification.isValid == true)
    }

    #if canImport(Security)
    @Test
    func keychainCredentialStoreRoundTripAndDelete() async throws {
        let service = "io.marcodotio.openclawkit.tests.\(UUID().uuidString)"
        let key = "anthropic"
        let store = KeychainCredentialStore(service: service)

        defer {
            Task {
                try? await store.deleteSecret(for: key)
            }
        }

        try await store.saveSecret("anthropic-secret", for: key)
        let loaded = try await store.loadSecret(for: key)
        #expect(loaded == "anthropic-secret")

        try await store.deleteSecret(for: key)
        let deleted = try await store.loadSecret(for: key)
        #expect(deleted == nil)
    }

    @Test
    func keychainCredentialStoreQueryIncludesAccessibility() async throws {
        let store = KeychainCredentialStore(
            service: "io.marcodotio.openclawkit.tests.\(UUID().uuidString)",
            accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        )

        let accessibility = try await store.itemQueryAccessibility(for: "openai")
        #expect(accessibility == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }
    #endif

    #if !canImport(Security)
    @Test
    func nonSecurityPlaceholderMaintainsAccessibilityInitializerShape() async throws {
        let store = KeychainCredentialStore(
            service: "io.marcodotio.openclawkit.tests",
            accessibility: "placeholder" as CFString
        )
        do {
            _ = try await store.loadSecret(for: "unavailable")
        } catch {
            #expect(String(describing: error).contains("Keychain"))
        }
    }
    #endif
}
