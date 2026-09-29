import Foundation
import Testing
@testable import OpenClawKit

/// In-memory Keychain used to exercise the relay settings end to end.
private final class InMemoryRelayCredentials: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    private(set) var accessGroups: [String?] = []
    var failWrites = false

    private func key(_ service: String, _ account: String) -> String {
        "\(service)|\(account)"
    }

    var store: ShareGatewayRelayCredentialStore {
        ShareGatewayRelayCredentialStore(
            load: { [self] service, account, group in
                self.lock.withLock {
                    self.accessGroups.append(group)
                    return self.items[self.key(service, account)]
                }
            },
            save: { [self] value, service, account, group in
                self.lock.withLock {
                    self.accessGroups.append(group)
                    guard !self.failWrites else { return false }
                    self.items[self.key(service, account)] = value
                    return true
                }
            },
            delete: { [self] service, account, _ in
                self.lock.withLock {
                    self.items[self.key(service, account)] = nil
                    return true
                }
            })
    }

    var storedJSON: [String] {
        self.lock.withLock { Array(self.items.values) }
    }
}

private struct RelayFixture {
    let suiteName = "ai.openclaw.tests.share.\(UUID().uuidString)"
    let legacySuiteName = "ai.openclaw.tests.share.legacy.\(UUID().uuidString)"
    let credentials = InMemoryRelayCredentials()

    var defaults: UserDefaults { UserDefaults(suiteName: self.suiteName)! }
    var legacyDefaults: UserDefaults { UserDefaults(suiteName: self.legacySuiteName)! }

    func environment(isAppExtension: Bool) -> ShareGatewayRelayEnvironment {
        let suiteName = self.suiteName
        let legacySuiteName = self.legacySuiteName
        return ShareGatewayRelayEnvironment(
            defaults: { UserDefaults(suiteName: suiteName)! },
            legacyDefaults: { UserDefaults(suiteName: legacySuiteName) },
            credentials: self.credentials.store,
            isAppExtension: { isAppExtension },
            credentialService: { "group.example.tests.share-gateway-relay" },
            credentialAccessGroup: { "group.example.tests" })
    }

    func cleanUp() {
        UserDefaults().removePersistentDomain(forName: self.suiteName)
        UserDefaults().removePersistentDomain(forName: self.legacySuiteName)
    }

    func run<T>(isAppExtension: Bool = false, _ body: () throws -> T) rethrows -> T {
        try ShareGatewayRelaySettings.$environment.withValue(self.environment(isAppExtension: isAppExtension)) {
            try body()
        }
    }
}

struct ShareGatewayRelayMigrationTests {
    private let config = ShareGatewayRelayConfig(
        gatewayURLString: "wss://relay.example.com",
        gatewayStableID: "manual|relay.example.com|443",
        token: "token",
        password: "password",
        sessionKey: "main")

    @Test func `secrets are stored in the keychain access group, never in defaults`() throws {
        let fixture = RelayFixture()
        defer { fixture.cleanUp() }
        try fixture.run {
            #expect(ShareGatewayRelaySettings.saveConfig(self.config))
            let raw = try #require(fixture.defaults.data(forKey: "share.gatewayRelay.config.v1"))
            let metadata = try JSONDecoder().decode(ShareGatewayRelayConfig.self, from: raw)
            #expect(metadata.token == nil)
            #expect(metadata.password == nil)
            #expect(String(decoding: raw, as: UTF8.self).contains("token\":\"token") == false)
            #expect(fixture.credentials.accessGroups.allSatisfy { $0 == "group.example.tests" })
            #expect(ShareGatewayRelaySettings.loadConfig() == self.config)
        }
    }

    @Test func `credentials for a different gateway are not merged`() throws {
        let fixture = RelayFixture()
        defer { fixture.cleanUp() }
        try fixture.run {
            #expect(ShareGatewayRelaySettings.saveConfig(self.config))
            // A route-only update (different stable ID) must not inherit the stored secrets.
            let other = ShareGatewayRelayConfig(
                gatewayURLString: "wss://other.example.com",
                gatewayStableID: "manual|other.example.com|443",
                token: nil,
                password: nil,
                sessionKey: "main")
            let data = try JSONEncoder().encode(other)
            fixture.defaults.set(data, forKey: "share.gatewayRelay.config.v1")
            let loaded = try #require(ShareGatewayRelaySettings.loadConfig())
            #expect(loaded.token == nil)
            #expect(loaded.password == nil)
        }
    }

    @Test func `host app migrates legacy plaintext secrets and scrubs the legacy suite`() throws {
        let fixture = RelayFixture()
        defer { fixture.cleanUp() }
        let legacyData = try JSONEncoder().encode(self.config)
        fixture.legacyDefaults.set(legacyData, forKey: "share.gatewayRelay.config.v1")

        try fixture.run(isAppExtension: false) {
            let loaded = try #require(ShareGatewayRelaySettings.loadConfig())
            #expect(loaded == self.config)
            #expect(fixture.legacyDefaults.data(forKey: "share.gatewayRelay.config.v1") == nil)
            let raw = try #require(fixture.defaults.data(forKey: "share.gatewayRelay.config.v1"))
            let metadata = try JSONDecoder().decode(ShareGatewayRelayConfig.self, from: raw)
            #expect(metadata.token == nil)
            #expect(fixture.credentials.storedJSON.count == 1)
            // A second load reads the migrated Keychain bundle.
            #expect(ShareGatewayRelaySettings.loadConfig() == self.config)
        }
    }

