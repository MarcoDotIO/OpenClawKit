import Foundation
import OpenClawKit
import Testing

@Suite("Managed configuration overlay")
struct ManagedConfigurationOverlayTests {
    struct StaticSource: ManagedConfigurationSource {
        let values: [ManagedOpenClawConfigPayload?]

        func payloads() -> AsyncStream<ManagedOpenClawConfigPayload?> {
            AsyncStream { continuation in
                for value in self.values {
                    continuation.yield(value)
                }
                continuation.finish()
            }
        }
    }

    struct StaticPasswords: ManagedSecretSource {
        let passwords: [String: String]

        func password(withIdentifier identifier: String) async throws -> String {
            guard let value = self.passwords[identifier] else {
                throw OpenClawCoreError.invalidConfiguration("unknown \(identifier)")
            }
            return value
        }
    }

    static let payloadJSON = #"""
    {
      "gateway": {"mode": "remote", "port": 1,
                  "remote": {"url": "wss://managed.example.com/ws", "transport": "direct", "tlsFingerprint": "sha256:aa", "remotePort": 443,
                             "token": "plaintext-should-be-ignored",
                             "edgeAuth": {"CF-Access-Client-Secret": {"source": "store", "provider": "managed", "id": "cf-secret"},
                                          "X-Plain": "ignored"}}},
      "ui": {"prefs": {"themeMode": "dark", "accent": "#112233"}},
      "lockedPaths": ["gateway.auth"],
      "secretIdentifiers": {"gateway.remote.token": "gateway-token"}
    }
    """#

    @Test
    func managedValuesWinAndPathsLock() throws {
        let payload = try JSONDecoder().decode(ManagedOpenClawConfigPayload.self, from: Data(Self.payloadJSON.utf8))
        let local = try OpenClawConfigDocument.decode(Data(#"""
        {"gateway": {"mode": "local", "port": 18789, "remote": {"url": "wss://local.example.com"}, "auth": {"mode": "token"}},
         "ui": {"prefs": {"themeMode": "light", "chatShowThinking": true}}}
        """#.utf8))
        let (effective, locked) = ManagedConfigurationOverlay.apply(payload, to: local)
        #expect(effective.gateway?.mode == .remote)
        #expect(effective.gateway?.port == 18_789)
        #expect(effective.gateway?.remote?.url == "wss://managed.example.com/ws")
        #expect(effective.gateway?.remote?.remotePort == 443)
        #expect(effective.gateway?.remote?.token?.ref == SecretRef(source: .store, provider: "managed", id: "gateway-token"))
        #expect(effective.gateway?.remote?.edgeAuth?["CF-Access-Client-Secret"]?.ref?.id == "cf-secret")
        #expect(effective.gateway?.remote?.edgeAuth?["X-Plain"] == nil)
        #expect(effective.ui?.prefs?.themeMode == .dark)
        #expect(effective.ui?.prefs?.chatShowThinking == true)
        #expect(effective.ui?.accentHex == "#112233")
        #expect(locked.contains("gateway.remote.url"))
        #expect(locked.contains("gateway.remote.token"))
        #expect(ManagedConfigurationOverlay.isLocked("gateway.auth.token", lockedPaths: locked))
        #expect(!ManagedConfigurationOverlay.isLocked("gateway.port", lockedPaths: locked))
        // The local document is unchanged (managed values are runtime-only).
        #expect(local.gateway?.remote?.url == "wss://local.example.com")

        var builder = ConfigMergePatchBuilder(base: local.jsonObject)
        builder.set(["gateway", "remote", "url"], AnyCodable("wss://elsewhere"))
        builder.set(["gateway", "port"], AnyCodable(18_790))
        #expect(ManagedConfigurationOverlay.lockedPathViolations(in: try builder.build(), lockedPaths: locked) == ["gateway.remote.url"])
    }

    @Test
    func overlayTracksTheLatestPayload() async throws {
        let payload = try JSONDecoder().decode(ManagedOpenClawConfigPayload.self, from: Data(Self.payloadJSON.utf8))
        let overlay = ManagedConfigurationOverlay(source: StaticSource(values: [nil, payload]))
        var seen: [ManagedOpenClawConfigPayload?] = []
        for await value in await overlay.updates() {
            seen.append(value)
        }
        #expect(seen.count == 2)
        #expect(await overlay.current == payload)
        let applied = await overlay.apply(to: OpenClawConfigDocument())
        #expect(applied.document.gateway?.mode == .remote)
        #expect(ManagedConfigurationOverlay.apply(nil, to: OpenClawConfigDocument()).lockedPaths.isEmpty)
    }

    @Test
    func managedSecretResolverResolvesManagedRefsAndDefersOthers() async throws {
        let resolver = ManagedSecretRefResolver(
            source: StaticPasswords(passwords: ["gateway-token": "managed-secret"]),
            fallback: DefaultSecretRefResolver(environment: ["LOCAL_TOKEN": "local-secret"])
        )
        let config = SecretsConfig()
        #expect(try await resolver.resolve(SecretRef(source: .store, provider: "managed", id: "gateway-token"), config: config) == "managed-secret")
        #expect(try await resolver.resolve(SecretRef(source: .env, id: "LOCAL_TOKEN"), config: config) == "local-secret")
        await #expect(throws: OpenClawCoreError.self) {
            _ = try await resolver.resolve(SecretRef(source: .store, provider: "managed", id: "missing"), config: config)
        }
    }
}
