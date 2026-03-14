import Foundation

/// Approved pairing metadata for a remote device.
public struct PairingRecord: Sendable, Equatable {
    /// Device identifier.
    public let deviceID: String
    /// Device role or trust class.
    public let role: String
    /// Pairing token associated with the device.
    public let token: String
    /// Approval timestamp in milliseconds since epoch.
    public let approvedAtMs: Int

    /// Creates a pairing record.
    /// - Parameters:
    ///   - deviceID: Device identifier.
    ///   - role: Device role.
    ///   - token: Pairing token.
    ///   - approvedAtMs: Approval timestamp in milliseconds.
    public init(deviceID: String, role: String, token: String, approvedAtMs: Int) {
        self.deviceID = deviceID
        self.role = role
        self.token = token
        self.approvedAtMs = approvedAtMs
    }
}

/// Actor that tracks pairing and command-approval state.
public actor SecurityRuntime {
    private var pairedDevices: [String: PairingRecord] = [:]
    private var execApprovals: [String: Bool] = [:]

    /// Creates an empty security runtime state container.
    public init() {}

    /// Approves or updates a paired device entry.
    /// - Parameters:
    ///   - deviceID: Device identifier.
    ///   - role: Device role.
    ///   - token: Pairing token.
    public func approveDevice(deviceID: String, role: String, token: String) {
        self.pairedDevices[deviceID] = PairingRecord(
            deviceID: deviceID,
            role: role,
            token: token,
            approvedAtMs: Int(Date().timeIntervalSince1970 * 1000)
        )
    }

    /// Returns pairing metadata for a device.
    /// - Parameter deviceID: Device identifier.
    /// - Returns: Pairing record when present.
    public func pairedDevice(_ deviceID: String) -> PairingRecord? {
        self.pairedDevices[deviceID]
    }

    /// Returns all paired devices sorted by device identifier.
    public func listPairedDevices() -> [PairingRecord] {
        self.pairedDevices.values.sorted { $0.deviceID < $1.deviceID }
    }

    /// Sets approval state for a command signature.
    /// - Parameters:
    ///   - command: Command identifier/signature.
    ///   - approved: Approval decision.
    public func setExecApproval(command: String, approved: Bool) {
        self.execApprovals[command] = approved
    }

    /// Returns whether a command has an approved execution record.
    /// - Parameter command: Command identifier/signature.
    /// - Returns: `true` if approved.
    public func isExecApproved(command: String) -> Bool {
        self.execApprovals[command] == true
    }
}
