import Foundation
import OpenClawProtocol
import Testing
@testable import OpenClawCore

@Suite("Config document bridge")
struct ConfigDocumentBridgeTests {
    static let upstreamJSON = #"""
    {
      "meta": {"lastTouchedVersion": "2026.9.6"},
      "secrets": {"providers": {"vault": {"source": "exec", "pluginIntegration": {"pluginId": "onepassword", "integrationId": "vault"}}},
                  "defaults": {"exec": "vault"}, "egressProxy": {"enabled": true, "allowedHosts": ["api.openai.com"]}},
      "auth": {"profiles": {"aws:default": {"provider": "amazon-bedrock", "mode": "aws-sdk", "displayName": "AWS"},
                            "future:x": {"provider": "future", "mode": "quantum"}},
               "order": {"amazon-bedrock": ["aws:default"]}},
      "models": {"mode": "replace", "providers": {
        "custom": {"baseUrl": "https://llm.example.com/v1", "api": "pi-messages",
                   "apiKey": {"source": "store", "id": "CUSTOM_KEY"}, "models": [{"id": "m1", "name": "M1"}]}}},
      "agents": {"defaults": {"workspace": "~/ws", "model": {"primary": "custom/m1", "fallbacks": ["openai/gpt-5.4"]},
                              "thinkingDefault": "ultra", "verboseDefault": "full", "elevatedDefault": "ask", "futureKnob": {"x": 1}},
                 "ownership": "explicit",
                 "entries": {"main": {"name": "Main"}, "research": {"model": "anthropic/claude-opus-4-6"}}},
      "bindings": [
        {"agentId": "research", "match": {"channel": "telegram", "accountId": "work", "peer": {"kind": "direct", "id": "42"}}},
        {"agentId": "main", "match": {"channel": "slack", "accountId": "*"}},
        {"agentId": "main", "match": {"channel": "discord", "guildId": "g1"}},
        {"type": "acp", "agentId": "research", "match": {"channel": "discord", "peer": {"kind": "channel", "id": "c1"}}}
      ],
      "tools": {"exec": {"host": "gateway", "mode": "auto", "node": "mac-mini"}, "profile": "coding"},
      "messages": {"responseUsage": "on"},
      "session": {"dmScope": "per-channel-peer", "mainKey": "home", "sendPolicy": {"default": "deny"}},
      "gateway": {"port": 18800, "mode": "remote", "bind": "lan", "auth": {"mode": "token", "token": "${GATEWAY_TOKEN}"},
                  "remote": {"url": "wss://gw.example.com", "remotePort": 18789, "sshHostKeyPolicy": "strict",
                             "edgeAuth": {"CF-Access-Client-Id": {"source": "env", "id": "CF_ID"}}},
                  "nodes": {"commands": {"deny": ["system.run"]}}, "publicOrigin": "https://gw.example.com"},
      "channels": {"defaults": {"groupPolicy": "allowlist"}, "telegram": {"enabled": true},
                   "matrix": {"enabled": true, "homeserver": "https://matrix.example.com", "limit": 5}}
    }
    """#

    @Test
    func importsUpstreamDocumentOntoSDKConfig() throws {
        let document = try OpenClawConfigDocument.decode(Data(Self.upstreamJSON.utf8))
        var base = OpenClawConfig()
        base.gateway.host = "10.0.0.5"
        base.agents.skillInvocationTimeoutMs = 12_000
        let collector = ConfigDecodeIssueCollector()
        let config = OpenClawConfig(document: document, base: base, issues: collector)

        // Secrets
        guard case .exec(let vault)? = config.secrets.providers["vault"] else {
            Issue.record("expected the plugin-integration exec provider")
            return
        }
        #expect(vault.pluginIntegration == ExecSecretPluginIntegration(pluginId: "onepassword", integrationId: "vault"))
        #expect(config.secrets.defaults.exec == "vault")
        #expect(config.secrets.egressProxy?.allowedHosts == ["api.openai.com"])
        // Gateway (SDK-local host preserved)
        #expect(config.gateway.host == "10.0.0.5")
        #expect(config.gateway.port == 18_800)
        #expect(config.gateway.mode == .remote)
        #expect(config.gateway.bind == .lan)
        #expect(config.gateway.auth.token == .ref(SecretRef(source: .env, id: "GATEWAY_TOKEN")))
        #expect(config.gateway.remote?.remotePort == 18_789)
        #expect(config.gateway.remote?.sshHostKeyPolicy == .strict)
        #expect(config.gateway.remote?.edgeAuth?["CF-Access-Client-Id"] == .ref(SecretRef(source: .env, id: "CF_ID")))
        #expect(config.gateway.nodes?.commands?.deny == ["system.run"])
        #expect(config.gateway.publicOrigin == "https://gw.example.com")
        // Auth
        #expect(config.auth.profiles["aws:default"] == AuthProfileConfig(provider: "amazon-bedrock", mode: .awsSDK, displayName: "AWS"))
        // Unknown modes are kept raw (and never selected) instead of being dropped.
        #expect(config.auth.profiles["future:x"]?.unrecognizedMode == "quantum")
        #expect(config.auth.profiles["future:x"]?.isModeRecognized == false)
        #expect(config.auth.order["amazon-bedrock"] == ["aws:default"])
        // Models
        #expect(config.models.mode == .replace)
        #expect(config.models.providers["custom"]?.baseURL == "https://llm.example.com/v1")
        #expect(config.models.providers["custom"]?.api == .piMessages)
        #expect(config.models.providers["custom"]?.enabled == true)
        // Agents
        #expect(config.agents.workspaceRoot == "~/ws")
        #expect(config.agents.modelOverride == "custom/m1")
        #expect(config.agents.thinkingLevel == .ultra)
        #expect(config.agents.verboseLevel == .full)
        #expect(config.agents.elevatedLevel == .ask)
        #expect(config.agents.responseUsage == .tokens)
        #expect(config.agents.execHost == .gateway)
        #expect(config.agents.execNode == "mac-mini")
        #expect(config.agents.execSecurity == .allowlist)
        #expect(config.agents.execAsk == .onMiss)
        #expect(config.agents.sendPolicy == .deny)
        #expect(Set(config.agents.agentIDs) == ["main", "research"])
        #expect(config.agents.defaultAgentID == "main")
        #expect(config.agents.skillInvocationTimeoutMs == 12_000)
        #expect(config.agents.routeAgentMap == ["telegram:work:42": "research", "slack": "main"])
        // Routing
        #expect(config.routing == RoutingConfig(defaultSessionKey: "home", includeChannelID: true, includeAccountID: false, includePeerID: true))
        // Unexpressible bindings and the unknown auth mode are reported.
        #expect(collector.issues.contains { $0.path == "bindings[2].match" })
        #expect(collector.issues.contains { $0.path == "auth.profiles.future:x" })
    }

    @Test
    func importsChannelsThroughTheChannelsSlice() throws {
        let document = try OpenClawConfigDocument.decode(Data(Self.upstreamJSON.utf8))
        let channels = OpenClawConfig(document: document).channels
        // Typed sections decode from their blocks; plugin blocks stay raw extension channels.
        #expect(channels.telegram.enabled == true)
        #expect(channels.defaults.groupPolicy == .allowlist)
        #expect(channels.rawSection(named: "matrix")?["homeserver"]?.stringValue == "https://matrix.example.com")
        #expect(channels.rawSection(named: "matrix")?["limit"]?.intValue == 5)
        #expect(channels.isChannelEnabled("matrix"))
        #expect(channels.pluginChannels.isEmpty)
        #expect(channels.extensionChannels["telegram"] == nil)
    }

    @Test
    func projectionMergesOverOriginalAndKeepsSDKOnlyKeysOut() throws {
        let original = try OpenClawConfigDocument.decode(Data(Self.upstreamJSON.utf8))
        var config = OpenClawConfig(document: original)
        config.gateway.port = 19_000
        config.agents.routeAgentMap["telegram:work:42"] = "main"
        config.agents.execSecurity = .full
        config.agents.execAsk = .always
        config.routing = RoutingConfig(defaultSessionKey: "home", includeChannelID: true, includeAccountID: true, includePeerID: true)

        let projected = config.documentProjection(preserving: original)
        let tree = projected.jsonObject
        #expect(tree["routing"] == nil)
        #expect(tree["runtime"] == nil)
        let gateway = try #require(tree["gateway"]?.dictionaryValue)
        #expect(gateway["port"]?.intValue == 19_000)
        #expect(gateway["host"] == nil)
        #expect(gateway["authMode"] == nil)
        #expect(gateway["channelHealthCheckMinutes"] == nil)
        // The authored `${GATEWAY_TOKEN}` string survives the round trip.
        #expect(gateway["auth"]?.dictionaryValue?["token"]?.stringValue == "${GATEWAY_TOKEN}")
        #expect(tree["secrets"]?.dictionaryValue?["resolution"] == nil)
        #expect(tree["auth"]?.dictionaryValue?["cooldowns"] == nil)
        // Passthrough data from the original survives.
        #expect(tree["agents"]?.dictionaryValue?["defaults"]?.dictionaryValue?["futureKnob"] != nil)
        #expect(tree["meta"]?.dictionaryValue?["lastTouchedVersion"]?.stringValue == "2026.9.6")
        // Exec pair without an exact mode keeps the legacy fields (never combined with mode).
        let exec = try #require(tree["tools"]?.dictionaryValue?["exec"]?.dictionaryValue)
        #expect(exec["mode"] == nil)
        #expect(exec["security"]?.stringValue == "full")
        #expect(exec["ask"]?.stringValue == "always")
        #expect(projected.session?.dmScope == .perAccountChannelPeer)
        // Bindings: regenerated route bindings plus the unexpressible originals.
        let bindings = projected.bindings ?? []
        var issues: [ConfigDecodeIssue] = []
        #expect(OpenClawConfigDocument.routeAgentMap(from: bindings, issues: &issues) == config.agents.routeAgentMap)
        #expect(bindings.contains { if case .acp = $0 { return true } else { return false } })
        #expect(bindings.contains { $0.match?.guildId == "g1" })
        // Models: upstream keys only.
        let provider = try #require(tree["models"]?.dictionaryValue?["providers"]?.dictionaryValue?["custom"]?.dictionaryValue)
        #expect(provider["baseUrl"]?.stringValue == "https://llm.example.com/v1")
        #expect(provider["baseURL"] == nil)
        #expect(provider["enabled"] == nil)
        #expect(provider["chatCompletionsPath"] == nil)
        #expect(projected.validationIssues().filter { $0.path.hasPrefix("gateway") }.isEmpty)
    }

    @Test
    func defaultSDKConfigProjectsToAMinimalDocument() {
        let projected = OpenClawConfig().documentProjection()
        let tree = projected.jsonObject
        #expect(tree["gateway"] == nil)
        #expect(tree["secrets"] == nil)
        #expect(tree["routing"] == nil)
        #expect(projected.agents?.entries?["main"] != nil)
    }

    @Test
    func sdkNativeDecodeToleratesUpstream2026_9_6Vocabulary() throws {
        // Regression: a single unknown enum value used to fail OpenClawConfig decoding entirely.
        let json = #"""
        {
          "agents": {"thinkingLevel": "ultra", "execHost": "quantum", "verboseLevel": "loud"},
          "auth": {"profiles": {"aws": {"provider": "amazon-bedrock", "mode": "aws-sdk", "displayName": "AWS"}}},
          "models": {"providers": {"pi": {"baseURL": "https://pi.example.com", "api": "pi-messages"}}},
          "gateway": {"auth": {"mode": "token", "token": {"source": "store", "id": "GATEWAY_TOKEN"}}, "mode": "satellite",
                      "remote": {"transport": "carrier-pigeon", "edgeAuth": {"X-Edge": "$EDGE_TOKEN"}}},
          "secrets": {"providers": {"shared": {"source": "store"}, "vault": {"source": "exec", "command": "/usr/bin/vault", "future": 1}}}
        }
        """#
        let result = try ConfigDecodeIssueCollector.decode(OpenClawConfig.self, from: Data(json.utf8))
        let config = result.value
        #expect(config.agents.thinkingLevel == .ultra)
        #expect(config.agents.execHost == nil)
        #expect(config.auth.profiles["aws"]?.mode == .awsSDK)
        #expect(config.auth.profiles["aws"]?.displayName == "AWS")
        #expect(config.models.providers["pi"]?.api == .piMessages)
        #expect(config.gateway.auth.token == .ref(SecretRef(source: .store, id: "GATEWAY_TOKEN")))
        #expect(config.gateway.mode == .local)
        #expect(config.gateway.remote?.transport == nil)
        #expect(config.gateway.remote?.edgeAuth?["X-Edge"] == .ref(SecretRef(source: .env, id: "EDGE_TOKEN")))
        #expect(config.secrets.providers["shared"] == .store(StoreSecretProviderConfig()))
        #expect(result.issues.contains { $0.kind == .unknownEnumValue })
    }

    @Test
    func routeBindingProjectionRoundTrips() {
        let map = ["telegram": "main", "telegram:work": "ops", "telegram:work:42": "research"]
        let bindings = OpenClawConfigDocument.bindings(fromRouteAgentMap: map)
        #expect(bindings.first?.match?.peer?.id == "42")
        #expect(bindings.last?.match?.accountId == "*")
        var issues: [ConfigDecodeIssue] = []
        #expect(OpenClawConfigDocument.routeAgentMap(from: bindings, issues: &issues) == map)
        #expect(issues.isEmpty)
    }
}
