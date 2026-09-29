// Sign in with ChatGPT UI, following OpenAI's UI/UX guidelines: the "Continue with ChatGPT" /
// "Sign in with ChatGPT" button on black or white, the one-time plan welcome, the "Using ChatGPT plan"
// indicator and the "Usage limit reached" prompt. Copy strings are OpenAI's; like the rest of ChatUI they
// are English source literals that hosts can localize in their own string catalog.
#if os(iOS) || os(macOS) || os(visionOS)
import SwiftUI

/// The Sign in with ChatGPT button.
///
/// OpenAI's guidelines pair the label with the ChatGPT logo. The SDK does not ship OpenAI's brand
/// assets: download the logo from OpenAI and pass it as `logo` (it is rendered as a template in the
/// label color, white on ``Style/black`` and black on ``Style/white``).
public struct SignInWithChatGPTButton: View {
    /// Button label.
    public enum Label: Sendable, Equatable {
        /// "Continue with ChatGPT" (recommended for starting sign-in).
        case continueWithChatGPT
        /// "Sign in with ChatGPT".
        case signInWithChatGPT

        /// Label text.
        public var title: String {
            switch self {
            case .continueWithChatGPT:
                return String(localized: "Continue with ChatGPT")
            case .signInWithChatGPT:
                return String(localized: "Sign in with ChatGPT")
            }
        }
    }

    /// Button colors.
    public enum Style: Sendable, Equatable {
        /// Black background, white label.
        case black
        /// White background, black label, hairline border.
        case white
    }

    private let label: Label
    private let style: Style
    private let logo: Image?
    private let isLoading: Bool
    private let action: () -> Void

    /// Creates the button.
    /// - Parameters:
    ///   - label: Label text.
    ///   - style: Colors.
    ///   - logo: ChatGPT logo from OpenAI's brand assets.
    ///   - isLoading: Shows a progress indicator and disables the button.
    ///   - action: Starts the sign-in.
    public init(
        _ label: Label = .continueWithChatGPT,
        style: Style = .black,
        logo: Image? = nil,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.style = style
        self.logo = logo
        self.isLoading = isLoading
        self.action = action
    }

    public var body: some View {
        Button(action: self.action) {
            HStack(spacing: 8) {
                if self.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(self.foreground)
                } else if let logo {
                    logo
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                }
                Text(self.label.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(self.foreground)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 16)
            .background(self.background, in: .rect(cornerRadius: 10))
            .overlay {
                if self.style == .white {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(Color.black.opacity(0.15), lineWidth: 1)
                }
            }
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(self.isLoading)
        .accessibilityLabel(Text(self.label.title))
    }

    private var foreground: Color {
        self.style == .black ? .white : .black
    }

    private var background: Color {
        self.style == .black ? .black : .white
    }
}

/// Links used by the ChatGPT plan views.
public enum ChatGPTPlanLinks {
    /// ChatGPT usage settings ("Manage usage").
    public static let manageUsage = SignInWithChatGPTConfiguration.manageUsageURL
    /// OpenAI Help Center ("Learn more").
    public static let learnMore = SignInWithChatGPTConfiguration.learnMoreURL
}

/// One-time welcome shown after the first sign-in that granted plan usage.
///
/// Show it once per account (``SignInWithChatGPTSignInResult/shouldShowPlanWelcome``), then call
/// ``SignInWithChatGPTSession/markPlanWelcomeSeen(subject:)``; never show it again.
public struct ChatGPTPlanWelcomeView: View {
    private let learnMoreURL: URL
    private let onDismiss: () -> Void

    /// Creates the welcome.
    /// - Parameters:
    ///   - learnMoreURL: "Learn more" destination.
    ///   - onDismiss: Called when the user taps "Got it".
    public init(learnMoreURL: URL = ChatGPTPlanLinks.learnMore, onDismiss: @escaping () -> Void) {
        self.learnMoreURL = learnMoreURL
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 16) {
            Text("You're using your ChatGPT plan")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Eligible usage in this app uses your ChatGPT plan. Manage usage in your ChatGPT settings.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Link("Learn more", destination: self.learnMoreURL)
                .font(.subheadline)
            Button(action: self.onDismiss) {
                Text("Got it")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(maxWidth: 420)
    }
}

/// "Using ChatGPT plan · Manage usage", shown near the composer or model picker while requests use the plan.
public struct ChatGPTPlanUsageIndicator: View {
    private let manageUsageURL: URL

    /// Creates the indicator.
    /// - Parameter manageUsageURL: "Manage usage" destination.
    public init(manageUsageURL: URL = ChatGPTPlanLinks.manageUsage) {
        self.manageUsageURL = manageUsageURL
    }

