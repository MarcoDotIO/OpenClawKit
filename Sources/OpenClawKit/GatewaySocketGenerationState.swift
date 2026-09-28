/// Prevents delayed callbacks from a retired socket from adopting a replacement route.
///
/// Admit a socket generation when its first push arrives and retire it on disconnect; callbacks
/// tagged with an older (retired) generation are rejected from then on.
public struct GatewaySocketGenerationState: Sendable {
    /// Generation currently admitted, or `nil` between sockets.
    public private(set) var activeGeneration: UInt64?
    private var lastRetiredGeneration: UInt64?

    /// Creates an empty state that accepts any first generation.
    public init() {}

    /// Returns whether callbacks from `generation` may still act.
    public func accepts(_ generation: UInt64) -> Bool {
        if let lastRetiredGeneration, generation <= lastRetiredGeneration {
            return false
        }
        return self.activeGeneration == nil || self.activeGeneration == generation
    }

    /// Admits `generation` as the active socket when it is still acceptable.
    /// - Returns: `false` when the generation is retired or another generation is active.
    public mutating func admit(_ generation: UInt64) -> Bool {
        guard self.accepts(generation) else { return false }
        self.activeGeneration = generation
        return true
    }

    /// Retires `generation`; later callbacks for it (or older generations) are rejected.
    /// - Returns: `false` when the generation was already retired or another generation is active.
    public mutating func retire(_ generation: UInt64) -> Bool {
        guard self.accepts(generation) else { return false }
        self.activeGeneration = nil
        self.lastRetiredGeneration = generation
        return true
    }
}
