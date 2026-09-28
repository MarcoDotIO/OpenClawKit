import Foundation
import OpenClawProtocol
import Testing
@testable import OpenClawCore

@Suite("Config document validation")
struct ConfigDocumentValidationTests {
    private static func issues(_ json: String) throws -> [ConfigDecodeIssue] {
        try OpenClawConfigDocument.decode(Data(json.utf8), migrateLegacyKeys: false).validationIssues()
    }

    @Test
    func rosterOwnershipRulesMatchUpstream() throws {
        let markerless = try Self.issues(#"{"agents": {"entries": {"main": {}, "ops": {}}}}"#)
        #expect(markerless.contains { $0.path == "agents.ownership" })
        #expect(try Self.issues(#"{"agents": {"ownership": "explicit", "entries": {"main": {}, "ops": {}}}}"#).isEmpty)
        let conflicting = try Self.issues(#"{"agents": {"ownership": "explicit", "entries": {"main": {"default": true}, "ops": {}}}}"#)
        #expect(conflicting.contains { $0.message.contains("cannot be combined") })
        let twoMarkers = try Self.issues(#"{"agents": {"entries": {"main": {"default": true}, "ops": {"default": true}}}}"#)
        #expect(twoMarkers.contains { $0.message.contains("at most one default") })
        let duplicate = try Self.issues(#"{"agents": {"ownership": "explicit", "entries": {"Main": {}, "main": {}}}}"#)
        #expect(duplicate.contains { $0.message.contains("resolve to the same agent id") })
        #expect(try Self.issues(#"{"agents": {"entries": {}}}"#).contains { $0.path == "agents.entries" })
        #expect(OpenClawConfigDocument.normalizeAgentID(" Research Team! ") == "research-team")
        #expect(OpenClawConfigDocument.normalizeAgentID("---") == "main")
        #expect(OpenClawConfigDocument.normalizeAgentID("Ops_1") == "ops_1")
    }

    @Test
    func gatewayRefinementsMatchUpstream() throws {
        let json = #"""
        {"gateway": {"port": 18789, "publicOrigin": "https://gw.example.com",
          "portals": {"ingress": {"domain": "example.com", "port": 18789}},
          "roles": {"default": "viewer", "definitions": {"admin": {"sessions": {"others": "write"}, "agents": "*", "scopes": ["operator.admin"]}}},
          "remote": {"edgeAuth": {"Connection": "x"}},
          "auth": {"mode": "trusted-proxy"}}}
        """#
        let issues = try Self.issues(json)
        let paths = Set(issues.map(\.path))
        #expect(paths.contains("gateway.portals.ingress.domain"))
        #expect(paths.contains("gateway.portals.ingress.port"))
        #expect(paths.contains("gateway.roles.default"))
        #expect(paths.contains("gateway.remote.edgeAuth"))
        #expect(paths.contains("gateway.auth.trustedProxy.userHeader"))
        #expect(paths.contains("gateway.trustedProxies"))
        let document = try OpenClawConfigDocument.decode(Data(json.utf8))
        #expect(document.gateway?.roles?.definitions?["admin"]?.allowsAllAgents == true)
        #expect(document.gateway?.roles?.definitions?["admin"]?.scopes == [.admin])
    }

    @Test
    func bindingsToolsAndExecRefinements() throws {
        let json = #"""
        {"bindings": [{"type": "acp", "agentId": "main", "match": {"channel": "discord"}}, {"type": "future", "agentId": "x"}],
         "tools": {"allow": ["read"], "alsoAllow": ["exec"], "exec": {"mode": "ask", "security": "allowlist", "ask": "on-miss"}},
         "agents": {"ownership": "explicit", "entries": {"main": {"tools": {"exec": {"mode": "full", "ask": "off"}}}, "ops": {}}}}
        """#
        let document = try OpenClawConfigDocument.decode(Data(json.utf8), migrateLegacyKeys: false)
        guard case .unknown = document.bindings?.last else {
            Issue.record("an unknown binding type should pass through")
            return
        }
        let issues = document.validationIssues()
        #expect(issues.contains { $0.path == "bindings[0].match.peer" })
        #expect(issues.contains { $0.path == "tools" && $0.message.contains("alsoAllow") })
        #expect(issues.contains { $0.path == "tools.exec" && $0.message.contains("use mode \"ask\"") })
        #expect(issues.contains { $0.path == "agents.entries.main.tools.exec" })
        #expect(document.tools?.exec?.effectivePolicy == ExecMode.ask.policy)
        // Encoding keeps the unknown binding verbatim.
        #expect(document.jsonObject["bindings"]?.arrayValue?.last?.dictionaryValue?["type"]?.stringValue == "future")
    }

    @Test
    func mcpChannelsTalkAndHooksRefinements() throws {
        let json = #"""
        {"mcp": {"servers": {"local": {"transport": "stdio"},
                             "remote": {"url": "https://x.invalid/mcp", "oauth": {"identity": "per-requester", "authProfileId": "p"}},
                             "legacy": {"command": "x", "connect_timeout": 5}}},
         "channels": {"telegram": {"dmPolicy": "open", "allowFrom": ["1"], "accounts": {"a": {}, "b": {}}},
                      "slack": {"dmPolicy": "allowlist", "defaultAccount": "missing", "accounts": {"x": {}}},
                      "discord": {"bindings": {"acp": []}}},
         "talk": {"provider": "acme", "providers": {"elevenlabs": {}}, "realtime": {"providers": {"a": {}, "b": {}}}},
         "hooks": {"mappings": [{"sessionMode": "persistent"}]}}
        """#
        let paths = Set(try Self.issues(json).map(\.path))
        #expect(paths.contains("mcp.servers.local.command"))
        #expect(paths.contains("mcp.servers.remote.oauth"))
        #expect(paths.contains("mcp.servers.remote.oauth.authProfileId"))
        #expect(paths.contains("mcp.servers.legacy.connect_timeout"))
        #expect(paths.contains("channels.telegram.allowFrom"))
        #expect(paths.contains("channels.telegram.defaultAccount"))
        #expect(paths.contains("channels.slack.allowFrom"))
        #expect(paths.contains("channels.slack.defaultAccount"))
        #expect(paths.contains("channels.discord.bindings.acp"))
        #expect(paths.contains("talk.provider"))
        #expect(paths.contains("talk.realtime.provider"))
        #expect(paths.contains("hooks.mappings[0].sessionKey"))
    }

    @Test
    func mcpTransportAliasesAndSessionRouting() throws {
        let document = try OpenClawConfigDocument.decode(Data(#"""
        {"mcp": {"servers": {"a": {"type": "http", "url": "https://x"}, "b": {"command": "npx"}, "c": {"url": "https://y"}}},
         "session": {"dmScope": "per-peer", "mainKey": "inbox", "maintenance": {"pruneAfter": 14}},
         "cron": {"sessionRetention": "12h"}}
        """#.utf8), migrateLegacyKeys: false)
        #expect(document.mcp?.servers?["a"]?.canonicalTransport == "streamable-http")
        #expect(document.mcp?.servers?["b"]?.canonicalTransport == "stdio")
        #expect(document.mcp?.servers?["c"]?.canonicalTransport == "streamable-http")
        let expectedRouting = RoutingConfig(defaultSessionKey: "inbox", includeChannelID: false, includeAccountID: false, includePeerID: true)
        #expect(document.session?.routingConfig == expectedRouting)
        #expect(document.session?.maintenance?.pruneAfterMilliseconds == Int64(1_209_600_000))
        #expect(document.cron?.sessionRetentionMilliseconds == Int64(43_200_000))
        // Migration renames the CLI alias for real writes.
        let migrated = try OpenClawConfigDocument.decode(try document.encoded())
        #expect(migrated.mcp?.servers?["a"]?.transport == "streamable-http")
        #expect(migrated.mcp?.servers?["a"]?.additionalProperties["type"] == nil)
    }
}