    public var body: some View {
        HStack(spacing: 6) {
            Text("Using ChatGPT plan")
                .foregroundStyle(.secondary)
            Text(verbatim: "·")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Link("Manage usage", destination: self.manageUsageURL)
        }
        .font(.caption)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

/// "Usage limit reached" prompt with "Manage usage" and an optional "Buy app credits" action.
public struct ChatGPTPlanUsageLimitView: View {
    /// Layout.
    public enum Layout: Sendable, Equatable {
        /// Full modal content.
        case modal
        /// Compact inline banner (for example above the composer).
        case compact
    }

    private let layout: Layout
    private let manageUsageURL: URL
    private let onBuyAppCredits: (() -> Void)?
    private let onDismiss: (() -> Void)?

    /// Creates the prompt.
    /// - Parameters:
    ///   - layout: Modal or compact layout.
    ///   - manageUsageURL: "Manage usage" destination.
    ///   - onBuyAppCredits: Shows "Buy app credits" when set (for apps that sell their own credits).
    ///   - onDismiss: Adds a close control when set.
    public init(
        layout: Layout = .modal,
        manageUsageURL: URL = ChatGPTPlanLinks.manageUsage,
        onBuyAppCredits: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.layout = layout
        self.manageUsageURL = manageUsageURL
        self.onBuyAppCredits = onBuyAppCredits
        self.onDismiss = onDismiss
    }

    public var body: some View {
        switch self.layout {
        case .modal:
            self.modal
        case .compact:
            self.compact
        }
    }

    private var modal: some View {
        VStack(spacing: 16) {
            Text("Usage limit reached")
                .font(.title3.weight(.semibold))
            Text("Review your plan or this app's limit in ChatGPT settings.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Link(destination: self.manageUsageURL) {
                Text("Manage usage")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            if let onBuyAppCredits {
                Button(action: onBuyAppCredits) {
                    Text("Buy app credits")
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered)
            }
            if let onDismiss {
                Button("Close", role: .cancel, action: onDismiss)
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(maxWidth: 420)
    }

    private var compact: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Usage limit reached")
                    .font(.subheadline.weight(.semibold))
                Text("Review your plan or this app's limit in ChatGPT settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Link("Manage usage", destination: self.manageUsageURL)
                .font(.subheadline.weight(.semibold))
            if let onBuyAppCredits {
                Button("Buy app credits", action: onBuyAppCredits)
                    .font(.subheadline)
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Close"))
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
    }
}

public extension View {
    /// Presents ``ChatGPTPlanWelcomeView`` as a sheet.
    /// - Parameters:
    ///   - isPresented: Presentation binding.
    ///   - onDismiss: Called after "Got it" (record it with ``SignInWithChatGPTSession/markPlanWelcomeSeen(subject:)``).
    /// - Returns: The modified view.
    func chatGPTPlanWelcomeSheet(isPresented: Binding<Bool>, onDismiss: @escaping () -> Void = {}) -> some View {
        self.sheet(isPresented: isPresented) {
            ChatGPTPlanWelcomeView {
                isPresented.wrappedValue = false
                onDismiss()
            }
            .presentationDetents([.medium])
        }
    }

    /// Presents ``ChatGPTPlanUsageLimitView`` while `error` holds a usage-limit ``ChatGPTPlanError``.
    /// - Parameters:
    ///   - error: Latest plan error; set it from a failed request and it clears on dismiss.
    ///   - onBuyAppCredits: Shows "Buy app credits" when set.
    /// - Returns: The modified view.
    func chatGPTPlanUsageLimitSheet(error: Binding<ChatGPTPlanError?>, onBuyAppCredits: (() -> Void)? = nil) -> some View {
        let isPresented = Binding<Bool>(
            get: { error.wrappedValue?.isUsageLimit == true },
            set: { if !$0 { error.wrappedValue = nil } }
        )
        return self.sheet(isPresented: isPresented) {
            ChatGPTPlanUsageLimitView(
                layout: .modal,
                onBuyAppCredits: onBuyAppCredits.map { buy in
                    {
                        error.wrappedValue = nil
                        buy()
                    }
                },
                onDismiss: { error.wrappedValue = nil }
            )
            .presentationDetents([.medium])
        }
    }
}

/// Observable state for a Sign in with ChatGPT settings screen or onboarding step.
///
/// ```swift
/// @State private var chatGPT = SignInWithChatGPTModel(session: session) {
///     SignInWithChatGPTWebAuthenticationBrowser(presentationAnchor: { window })
/// }
///
/// SignInWithChatGPTButton(logo: Image("ChatGPTLogo"), isLoading: chatGPT.isSigningIn) {
///     Task { await chatGPT.signIn() }
/// }
/// .chatGPTPlanWelcomeSheet(isPresented: $chatGPT.showsPlanWelcome) { Task { await chatGPT.acknowledgePlanWelcome() } }
/// .chatGPTPlanUsageLimitSheet(error: $chatGPT.planError)
/// ```
@MainActor
@Observable
public final class SignInWithChatGPTModel {
    /// Session that owns accounts and tokens.
    public let session: SignInWithChatGPTSession
    /// Known accounts, most recent first.
    public private(set) var accounts: [SignInWithChatGPTAccount] = []
    /// Active account.
    public private(set) var activeAccount: SignInWithChatGPTAccount?
    /// Whether a sign-in is running.
    public private(set) var isSigningIn = false
    /// Latest user-facing error message.
    public var errorMessage: String?
    /// Whether the one-time plan welcome should be presented.
    public var showsPlanWelcome = false
    /// Latest plan error (drives `chatGPTPlanUsageLimitSheet(error:onBuyAppCredits:)`).
    public var planError: ChatGPTPlanError?

    @ObservationIgnored private let makeBrowser: @MainActor () -> any SignInWithChatGPTBrowser
    @ObservationIgnored private var welcomeSubject: String?

    /// Creates the model.
    /// - Parameters:
    ///   - session: Sign in with ChatGPT session.
    ///   - browser: Creates the browser presenter for each sign-in.
    public init(session: SignInWithChatGPTSession, browser: @escaping @MainActor () -> any SignInWithChatGPTBrowser) {
        self.session = session
        self.makeBrowser = browser
    }

    /// Whether the active account is signed in with plan usage.
    public var isUsingChatGPTPlan: Bool {
        self.activeAccount.map { $0.isSignedIn && $0.usesChatGPTPlan } ?? false
    }

    /// Reloads accounts from the session.
    public func reload() async {
        do {
            self.accounts = try await self.session.accounts()
            self.activeAccount = try await self.session.activeAccount()
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    /// Signs in (or re-authenticates a known account) and presents the plan welcome when due.
    /// - Parameters:
    ///   - subject: Known account to re-authenticate.
    ///   - consent: Re-consent parameter.
    public func signIn(reauthenticating subject: String? = nil, consent: SignInWithChatGPTConsentPrompt = .automatic) async {
        guard !self.isSigningIn else { return }
        self.isSigningIn = true
        self.errorMessage = nil
        defer { self.isSigningIn = false }
        do {
            let result = try await self.session.signIn(using: self.makeBrowser(), reauthenticating: subject, consent: consent)
            if result.shouldShowPlanWelcome {
                self.welcomeSubject = result.account.subject
                self.showsPlanWelcome = true
            }
            await self.reload()
        } catch SignInWithChatGPTError.cancelled, SignInWithChatGPTError.accessDenied {
            await self.reload()
        } catch {
            self.errorMessage = error.localizedDescription
            await self.reload()
        }
    }

    /// Records that the plan welcome was shown.
    public func acknowledgePlanWelcome() async {
        self.showsPlanWelcome = false
        guard let subject = self.welcomeSubject else { return }
        self.welcomeSubject = nil
        try? await self.session.markPlanWelcomeSeen(subject: subject)
        await self.reload()
    }

    /// Makes an account active.
    /// - Parameter subject: Account subject.
    public func selectAccount(subject: String) async {
        do {
            try await self.session.setActiveAccount(subject: subject)
        } catch {
            self.errorMessage = error.localizedDescription
        }
        await self.reload()
    }

    /// Signs an account out (revoking its refresh token).
    /// - Parameter subject: Account subject; `nil` signs out the active account.
    public func signOut(subject: String? = nil) async {
        do {
            try await self.session.signOut(subject: subject)
        } catch {
            self.errorMessage = error.localizedDescription
        }
        await self.reload()
    }

    /// Routes a request error: usage-limit errors present the usage-limit sheet, sign-in errors set
    /// ``errorMessage``.
    /// - Parameter error: Error thrown by a ChatGPT plan request.
    public func handle(_ error: any Error) {
        if let planError = error as? ChatGPTPlanError {
            self.planError = planError
            if !planError.isUsageLimit {
                self.errorMessage = planError.localizedDescription
            }
        } else {
            self.errorMessage = error.localizedDescription
        }
    }
}
#endif
