# Sign in with ChatGPT

Let people sign in with their ChatGPT account and run eligible inference on their ChatGPT
plan instead of an API key.

## Overview

[Sign in with ChatGPT](https://developers.openai.com/siwc) (SIWC) is OpenAI's OAuth flow
for apps and agents. With the ChatGPT plan scopes granted, the access token calls the
Responses API on the user's plan: they pay nothing extra up to their plan's limits, and
you ship no API key. OpenClawKit 2026.3.1 implements the open-source "ChatGPT plan usage"
flow end to end:

- ``SignInWithChatGPTSession`` (`OpenClawCore`, also on Linux) runs the browser sign-in,
  validates ID tokens, stores accounts, refreshes and revokes tokens.
- ``ChatGPTPlanModelProvider`` (`OpenClawModels`) is a ``ModelProvider`` that sends plan
  inference to `https://api.openai.com/v1/responses`.
- `OpenClawChatUI` adds the branded button, the one-time welcome, the "Using ChatGPT plan"
  indicator and the "Usage limit reached" prompt, plus the `SignInWithChatGPTModel`
  observable.

SIWC is a separate OAuth client from the ChatGPT/Codex login used by the
`openai-chatgpt-responses` route (``OpenAIChatGPTOAuthConfiguration``). SIWC is in
preview at OpenAI; read [Preview limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)
before shipping.

## Sign in

```swift
import OpenClawKit

let session = SignInWithChatGPTSession(
    configuration: SignInWithChatGPTClientConfiguration(agentName: "MyAgent"),
    credentialStore: KeychainCredentialStore()
)

// iOS, visionOS, macOS: an ASWebAuthenticationSession sheet that shares Safari's cookies.
let browser = SignInWithChatGPTWebAuthenticationBrowser(presentationAnchor: { window })
// macOS alternative: the user's default browser.
// let browser = SignInWithChatGPTExternalBrowser.systemDefault

let result = try await session.signIn(using: browser)
if result.shouldShowPlanWelcome {
    // Present ChatGPTPlanWelcomeView once, then:
    try await session.markPlanWelcomeSeen(subject: result.account.subject)
}
```

``SignInWithChatGPTSession/signIn(using:reauthenticating:consent:timeout:)`` starts a
one-shot listener on `http://127.0.0.1:1455/auth/callback` (another free port when 1455
is busy; OpenAI only lets the port vary and rejects `localhost`), opens the authorization
page, waits for the callback, exchanges the code with PKCE (`S256`) and validates the
RS256 ID token (JWKS signature, issuer, audience, expiry and nonce). Callbacks with the
wrong `state` are answered with `400` and ignored, so another local process cannot finish
the sign-in for you.

- **Registration.** The first sign-in of an account uses `client_id=dynamic_agent_client`
  with `agent_name_hint` (your ``SignInWithChatGPTClientConfiguration/agentName``). The
  callback returns the issued client id (`oaiapp_…`) that the account keeps from then on.
- **Re-authentication.** Pass `reauthenticating:` with a known account's subject: the saved
  client id is reused with `id_token_hint` and `login_hint`. To re-enable plan usage after
  the user turned it off, pass `consent: .forceReconsent` (or `.consent` for
  `prompt=consent`).
- **Host identifier.** Every authorization carries `ext_agent_host_id`. The account store
  persists a random `urn:uuid:` identifier before the first sign-in; apps that already hold
  a stable device key can call ``SignInWithChatGPTAccountStore/setHostIdentifier(_:)``
  with `SignInWithChatGPTHostIdentifier(deviceIdentity:)` (an RFC 9278 JWK thumbprint of the
  gateway device key) before signing in.
- **Custom callback handling.** ``SignInWithChatGPTSession/beginAuthorization(redirectURI:reauthenticating:consent:)``
  and ``SignInWithChatGPTSession/completeAuthorization(callbackURL:pending:)`` split the
  flow for hosts that serve the redirect themselves.

tvOS and watchOS have no browser, so the listener and `signIn(using:)` are not available
there; tokens and inference still work with a credential record imported from another
device.

## Run inference on the plan

```swift
let catalog = ChatGPTPlanModelProvider(tokenProvider: session)
let models = try await catalog.listModels()   // `visibility == "list"` models, in server order

let provider = ChatGPTPlanModelProvider(tokenProvider: session, defaultModelID: models.first?.slug)
let reply = try await provider.generate(ModelGenerationRequest(sessionKey: "main", prompt: "Hi"))
```

``SignInWithChatGPTSession`` conforms to ``ChatGPTPlanAccessTokenProvider``: it refreshes
access tokens five minutes before they expire (never before `earliest_refresh_at`), runs
one refresh per account at a time and stores rotated refresh tokens together with the new
access token. Use ``SignInWithChatGPTSession/tokenProvider(for:)`` to pin a provider to one
account when several are signed in.

The provider shapes every request for plan usage:

- `store: false` and `stream: true` always; only `response.completed` counts as success, and
  a `response.failed` mid-stream throws.
- The system prompt becomes `instructions`; transcript system messages become `developer`
  messages.
- Unsupported fields (`temperature`, `top_p`, `max_output_tokens`, `service_tier`,
  `metadata`, `truncation`, `user`, `previous_response_id`, …) are never sent, whatever the
  request policy says.
- Function tools are grouped in one `namespace` tool (``ChatGPTPlanModelProvider/Options/toolNamespace``,
  default `openclaw`), and replayed function calls carry the namespace. A named tool choice
  sends only that tool with `tool_choice: "required"`.
- A `401` refreshes the token once and retries.

Hosted tools (image generation, file search, code interpreter, computer use, hosted MCP,
`tool_search`) and audio or video input are not available on plan usage; the server answers
with `subscription_sharing_unsupported_capability`.

## Handle plan errors

Plan errors are thrown as ``ChatGPTPlanError``, built from `subscription_sharing_*` and
`chatpass_v2_*` codes or from direct-admission `401`/`403`/`503` responses.
``ChatGPTPlanError/recovery`` says what to offer:

| Recovery | Kinds | UI |
| --- | --- | --- |
| `manageUsage` | `usageLimitReached`, `notEligible` | "Usage limit reached" with "Manage usage" |
| `signInAgain` | `invalidUser`, `scopeNotAuthorized`, `invalidAuthorizationContext` | Sign in again; re-consent when ``ChatGPTPlanError/requiresPlanReconsent`` |
| `retryLater` | `usageUnavailable`, `userUnavailable` | Retry, honoring ``ChatGPTPlanError/retryAfter`` |
| `changeRequest` | `unsupportedCapability`, `routeNotSupported` | Remove the unsupported feature |

Token errors are ``SignInWithChatGPTError`` values. A rejected refresh token (`invalid_grant`,
`refresh_token_expired`, `refresh_token_reused`, …) clears the account's tokens and throws
``SignInWithChatGPTError/reauthenticationRequired(subject:reason:)``; the account keeps its
client id so the next sign-in re-authenticates the same registration. `invalid_client` is a
configuration error (``SignInWithChatGPTError/invalidClient(_:)``).

## Accounts, sign-out and storage

- ``SignInWithChatGPTSession/accounts()`` lists every account on the host;
  ``SignInWithChatGPTSession/setActiveAccount(subject:)`` picks the one used by default.
  Each account has its own registration: client ids and tokens are never mixed.
- ``SignInWithChatGPTSession/signOut(subject:)`` revokes the refresh token (retrying network
  errors and `5xx`), clears the tokens and keeps the client id and host identifier.
  ``SignInWithChatGPTSession/removeAccount(subject:)`` forgets the account entirely.
- Credentials live in a ``CredentialStore``: use ``KeychainCredentialStore`` on Apple
  platforms. ``FileCredentialStore`` writes `0600` files atomically (the file is created
  with owner-only permissions before any secret is written) in `0700` directories.
- ``SignInWithChatGPTSession/exportCredentialRecord(subject:)`` and
  ``SignInWithChatGPTSession/importCredentialRecord(_:)`` move a session in the documented
  credential-record JSON (`client_id`, `access_token`, `refresh_token`, `id_token`,
  `expires_in`, ISO 8601 `saved_at`, `ext_agent_host_id`, …), for example to a self-hosted
  VM, which then refreshes the tokens itself. The record holds live tokens: transfer it only
  over an encrypted channel.

Refreshes are serialized within one session. Share a single session per credential store;
processes that share a store must coordinate refreshes themselves.

## UI

```swift
@State private var chatGPT = SignInWithChatGPTModel(session: session) {
    SignInWithChatGPTWebAuthenticationBrowser(presentationAnchor: { window })
}

var body: some View {
    VStack {
        SignInWithChatGPTButton(.continueWithChatGPT, style: .black, logo: Image("ChatGPTLogo"),
                                isLoading: chatGPT.isSigningIn) {
            Task { await chatGPT.signIn() }
        }
        if chatGPT.isUsingChatGPTPlan {
            ChatGPTPlanUsageIndicator()
        }
    }
    .chatGPTPlanWelcomeSheet(isPresented: $chatGPT.showsPlanWelcome) {
        Task { await chatGPT.acknowledgePlanWelcome() }
    }
    .chatGPTPlanUsageLimitSheet(error: $chatGPT.planError)
}
```

The views follow OpenAI's [UI/UX guidelines](https://developers.openai.com/siwc/ui-ux-guidelines)
and use OpenAI's copy: "Continue with ChatGPT" / "Sign in with ChatGPT" on black or white,
"You're using your ChatGPT plan" (shown once per account), "Using ChatGPT plan · Manage
usage" near the composer, and "Usage limit reached" with "Manage usage"
(`https://chatgpt.com/settings/usage`) and an optional "Buy app credits". The SDK does not
ship OpenAI's logo: download it from OpenAI's brand assets and pass it as `logo`.

## Testing

The flow is covered offline with a scripted authorization server and RS256 fixtures
(`SignInWithChatGPTSessionTests`, `SignInWithChatGPTAuthorizationTests`,
`ChatGPTPlanModelProviderTests`), including a real loopback round trip, on macOS and on
Linux (where RS256 uses swift-crypto's `_CryptoExtras`). A live sign-in needs a person
in a browser, so there is no automated live test.
