import Foundation
#if os(macOS)
import AppKit
#endif

public extension SignInWithChatGPTHostIdentifier {
    /// RFC 9278 host identifier derived from a gateway device identity's Ed25519 public key.
    ///
    /// The device identity is already a stable per-install key, which makes it a good
    /// `ext_agent_host_id` source; the thumbprint does not reveal the key or the user.
    /// - Parameter identity: Device identity.
    /// - Returns: The identifier, or `nil` when the stored public key is not a 32-byte Ed25519 key.
    init?(deviceIdentity identity: DeviceIdentity) {
        guard let key = Data(base64Encoded: identity.publicKey), let identifier = Self.jwkThumbprint(ed25519PublicKey: key) else {
            return nil
        }
        self = identifier
    }
}

#if os(macOS)
public extension SignInWithChatGPTExternalBrowser {
    /// Opens the authorization page in the user's default browser.
    static var systemDefault: SignInWithChatGPTExternalBrowser {
        SignInWithChatGPTExternalBrowser { url in
            await MainActor.run { NSWorkspace.shared.open(url) }
        }
    }
}
#endif
