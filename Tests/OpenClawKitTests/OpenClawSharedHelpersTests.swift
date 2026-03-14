import CryptoKit
import Foundation
import Testing
@testable import OpenClawKit

@Suite("OpenClaw shared helpers")
struct OpenClawSharedHelpersTests {
    @Test
    func resourcesBundleIncludesImportedArtifacts() {
        #expect(OpenClawKitResources.bundle.url(forResource: "tool-display", withExtension: "json") != nil)
        #expect(
            OpenClawKitResources.bundle
                .paths(forResourcesOfType: "html", inDirectory: nil)
                .contains(where: { $0.hasSuffix("/scaffold.html") })
        )
    }

    @Test
    func toolDisplayResolvesNestedBrowserActionDetails() {
        let args = AnyCodable([
            "action": AnyCodable("act"),
            "request": AnyCodable([
                "selector": AnyCodable("#composer"),
                "text": AnyCodable("ignored"),
            ]),
        ])

        let summary = ToolDisplayRegistry.resolve(name: "browser", args: args)

        #expect(summary.title == "Browser")
        #expect(summary.emoji == "🌐")
        #expect(summary.verb == "act")
        #expect(summary.detail == "#composer")
    }

    @Test
    func talkConfigBridgePreservesNestedFoundationCollections() {
        let bridged = TalkConfigParsing.bridgeFoundationDictionary([
            "resolved": [
                "provider": "elevenlabs",
                "config": [
                    "voice": "Nova",
                    "latency": 150,
                    "modes": ["fast", "spoken"],
                ],
            ],
            "silenceTimeoutMs": 2500,
            "metadata": [
                "enabled": true,
                "disabled": NSNull(),
            ],
        ])

        let selection = TalkConfigParsing.selectProviderConfig(bridged, defaultProvider: "fallback")

        #expect(selection?.provider == "elevenlabs")
        #expect(selection?.normalizedPayload == true)
        #expect(selection?.config["voice"] == AnyCodable("Nova"))
        #expect(selection?.config["latency"] == AnyCodable(150))
        #expect(selection?.config["modes"]?.arrayValue?.compactMap(\.stringValue) == ["fast", "spoken"])
        #expect(bridged?["metadata"]?.dictionaryValue?["enabled"] == AnyCodable(true))
        #expect(bridged?["metadata"]?.dictionaryValue?["disabled"]?.foundationValue is NSNull)
        #expect(TalkConfigParsing.resolvedSilenceTimeoutMs(bridged, fallback: 1000) == 2500)
    }

    @Test
    func deviceAuthPayloadNormalizesMetadataAndProducesSignedDictionary() {
        let privateKey = Curve25519.Signing.PrivateKey()
        let identity = DeviceIdentity(
            deviceId: "device-123",
            publicKey: privateKey.publicKey.rawRepresentation.base64EncodedString(),
            privateKey: privateKey.rawRepresentation.base64EncodedString(),
            createdAtMs: 1
        )

        let payload = GatewayDeviceAuthPayload.buildV3(
            deviceId: identity.deviceId,
            clientId: "ios-client",
            clientMode: "control-ui",
            role: "operator",
            scopes: ["operator.read", "operator.write"],
            signedAtMs: 123,
            token: "device-token",
            nonce: "nonce-1",
            platform: " iOS ",
            deviceFamily: "iPhone 15"
        )

        #expect(
            payload == "v3|device-123|ios-client|control-ui|operator|operator.read,operator.write|123|device-token|nonce-1|ios|iphone 15"
        )

        let signed = GatewayDeviceAuthPayload.signedDeviceDictionary(
            payload: payload,
            identity: identity,
            signedAtMs: 123,
            nonce: "nonce-1"
        )

        #expect(signed?["id"] == AnyCodable("device-123"))
        #expect(signed?["signedAt"] == AnyCodable(123))
        #expect(signed?["nonce"] == AnyCodable("nonce-1"))
        #expect(signed?["publicKey"]?.stringValue?.isEmpty == false)
        #expect(signed?["signature"]?.stringValue?.isEmpty == false)
    }

    @Test
    func canvasJSONLValidationRejectsA2UIV09Messages() throws {
        let valid = """
        {"beginRendering":{"surfaceId":"surface-1"}}
        {"surfaceUpdate":{"surfaceId":"surface-1","html":"<p>Hello</p>"}}
        """

        let messages = try OpenClawCanvasA2UIJSONL.decodeMessagesFromJSONL(valid)
        let encoded = try OpenClawCanvasA2UIJSONL.encodeMessagesJSONArray(messages)

        #expect(messages.count == 2)
        #expect(encoded.contains("beginRendering"))
        #expect(encoded.contains("surfaceUpdate"))

        do {
            _ = try OpenClawCanvasA2UIJSONL.decodeMessagesFromJSONL(#"{"createSurface":{"id":"surface-2"}}"#)
            Issue.record("Expected A2UI v0.9 payload to be rejected")
        } catch {
            #expect(error.localizedDescription.contains("createSurface"))
        }
    }

    @Test
    func shareToAgentDeepLinkBuildsCanonicalMessageAndQueryItems() {
        let payload = SharedContentPayload(
            title: " OpenClaw Docs ",
            url: URL(string: "https://docs.openclaw.ai/providers/openai"),
            text: " Latest provider notes "
        )

        guard let url = ShareToAgentDeepLink.buildURL(from: payload, instruction: "Summarize this.") else {
            Issue.record("Expected share deep link")
            return
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let message = components?.queryItems?.first(where: { $0.name == "message" })?.value
        let thinking = components?.queryItems?.first(where: { $0.name == "thinking" })?.value

        #expect(url.scheme == "openclaw")
        #expect(components?.host == "agent")
        #expect(thinking == "low")
        #expect(message?.contains("Shared from iOS.") == true)
        #expect(message?.contains("Title: OpenClaw Docs") == true)
        #expect(message?.contains("URL: https://docs.openclaw.ai/providers/openai") == true)
        #expect(message?.contains("Text:\nLatest provider notes") == true)
        #expect(message?.contains("Summarize this.") == true)
    }
}
