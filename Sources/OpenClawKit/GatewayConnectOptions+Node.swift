import Foundation
import OpenClawCore
import OpenClawProtocol

// Node-role connect helpers and config bridges, kept out of GatewayConnectOptions.swift so the core
// option type stays a plain value.
extension GatewayConnectOptions {
    /// Node commands retired upstream (OpenClaw 2026.8.1, #126030) that a node must never advertise:
    /// canvas is a widget presenter now, so `canvas.eval`, `canvas.snapshot` and the A2UI commands
    /// are gone.
    public static let retiredNodeCommands: Set<String> = [
        "canvas.eval",
        "canvas.snapshot",
        "canvas.a2ui.push",
        "canvas.a2ui.pushJSONL",
        "canvas.a2ui.reset",
    ]

    /// Default node-role options (`role: node`, `mode: node`, no operator scopes).
    ///
    /// When `caps` contains ``OpenClawCapability/canvas`` the canvas presenter commands
    /// (``OpenClawCanvasCommand/presenterCommands``) are added; ``retiredNodeCommands`` are always
    /// removed, so an older command list cannot re-advertise `canvas.eval`/`canvas.snapshot`.
    /// Commands are de-duplicated in first-seen order.
    /// - Parameters:
    ///   - caps: Capabilities this node implements.
    ///   - commands: Node commands this node implements (besides the canvas presenter commands).
    ///   - permissions: Permission flags, for example ``OpenClawPermissionsSnapshot/permissionsMap``.
    ///   - clientId: Registry client id; defaults to ``defaultClientID``.
    ///   - displayName: Display name; defaults to the device name.
    /// - Returns: Node connect options.
    public static func defaultNode(
        caps: [OpenClawCapability],
        commands: [String] = [],
        permissions: [String: Bool] = [:],
        clientId: String = GatewayConnectOptions.defaultClientID,
        displayName: String? = nil) -> GatewayConnectOptions
    {
        var advertised = commands
        if caps.contains(.canvas) {
            advertised += OpenClawCanvasCommand.presenterCommands.map(\.rawValue)
        }
        return GatewayConnectOptions(
            role: "node",
            scopes: [],
            caps: Self.orderedUnique(caps.map(\.rawValue)),
            commands: Self.advertisableNodeCommands(advertised),
            permissions: permissions,
            clientId: clientId,
            clientMode: GatewayClientMode.node.rawValue,
            clientDisplayName: displayName ?? InstanceIdentity.displayName)
    }

    /// Filters a node command list: trims, drops empties and ``retiredNodeCommands``, and de-duplicates.
    /// - Parameter commands: Candidate commands.
    /// - Returns: Commands safe to advertise in `connect.commands`.
    public static func advertisableNodeCommands(_ commands: [String]) -> [String] {
        Self.orderedUnique(
            commands
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !Self.retiredNodeCommands.contains($0) })
    }

    /// Returns a copy whose ``permissions`` carry a permission snapshot (existing keys are replaced).
    /// - Parameter snapshot: Current OS permission states, for example from
    ///   ``OpenClawPermissionsSnapshot/current(_:location:)``.
    /// - Returns: Updated options.
    public func reportingPermissions(_ snapshot: OpenClawPermissionsSnapshot) -> GatewayConnectOptions {
        var copy = self
        copy.permissions.merge(snapshot.permissionsMap) { _, reported in reported }
        return copy
    }

    /// Returns a copy whose ``handshakeTimeoutMs`` defaults to the gateway config
    /// (`OPENCLAW_HANDSHAKE_TIMEOUT_MS`, then `gateway.handshakeTimeoutMs`); an explicit value wins.
    /// - Parameters:
    ///   - config: Gateway config section.
    ///   - environment: Process environment.
    /// - Returns: Updated options.
    public func applyingGatewayConfig(
        _ config: GatewayConfig,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> GatewayConnectOptions
    {
        guard self.handshakeTimeoutMs == nil else { return self }
        var copy = self
        copy.handshakeTimeoutMs = config.effectiveHandshakeTimeoutMs(environment: environment)
        return copy
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
