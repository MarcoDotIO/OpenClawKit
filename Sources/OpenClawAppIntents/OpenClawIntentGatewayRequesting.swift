import Foundation
import OpenClawKit

/// Minimal gateway RPC surface used by ``GatewayOpenClawIntentHost``.
///
/// This is the shared OpenClawKit ``GatewayRequestSending`` seam (one protocol for every typed
/// gateway helper), so `GatewayChannelActor` already conforms and a fake or custom transport written
/// for any other OpenClawKit helper also drives the App Intents host.
public typealias OpenClawIntentGatewayRequesting = GatewayRequestSending
