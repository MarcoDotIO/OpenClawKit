import Foundation
import Testing
@testable import OpenClawKit

struct LocalNetworkHostPolicyTests {
    @Test(arguments: [
        ("localhost", true),
        ("127.0.0.1", true),
        ("127.8.9.10", true),
        ("[::1]", true),
        ("::ffff:127.0.0.1", true),
        ("mac-studio.local", true),
        ("MAC-STUDIO.LOCAL.", true),
        ("10.1.2.3", true),
        ("172.16.0.1", true),
        ("172.31.255.255", true),
        ("192.168.1.20", true),
        ("169.254.10.10", true),
        ("fd12::1", true),
        ("[fc00::abcd]", true),
        ("[fe80::1%en0]", true),
        ("fe80::1%25en0", true),
        ("febf::1", true),
        // Tightened in 2026.3.0: tailnet, CGNAT and single-label names need TLS now.
        ("100.100.1.1", false),
        ("100.64.0.1", false),
        ("mybox", false),
        ("mybox.tail123.ts.net", false),
        ("gateway.tailscale.net", false),
        // Never local.
        ("172.32.0.1", false),
        ("8.8.8.8", false),
        ("gateway.example.com", false),
        ("127.example.com", false),
        ("fec0::1", false),
        ("2001:db8::1", false),
        ("", false),
        ("   ", false),
    ] as [(String, Bool)])
    func `strict policy classifies hosts like upstream`(host: String, expected: Bool) {
        #expect(LoopbackHost.isLocalNetworkHost(host, policy: .strict) == expected)
    }

    @Test func `default process policy is strict`() {
        #expect(LocalNetworkHostPolicy.current == .strict)
        #expect(!LoopbackHost.isLocalNetworkHost("mybox.tail123.ts.net"))
        #expect(!LoopbackHost.isLocalNetworkHost("100.100.1.1"))
        #expect(!LoopbackHost.isLocalNetworkHost("mybox"))
    }

    @Test func `legacy permissive policy restores tailnet and single-label hosts`() {
        let policy = LocalNetworkHostPolicy.legacyPermissive
        #expect(LoopbackHost.isLocalNetworkHost("mybox.tail123.ts.net", policy: policy))
        #expect(LoopbackHost.isLocalNetworkHost("gateway.tailscale.net", policy: policy))
        #expect(LoopbackHost.isLocalNetworkHost("100.100.1.1", policy: policy))
        #expect(LoopbackHost.isLocalNetworkHost("mybox", policy: policy))
        #expect(!LoopbackHost.isLocalNetworkHost("gateway.example.com", policy: policy))
        #expect(!LoopbackHost.isLocalNetworkHost("100.128.0.1", policy: policy))

        let tailnetOnly = LocalNetworkHostPolicy(allowsTailnetHosts: true)
        #expect(LoopbackHost.isLocalNetworkHost("mybox.tail123.ts.net", policy: tailnetOnly))
        #expect(!LoopbackHost.isLocalNetworkHost("mybox", policy: tailnetOnly))
    }

    @Test func `loopback detection never matches hostname prefixes`() {
        #expect(LoopbackHost.isLoopbackHost("127.0.0.1"))
        #expect(LoopbackHost.isLoopbackHost(" LOCALHOST. "))
        #expect(!LoopbackHost.isLoopbackHost("127.example.com"))
        #expect(!LoopbackHost.isLoopbackHost("localhost.example.com"))
        #expect(!LoopbackHost.isLoopbackHost("10.0.0.1"))
    }

    @Test func `normalized host strips brackets zones and trailing dots`() {
        #expect(LoopbackHost.normalizedHost(" [FE80::1%en0] ") == "fe80::1")
        #expect(LoopbackHost.normalizedHost("Gateway.Local.") == "gateway.local")
    }

    @Test func `unspecified addresses are recognized`() {
        #expect(LoopbackHost.isUnspecifiedAddress("0.0.0.0"))
        #expect(LoopbackHost.isUnspecifiedAddress("[::]"))
        #expect(LoopbackHost.isUnspecifiedAddress("::0"))
        #expect(!LoopbackHost.isUnspecifiedAddress("127.0.0.1"))
        #expect(!LoopbackHost.isUnspecifiedAddress("gateway.local"))
    }

    @Test(arguments: [
        ("ws://127.0.0.1:18789", GatewayTransportSecurityDecision.ok),
        ("ws://localhost:18789", .ok),
        ("wss://gateway.example.com", .ok),
        ("https://gateway.example.com", .ok),
        ("wss://mybox.tail123.ts.net", .ok),
        ("ws://192.168.1.20:18789", .warnCleartextLAN),
        ("ws://mac-studio.local:18789", .warnCleartextLAN),
        ("http://[fd12::1]:18789", .warnCleartextLAN),
        ("ws://mybox.tail123.ts.net:18789", .requireTLS),
        ("ws://100.100.1.1:18789", .requireTLS),
        ("ws://mybox:18789", .requireTLS),
        ("ws://gateway.example.com", .requireTLS),
        ("ws://0.0.0.0:18789", .rejectNonRoutable),
        ("wss://[::]:443", .rejectNonRoutable),
    ] as [(String, GatewayTransportSecurityDecision)])
    func `transport policy classifies gateway URLs`(raw: String, expected: GatewayTransportSecurityDecision) throws {
        let url = try #require(URL(string: raw))
        #expect(GatewayTransportSecurityPolicy.evaluate(url: url, policy: .strict) == expected)
    }

    @Test func `transport policy honors an opted-in tailnet override`() throws {
        let url = try #require(URL(string: "ws://mybox.tail123.ts.net:18789"))
        #expect(GatewayTransportSecurityPolicy.evaluate(url: url, policy: .legacyPermissive) == .warnCleartextLAN)
    }

    @Test func `transport policy rejects URLs without a host`() throws {
        let url = try #require(URL(string: "ws:///path"))
        #expect(GatewayTransportSecurityPolicy.evaluate(url: url, policy: .strict) == .rejectNonRoutable)
    }
}
