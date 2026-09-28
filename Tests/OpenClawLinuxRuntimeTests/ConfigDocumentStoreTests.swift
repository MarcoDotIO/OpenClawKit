import Foundation
import OpenClawProtocol
import Testing
@testable import OpenClawCore

@Suite("Config document store")
struct ConfigDocumentStoreTests {
    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclawkit-config-document-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    @Test
    func loadsJSON5AndReportsLegacyKeys() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("openclaw.json")
        try Self.write("""
        {
          // JSON5 comment
          meta: { lastTouchedVersion: "2026.9.1", lastTouchedAt: "2026-09-01T00:00:00Z" },
          defaultModel: "openai/gpt-5.4",
          agents: { list: [{ id: "main" }] },
        }
        """, to: url)
        let store = OpenClawConfigDocumentStore(fileURL: url, environment: [:])
        let loaded = try await store.load()
        #expect(loaded.exists)
        #expect(loaded.hash == OpenClawCrypto.sha256Hex(loaded.rawData))
        #expect(loaded.touchedVersion == "2026.9.1")
        #expect(loaded.hasIncludes == false)
        #expect(loaded.document.agents?.defaults?.model?.primary == "openai/gpt-5.4")
        #expect(loaded.document.agents?.entries?["main"] != nil)
        #expect(loaded.migrationChanges.contains { $0.id == "defaultModel->agents.defaults.model" })
        #expect(loaded.legacyIssues.contains { $0.kind == .retiredKey || $0.kind == .legacyKey })

