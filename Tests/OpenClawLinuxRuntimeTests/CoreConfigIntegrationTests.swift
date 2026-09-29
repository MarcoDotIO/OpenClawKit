import Foundation
import OpenClawProtocol
import Testing
@testable import OpenClawCore

@Suite("Core config integration (channels, audit, sections)")
struct CoreConfigIntegrationTests {
    // MARK: Security audit

    @Test
    func auditAppendsChannelFindingsWithoutDuplicatingChannelSecrets() {
        var channels = ChannelsConfig(
            telegram: TelegramChannelConfig(enabled: true, botToken: "123:plain", mentionOnly: true),
            bluebubbles: LegacyBlueBubblesChannelConfig(enabled: true, serverURL: "http://bb.local:1234", password: "bb-pass")
        )
        channels.extensionChannels["sms"] = AnyCodable(.object([
            "authToken": AnyCodable("sms-plain"),
            "accounts": AnyCodable(.object(["work": AnyCodable(.object(["authToken": AnyCodable("sms-work")]))])),
        ]))
        channels.msteams = MicrosoftTeamsChannelConfig(enabled: true, mentionOnly: true)
        channels.msteams.cloud = .usGov
        let report = SecurityAuditRunner.run(options: SecurityAuditOptions(config: OpenClawConfig(channels: channels)))

        let channelDetail = report.findings.first { $0.id == "channels.secrets.plaintext" }?.detail ?? ""
        #expect(channelDetail.contains("channels.telegram.botToken"))
        #expect(channelDetail.contains("channels.bluebubbles.password"))
        #expect(channelDetail.contains("channels.sms.authToken"))
        #expect(channelDetail.contains("channels.sms.accounts.work.authToken"))
        #expect(report.findings.contains { $0.id == "channels.bluebubbles.removed-upstream" && $0.severity == .info })
        #expect(report.findings.contains { $0.id == "channels.msteams.cloud-service-url" })
        // The SDK-native finding no longer repeats typed channel keys.
        let configDetail = report.findings.first { $0.id == "secrets.config.plaintext" }?.detail ?? ""
        #expect(!configDetail.contains("channels."))
    }

