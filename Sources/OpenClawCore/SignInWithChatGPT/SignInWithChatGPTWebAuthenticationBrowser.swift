#if canImport(AuthenticationServices) && !os(tvOS) && !os(watchOS)
import AuthenticationServices
import Foundation

/// Presents the Sign in with ChatGPT page in an `ASWebAuthenticationSession`.
///
/// The redirect goes to the loopback listener (`http://127.0.0.1:<port>/auth/callback`), which
/// `ASWebAuthenticationSession` cannot intercept, so the session is started without a callback scheme
/// and ``dismiss()`` cancels it once the listener received the callback. The session shares cookies
/// with Safari by default, so users already signed in to ChatGPT only confirm consent.
@MainActor
public final class SignInWithChatGPTWebAuthenticationBrowser: NSObject, SignInWithChatGPTBrowser, ASWebAuthenticationPresentationContextProviding {
    private let prefersEphemeralSession: Bool
    private let presentationAnchorProvider: (() -> ASPresentationAnchor)?
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<Void, Error>?

    /// Creates a browser presenter.
    /// - Parameters:
    ///   - prefersEphemeralSession: Use a private browsing session (no shared ChatGPT cookies).
    ///   - presentationAnchor: Window that presents the sheet (required on macOS and in multi-window apps).
    public init(prefersEphemeralSession: Bool = false, presentationAnchor: (() -> ASPresentationAnchor)? = nil) {
        self.prefersEphemeralSession = prefersEphemeralSession
        self.presentationAnchorProvider = presentationAnchor
    }

    /// Shows the page and suspends until ``dismiss()`` or the user closes it.
    /// - Parameter authorizationURL: Authorization URL.
    /// - Throws: ``SignInWithChatGPTError/cancelled`` when the user closes the sheet.
    public func present(_ authorizationURL: URL) async throws {
        guard self.session == nil else {
            throw OpenClawCoreError.unavailable("A Sign in with ChatGPT browser session is already open")
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.continuation = continuation
                let session = ASWebAuthenticationSession(url: authorizationURL, callbackURLScheme: nil) { [weak self] _, error in
                    Task { @MainActor [weak self] in
                        self?.finish(error: error)
                    }
                }
                session.prefersEphemeralWebBrowserSession = self.prefersEphemeralSession
                session.presentationContextProvider = self
                self.session = session
                if !session.start() {
                    self.session = nil
                    self.continuation = nil
                    continuation.resume(throwing: OpenClawCoreError.unavailable("Could not start the Sign in with ChatGPT browser session"))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.session?.cancel()
            }
        }
    }

    /// Cancels the browser session after the callback arrived.
    public func dismiss() async {
        self.session?.cancel()
    }

    /// Anchor for the authentication sheet.
    /// - Parameter session: Requesting session.
    /// - Returns: Presentation anchor.
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        _ = session
        if let anchor = self.presentationAnchorProvider?() {
            return anchor
        }
        #if os(visionOS)
        let windowType: NSObject.Type = ASPresentationAnchor.self
        return unsafeDowncast(windowType.init(), to: ASPresentationAnchor.self)
        #else
        return ASPresentationAnchor()
        #endif
    }

    private func finish(error: (any Error)?) {
        self.session = nil
        guard let continuation = self.continuation else { return }
        self.continuation = nil
        if let error {
            if let authError = error as? ASWebAuthenticationSessionError, authError.code == .canceledLogin {
                continuation.resume(throwing: SignInWithChatGPTError.cancelled)
            } else {
                continuation.resume(throwing: error)
            }
        } else {
            continuation.resume()
        }
    }
}
#endif
