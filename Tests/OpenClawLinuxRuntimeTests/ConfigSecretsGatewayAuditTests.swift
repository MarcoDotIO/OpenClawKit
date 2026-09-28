import Foundation
import OpenClawProtocol
import Testing
@testable import OpenClawCore

@Suite("Config secrets, gateway and audit 2026.9.6")
struct ConfigSecretsGatewayAuditTests {
    // MARK: Secrets

    @Test
    func secretInputAcceptsShorthandsAndRetiredMarkers() throws {
        let collector = ConfigDecodeIssueCollector()
        let decoder = JSONDecoder()
        decoder.userInfo[.openClawConfigIssues] = collector
        let payload = #"""
        ["$OPENAI_API_KEY", "${OPENAI_API_KEY}", "secretref-env:OPENAI_API_KEY", "__env__:OPENAI_API_KEY", "$lowercase", "plain"]
        """#
        let values = try decoder.decode([SecretInput].self, from: Data(payload.utf8))
        let envRef = SecretInput.ref(SecretRef(source: .env, id: "OPENAI_API_KEY"))
        #expect(Array(values.prefix(4)) == [envRef, envRef, envRef, envRef])
        #expect(values[4] == .string("$lowercase"))
        #expect(values[5] == .string("plain"))
        #expect(collector.issues.filter { $0.kind == .legacyKey }.count == 2)
        // Markers are never written back.
        let encoded = String(decoding: try JSONEncoder().encode(values[2]), as: UTF8.self)
        #expect(!encoded.contains("secretref-env"))
    }

    @Test
    func execIDsAcceptHashAndStoreIDsUseEnvGrammar() {
        #expect(SecretRef(source: .exec, id: "aws/secret#json_key").validationError() == nil)
        #expect(SecretRef(source: .exec, id: "vault/../x").validationError() != nil)
        #expect(SecretRef(source: .store, id: "OPENAI_API_KEY").validationError() == nil)
        #expect(SecretRef(source: .store, id: "openai").validationError() != nil)
    }

    @Test
    func execPluginIntegrationDecodesAndProjects() throws {
        let json = #"{"source": "exec", "pluginIntegration": {"pluginId": "onepassword", "integrationId": "vault"}}"#
        let provider = try JSONDecoder().decode(SecretProviderConfig.self, from: Data(json.utf8))
        guard case .exec(let exec) = provider else {
            Issue.record("expected an exec provider")
            return
        }
        #expect(exec.pluginIntegration?.pluginId == "onepassword")
        #expect(exec.validationErrors().isEmpty)
        let projected = ConfigTreeCoding.encodeObject(provider)
        #expect(projected["command"] != nil)
        let upstream = ConfigTreeCoding.encode(provider, projection: true).dictionaryValue ?? [:]
        #expect(Set(upstream.keys) == ["source", "pluginIntegration"])

        let manual = ExecSecretProviderConfig(command: "vault", args: Array(repeating: "x", count: 129), timeoutMs: 200_000, allowInsecurePath: true)
        #expect(manual.validationErrors().count >= 3)
        let manualProjection = ConfigTreeCoding.encode(SecretProviderConfig.exec(manual), projection: true).dictionaryValue ?? [:]
        #expect(manualProjection["allowInsecurePath"] == nil)
    }

    @Test
    func secretsProjectionDropsResolutionAndKeepsEgressProxy() {
        let secrets = SecretsConfig(egressProxy: SecretEgressProxyConfig(enabled: true, allowedHosts: ["api.openai.com"]))
        let upstream = ConfigTreeCoding.encode(secrets, projection: true).dictionaryValue ?? [:]
        #expect(upstream["resolution"] == nil)
        #expect(upstream["egressProxy"]?.dictionaryValue?["enabled"]?.boolValue == true)
        #expect(ConfigTreeCoding.encodeObject(secrets)["resolution"] != nil)
    }

    @Test
    func defaultResolverHandlesEnvFileAndStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("openclawkit-secret-resolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let jsonFile = directory.appendingPathComponent("secrets.json")
        try Data(#"{"providers": {"openai": {"apiKey": "sk-file"}}, "a/b": {"c~d": "escaped"}}"#.utf8).write(to: jsonFile)
        let singleFile = directory.appendingPathComponent("token.txt")
        try Data("single-value\n".utf8).write(to: singleFile)
        let store = FileCredentialStore(fileURL: directory.appendingPathComponent("credentials.json"))
        try await store.saveSecret("store-value", for: "GATEWAY_TOKEN")

        let config = SecretsConfig(
            providers: [
                "default": .env(EnvSecretProviderConfig(allowlist: ["ALLOWED"])),
                "mounted": .file(FileSecretProviderConfig(path: jsonFile.path)),
                "single": .file(FileSecretProviderConfig(path: singleFile.path, mode: .singleValue)),
            ],
            defaults: SecretDefaultsConfig(file: "mounted")
        )
        let resolver = DefaultSecretRefResolver(environment: ["ALLOWED": "env-value", "BLOCKED": "nope"], credentialStore: store)
        #expect(try await resolver.resolve(SecretRef(source: .env, id: "ALLOWED"), config: config) == "env-value")
        await #expect(throws: OpenClawCoreError.self) {
            _ = try await resolver.resolve(SecretRef(source: .env, id: "BLOCKED"), config: config)
        }
        // The implicit default alias falls back to secrets.defaults.file.
        #expect(try await resolver.resolve(SecretRef(source: .file, id: "/providers/openai/apiKey"), config: config) == "sk-file")
        #expect(try await resolver.resolve(SecretRef(source: .file, provider: "mounted", id: "/a~1b/c~0d"), config: config) == "escaped")
        #expect(try await resolver.resolve(SecretRef(source: .file, provider: "single", id: "value"), config: config) == "single-value")
        #expect(try await resolver.resolve(SecretRef(source: .store, id: "GATEWAY_TOKEN"), config: config) == "store-value")
        #expect(try await resolver.resolve(SecretInput.string("literal"), config: config) == "literal")
    }

    #if os(macOS) || os(Linux)
    @Test
    func execResolverRunsTheJSONProtocol() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("openclawkit-exec-resolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("resolver.sh")
        let body = """
        #!/bin/sh
        cat >/dev/null
        printf '{"protocolVersion":1,"values":{"vault/openai#key":"%s"}}' "$SECRET_SUFFIX"

        """
        try Data(body.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: script.path)
        let config = SecretsConfig(providers: [
            "vault": .exec(ExecSecretProviderConfig(command: script.path, env: ["SECRET_SUFFIX": "from-exec"], trustedDirs: [directory.path])),
        ])
        let resolver = DefaultSecretRefResolver(environment: [:])
        let value = try await resolver.resolve(SecretRef(source: .exec, provider: "vault", id: "vault/openai#key"), config: config)
        #expect(value == "from-exec")
    }
    #endif

    // MARK: Gateway

    @Test
    func gatewayProjectionOmitsSDKOnlyAndRetiredKeys() throws {
        var gateway = GatewayConfig(
            host: "0.0.0.0",
            controlUi: GatewayControlUIConfig(enabled: true, allowInsecureAuth: true, dangerouslyDisableDeviceAuth: true),
            tailscale: GatewayTailscaleConfig(mode: .serve, resetOnExit: true),
            remote: GatewayRemoteConfig(enabled: true, url: "wss://x.example.com", edgeAuth: ["X-Edge": .string("t")]),
            http: GatewayHTTPConfig(endpoints: GatewayHTTPEndpointsConfig(
                chatCompletions: GatewayHTTPChatCompletionsConfig(enabled: true, maxBodyBytes: 1),
                responses: GatewayHTTPResponsesConfig(enabled: true, maxBodyBytes: 2, maxURLParts: 3)
            )),
            channelHealthCheckMinutes: 9,
            reload: .hybrid,
            handshakeTimeoutMs: 5_000
        )
        gateway.nodes = GatewayNodesConfig(allowSkills: false, commands: GatewayNodeCommandsConfig(deny: ["system.run"]))
        let upstream = ConfigTreeCoding.encode(gateway, projection: true).dictionaryValue ?? [:]
        for key in ["host", "authMode", "channelHealthCheckMinutes", "handshakeTimeoutMs", "trustedProxies", "allowRealIpFallback"] {
            #expect(upstream[key] == nil, "\(key) leaked into the projection")
        }
        #expect(upstream["controlUi"]?.dictionaryValue?["allowInsecureAuth"] == nil)
        #expect(upstream["controlUi"]?.dictionaryValue?["dangerouslyDisableDeviceAuth"] == nil)
        #expect(upstream["tailscale"]?.dictionaryValue?["resetOnExit"] == nil)
        #expect(upstream["remote"]?.dictionaryValue?["enabled"] == nil)
        #expect(upstream["reload"]?.dictionaryValue?["mode"]?.stringValue == "hybrid")
        let endpoints = upstream["http"]?.dictionaryValue?["endpoints"]?.dictionaryValue
        #expect(endpoints?["chatCompletions"]?.dictionaryValue?["maxBodyBytes"] == nil)
        #expect(endpoints?["responses"]?.dictionaryValue?["maxBodyBytes"] == nil)
        #expect(endpoints?["responses"]?.dictionaryValue?["maxUrlParts"]?.intValue == 3)
        #expect(upstream["nodes"]?.dictionaryValue?["commands"]?.dictionaryValue?["deny"]?.arrayValue?.count == 1)

        // The SDK-native file keeps everything.
        let native = ConfigTreeCoding.encodeObject(gateway)
        #expect(native["host"]?.stringValue == "0.0.0.0")
        #expect(native["channelHealthCheckMinutes"]?.intValue == 9)
        let decoded = try ConfigTreeCoding.decode(GatewayConfig.self, from: AnyCodable(.object(native)), issues: nil)
        #expect(decoded == gateway)
        // Upstream-only decode path through the document gateway validates cleanly.
        let document = try OpenClawConfigDocument.Gateway(jsonObject: upstream)
        #expect(document.validationIssues().isEmpty)
    }

    @Test
    func gatewayDecodesRetiredNodeAndReloadSpellings() throws {
        let json = #"{"nodes": {"denyCommands": ["system.run"], "skills": {"enabled": false}}, "reload": {"mode": "restart"}, "handshakeTimeoutMs": 4000}"#
        let collector = ConfigDecodeIssueCollector()
        let decoder = JSONDecoder()
        decoder.userInfo[.openClawConfigIssues] = collector
        let gateway = try decoder.decode(GatewayConfig.self, from: Data(json.utf8))
        #expect(gateway.nodes?.commands?.deny == ["system.run"])
        #expect(gateway.nodes?.allowSkills == false)
        #expect(gateway.reload == .hybrid)
        #expect(gateway.handshakeTimeoutMs == 4_000)
        #expect(gateway.effectiveHandshakeTimeoutMs(environment: ["OPENCLAW_HANDSHAKE_TIMEOUT_MS": "9000"]) == 9_000)
        #expect(gateway.effectiveHandshakeTimeoutMs(environment: [:]) == 4_000)
        #expect(collector.issues.contains { $0.kind == .legacyKey })
    }

    @Test
    func gatewayValidationCoversSecretsOriginsAndEdgeAuth() {
        var gateway = GatewayConfig(auth: .plaintext(mode: .token, token: "changeme"))
        gateway.publicOrigin = "http://gw.example.com"
        gateway.remote = GatewayRemoteConfig(edgeAuth: ["Host": .string("x"), "x-edge": .string("y")])
        let errors = gateway.validationErrors()
        #expect(errors.contains { $0.contains("placeholder") })
        #expect(errors.contains { $0.contains("publicOrigin") })
        #expect(errors.contains { $0.contains("transport-owned") })
        #expect(GatewayEdgeAuthHeaders.validationError(["X-A", "x-a"])?.contains("differ only by case") == true)
        #expect(GatewayEdgeAuthHeaders.validationError(["bad header"]) != nil)
        #expect(GatewayEdgeAuthHeaders.validationError([]) != nil)
        #expect(GatewayEdgeAuthHeaders.validationError(["CF-Access-Client-Id"]) == nil)
        #expect(GatewayConfig.isValidPublicOrigin("https://gw.example.com"))
        #expect(GatewayConfig.isValidPublicOrigin("http://127.0.0.1:18789"))
        #expect(!GatewayConfig.isValidPublicOrigin("https://gw.example.com/path"))
    }

    @Test
    func sharedSecretPolicyRejectsPlaceholdersAndComparesInConstantTime() {
        #expect(GatewaySharedSecretPolicy.evaluate("  ") == .placeholder)
        #expect(GatewaySharedSecretPolicy.evaluate("ChangeMe") == .placeholder)
        #expect(GatewaySharedSecretPolicy.evaluate("__OPENCLAW_REDACTED__") == .placeholder)
        #expect(GatewaySharedSecretPolicy.evaluate("short-secret") == .weak)
        #expect(GatewaySharedSecretPolicy.evaluate("7c1d0f5e9a8b4c3d2e1f0a9b8c7d6e5f") == .acceptable)
        #expect(GatewaySharedSecretPolicy.constantTimeEquals("abc", "abc"))
        #expect(!GatewaySharedSecretPolicy.constantTimeEquals("abc", "abd"))
        #expect(!GatewaySharedSecretPolicy.constantTimeEquals("abc", "abcd"))
        #expect(GatewaySharedSecretPolicy.presentedSecret(mode: .token, token: nil, password: "p") == "p")
        #expect(GatewaySharedSecretPolicy.presentedSecret(mode: .password, token: "t", password: "p") == "p")
        #expect(GatewaySharedSecretPolicy.presentedSecret(mode: .token, token: "t", password: "p") == "t")
        #expect(GatewayAuthConfig.plaintext(mode: .password, token: "t").sharedSecret == .string("t"))
    }

    // MARK: Audit

    @Test
    func auditSuppressionsMoveMatchingFindingsAside() throws {
        let config = OpenClawConfig(gateway: GatewayConfig(auth: .plaintext(mode: .none)))
        let suppression = SecurityAuditSuppression(checkID: "gateway.auth-mode-unsafe", detailIncludes: "NONE", reason: "loopback lab")
        let report = SecurityAuditRunner.run(options: SecurityAuditOptions(config: config, suppressions: [suppression]))
        #expect(!report.findings.contains { $0.id == "gateway.auth-mode-unsafe" })
        #expect(report.suppressedFindings.map(\.id) == ["gateway.auth-mode-unsafe"])
        #expect(!SecurityAuditSuppression(checkID: "gateway.auth-mode-unsafe", titleIncludes: "nothing like this").matches(report.suppressedFindings[0]))

        // Reports written before suppressions existed still decode.
        let legacy = #"{"generatedAt": 0, "findings": []}"#
        let decoded = try JSONDecoder().decode(SecurityAuditReport.self, from: Data(legacy.utf8))
        #expect(decoded.suppressedFindings.isEmpty)
    }

    @Test
    func auditScansDocumentSecretPathsAndHonorsDocumentSuppressions() throws {
        let json = #"""
        {
          "gateway": {"controlUi": {"github": {"token": "ghp_plain"}}, "remote": {"edgeAuth": {"X-Edge": "edge-plain", "X-Ref": "${EDGE}"}}},
          "skills": {"entries": {"s": {"apiKey": "sk-skill"}}},
          "talk": {"providers": {"elevenlabs": {"apiKey": "__OPENCLAW_REDACTED__"}}},
          "hooks": {"token": "hook-plain"},
          "security": {"audit": {"suppressions": [{"checkId": "gateway.auth-mode-unsafe"}]}}
        }
        """#
        let document = try OpenClawConfigDocument.decode(Data(json.utf8))
        let report = SecurityAuditRunner.run(options: SecurityAuditOptions(
            config: OpenClawConfig(gateway: GatewayConfig(auth: .plaintext(mode: .none))),
            document: document
        ))
        let detail = report.findings.first { $0.id == "secrets.document.plaintext" }?.detail ?? ""
        #expect(detail.contains("gateway.controlUi.github.token"))
        #expect(detail.contains("gateway.remote.edgeAuth.X-Edge"))
        #expect(!detail.contains("X-Ref"))
        #expect(detail.contains("skills.entries.s.apiKey"))
        #expect(!detail.contains("talk.providers"))
        #expect(detail.contains("hooks.token"))
        #expect(report.suppressedFindings.contains { $0.id == "gateway.auth-mode-unsafe" })
    }

    @Test
    func auditFlagsPlaceholderAndWeakGatewaySecrets() {
        let placeholder = SecurityAuditRunner.run(options: SecurityAuditOptions(
            config: OpenClawConfig(gateway: GatewayConfig(auth: .plaintext(mode: .token, token: "your-token")))
        ))
        #expect(placeholder.findings.contains { $0.id == "gateway.auth.secret-placeholder" && $0.severity == .error })
        let weak = SecurityAuditRunner.run(options: SecurityAuditOptions(
            config: OpenClawConfig(gateway: GatewayConfig(auth: .plaintext(mode: .password, password: "hunter2x")))
        ))
        #expect(weak.findings.contains { $0.id == "gateway.auth.secret-weak" })
    }

    // MARK: Auth

    @Test
    func authProfilesCarryDisplayNameAndInt64Timestamps() throws {
        let json = #"{"profiles": {"a": {"provider": "openai", "mode": "oauth", "displayName": "Work"}}, "order": {}, "cooldowns": {"billingMaxHours": 3}}"#
        let auth = try JSONDecoder().decode(AuthConfig.self, from: Data(json.utf8))
        #expect(auth.profiles["a"]?.displayName == "Work")
        let upstream = ConfigTreeCoding.encode(auth, projection: true).dictionaryValue ?? [:]
        #expect(upstream["cooldowns"] == nil)
        #expect(ConfigTreeCoding.encodeObject(auth)["cooldowns"] != nil)

        let stats = try JSONDecoder().decode(AuthProfileUsageStats.self, from: Data(#"{"lastUsed": 4102444800000, "cooldownUntil": 4102444800001}"#.utf8))
        #expect(stats.lastUsed == Int64(4_102_444_800_000))
        #expect(stats.cooldownUntil == Int64(4_102_444_800_001))
    }
}