    @Test func `extension-first upgrade scrubs legacy secrets and asks for reconnect`() throws {
        let fixture = RelayFixture()
        defer { fixture.cleanUp() }
        let legacyData = try JSONEncoder().encode(self.config)
        fixture.defaults.set(legacyData, forKey: "share.gatewayRelay.config.v1")

        fixture.run(isAppExtension: true) {
            #expect(ShareGatewayRelaySettings.loadConfig() == nil)
            #expect(fixture.defaults.data(forKey: "share.gatewayRelay.config.v1") == nil)
            #expect(fixture.credentials.storedJSON.isEmpty)
            #expect(ShareGatewayRelaySettings.loadLastEvent()?.contains("reconnect") == true)
        }
    }

    @Test func `failed keychain write rejects the config`() throws {
        let fixture = RelayFixture()
        defer { fixture.cleanUp() }
        fixture.credentials.failWrites = true
        fixture.run {
            #expect(!ShareGatewayRelaySettings.saveConfig(self.config))
            #expect(fixture.defaults.data(forKey: "share.gatewayRelay.config.v1") == nil)
            #expect(ShareGatewayRelaySettings.loadConfig() == nil)
        }
    }

    @Test func `unscoped device auth is discarded only without a stable id`() throws {
        let fixture = RelayFixture()
        defer { fixture.cleanUp() }
        fixture.run {
            var discards = 0
            #expect(ShareGatewayRelaySettings.saveConfig(self.config))
            _ = ShareGatewayRelaySettings.loadConfigDiscardingUnscopedDeviceAuth { discards += 1 }
            #expect(discards == 0)

            let unscoped = ShareGatewayRelayConfig(
                gatewayURLString: "wss://relay.example.com",
                token: "token",
                password: nil,
                sessionKey: "main")
            #expect(ShareGatewayRelaySettings.saveConfig(unscoped))
            let loaded = ShareGatewayRelaySettings.loadConfigDiscardingUnscopedDeviceAuth { discards += 1 }
            #expect(loaded?.token == "token")
            #expect(discards == 1)
        }
    }

    @Test func `default discard drops only unscoped share-extension tokens`() throws {
        let fixture = RelayFixture()
        defer { fixture.cleanUp() }
        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-share-relay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        try DeviceIdentityPaths.$scopedStateDirURL.withValue(stateDirectory) {
            let identity = try DeviceIdentityStore.loadOrCreatePersistedOrThrow(profile: .shareExtension)
            for gatewayID in [nil, "gateway-a"] as [String?] {
                _ = DeviceAuthStore.storeTokenResult(
                    deviceId: identity.deviceId,
                    role: "operator",
                    token: "token-\(gatewayID ?? "unscoped")",
                    scopes: [],
                    gatewayID: gatewayID,
                    profile: .shareExtension)
            }
            try fixture.run {
                let unscoped = ShareGatewayRelayConfig(
                    gatewayURLString: "wss://relay.example.com",
                    token: "token",
                    password: nil,
                    sessionKey: "main")
                #expect(ShareGatewayRelaySettings.saveConfig(unscoped))
                let loaded = try #require(ShareGatewayRelaySettings.loadConfigDiscardingUnscopedDeviceAuth())
                #expect(loaded.token == "token")
            }
            #expect(DeviceAuthStore.loadToken(
                deviceId: identity.deviceId, role: "operator", gatewayID: nil, profile: .shareExtension) == nil)
            #expect(DeviceAuthStore.loadToken(
                deviceId: identity.deviceId, role: "operator", gatewayID: "gateway-a", profile: .shareExtension)?
                .token == "token-gateway-a")
        }
    }

    @Test func `clear config removes metadata and credentials`() {
        let fixture = RelayFixture()
        defer { fixture.cleanUp() }
        fixture.run {
            #expect(ShareGatewayRelaySettings.saveConfig(self.config))
            ShareGatewayRelaySettings.clearConfig()
            #expect(ShareGatewayRelaySettings.loadConfig() == nil)
            #expect(fixture.credentials.storedJSON.isEmpty)
        }
    }
}

struct OpenClawAppGroupTests {
    @Test func `Info.plist value wins and is trimmed`() {
        #expect(OpenClawAppGroup.identifier(infoDictionaryValue: "  group.example.app  ") == "group.example.app")
    }

    @Test func `missing Info.plist value never falls back to the upstream team group`() {
        let resolved = OpenClawAppGroup.identifier(infoDictionaryValue: nil)
        #expect(resolved != "group.ai.openclawfoundation.app.shared")
        #expect(resolved == OpenClawAppGroup.overrideIdentifier)
        #expect(OpenClawAppGroup.identifier(infoDictionaryValue: 42) == OpenClawAppGroup.overrideIdentifier)
    }
}

struct ShareToAgentDeepLinkMessageTests {
    @Test func `message omits the share preamble without content and injects no default instruction`() {
        let empty = SharedContentPayload(title: " ", url: nil, text: nil)
        #expect(ShareToAgentDeepLink.buildMessage(from: empty) == "")
        #expect(ShareToAgentDeepLink.buildURL(from: empty) == nil)
        #expect(ShareToAgentDeepLink.buildMessage(from: empty, instruction: "Summarize") == "Summarize")

        let content = SharedContentPayload(title: "Doc", url: nil, text: nil)
        #expect(ShareToAgentDeepLink.buildMessage(from: content) == "Shared from iOS.\n\nTitle: Doc")
    }
}
