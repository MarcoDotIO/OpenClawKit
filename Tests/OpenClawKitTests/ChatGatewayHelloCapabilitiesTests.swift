import Foundation
import OpenClawKit
import OpenClawProtocol
import Testing

// The two upstream `ChatGatewayPayloadCodecTests` hello cases trimmed in wave 1, restored now that
// `HelloOk.supportsServerCapability(_:)` and `advertisedOperatorScopes()` are public kit API.
struct ChatGatewayHelloCapabilitiesTests {
    @Test func `published catalog hello enables direct session model choices`() throws {
        let data = Data("""
        {"type":"hello-ok","protocol":4,"server":{},
         "features":{"capabilities":["published-model-catalog"]},
         "snapshot":{"presence":[],"health":{},"stateVersion":{"presence":0,"health":0},"uptimeMs":0},
         "auth":{},"policy":{}}
        """.utf8)
        let hello = try JSONDecoder().decode(HelloOk.self, from: data)

        #expect(hello.supportsServerCapability(.publishedModelCatalog))
        #expect(!hello.supportsServerCapability(.chatSendRoutingContract))
    }

    @Test func `hello operator scopes preserve the exact advertised authorization`() {
        let snapshot = Snapshot(
            presence: [],
            health: [:],
            stateversion: StateVersion(presence: 0, health: 0),
            uptimems: 0)
        let hello = HelloOk(
            type: "hello-ok",
            _protocol: 3,
            server: [:],
            features: [:],
            snapshot: snapshot,
            auth: ["scopes": AnyCodable([
                AnyCodable("operator.read"),
                AnyCodable("operator.admin"),
            ])],
            policy: [:])
        let missing = HelloOk(
            type: "hello-ok",
            _protocol: 3,
            server: [:],
            features: [:],
            snapshot: snapshot,
            auth: [:],
            policy: [:])

        #expect(hello.advertisedOperatorScopes() == ["operator.read", "operator.admin"])
        #expect(missing.advertisedOperatorScopes() == nil)
    }
}
