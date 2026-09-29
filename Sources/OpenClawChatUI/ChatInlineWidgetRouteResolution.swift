import Foundation

// Ported from upstream OpenClaw 2026.9.6 `ChatInlineWidgetView.swift`
// (`OpenClawChatWidgetURLResolver.resolveResource`). Upstream takes the kit's `GatewayCanvasHostRoute`;
// this port is generic over `OpenClawChatCanvasSurfaceRoute`, so any route value with a URL and an
// optional TLS pin (including `GatewayCanvasHostRoute` once it conforms) works unchanged.

/// A canvas capability surface the gateway advertised: its URL and optional TLS certificate pin.
public protocol OpenClawChatCanvasSurfaceRoute: Sendable, Equatable {
    /// Capability surface URL (`https://host/__openclaw__/cap/<token>`).
    var url: String { get }
    /// SHA-256 TLS certificate fingerprint the widget web view must pin, if any.
    var tlsFingerprintSHA256: String? { get }
}

extension OpenClawChatWidgetURLResolver {
    /// Resolves an inline widget `target` against the current node or operator canvas surface.
    ///
    /// With `failedResource == nil`, returns the preferred current surface (node first). After a load
    /// failure, tries each surface role at most once: the node surface as observed, then after one
    /// `refreshNodeSurfaceRoute`, re-reads both roles (a refresh can lose a reconnect race), then one
    /// `refreshOperatorSurfaceRoute`. A candidate only counts when its URL or TLS pin differs from the
    /// failed resource, and pins are only accepted on HTTPS surfaces.
    public static func resolveResource<Route: OpenClawChatCanvasSurfaceRoute>(
        target: String,
        replacing failedResource: OpenClawChatWidgetResource?,
        currentSurfaceRoutes: @Sendable () async -> (node: Route?, operatorSurface: Route?),
        refreshNodeSurfaceRoute: @Sendable (Route?) async -> Route?,
        refreshOperatorSurfaceRoute: @Sendable (Route?) async -> Route?) async
        -> OpenClawChatWidgetResource?
    {
        let observed = await currentSurfaceRoutes()
        guard let failedResource else {
            return self.resolvePreferred(
                surfaces: observed,
                target: target,
                excluding: nil,
                blockedRoles: [],
                attemptedRoles: [])
        }
        let blockedRoles = failedResource.attemptedSurfaceRoles
        if failedResource.surfaceRole == .legacy,
           blockedRoles.contains(.legacy)
        {
            return nil
        }
        let attemptedRoles = blockedRoles.union([failedResource.surfaceRole])
        if !blockedRoles.contains(.node),
           let nodeSurface = observed.node,
           let currentNode = self.resolve(
               surface: nodeSurface,
               role: .node,
               target: target,
               attemptedRoles: attemptedRoles),
           self.isReplacement(currentNode, for: failedResource)
        {
            return currentNode
        }

        if !blockedRoles.contains(.node),
           let refreshedSurface = await refreshNodeSurfaceRoute(observed.node),
           let refreshed = resolve(
               surface: refreshedSurface,
               role: .node,
               target: target,
               attemptedRoles: attemptedRoles),
           self.isReplacement(refreshed, for: failedResource)
        {
            return refreshed
        }

        // A nil refresh can mean its route lease lost a reconnect race. Re-read
        // both roles so a replacement connection and its TLS pin win together.
        let afterNodeRefresh = await currentSurfaceRoutes()
        if let replacement = self.resolvePreferred(
            surfaces: afterNodeRefresh,
            target: target,
            excluding: failedResource,
            blockedRoles: blockedRoles,
            attemptedRoles: attemptedRoles)
        {
            return replacement
        }

        if !blockedRoles.contains(.operatorSurface),
           let refreshedSurface = await refreshOperatorSurfaceRoute(afterNodeRefresh.operatorSurface),
           let refreshed = resolve(
               surface: refreshedSurface,
               role: .operatorSurface,
               target: target,
               attemptedRoles: attemptedRoles),
           self.isReplacement(refreshed, for: failedResource)
        {
            return refreshed
        }

        return await self.resolvePreferred(
            surfaces: currentSurfaceRoutes(),
            target: target,
            excluding: failedResource,
            blockedRoles: blockedRoles,
            attemptedRoles: attemptedRoles)
    }

    private static func resolve(
        surface: some OpenClawChatCanvasSurfaceRoute,
        role: OpenClawChatWidgetSurfaceRole,
        target: String,
        attemptedRoles: Set<OpenClawChatWidgetSurfaceRole>) -> OpenClawChatWidgetResource?
    {
        guard let url = resolve(surfaceURL: surface.url, target: target) else { return nil }
        let resource = OpenClawChatWidgetResource(
            url: url,
            tlsFingerprintSHA256: surface.tlsFingerprintSHA256,
            surfaceRole: role,
            attemptedSurfaceRoles: attemptedRoles)
        return resource.hasValidTLSBinding ? resource : nil
    }

    private static func resolvePreferred<Route: OpenClawChatCanvasSurfaceRoute>(
        surfaces: (node: Route?, operatorSurface: Route?),
        target: String,
        excluding failedResource: OpenClawChatWidgetResource?,
        blockedRoles: Set<OpenClawChatWidgetSurfaceRole>,
        attemptedRoles: Set<OpenClawChatWidgetSurfaceRole>) -> OpenClawChatWidgetResource?
    {
        [
            (role: OpenClawChatWidgetSurfaceRole.node, surface: surfaces.node),
            (role: OpenClawChatWidgetSurfaceRole.operatorSurface, surface: surfaces.operatorSurface),
        ]
            .lazy
            .filter { !blockedRoles.contains($0.role) }
            .compactMap { candidate in
                candidate.surface.flatMap {
                    self.resolve(
                        surface: $0,
                        role: candidate.role,
                        target: target,
                        attemptedRoles: attemptedRoles)
                }
            }
            .first { self.isReplacement($0, for: failedResource) }
    }

    private static func isReplacement(
        _ candidate: OpenClawChatWidgetResource,
        for failedResource: OpenClawChatWidgetResource?) -> Bool
    {
        guard let failedResource else { return true }
        // Legacy URL-only callers cannot express trust identity, so retain
        // their URL-only exclusion while resource-aware callers compare both.
        if failedResource.surfaceRole == .legacy,
           failedResource.tlsFingerprintSHA256 == nil
        {
            return candidate.url != failedResource.url
        }
        return candidate.url != failedResource.url ||
            candidate.tlsFingerprintSHA256 != failedResource.tlsFingerprintSHA256
    }
}
