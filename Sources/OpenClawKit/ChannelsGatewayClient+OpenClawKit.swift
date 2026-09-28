import Foundation

public extension ChannelsGatewayClient {
    /// Creates a channel control client over a gateway connection.
    /// - Parameters:
    ///   - channel: Connected gateway channel.
    ///   - timeoutMs: Per-request timeout in milliseconds.
    init(channel: GatewayChannelActor, timeoutMs: Double? = nil) {
        self.init { method, params in
            try await channel.request(method: method, params: params, timeoutMs: timeoutMs)
        }
    }
}

public extension OpenClawSDK {
    /// Fetches `channels.status` from a connected gateway.
    /// - Parameters:
    ///   - channel: Connected gateway channel.
    ///   - probe: Whether the gateway should probe channel credentials.
    ///   - channelFilter: Optional channel id filter.
    /// - Returns: Typed channel status report.
    func channelsStatus(
        via channel: GatewayChannelActor,
        probe: Bool = false,
        channelFilter: String? = nil
    ) async throws -> ChannelsStatusReport {
        try await ChannelsGatewayClient(channel: channel).status(probe: probe, channel: channelFilter)
    }

    /// Lists pending DM pairing requests (`channels.pairing.list`).
    /// - Parameters:
    ///   - channel: Connected gateway channel.
    ///   - channelFilter: Optional channel id filter.
    ///   - accountID: Optional account filter.
    /// - Returns: Typed pairing list report.
    func channelPairingList(
        via channel: GatewayChannelActor,
        channelFilter: String? = nil,
        accountID: String? = nil
    ) async throws -> ChannelsPairingListReport {
        try await ChannelsGatewayClient(channel: channel).pairingList(channel: channelFilter, accountID: accountID)
    }

    /// Approves a pending DM pairing request (`channels.pairing.approve`).
    /// - Parameters:
    ///   - channel: Connected gateway channel.
    ///   - channelID: Channel id of the request.
    ///   - accountID: Account id of the request.
    ///   - requestID: Opaque request id.
    ///   - notify: Whether to notify the approved sender.
    /// - Returns: Typed approve report.
    func approveChannelPairing(
        via channel: GatewayChannelActor,
        channelID: String,
        accountID: String,
        requestID: String,
        notify: Bool? = nil
    ) async throws -> ChannelsPairingApproveReport {
        try await ChannelsGatewayClient(channel: channel).pairingApprove(
            channel: channelID,
            accountID: accountID,
            requestID: requestID,
            notify: notify
        )
    }

    /// Dismisses a pending DM pairing request (`channels.pairing.dismiss`).
    /// - Parameters:
    ///   - channel: Connected gateway channel.
    ///   - channelID: Channel id of the request.
    ///   - accountID: Account id of the request.
    ///   - requestID: Opaque request id.
    /// - Returns: Typed dismiss report.
    func dismissChannelPairing(
        via channel: GatewayChannelActor,
        channelID: String,
        accountID: String,
        requestID: String
    ) async throws -> ChannelsPairingDismissReport {
        try await ChannelsGatewayClient(channel: channel).pairingDismiss(channel: channelID, accountID: accountID, requestID: requestID)
    }
}
