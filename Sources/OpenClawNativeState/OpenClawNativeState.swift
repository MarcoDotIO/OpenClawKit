import Foundation

/// Namespace for the OpenClaw native state store.
///
/// `OpenClawNativeState` owns the shared SQLite state database (`state/openclaw.sqlite`) that
/// Apple clients use for device identity, device auth tokens, exec approvals, and other durable
/// runtime state. It is built on the system SQLite3 library and CryptoKit and has no third-party
/// dependencies. The module is Apple-only.
public enum OpenClawNativeState {
    /// Release of OpenClawKit that introduced this module surface.
    public static let moduleVersion = "2026.3.0"
}
