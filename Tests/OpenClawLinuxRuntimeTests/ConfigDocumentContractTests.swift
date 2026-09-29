import Foundation
import OpenClawProtocol
import Testing
@testable import OpenClawCore

/// Locates the upstream config fixtures copied by `Scripts/sync-config-fixtures.sh`.
enum ConfigFixtures {
    static let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)
        .appendingPathComponent("Config", isDirectory: true)

    static func data(_ relativePath: String) throws -> Data {
        try Data(contentsOf: self.directory.appendingPathComponent(relativePath))
    }

    static func files(in subdirectory: String, extension fileExtension: String) throws -> [URL] {
        let folder = self.directory.appendingPathComponent(subdirectory, isDirectory: true)
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == fileExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

@Suite("Config document contract")
struct ConfigDocumentContractTests {
    // MARK: Corpus decode

    @Test
    func everyCorpusFixtureDecodesLosslessly() throws {
        let fixtures = try ConfigFixtures.files(in: "corpus", extension: "json")
        #expect(fixtures.count == 16)
        for url in fixtures {
            let data = try Data(contentsOf: url)
            let collector = ConfigDecodeIssueCollector()
            let document = try OpenClawConfigDocument.decode(data, allowJSON5: true, issues: collector)
            let typeMismatches = collector.issues.filter { $0.kind == .typeMismatch }
            #expect(typeMismatches.isEmpty, "\(url.lastPathComponent): \(typeMismatches)")

            // Lossless passthrough: encode → decode reproduces the same tree.
            let encoded = try document.encoded()
            let reparsed = try OpenClawConfigDocument.decode(encoded)
            #expect(reparsed.jsonObject == document.jsonObject, "\(url.lastPathComponent) did not round-trip")

            // Without legacy keys, the typed tree equals the source tree exactly.
            let source = try OpenClawJSON5.parse(data).dictionaryValue ?? [:]
            if OpenClawConfigMigrator.proposedChanges(for: source).isEmpty {
                #expect(document.jsonObject == source, "\(url.lastPathComponent) lost or synthesized keys")
            }
        }
    }

    @Test
    func docsExamplesParseAndDecode() throws {
        let blocks = try ConfigFixtures.files(in: "docs", extension: "json5")
        #expect(!blocks.isEmpty)
        var decoded = 0
        for url in blocks {
            let data = try Data(contentsOf: url)
            guard let tree = try? OpenClawJSON5.parse(data), tree.dictionaryValue != nil else {
                // Some doc blocks are prose fragments (for example `// ...` elisions); skip them.
                continue
            }
            let collector = ConfigDecodeIssueCollector()
            _ = try OpenClawConfigDocument.decode(data, issues: collector)
            let typeMismatches = collector.issues.filter { $0.kind == .typeMismatch }
            #expect(typeMismatches.isEmpty, "\(url.lastPathComponent): \(typeMismatches)")
            decoded += 1
        }
        #expect(decoded >= 20)
    }

    // MARK: Doctor replay

    @Test
    func legacyFirstAgentWorkspacePinFollowsUpstreamConditions() throws {
        func migratedEntries(_ agents: String, environment: [String: String] = ["HOME": "/h"]) throws -> [String: AnyCodable] {
            var tree = try #require(try OpenClawJSON5.parse(Data(#"{"agents": \#(agents)}"#.utf8)).dictionaryValue)
            OpenClawConfigMigrator.migrate(&tree, environment: environment)
            return try #require(tree["agents"]?.dictionaryValue?["entries"]?.dictionaryValue)
        }
        func workspace(_ entries: [String: AnyCodable], _ id: String) -> String? {
            entries[id]?.dictionaryValue?["workspace"]?.stringValue
        }
        let list = #"{"list": [{"id": "main"}, {"id": "work"}]}"#
        #expect(workspace(try migratedEntries(list), "main") == "/h/.openclaw/workspace")
        #expect(workspace(try migratedEntries(list), "work") == nil)
        // agents.defaults.workspace wins (trimmed), then the environment-derived defaults.
        #expect(workspace(try migratedEntries(#"{"defaults": {"workspace": " /srv/ws "}, "list": [{"id": "a"}, {"id": "b"}]}"#), "a") == "/srv/ws")
        #expect(workspace(try migratedEntries(list, environment: ["HOME": "/h", "OPENCLAW_WORKSPACE_DIR": "/custom/ws"]), "main") == "/custom/ws")
        #expect(workspace(try migratedEntries(list, environment: ["HOME": "/h", "OPENCLAW_STATE_DIR": "/state"]), "main") == "/state/workspace")
        #expect(workspace(try migratedEntries(list, environment: ["HOME": "/h", "OPENCLAW_PROFILE": "work"]), "main") == "/h/.openclaw-work/workspace")
        // A blank workspace is pinned; an authored one is kept.
        #expect(workspace(try migratedEntries(#"{"list": [{"id": "a", "workspace": "  "}, {"id": "b"}]}"#), "a") == "/h/.openclaw/workspace")
        #expect(workspace(try migratedEntries(#"{"list": [{"id": "a", "workspace": "/mine"}, {"id": "b"}]}"#), "a") == "/mine")
        // No pin: explicit ownership, a default marker, a single entry, or an existing roster.
        #expect(workspace(try migratedEntries(#"{"ownership": "explicit", "list": [{"id": "a"}, {"id": "b"}]}"#), "a") == nil)
        #expect(workspace(try migratedEntries(#"{"list": [{"id": "a"}, {"id": "b", "default": true}]}"#), "a") == nil)
        #expect(workspace(try migratedEntries(#"{"list": [{"id": "a"}, {"id": "b", "default": "yes"}]}"#), "a") == nil)
        #expect(workspace(try migratedEntries(#"{"list": [{"id": "a"}, {"id": "b", "default": false}]}"#), "a") == "/h/.openclaw/workspace")
        #expect(workspace(try migratedEntries(#"{"list": [{"id": "a"}]}"#), "a") == nil)
        #expect(workspace(try migratedEntries(#"{"entries": {"a": {}, "b": {}}, "list": [{"id": "a"}, {"id": "b"}]}"#), "a") == nil)
    }

    @Test
    func doctorFixtureMigratesLikeUpstreamDoctor() throws {
        let data = try ConfigFixtures.data("doctor-2026.7.1.json")
        var tree = try #require(try OpenClawJSON5.parse(data).dictionaryValue)
        let environment = ["HOME": "/Users/oc-fixture"]
        let changes = OpenClawConfigMigrator.migrate(&tree, environment: environment)
        #expect(!changes.isEmpty)

        let meta = tree["meta"]?.dictionaryValue
        #expect(meta?["lastTouchedAt"] == nil)
        #expect(meta?["lastTouchedVersion"]?.stringValue == "2026.7.1-2")

        let agents = try #require(tree["agents"]?.dictionaryValue)
        #expect(agents["list"] == nil)
        let entries = try #require(agents["entries"]?.dictionaryValue)
        #expect(Set(entries.keys) == ["main", "research"])
        #expect(entries["main"]?.dictionaryValue?["id"] == nil)
        // Upstream doctor pins the first markerless agent to the shared workspace.
        #expect(entries["main"]?.dictionaryValue?["workspace"]?.stringValue == "/Users/oc-fixture/.openclaw/workspace")
        #expect(entries["research"]?.dictionaryValue?["workspace"] == nil)
        #expect(agents["ownership"]?.stringValue == "explicit")
        #expect(agents["defaults"]?.dictionaryValue?["memorySearch"] == nil)

        let memorySearch = try #require(tree["memory"]?.dictionaryValue?["search"]?.dictionaryValue)
        #expect(memorySearch["provider"]?.stringValue == "local")
        #expect(memorySearch["model"]?.stringValue == "hf:Qwen/Qwen3-Embedding-0.6B-GGUF:q8_0")

        let gateway = try #require(tree["gateway"]?.dictionaryValue)
        #expect(gateway["tailscale"]?.dictionaryValue?["resetOnExit"] == nil)
        let nodes = try #require(gateway["nodes"]?.dictionaryValue)
        #expect(nodes["denyCommands"] == nil)
        #expect(nodes["commands"]?.dictionaryValue?["deny"]?.arrayValue?.compactMap(\.stringValue) == ["system.run"])

        let media = try #require(tree["tools"]?.dictionaryValue?["media"]?.dictionaryValue)
        #expect(media["audio"] == nil)
        let models = try #require(media["models"]?.arrayValue)
        #expect(models.count == 1)
        #expect(models.first?.dictionaryValue?["capabilities"]?.arrayValue?.compactMap(\.stringValue) == ["audio"])
        #expect(models.first?.dictionaryValue?["command"]?.stringValue == "echo")

        // A second pass is a no-op (upstream: the second doctor pass leaves the bytes unchanged).
        var second = tree
        #expect(OpenClawConfigMigrator.migrate(&second, environment: environment).isEmpty)
        #expect(second == tree)

        // The typed view sees the canonical shape.
        let document = try OpenClawConfigDocument.decode(data)
        #expect(document.agents?.entryOrder == ["main", "research"])
        #expect(document.agents?.ownership == "explicit")
        #expect(document.agents?.resolvedDefaultAgentID == nil)
        #expect(document.gateway?.nodes?.commands?.deny == ["system.run"])
        #expect(document.tools?.alsoAllow == ["browser"])
    }

    @Test
    func legacyRosterFixtureKeepsDefaultMarkerAndRenamesOpenAIAPI() throws {
        let data = try ConfigFixtures.data("corpus/legacy-roster.json")
        var tree = try #require(try OpenClawJSON5.parse(data).dictionaryValue)
        let changes = OpenClawConfigMigrator.migrate(&tree)
        #expect(changes.contains { $0.id == "runtime.agents-entries" })
        #expect(changes.contains { $0.id == "models.providers.api-openai->openai-completions" })

        let entries = try #require(tree["agents"]?.dictionaryValue?["entries"]?.dictionaryValue)
        #expect(entries["main"]?.dictionaryValue?["default"]?.boolValue == true)
        #expect(tree["agents"]?.dictionaryValue?["ownership"] == nil)
        let provider = tree["models"]?.dictionaryValue?["providers"]?.dictionaryValue?["openai"]?.dictionaryValue
        #expect(provider?["api"]?.stringValue == "openai-completions")

        let document = try OpenClawConfigDocument.decode(data)
        #expect(document.agents?.resolvedDefaultAgentID == "main")
        #expect(document.models?.providers?["openai"]?.modelAPI == .openAICompletions)
    }

    @Test
    func migrationTableKeepsUpstreamIdentifiers() {
        let ids = Set(OpenClawConfigMigrator.migrations.map(\.id))
        for expected in [
            "runtime.agents-entries", "runtime.agents-explicit-ownership", "memorySearch->memory.search",
            "gateway.tailscale.reset-on-exit-remove", "gateway.bind.host-alias->bind-mode", "mcp.servers.canonicalize",
            "tts.top-level-owner", "runtime.doctor-tier-eval-tranche", "runtime.final-layout-polish",
            "session.canonical-aliases", "defaultModel->agents.defaults.model",
        ] {
            #expect(ids.contains(expected), "missing migration \(expected)")
        }
        #expect(OpenClawConfigMigrator.migrations.contains { !$0.isApplied })
    }

    // MARK: Leniency

    @Test
    func unknownKeysAndMistypedLeavesRoundTrip() throws {
        let json = #"""
        {
          "futureRootKey": {"nested": [1, 2, {"deep": true}]},
          "gateway": {"port": "not-a-number", "mode": "satellite", "brandNew": 7},
          "session": {"dmScope": "per-galaxy", "maintenance": {"pruneAfter": "30d"}},
          "agents": {"defaults": {"thinkingDefault": "ULTRA", "fastModeDefault": "auto"},
                     "entries": {"main": {"model": {"primary": "openai/gpt-5.4", "fallbacks": ["anthropic/x"]}}}}
        }
        """#
        let collector = ConfigDecodeIssueCollector()
        let document = try OpenClawConfigDocument.decode(Data(json.utf8), issues: collector)
        #expect(document.additionalProperties["futureRootKey"] != nil)
        #expect(document.gateway?.port == nil)
        #expect(document.gateway?.additionalProperties["port"]?.stringValue == "not-a-number")
        #expect(document.gateway?.mode?.rawValue == "satellite")
        #expect(document.gateway?.mode?.isKnown == false)
        #expect(document.session?.dmScope?.isKnown == false)
        #expect(document.agents?.defaults?.thinkingDefault?.thinkLevel == .ultra)
        #expect(document.agents?.defaults?.fastModeDefault == .auto)
        #expect(document.agents?.entries?["main"]?.model?.primary == "openai/gpt-5.4")
        #expect(document.agents?.entries?["main"]?.model?.fallbacks == ["anthropic/x"])
        #expect(document.session?.maintenance?.pruneAfterMilliseconds == Int64(2_592_000_000))
        #expect(collector.issues.contains { $0.kind == .typeMismatch && $0.path == "gateway.port" })
        #expect(collector.issues.contains { $0.kind == .unknownEnumValue && $0.path == "gateway.mode" })

        let tree = try #require(try OpenClawJSON5.parse(Data(json.utf8)).dictionaryValue)
        var expected = tree
        // Think levels are lowercased like upstream; everything else round-trips unchanged.
        var agents = expected["agents"]?.dictionaryValue ?? [:]
        var defaults = agents["defaults"]?.dictionaryValue ?? [:]
        defaults["thinkingDefault"] = AnyCodable("ultra")
        agents["defaults"] = AnyCodable(defaults)
        expected["agents"] = AnyCodable(agents)
        #expect(document.jsonObject == expected)
    }

    @Test
    func secretValuesKeepAuthoredForms() throws {
        let json = #"""
        {
          "gateway": {"auth": {"mode": "token", "token": "${OPENCLAW_GATEWAY_TOKEN}"},
                      "remote": {"token": "$REMOTE_TOKEN", "password": {"source": "store", "id": "REMOTE_PASSWORD"}}},
          "models": {"providers": {"custom": {"baseUrl": "https://x.invalid/v1", "apiKey": "secretref-env:CUSTOM_KEY", "models": []}}}
        }
        """#
        let collector = ConfigDecodeIssueCollector()
        let document = try OpenClawConfigDocument.decode(Data(json.utf8), issues: collector)
        #expect(document.gateway?.auth?.token?.ref == SecretRef(source: .env, id: "OPENCLAW_GATEWAY_TOKEN"))
        #expect(document.gateway?.remote?.token?.ref == SecretRef(source: .env, id: "REMOTE_TOKEN"))
        #expect(document.gateway?.remote?.password?.ref == SecretRef(source: .store, id: "REMOTE_PASSWORD"))
        #expect(document.models?.providers?["custom"]?.apiKey?.ref == SecretRef(source: .env, id: "CUSTOM_KEY"))
        #expect(collector.issues.contains { $0.kind == .legacyKey && $0.path.hasSuffix("apiKey") })
        // Encoding keeps the authored strings.
        let tree = try #require(try OpenClawJSON5.parse(try document.encoded()).dictionaryValue)
        #expect(tree["gateway"]?.dictionaryValue?["auth"]?.dictionaryValue?["token"]?.stringValue == "${OPENCLAW_GATEWAY_TOKEN}")
    }

    // MARK: Talk contract

    /// Runs every case of the upstream `talk-config-contract.json` at the document layer:
    /// payloads round-trip losslessly, the schema's provider-selection refinements flag exactly
    /// the cases where upstream selection yields nothing, and `silenceTimeoutMs` only types
    /// integral numbers (anything else is preserved raw for the Talk consumer's fallback).
    @Test
    func talkContractFixtureCasesDecodeAtTheDocumentLayer() throws {
        let contract = try #require(try OpenClawJSON5.parse(try ConfigFixtures.data("talk-config-contract.json")).dictionaryValue)
        let selectionCases = try #require(contract["selectionCases"]?.arrayValue)
        let timeoutCases = try #require(contract["timeoutCases"]?.arrayValue)
        #expect(selectionCases.count == 4)
        #expect(timeoutCases.count == 6)

        for entry in selectionCases {
            let testCase = try #require(entry.dictionaryValue)
            let id = testCase["id"]?.stringValue ?? "?"
            let talkTree = try #require(testCase["talk"])
            let document = try OpenClawConfigDocument.decode(jsonObject: ["talk": talkTree], migrateLegacyKeys: false)
            let talk = try #require(document.talk, "\(id)")
            #expect(document.jsonObject["talk"] == talkTree, "\(id): talk payload must round-trip")
            let flagged = !talk.validationIssues().isEmpty
            let selectsNothing = testCase["expectedSelection"]?.isNull ?? true
            #expect(flagged == selectsNothing, "\(id): validation disagrees with upstream selection")
            if let expected = testCase["expectedSelection"]?.dictionaryValue, let provider = expected["provider"]?.stringValue {
                let entry = try #require(talk.providers?[provider], "\(id)")
                #expect(entry.additionalProperties["voiceId"] == expected["voiceId"], "\(id)")
                #expect(entry.apiKey?.plaintext == expected["apiKey"]?.stringValue, "\(id)")
            }
        }

        for entry in timeoutCases {
            let testCase = try #require(entry.dictionaryValue)
            let id = testCase["id"]?.stringValue ?? "?"
            let talkTree = try #require(testCase["talk"])
            let collector = ConfigDecodeIssueCollector()
            let document = try OpenClawConfigDocument.decode(jsonObject: ["talk": talkTree], migrateLegacyKeys: false, issues: collector)
            let talk = try #require(document.talk, "\(id)")
            let raw = talkTree.dictionaryValue?["silenceTimeoutMs"]
            let typed = talk.silenceTimeoutMs
            if testCase["expectedTimeoutMs"] != testCase["fallback"] {
                #expect(typed == testCase["expectedTimeoutMs"]?.intValue, "\(id)")
            } else if typed == nil {
                // Mistyped values stay in the document so a rewrite keeps what the user authored.
                #expect(talk.additionalProperties["silenceTimeoutMs"] == raw, "\(id)")
                #expect(collector.issues.contains { $0.path == "talk.silenceTimeoutMs" }, "\(id)")
            } else {
                // Integral but non-positive: typed as authored; the Talk consumer applies the fallback.
                #expect(typed == 0, "\(id)")
            }
            #expect(document.jsonObject["talk"]?.dictionaryValue?["silenceTimeoutMs"] == raw, "\(id)")
        }
    }

    // MARK: Duration and sizes

    @Test
    func durationParsingMatchesUpstream() {
        #expect(ConfigDuration.parseMilliseconds("500ms") == 500)
        #expect(ConfigDuration.parseMilliseconds("30s") == 30_000)
        #expect(ConfigDuration.parseMilliseconds("1h30m") == 5_400_000)
        #expect(ConfigDuration.parseMilliseconds("2m500ms") == 120_500)
        #expect(ConfigDuration.parseMilliseconds("7", defaultUnit: .days) == Int64(604_800_000))
        #expect(ConfigDuration.parseMilliseconds("1.5h") == 5_400_000)
        #expect(ConfigDuration.parseMilliseconds("0h") == 0)
        #expect(ConfigDuration.parseMilliseconds("1h30") == nil)
        #expect(ConfigDuration.parseMilliseconds("") == nil)
        #expect(ConfigDuration.parseMilliseconds("-5m") == nil)
        #expect(ConfigByteSize.parse("2mb") == 2_097_152)
        #expect(ConfigByteSize.parse("512") == 512)
        #expect(ConfigByteSize.parse("lots") == nil)
    }

    @Test
    func redactionSentinelsMatchWholeValues() {
        #expect(ConfigRedaction.isRedactedSecretValue("__OPENCLAW_REDACTED__"))
        #expect(ConfigRedaction.isRedactedSecretValue("  [REDACTED]  "))
        #expect(ConfigRedaction.isRedactedSecretValue("***"))
        #expect(!ConfigRedaction.isRedactedSecretValue("sk-REDACTED-live"))
        #expect(!ConfigRedaction.isRedactedSecretValue(nil as String?))
    }
}
