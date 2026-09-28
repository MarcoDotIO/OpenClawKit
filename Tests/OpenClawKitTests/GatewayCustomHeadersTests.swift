import Foundation
import OpenClawProtocol
import Testing
@testable import OpenClawKit

@Suite("Gateway custom headers and connect challenge")
struct GatewayCustomHeadersTests {
    @Test
    func sanitizedKeepsOperatorProxyCredentialHeaders() {
        let headers = GatewayCustomHeaders.sanitized([
            "CF-Access-Client-Id": "client-id",
            "CF-Access-Client-Secret": "client-secret",
            "Authorization": "Basic dXNlcjpwYXNz",
        ])
        #expect(headers == [
            "CF-Access-Client-Id": "client-id",
            "CF-Access-Client-Secret": "client-secret",
            "Authorization": "Basic dXNlcjpwYXNz",
        ])
    }

    @Test
    func sanitizedDropsReservedHandshakeHeaderNames() {
        let headers = GatewayCustomHeaders.sanitized([
            "Host": "evil.example",
            "connection": "close",
            "Upgrade": "h2c",
            "Sec-WebSocket-Protocol": "override",
            "sec-websocket-key": "override",
            "Content-Length": "0",
            "Proxy-Connection": "keep-alive",
            "X-Allowed": "yes",
        ])
        #expect(headers == ["X-Allowed": "yes"])
    }

    @Test
    func sanitizedDropsInvalidNamesAndControlCharacters() {
        let headers = GatewayCustomHeaders.sanitized([
            "": "value",
            "   ": "value",
            "X Bad": "value",
            "X:Bad": "value",
            "X-Bad-é": "value",
            "X-Split\r\nEvil": "value",
            "X-Value-Split": "a\r\nEvil: b",
            "X-Tab-Value": "a\tb",
            "X-Fine": "value",
        ])
        #expect(headers == ["X-Fine": "value"])
    }

    @Test
    func reservedNameCheckIsCaseAndWhitespaceInsensitive() {
        #expect(GatewayCustomHeaders.isReservedName(" HOST "))
        #expect(GatewayCustomHeaders.isReservedName("Sec-WebSocket-Extensions"))
        #expect(!GatewayCustomHeaders.isReservedName("CF-Access-Client-Id"))
    }

    @Test
    func challengeParsesTheGatewayIssuedTimestamp() {
        #expect(GatewayConnectChallengeSupport.challenge(from: [
            "nonce": AnyCodable(" nonce-1 "),
            "ts": AnyCodable(1_700_000_000_123),
        ]) == GatewayConnectChallenge(nonce: "nonce-1", issuedAtMs: 1_700_000_000_123))
        #expect(GatewayConnectChallengeSupport.challenge(from: [
            "nonce": AnyCodable("nonce-2"),
            "ts": AnyCodable(1_800_000_000_000.0),
        ])?.issuedAtMs == 1_800_000_000_000)
    }

    @Test
    func challengeRejectsMalformedPayloads() {
        let payloads: [[String: AnyCodable]?] = [
            ["nonce": AnyCodable("nonce-1"), "ts": AnyCodable("1700000000123")],
            ["nonce": AnyCodable("nonce-1"), "ts": AnyCodable(-1)],
            ["nonce": AnyCodable("nonce-1"), "ts": AnyCodable(1.5)],
            ["nonce": AnyCodable(" "), "ts": AnyCodable(1_700_000_000_123)],
            ["nonce": AnyCodable("nonce-1")],
            nil,
        ]
        for payload in payloads {
            #expect(GatewayConnectChallengeSupport.challenge(from: payload) == nil)
        }
    }

    @Test
    func deviceProofPayloadVectorsMatchUpstream() {
        let fields = GatewayDeviceAuthPayload.Fields(
            deviceId: "dev-1",
            client: .init(id: "openclaw-macos", mode: "ui"),
            role: "operator",
            scopes: ["operator.admin", "operator.read"],
            signedAtMs: 1_800_000_000_000,
            token: "tok-123",
            nonce: "nonce-abc")
        #expect(GatewayDeviceAuthPayload.buildConnectCompatibilityPayload(fields: fields)
            == "v2|dev-1|openclaw-macos|ui|operator|operator.admin,operator.read|1800000000000|tok-123|nonce-abc")
        #expect(GatewayDeviceAuthPayload.buildV3(fields: fields, platform: "  IOS  ", deviceFamily: "  iPhone  ")
            == "v3|dev-1|openclaw-macos|ui|operator|operator.admin,operator.read|1800000000000|tok-123|nonce-abc|ios|iphone")
        #expect(GatewayDeviceAuthPayload.normalizeMetadataField("  İOS  ") == "İos")
        #expect(GatewayDeviceAuthPayload.normalizeMetadataField(nil) == "")
    }
}
