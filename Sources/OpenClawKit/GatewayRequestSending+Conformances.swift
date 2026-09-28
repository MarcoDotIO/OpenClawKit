import Foundation

// Kept in its own file so gateway-core changes to GatewayChannelActor / GatewayNodeSession only need a
// local fix-up here. Both conformances rely on the stable request signatures of those types.

extension GatewayChannelActor: GatewayRequestSending {}

extension GatewayNodeSession: GatewayNodeRequestSending {}

extension GatewayNodeSession: GatewayNodeEventSending {}
