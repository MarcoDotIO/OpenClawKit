import Foundation
import Testing
@testable import OpenClawKit

@Suite("Gateway protocol negotiation")
struct GatewayProtocolNegotiationTests {
    private func options(role: String, mode: String, minimum: Int? = nil) -> GatewayConnectOptions {
        GatewayConnectOptions(
            role: role,
            scopes: [],
            caps: [],
            commands: [],
            permissions: [:],
            clientId: GatewayClientID.macosApp.rawValue,
            clientMode: mode,
            clientDisplayName: nil,
            minimumProtocolVersion: minimum
        )
    }

    @Test
    func operatorsRequireV4AndNodesAcceptNMinusOne() {
        #expect(GatewayChannelActor.minimumProtocolVersion(role: "operator", clientMode: "ui") == 4)
        #expect(GatewayChannelActor.minimumProtocolVersion(role: "node", clientMode: "node") == 3)
        #expect(GatewayChannelActor.minimumProtocolVersion(role: "node", clientMode: "ui") == 4)

        #expect(GatewayChannelActor.supportedProtocols(for: nil) == 4...4)
        #expect(GatewayChannelActor.supportedProtocols(for: self.options(role: "operator", mode: "ui")) == 4...4)
        #expect(GatewayChannelActor.supportedProtocols(for: self.options(role: "node", mode: "node")) == 3...4)
    }

    @Test
    func legacyGatewayOptInWidensTheRange() {
        #expect(GatewayChannelActor.supportedProtocols(for: self.options(role: "operator", mode: "ui", minimum: 3)) == 3...4)
        #expect(GatewayChannelActor.supportedProtocols(for: self.options(role: "operator", mode: "ui", minimum: 0)) == 1...4)
        #expect(GatewayChannelActor.supportedProtocols(for: self.options(role: "operator", mode: "ui", minimum: 9)) == 4...4)
        #expect(OpenClawSDK.shared.buildInfo.protocolVersion == 4)
    }
}
