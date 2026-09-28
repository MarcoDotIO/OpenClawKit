// Vendored by Scripts/protocol-gen-swift.mjs from OpenClaw 2026.9.6 (eb377ac59e) — do not edit by hand
extension WakeParams {
    // periphery:ignore - Shipped before sessionKey; remove only at a breaking protocol API window.
    /// Source-compatible initializer from before `sessionKey` was added; targets the default session.
    public init(
        mode: AnyCodable,
        text: String)
    {
        self.init(mode: mode, text: text, sessionkey: nil)
    }
}