        let unmigrated = try await store.load(migrateLegacyKeys: false)
        #expect(unmigrated.document.additionalProperties["defaultModel"]?.stringValue == "openai/gpt-5.4")
    }

    @Test
    func writeGuardsStampMetaAndRotateBackups() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("openclaw.json")
        try Self.write(#"{"meta":{"lastTouchedVersion":"2026.9.1","lastTouchedAt":"x"},"gateway":{"port":18789},"zeta":1,"alpha":2}"#, to: url)
        let store = OpenClawConfigDocumentStore(fileURL: url, environment: [:])

        var loaded = try await store.load()
        for round in 1...6 {
            var document = loaded.document
            document.gateway?.port = 19_000 + round
            loaded = try await store.save(document, expectedHash: loaded.hash, options: .init(touchedVersion: "2026.9.6"))
        }
        let written = try #require(try OpenClawJSON5.parse(try Data(contentsOf: url)).dictionaryValue)
        let meta = try #require(written["meta"]?.dictionaryValue)
        #expect(meta["lastTouchedAt"] == nil)
        #expect(meta["lastTouchedVersion"]?.stringValue == "2026.9.6")
        #expect(written["gateway"]?.dictionaryValue?["port"]?.intValue == 19_006)

        // Five-slot ring: .bak, .bak.1 … .bak.4 (newest first).
        for index in 0..<5 {
            let name = index == 0 ? "openclaw.json.bak" : "openclaw.json.bak.\(index)"
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path), "missing \(name)")
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("openclaw.json.bak.5").path))
        let newestBackup = try #require(try OpenClawJSON5.parse(try Data(contentsOf: directory.appendingPathComponent("openclaw.json.bak"))).dictionaryValue)
        #expect(newestBackup["gateway"]?.dictionaryValue?["port"]?.intValue == 19_005)

        // Authored key order survives; the file ends with a newline.
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        let zeta = try #require(text.range(of: "\"zeta\""))
        let alpha = try #require(text.range(of: "\"alpha\""))
        #expect(zeta.lowerBound < alpha.lowerBound)
        #expect(text.hasSuffix("}\n"))

        #if !os(Windows)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(mode & 0o777 == 0o600)
        #endif
    }

    @Test
    func conflictIncludeAndFutureVersionGuardsRefuseWrites() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("openclaw.json")
        try Self.write(#"{"gateway":{"port":18789}}"#, to: url)
        let store = OpenClawConfigDocumentStore(fileURL: url, environment: [:])
        let loaded = try await store.load()

        await #expect(throws: OpenClawConfigDocumentStore.StoreError.self) {
            try await store.save(loaded.document, expectedHash: "stale")
        }

        try Self.write(#"{"$include":"./base.json5","gateway":{"port":1}}"#, to: url)
        let included = try await store.load()
        #expect(included.hasIncludes)
        await #expect(throws: OpenClawConfigDocumentStore.StoreError.includesNotWritable) {
            try await store.save(included.document, expectedHash: included.hash)
        }

        try Self.write(#"{"meta":{"lastTouchedVersion":"2027.1.1"}}"#, to: url)
        let future = try await store.load()
        await #expect(throws: OpenClawConfigDocumentStore.StoreError.futureVersion(touchedVersion: "2027.1.1", currentVersion: "2026.9.6")) {
            try await store.save(future.document, expectedHash: future.hash)
        }
        let overridden = OpenClawConfigDocumentStore(fileURL: url, environment: ["OPENCLAW_ALLOW_OLDER_BINARY_DESTRUCTIVE_ACTIONS": "yes"])
        let written = try await overridden.save(future.document, expectedHash: future.hash)
        #expect(written.touchedVersion == "2026.9.6")
    }

    @Test
    func writesStripSDKOnlyKeys() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("openclaw.json")
        let store = OpenClawConfigDocumentStore(fileURL: url, environment: [:])
        var document = OpenClawConfigDocument()
        document.additionalProperties["routing"] = AnyCodable(.object(["includePeerID": AnyCodable(.bool(true))]))
        document.additionalProperties["runtime"] = AnyCodable(.object([:]))
        var gateway = OpenClawConfigDocument.Gateway()
        gateway.port = 18_789
        gateway.additionalProperties["host"] = AnyCodable(.string("127.0.0.1"))
        document.gateway = gateway
        _ = try await store.save(document, expectedHash: nil)
        let written = try #require(try OpenClawJSON5.parse(try Data(contentsOf: url)).dictionaryValue)
        #expect(written["routing"] == nil)
        #expect(written["runtime"] == nil)
        #expect(written["gateway"]?.dictionaryValue?["host"] == nil)
        #expect(written["gateway"]?.dictionaryValue?["port"]?.intValue == 18_789)
    }

    @Test
    func resolvesPathsLikeUpstream() {
        let home = "/tmp/openclaw-home"
        #expect(OpenClawConfigDocumentStore.defaultConfigURL(environment: ["OPENCLAW_CONFIG_PATH": "~/custom.json", "HOME": home]).path
            == "\(home)/custom.json")
        #expect(OpenClawConfigDocumentStore.defaultConfigURL(environment: ["OPENCLAW_STATE_DIR": "/srv/openclaw", "HOME": home]).path
            == "/srv/openclaw/openclaw.json")
        #expect(OpenClawConfigDocumentStore.defaultConfigURL(environment: ["OPENCLAW_PROFILE": "work", "HOME": home]).path
            == "\(home)/.openclaw-work/openclaw.json")
        #expect(OpenClawConfigDocumentStore.defaultConfigURL(environment: ["OPENCLAW_PROFILE": "default", "HOME": home]).path
            == "\(home)/.openclaw/openclaw.json")
        #expect(OpenClawConfigDocumentStore.defaultConfigURL(environment: ["OPENCLAW_HOME": "/opt/oc", "HOME": home]).path
            == "/opt/oc/.openclaw/openclaw.json")
    }

    @Test
    func versionGuardFollowsOpenClawSemver() {
        #expect(OpenClawVersionComparison.shouldWarnOnTouchedVersion(current: "2026.9.6", touched: "2026.10.1"))
        #expect(!OpenClawVersionComparison.shouldWarnOnTouchedVersion(current: "2026.9.6", touched: "2026.9.6"))
        #expect(!OpenClawVersionComparison.shouldWarnOnTouchedVersion(current: "2026.9.6", touched: "2026.9.6-2"))
        #expect(OpenClawVersionComparison.shouldWarnOnTouchedVersion(current: "2026.9.6", touched: "2026.9.7-beta.1"))
        #expect(!OpenClawVersionComparison.shouldWarnOnTouchedVersion(current: "2026.9.6", touched: "2026.7.1-2"))
        #expect(OpenClawVersionComparison.compare("2026.9.6-2", "2026.9.6") == 1)
        #expect(OpenClawVersionComparison.compare("2026.9.6-beta.1", "2026.9.6") == -1)
        #expect(!OpenClawVersionComparison.shouldWarnOnTouchedVersion(current: "2026.9.6", touched: "garbage"))
    }

    @Test
    func envSubstitutionResolvesUppercaseNamesAndEscapes() throws {
        let json = #"""
        {"gateway": {"auth": {"token": "${GATEWAY_TOKEN}"}, "remote": {"url": "wss://${HOST_NAME}/ws", "token": "$${LITERAL}"}},
         "models": {"providers": {"x": {"baseUrl": "https://${missing_lower}/${MISSING_VAR}", "models": []}}}}
        """#
        let document = try OpenClawConfigDocument.decode(Data(json.utf8), migrateLegacyKeys: false)
        let resolved = document.resolvedForRuntime(environment: ["GATEWAY_TOKEN": "secret-token-value", "HOST_NAME": "gw.example.com"])
        #expect(resolved.document.gateway?.auth?.token?.plaintext == "secret-token-value")
        #expect(resolved.document.gateway?.remote?.url == "wss://gw.example.com/ws")
        #expect(resolved.document.gateway?.remote?.token?.raw.stringValue == "${LITERAL}")
        #expect(resolved.document.models?.providers?["x"]?.baseUrl == "https://${missing_lower}/${MISSING_VAR}")
        #expect(resolved.issues.map(\.path) == ["models.providers.x.baseUrl"])
        // The authored document is untouched.
        #expect(document.gateway?.auth?.token?.raw.stringValue == "${GATEWAY_TOKEN}")
    }
}
