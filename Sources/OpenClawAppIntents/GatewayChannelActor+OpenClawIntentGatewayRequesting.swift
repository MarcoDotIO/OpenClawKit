import Foundation
import OpenClawKit

// Kept in its own file so gateway-channel signature changes stay a one-file merge fix-up.
extension GatewayChannelActor: OpenClawIntentGatewayRequesting {}
