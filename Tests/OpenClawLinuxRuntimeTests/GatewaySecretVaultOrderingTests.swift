import Foundation
import Testing
import OpenClawCore
import OpenClawGateway

/// Secret vault mutations apply in one order to the store and the index (2026.3.0 FX1 review fix).
@Suite("Gateway secret vault ordering")
struct GatewaySecretVaultOrderingTests {
    /// Store whose `saveSecret` suspends after applying the value, so a concurrent delete could
    /// otherwise commit its index change first.
    actor SlowSaveCredentialStore: CredentialStore {
        private var values: [String: String] = [:]

        func saveSecret(_ value: String, for key: String) async throws {
            self.values[key] = value
            try await Task.sleep(nanoseconds: 30_000_000)
        }

        func loadSecret(for key: String) async throws -> String? {
            self.values[key]
        }

        func deleteSecret(for key: String) async throws {
            self.values[key] = nil
        }
    }

    @Test
    func concurrentVaultSetAndDeleteKeepTheIndexAndStoreInStep() async throws {
        let store = SlowSaveCredentialStore()
        let vault = GatewaySecretVault(credentialStore: store)
        for round in 0..<10 {
            let key = "API_KEY_\(round)"
            async let set: Void = vault.setSecret("v\(round)", for: key)
            async let delete = vault.deleteSecret(for: key)
            _ = try await (set, delete)
            let listed = await vault.listSecretKeys().contains(key)
            let stored = try await store.loadSecret(for: key) != nil
            #expect(listed == stored, "round \(round): index \(listed) store \(stored)")
        }
        // The index and the store also agree when the key already held a value.
        try await vault.setSecret("x", for: "ORDERED")
        async let later: Void = vault.setSecret("y", for: "ORDERED")
        async let removed = vault.deleteSecret(for: "ORDERED")
        _ = try await (later, removed)
        #expect(await vault.listSecretKeys().contains("ORDERED") == (try await store.loadSecret(for: "ORDERED") != nil))
    }
}