    @Test
    func auditNeverFlagsNonSecretProviderMarkers() throws {
        let config = OpenClawConfig(models: ModelsConfig(providers: [
            "apple-fm": ModelProviderConfig(enabled: true, baseURL: "http://127.0.0.1", apiKey: ModelAuthMarkers.appleFoundationModelsLocal),
            "ollama": ModelProviderConfig(enabled: true, baseURL: "http://127.0.0.1:11434", apiKey: "ollama-local"),
            "bedrock": ModelProviderConfig(enabled: true, baseURL: "https://bedrock.example.com", apiKey: "AWS_PROFILE", auth: .awsSDK, region: "us-east-1"),
            "codex": ModelProviderConfig(enabled: true, baseURL: "https://api.example.com", apiKey: "oauth:openai", auth: .oauth),
            "real": ModelProviderConfig(enabled: true, baseURL: "https://api.example.com", apiKey: "sk-real", auth: .apiKey),
        ]))
        let report = SecurityAuditRunner.run(options: SecurityAuditOptions(config: config))
        let detail = report.findings.first { $0.id == "secrets.config.plaintext" }?.detail ?? ""
        #expect(detail.contains("models.providers.real.apiKey"))
        for markerProvider in ["apple-fm", "ollama", "bedrock", "codex"] {
            #expect(!detail.contains("models.providers.\(markerProvider).apiKey"))
        }

        let document = try OpenClawConfigDocument.decode(Data(#"""
        {"models": {"providers": {"apple-fm": {"apiKey": "apple-fm-local"}, "x": {"apiKey": "sk-doc"}}},
         "channels": {"telegram": {"botToken": "doc-plain"}}}
        """#.utf8))
        let documentReport = SecurityAuditRunner.run(options: SecurityAuditOptions(document: document))
        let documentDetail = documentReport.findings.first { $0.id == "secrets.document.plaintext" }?.detail ?? ""
        #expect(documentDetail.contains("models.providers.x.apiKey"))
        #expect(!documentDetail.contains("apple-fm"))
        // Without an SDK-native config the document's channel blocks are audited directly.
        #expect(documentReport.findings.contains { $0.id == "channels.secrets.plaintext" && $0.detail.contains("channels.telegram.botToken") })
    }

    @Test
    func markerPolicyMatchesUpstreamVocabulary() {
        #expect(ModelAuthMarkers.isNonSecretMarker("apple-fm-local"))
        #expect(ModelAuthMarkers.isNonSecretMarker(" lmstudio-local "))
        #expect(ModelAuthMarkers.isNonSecretMarker("oauth:anthropic"))
        #expect(ModelAuthMarkers.isNonSecretMarker("secretref-env:OPENAI_API_KEY"))
        #expect(ModelAuthMarkers.isNonSecretMarker("secretref-managed"))
        #expect(ModelAuthMarkers.isNonSecretMarker("GOOGLE_API_KEY"))
        #expect(!ModelAuthMarkers.isNonSecretMarker("GOOGLE_API_KEY", includeEnvVarNames: false))
        #expect(!ModelAuthMarkers.isNonSecretMarker("sk-live-123"))
        #expect(!ModelAuthMarkers.isNonSecretMarker(""))
        #expect(!ModelAuthMarkers.isNonSecretMarker(nil))
    }

    // MARK: Channels document

    static let channelsJSON = #"""
    {
      "session": {"dmScope": "per-channel-peer", "legacyChannelAccountKeys": true},
      "messages": {"visibleReplies": "automatic",
                   "groupChat": {"unmentionedInbound": "room_event", "visibleReplies": false, "historyLimit": 20, "futureKnob": 1}},
      "channels": {
        "defaults": {"groupPolicy": "open"},
        "modelByChannel": {"telegram": {"-100": "openai/gpt-5.4"}},
        "telegram": {"enabled": true, "botToken": "${TELEGRAM_BOT_TOKEN}", "dmPolicy": "pairing", "customUpstreamKey": {"a": 1}},
        "whatsapp": {"allowFrom": ["+15555550123"]},
        "matrix": {"enabled": true, "homeserver": "https://matrix.example.com"}
      }
    }
    """#

    @Test
    func documentChannelsUseTheChannelsSliceDocument() throws {
        let document = try OpenClawConfigDocument.decode(Data(Self.channelsJSON.utf8))
        let channels = try #require(document.channels)
        #expect(Set(channels.channels.keys) == ["telegram", "whatsapp", "matrix"])
        #expect(channels.defaults?.groupPolicy == .open)
        #expect(channels.modelByChannel?["telegram"]?["-100"] == "openai/gpt-5.4")
        // Lossless: unmodeled keys inside channel blocks survive an encode/decode round trip.
        let reparsed = try OpenClawConfigDocument.decode(try document.encoded())
        #expect(reparsed.channels == document.channels)
        #expect(reparsed.channels?.channels["telegram"]?.raw["customUpstreamKey"] != nil)
    }

    @Test
    func importMapsChannelsCompatibilityAndGroupChat() throws {
        let document = try OpenClawConfigDocument.decode(Data(Self.channelsJSON.utf8))
        var base = OpenClawConfig()
        base.channels.webchat = WebChatChannelConfig(enabled: true, sharedSecret: "sdk-only")
        base.channels.discord = DiscordChannelConfig(enabled: true, botToken: "kept", mentionOnly: true)
        let config = OpenClawConfig(document: document, base: base)

        #expect(config.channels.telegram.enabled)
        #expect(config.channels.telegram.botTokenInput == .ref(SecretRef(source: .env, id: "TELEGRAM_BOT_TOKEN")))
        #expect(config.channels.extensionChannels["whatsapp"] != nil)
        #expect(config.channels.extensionChannels["matrix"] != nil)
        #expect(config.channels.defaults.groupPolicy == .open)
        #expect(config.channels.modelByChannel["telegram"]?["-100"] == "openai/gpt-5.4")
        // SDK-only sections and typed sections absent from the document keep the base values.
        #expect(config.channels.webchat.enabled)
        #expect(config.channels.discord.botToken == "kept")
        // session.legacyChannelAccountKeys → channels.compatibility.legacySessionAccountKeys.
        #expect(config.channels.compatibility.legacySessionAccountKeys)

        let groupChat = try #require(document.messages?.groupChat)
        #expect(groupChat.effectiveUnmentionedInbound == "room_event")
        #expect(groupChat.visibleRepliesMode == "message_tool")
        #expect(groupChat.historyLimit == 20)
        #expect(groupChat.additionalProperties["futureKnob"] != nil)
        #expect(document.messages?.groupVisibleRepliesMode == "message_tool")
        var withoutGroupOverride = try #require(document.messages)
        withoutGroupOverride.groupChat?.visibleReplies = nil
        #expect(withoutGroupOverride.groupVisibleRepliesMode == "automatic")
        #expect(OpenClawConfigDocument.Messages.GroupChat().effectiveUnmentionedInbound == "user_request")
    }

    @Test
    func projectionExportsChannelsThroughTheChannelsSlice() throws {
        let original = try OpenClawConfigDocument.decode(Data(Self.channelsJSON.utf8))
        var config = OpenClawConfig(document: original)
        config.channels.telegram.mentionOnly = false
        config.channels.whatsappCloud = WhatsAppCloudChannelConfig(enabled: true, accessToken: "sdk-only")
        config.channels.pluginChannels["legacy-plugin"] = PluginChannelConfig(enabled: true, config: ["room": "lobby"])
        let tree = config.documentProjection(preserving: original).jsonObject
        let channels = try #require(tree["channels"]?.dictionaryValue)
        let telegram = try #require(channels["telegram"]?.dictionaryValue)
        #expect(telegram["customUpstreamKey"] != nil)
        #expect(telegram["requireMention"] == nil)
        // The authored env template survives instead of becoming a SecretRef object.
        #expect(telegram["botToken"]?.stringValue == "${TELEGRAM_BOT_TOKEN}")
        #expect(telegram["groups"]?.dictionaryValue?["*"]?.dictionaryValue?["requireMention"]?.boolValue == false)
        #expect(channels["matrix"]?.dictionaryValue?["homeserver"]?.stringValue == "https://matrix.example.com")
        #expect(channels["whatsapp"] != nil)
        #expect(channels["whatsappCloud"] == nil)
        #expect(channels["pluginChannels"] == nil)
        #expect(channels["compatibility"] == nil)
        #expect(channels["legacy-plugin"]?.dictionaryValue?["room"]?.stringValue == "lobby")
        // SDK-only session keys never reach openclaw.json writes.
        var written = tree
        OpenClawConfigDocument.stripSDKOnlyKeys(from: &written)
        #expect(written["session"]?.dictionaryValue?["legacyChannelAccountKeys"] == nil)
    }

    @Test
    func channelValidationCoversTypedAndPluginBlocks() throws {
        let document = try OpenClawConfigDocument.decode(Data(#"""
        {"channels": {"discord": {"bindings": {"acp": {}}}, "matrix": {"dmPolicy": "allowlist"},
                      "telegram": {"allowFrom": [123], "dmPolicy": "open"}}}
        """#.utf8))
        let paths = Set(document.validationIssues().map(\.path))
        #expect(paths.contains("channels.discord.bindings.acp"))
        #expect(paths.contains("channels.matrix.allowFrom"))
        #expect(paths.contains("channels.telegram.allowFrom"))
    }

    // MARK: Models, auth and runtime sections

    @Test
    func catalogRefreshRoundTripsThroughBothModels() throws {
        let native = try JSONDecoder().decode(ModelsConfig.self, from: Data(#"{"catalogRefresh": {"enabled": true, "url": "https://catalog.example.com/models.json"}}"#.utf8))
        #expect(native.catalogRefresh == ModelCatalogRefreshConfig(enabled: true, url: "https://catalog.example.com/models.json"))
        #expect(native.catalogRefresh?.hasValidURL == true)
        let reencoded = try JSONDecoder().decode(ModelsConfig.self, from: try JSONEncoder().encode(native))
        #expect(reencoded.catalogRefresh == native.catalogRefresh)
        // A malformed section is dropped instead of failing ModelsConfig.
        let lenient = try JSONDecoder().decode(ModelsConfig.self, from: Data(#"{"catalogRefresh": "yes"}"#.utf8))
        #expect(lenient.catalogRefresh == nil)

        let document = try OpenClawConfigDocument.decode(Data(#"{"models": {"catalogRefresh": {"enabled": false}}}"#.utf8))
        let config = OpenClawConfig(document: document)
        #expect(config.models.catalogRefresh == ModelCatalogRefreshConfig(enabled: false))
        var changed = config
        changed.models.catalogRefresh = ModelCatalogRefreshConfig(enabled: true, url: "http://127.0.0.1:9000/c.json")
        let projected = changed.documentProjection(preserving: document)
        #expect(projected.models?.catalogRefreshConfig == changed.models.catalogRefresh)
    }

    @Test
    func unknownAuthModesRoundTripAndAreNeverSelected() throws {
        let collector = ConfigDecodeIssueCollector()
        let decoder = JSONDecoder()
        decoder.userInfo[.openClawConfigIssues] = collector
        let auth = try decoder.decode(AuthConfig.self, from: Data(#"""
        {"profiles": {"q": {"provider": "openai", "mode": "quantum"}, "k": {"provider": "openai", "mode": "api_key"}}}
        """#.utf8))
        let quantum = try #require(auth.profiles["q"])
        #expect(quantum.unrecognizedMode == "quantum")
        #expect(quantum.rawMode == "quantum")
        #expect(!quantum.isModeRecognized)
        #expect(auth.profiles["k"]?.isModeRecognized == true)
        #expect(collector.issues.contains { $0.kind == .unknownEnumValue })
        let encoded = try #require(ConfigTreeCoding.encodeObject(auth)["profiles"]?.dictionaryValue?["q"]?.dictionaryValue)
        #expect(encoded["mode"]?.stringValue == "quantum")

        let snapshot = AuthProfileStoreSnapshot(profiles: [
            "q": .init(provider: "openai", mode: .token),
            "k": .init(provider: "openai", mode: .apiKey),
        ])
        let order = AuthProfileResolver.resolveProfileOrder(provider: "openai", config: auth, snapshot: snapshot)
        #expect(order == ["k"])
    }

    @Test
    func upstreamRuntimeSectionsDecodeOnTheSDKConfigAndBridge() throws {
        let json = #"""
        {"mcp": {"servers": {"fs": {"command": "/usr/local/bin/mcp-fs", "args": ["--root", "/tmp"], "futureKey": 1}}},
         "skills": {"allowBundled": ["weather"], "entries": {"weather": {"enabled": false}}},
         "memory": {"search": {"enabled": true, "provider": "openai", "query": {"maxResults": 8}}},
         "plugins": {"entries": {"canvas": {"enabled": true, "config": {"host": {"enabled": false}}}}}}
        """#
        let native = try JSONDecoder().decode(OpenClawConfig.self, from: Data(json.utf8))
        #expect(native.mcp?.servers?["fs"]?.command == "/usr/local/bin/mcp-fs")
        #expect(native.mcp?.servers?["fs"]?.additionalProperties["futureKey"] != nil)
        #expect(native.skills?.isSkillEnabled("weather") == false)
        #expect(native.memory?.search?.enabled == true)
        #expect(native.plugins?.entries?["canvas"]?.config?["host"]?.dictionaryValue?["enabled"]?.boolValue == false)
        let roundTripped = try JSONDecoder().decode(OpenClawConfig.self, from: try JSONEncoder().encode(native))
        #expect(roundTripped == native)
        // Absent sections stay absent in the SDK-native file.
        let empty = ConfigTreeCoding.encodeObject(OpenClawConfig())
        #expect(empty["mcp"] == nil && empty["plugins"] == nil)
        // A malformed section is dropped instead of failing the whole config.
        let lenient = try JSONDecoder().decode(OpenClawConfig.self, from: Data(#"{"mcp": 7}"#.utf8))
        #expect(lenient.mcp == nil)

        let document = try OpenClawConfigDocument.decode(Data(json.utf8))
        let imported = OpenClawConfig(document: document)
        #expect(imported.mcp == document.mcp)
        #expect(imported.memory == document.memory)
        var changed = imported
        changed.skills?.entries?["weather"]?.enabled = true
        let projected = changed.documentProjection(preserving: document)
        #expect(projected.skills?.isSkillEnabled("weather") == true)
        #expect(projected.plugins == document.plugins)
        // Runtime bridges written against the document accept SDK-native configs too.
        let sections = native.runtimeSectionsDocument
        #expect(sections.mcp == native.mcp && sections.memory == native.memory)
        #expect(sections.agents == nil && sections.channels == nil)
    }

    @Test
    func routingSessionKeyFormatDrivesDerivedKeys() throws {
        let canonical = try JSONDecoder().decode(OpenClawConfig.self, from: Data(#"{"routing": {"sessionKeyFormat": "canonical"}}"#.utf8))
        #expect(canonical.routing.sessionKeyFormat == .canonical)
        let context = SessionRoutingContext(channel: "telegram", accountID: "work", peerID: "42")
        let key = SessionKeyResolver.derive(context: context, config: canonical)
        #expect(key.hasPrefix("agent:"))
        #expect(key == SessionKeyResolver.derive(context: context, config: canonical, format: .canonical))
        let legacy = OpenClawConfig()
        #expect(SessionKeyResolver.derive(context: context, config: legacy) == "telegram:work:42")
        // The default format is not written, so existing SDK files stay byte-stable.
        #expect(ConfigTreeCoding.encodeObject(legacy.routing)["sessionKeyFormat"] == nil)
        #expect(ConfigTreeCoding.encodeObject(canonical.routing)["sessionKeyFormat"]?.stringValue == "canonical")
        let unknown = try JSONDecoder().decode(RoutingConfig.self, from: Data(#"{"sessionKeyFormat": "galactic"}"#.utf8))
        #expect(unknown.sessionKeyFormat == .legacy)
    }

    @Test
    func legacyCanvasHostMigratesToTheCanvasPlugin() throws {
        let collector = ConfigDecodeIssueCollector()
        let document = try OpenClawConfigDocument.decode(
            Data(#"{"canvasHost": {"enabled": false, "root": "/tmp/canvas"}}"#.utf8),
            issues: collector
        )
        #expect(document.additionalProperties["canvasHost"] == nil)
        let host = document.plugins?.entries?["canvas"]?.config?["host"]?.dictionaryValue
        #expect(host?["enabled"]?.boolValue == false)
        #expect(host?["root"] == nil)
        #expect(collector.issues.contains { $0.path.hasPrefix("canvasHost") })
    }

    @Test
    func canvasHostMigrationKeepsPluginEnableAndDropsRetiredHostKeys() throws {
        let document = try OpenClawConfigDocument.decode(Data(#"""
        {"canvasHost": {"enabled": false, "port": 18793},
         "plugins": {"entries": {"canvas": {"config": {"host": {"enabled": true, "port": 1, "liveReload": true}, "keep": 1}}}}}
        """#.utf8))
        let config = document.plugins?.entries?["canvas"]?.config
        let host = config?["host"]?.dictionaryValue
        #expect(host?["enabled"]?.boolValue == true)
        #expect(host?["port"] == nil)
        #expect(host?["liveReload"] == nil)
        #expect(config?["keep"]?.intValue == 1)

        // Retired plugin host keys alone also migrate; a host without enabled is removed.
        let pluginOnly = try OpenClawConfigDocument.decode(Data(#"""
        {"plugins": {"entries": {"canvas": {"config": {"host": {"port": 1}}}}}}
        """#.utf8))
        #expect(pluginOnly.plugins?.entries?["canvas"]?.config?["host"] == nil)
    }

    @Test
    func canvasHostMigrationRetainsTemplateAndPopulatedRoots() throws {
        let template = try OpenClawConfigDocument.decode(Data(#"""
        {"canvasHost": {"root": "${CANVAS_ROOT}"}}
        """#.utf8))
        let templateHost = template.plugins?.entries?["canvas"]?.config?["host"]?.dictionaryValue
        #expect(templateHost?["root"]?.stringValue == "${CANVAS_ROOT}")
        #expect(templateHost?["enabled"] == nil)
        #expect(template.additionalProperties["canvasHost"] == nil)

        let legacyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-canvas-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: legacyRoot) }
        let empty = MigrationValue.string(legacyRoot.path)
        #expect(ConfigMigrationRules.shouldRetainLegacyCanvasRoot(empty) == false)
        try FileManager.default.createDirectory(
            at: legacyRoot.appendingPathComponent("documents/doc-1", isDirectory: true),
            withIntermediateDirectories: true
        )
        #expect(ConfigMigrationRules.shouldRetainLegacyCanvasRoot(empty))
        let populated = try OpenClawConfigDocument.decode(Data(
            #"{"canvasHost": {"enabled": true, "root": "\#(legacyRoot.path)"}}"#.utf8
        ))
        let populatedHost = populated.plugins?.entries?["canvas"]?.config?["host"]?.dictionaryValue
        #expect(populatedHost?["root"]?.stringValue == legacyRoot.path)
        #expect(populatedHost?["enabled"]?.boolValue == true)
    }

    // MARK: Gateway import and projection

    @Test
    func gatewayImportKeepsAuthoredValuesAndRoundTripsUnchanged() throws {
        let json = #"""
        {"gateway": {"port": 19001, "mode": "remote", "bind": "lan",
                     "auth": {"mode": "password", "password": "${GW_PW}", "rateLimit": {"maxAttempts": 1.5, "windowMs": 60000}},
                     "http": {"securityHeaders": {"strictTransportSecurity": false}},
                     "remote": {"url": "wss://gw.example.com"}}}
        """#
        let original = try OpenClawConfigDocument.decode(Data(json.utf8))
        let collector = ConfigDecodeIssueCollector()
        let config = OpenClawConfig(document: original, issues: collector)
        #expect(config.gateway.port == 19001)
        #expect(config.gateway.mode == .remote)
        #expect(config.gateway.bind == .lan)
        #expect(config.gateway.auth.mode == .password)
        #expect(config.gateway.http?.securityHeaders?.strictTransportSecurityDisabled == true)
        #expect(config.gateway.http?.securityHeaders?.strictTransportSecurity == nil)
        #expect(config.gateway.auth.rateLimit?.windowMs == 60000)
        // Only the malformed leaf is dropped, and it is reported.
        #expect(config.gateway.auth.rateLimit?.maxAttempts == nil)
        #expect(collector.issues.contains { $0.path.contains("maxAttempts") })

        // A no-change round trip keeps the authored gateway exactly.
        let projected = config.documentProjection(preserving: original)
        #expect(projected.jsonObject["gateway"] == original.jsonObject["gateway"])

        // A change writes only the changed key.
        var changed = config
        changed.gateway.port = 19002
        let changedGateway = try #require(changed.documentProjection(preserving: original).jsonObject["gateway"]?.dictionaryValue)
        #expect(changedGateway["port"] == AnyCodable(.int(19002)))
        #expect(changedGateway["mode"]?.stringValue == "remote")
        #expect(changedGateway["bind"]?.stringValue == "lan")
        #expect(changedGateway["auth"] == original.jsonObject["gateway"]?.dictionaryValue?["auth"])
        #expect(changedGateway["http"]?.dictionaryValue?["securityHeaders"]?.dictionaryValue?["strictTransportSecurity"]?.boolValue == false)

        // Removing a block in the SDK config removes it from the projection.
        var removed = config
        removed.gateway.remote = nil
        #expect(removed.documentProjection(preserving: original).jsonObject["gateway"]?.dictionaryValue?["remote"] == nil)
    }

    @Test
    func gatewayProjectionNeverAddsDefaultsTheDocumentOmitted() throws {
        let original = try OpenClawConfigDocument.decode(Data(#"{"gateway": {"auth": {"mode": "token", "token": "abc"}}}"#.utf8))
        let config = OpenClawConfig(document: original)
        let gateway = try #require(config.documentProjection(preserving: original).jsonObject["gateway"]?.dictionaryValue)
        #expect(gateway["mode"] == nil)
        #expect(gateway["port"] == nil)
        #expect(gateway["bind"] == nil)
        #expect(gateway == original.jsonObject["gateway"]?.dictionaryValue)
        // HSTS strings still round-trip through the SDK type.
        let headers = GatewayHTTPSecurityHeadersConfig(strictTransportSecurity: "max-age=31536000")
        let decoded = try JSONDecoder().decode(GatewayHTTPSecurityHeadersConfig.self, from: try JSONEncoder().encode(headers))
        #expect(decoded == headers)
    }

    @Test
    func malformedSectionLeavesAreReportedWithoutDroppingTheSection() throws {
        let json = #"{"gateway": {"port": "19001x", "mode": "remote"}, "secrets": {"defaults": {"env": 7, "file": "vault"}}}"#
        let original = try OpenClawConfigDocument.decode(Data(json.utf8))
        let collector = ConfigDecodeIssueCollector()
        let config = OpenClawConfig(document: original, issues: collector)
        #expect(config.gateway.mode == .remote)
        #expect(config.gateway.port == GatewayConfig.defaultPort)
        #expect(config.secrets.defaults.file == "vault")
        #expect(collector.issues.contains { $0.path.hasSuffix("port") })
        #expect(collector.issues.contains { $0.path.hasSuffix("env") })
        // The malformed authored port is kept on a no-change projection.
        #expect(config.documentProjection(preserving: original).jsonObject["gateway"] == original.jsonObject["gateway"])
    }
}
