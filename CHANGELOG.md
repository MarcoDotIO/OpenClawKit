# Changelog

## Unreleased

## 2026.3.3 - 2026-10-07

OpenClawKit 2026.3.3 adds support for the official OpenAI
[Decisions API](https://developers.openai.com/api/docs/guides/decisions), currently
in public beta with `gpt-6-luna`. This is an additive SDK feature on Apple platforms
and Linux; the upstream parity target remains OpenClaw `2026.9.6`.

### Added

- `OpenAIDecisionsClient` (`OpenClawModels`, re-exported by `OpenClawKit`) sends
  `POST /v1/decisions` with an explicit OpenAI Platform API key or `OPENAI_API_KEY`
  from the host environment. Local `.env` files stay ignored and must be loaded
  by the host. Configurable API base URL, organization/project scope, timeout and
  HTTP transport use the existing cross-platform networking contract.
- Typed requests for predicate, choice and score questions with optional names,
  shared text or user-message evidence, inline base64 images and image detail,
  and `safety_identifier`. String and Boolean choices retain their JSON types.
  Duplicate names, invalid choice counts/values, non-inline images and more than
  128 images are rejected before the network call.
- Typed ordered answers, per-question refusals, choice/score distributions,
  confidence, fractional rubric scores and exact token usage, with conversion
  to `ModelUsage`. Invalid response schemas and mismatched answer names/counts
  are rejected without exposing the response body.
- `OpenAIDecisionsHTTPError` preserves status, OpenAI code/type, request id and
  `Retry-After`, and redacts credentials in provider error details. The client
  makes one request and leaves retry decisions to the host.
- DocC article "OpenAI Decisions", README example, cross-platform offline
  `OpenAIDecisionsClientTests` and an opt-in `LiveProviderOpenAIDecisionsTests`
  smoke test for all three question types and usage.

### Tests

- Local macOS regression suites passed: 597 cross-platform runtime tests, 3,152
  SDK tests and 20 E2E tests reported by `swift test` (live suites stay gated).
  The new offline Decisions suite has 12 tests, including parameterized HTTP
  failures, malformed responses and answer matching.
- Local Linux Swift 6.2 warnings-as-errors build and all 586 runtime tests passed
  in Docker with two compiler jobs, including the new Decisions suite.
- Two opt-in live requests with the local `.env` key passed against `gpt-6-luna`:
  predicate/choice/score text questions and inline images with Boolean choices.
  OpenAI reported 522 input tokens and zero output tokens across both requests.
- Local repository SwiftLint, strict networking concurrency compilation and
  DocC documentation build passed. The compiled "OpenAI Decisions" article has
  no unresolved symbol warnings.

## 2026.3.2 - 2026-10-01

OpenClawKit 2026.3.2 is a patch release. Decoding and importing channel config
now uses a fraction of the stack it did; before, it could overflow a 512 KB
cooperative thread in debug builds. The test suites also stop failing on loaded
CI runners. There are no breaking changes, and the upstream parity target stays
OpenClaw `2026.9.6`.

### Added

- `ConfigBoxed`, the non-optional counterpart of `ConfigIndirect`: a property
  wrapper that keeps a large config value on the heap with value semantics.

### Fixed

- Decoding and importing channel config uses much less stack, so it no longer
  risks overflowing a 512 KB cooperative thread (the OpenClawLinuxRuntimeTests
  bundle crashed with SIGBUS this way in debug builds). `ChannelsConfig` stores
  its ten typed channel sections with `@ConfigBoxed` (about 6 KB → 170 bytes;
  `OpenClawConfig` 8.5 KB → 2.3 KB), each section decodes in its own frame, and
  `OpenClawConfig(document:)` imports secrets, gateway, auth and models in
  separate helpers. Peak stack for `OpenClawConfig(document:)` dropped from
  about 390 KB to 104 KB in debug builds (224 KB to 81 KB in release), and for
  a full `ChannelsConfig` decode from 110 KB to 38 KB. The public properties
  are unchanged.

### Tests

- Test waits no longer give up at a wall-clock deadline (#22, #25, #26, #29,
  #30). The macOS CI job runs about 3,150 tests in parallel and can stall the
  cooperative pool for 5–8 s, which failed waits whose condition was about to
  hold.
  - Waits now await an event, or poll until the test is cancelled, and every
    suite or test that waits has `.timeLimit(.minutes(1))`.
  - A wait that hangs records which wait it was (`AsyncWaitTimeoutError`).
  - Product waits that ignore cancellation, such as `agent.wait`,
    `EmbeddedAgentRuntime.wait(runID:)` and the approval and question brokers,
    go through `awaitCancellable`, so the time limit can end them.
  - Elapsed-time assertions became time limits or ordering checks.
  - Product timeouts on passing paths are now past the time limit, so a
    regression fails as a hang instead of passing when the timeout fires.
- Each speech-synthesizer test uses its own `TalkSystemSpeechSynthesizer`, so
  parallel suites no longer share its state (#23).
- Chat view-model tests stamp canned replies after the send instead of at test
  start plus a fixed offset. A stalled send no longer makes the reply look
  older than the message it answers (#27).
- `ConfigDecodeStackDepthTests` measures the peak stack of the channel-config
  decode and the document import on a thread whose stack the test maps itself,
  and bounds both (#28).
- 3,755 macOS tests pass under `swift test` (Swift Testing: 3,150 in
  `OpenClawKitTests`, 585 in `OpenClawLinuxRuntimeTests`, 20 E2E), and the
  `OpenClawLinuxRuntimeTests` bundle no longer crashes with SIGBUS.
- Release gates: all 13 required CI checks passed on the release tree.

## 2026.3.1 - 2026-09-30

OpenClawKit 2026.3.1 adds [Sign in with ChatGPT](https://developers.openai.com/siwc)
(SIWC): people sign in with their ChatGPT account and run eligible inference on
their ChatGPT plan instead of an API key. The release is additive; there are no
breaking changes, and the upstream parity target stays OpenClaw `2026.9.6`
(upstream has no SIWC client, so this is an SDK-native feature).

### Added

- `SignInWithChatGPTSession` (`OpenClawCore`, Apple platforms and Linux): the
  open-source "ChatGPT plan usage" flow. The first sign-in of an account
  registers with `client_id=dynamic_agent_client` and `agent_name_hint`, later
  sign-ins reuse the issued `oaiapp_…` client id with `id_token_hint` and
  `login_hint`, and `consent: .forceReconsent` / `.consent` re-enable plan usage.
  Every authorization sends PKCE `S256`, `state`, `nonce`,
  `resource=https://api.openai.com/v1` and a persisted `ext_agent_host_id`.
- `SignInWithChatGPTLoopbackListener`: a one-shot `127.0.0.1` callback server
  on `/auth/callback` (port 1455, or an ephemeral port when busy) that ignores
  callbacks with the wrong `state`; not built for tvOS and watchOS.
- RS256 ID-token validation (`SignInWithChatGPTIDTokenValidator`, JWKS cache
  with key-rotation refresh): signature, `iss`, `aud`, `azp`, `exp`, `iat`,
  `nbf`, `nonce` and `sub`; keys under 2048 bits are rejected. Verification
  uses Security.framework on Apple platforms and swift-crypto's `_CryptoExtras`
  on Linux (a new Linux-only dependency of `OpenClawCore`).
- Token lifecycle: code exchange, refresh five minutes before expiry (never
  before `earliest_refresh_at`), one refresh per account at a time with rotated
  refresh tokens replaced together with the access token, and a forced refresh
  when inference returns `401`. Rejected refresh tokens clear the tokens and
  throw `reauthenticationRequired` while keeping the account's client id.
- Accounts: `SignInWithChatGPTAccountStore` keeps multiple accounts (separate
  registrations, never mixed), the active account, the one-time plan-welcome
  flag and the documented credential record (`client_id`, `access_token`,
  `refresh_token`, `id_token`, `expires_in`, ISO 8601 `saved_at`,
  `ext_agent_host_id`) in any `CredentialStore`. Sign-out revokes the refresh
  token with retries and keeps the client id and host id; credential records can
  be exported and imported (for example to a self-hosted VM).
- `SignInWithChatGPTHostIdentifier`: `urn:uuid:`, RFC 9278 JWK-thumbprint and
  `did:key:` host ids, including `init(deviceIdentity:)` from the gateway device
  key.
- `ChatGPTPlanModelProvider` (`OpenClawModels`): Responses inference on the
  plan with `store: false`, `stream: true`, `instructions`, developer-role
  system messages, namespaced function tools, `tool_choice` mapping, and no
  unsupported fields (`temperature`, `top_p`, `max_output_tokens`, …);
  `listModels()` returns the `visibility == "list"` models in server order.
- `ChatGPTPlanError`: typed plan errors for the `subscription_sharing_*` and
  `chatpass_v2_*` codes and direct-admission responses, with a `recovery`
  (`manageUsage`, `signInAgain`, `retryLater`, `changeRequest`) and
  `Retry-After`.
- Apple presenters: `SignInWithChatGPTWebAuthenticationBrowser`
  (`ASWebAuthenticationSession` on iOS, macOS and visionOS) and
  `SignInWithChatGPTExternalBrowser.systemDefault` on macOS.
- `OpenClawChatUI`: `SignInWithChatGPTButton` ("Continue with ChatGPT" /
  "Sign in with ChatGPT", black or white, host-supplied logo),
  `ChatGPTPlanWelcomeView`, `ChatGPTPlanUsageIndicator`,
  `ChatGPTPlanUsageLimitView`, the `chatGPTPlanWelcomeSheet` and
  `chatGPTPlanUsageLimitSheet` modifiers, and the `SignInWithChatGPTModel`
  observable.
- DocC article "Sign in with ChatGPT".

### Changed

- `FileCredentialStore` now writes through `OpenClawFileSystem.writePrivateData`:
  the file is created with `0600` before any secret is written and atomically
  renamed into place (previously it was written, then `chmod`ed), and a missing
  parent directory is created with `0700`.
- The Responses stream parser records the error code of `response.failed` and
  `error` events.
- `InteractiveAuthFlowCatalog.descriptors` lists a `chatgpt-plan` browser OAuth
  descriptor ("Sign in with ChatGPT") between the upstream flows and the SDK
  device-code flows, so code that iterates the catalog sees one more entry.

### Tests

- 3,752 macOS tests pass under `swift test` (Swift Testing: 3,150 in
  `OpenClawKitTests`, 582 in `OpenClawLinuxRuntimeTests`, 20 E2E), and 571 Linux
  tests (`OpenClawLinuxRuntimeTests`) pass in the Swift 6.2 Docker gate.
- New offline suites `SignInWithChatGPTAuthorizationTests`,
  `SignInWithChatGPTSessionTests` and `ChatGPTPlanModelProviderTests` run on
  macOS and Linux against a scripted authorization server, fixed RS256 fixtures
  and a real loopback round trip. `SignInWithChatGPTAppleTests` covers private
  credential files, RFC 9278 host ids from a device identity and the SwiftUI
  usage-limit routing.
- Sign in with ChatGPT has no live suite: signing in needs a person in a
  browser.
- Release gates: all 13 required CI checks passed on the release tree
  (SwiftLint, generator and fixture drift, the Linux Swift 6.2 validation, macOS
  build and tests with Xcode 27, the Apple platform matrix on all five
  platforms, the `ExperimentalAppleModelDelegation` trait build, the iOS and
  tvOS example builds and the DocC site build), as did the non-required Xcode 26
  compatibility build and CodeQL.

## 2026.3.0 - 2026-09-29

OpenClawKit 2026.3.0 brings the SDK to feasible parity with upstream OpenClaw
`2026.9.6` (`.codex/openclaw` at `eb377ac59e`, previously `6b0c72bec8` /
`2026.4.25`) and adopts the Apple 27 frameworks behind availability gates. It
builds with Xcode 27.1 / Swift 6.4 on all five Apple platforms at the unchanged
floors (iOS 17, macOS 14, tvOS 17, watchOS 10, visionOS 26), while the
cross-platform modules keep building with Swift 6.2 on Linux. Read "Breaking
changes" before upgrading: gateway protocol v4, the channel `dmPolicy: pairing`
default, the `apple-fm` provider id and the native-state device identity store
change runtime behavior. The DocC article "Migrating to 2026.3" has before/after
snippets for every item.

### Added

#### Protocol v4 and gateway

- `OpenClawProtocol` is re-pinned to OpenClaw `2026.9.6` (`eb377ac59e`): the
  vendored `GatewayModels.swift` (1,061 types, `GATEWAY_PROTOCOL_VERSION` 4,
  minimum client protocol 4, minimum node protocol 3) plus the
  `AgentSummary+Kind`, `WakeParamsCompatibility` and `WizardHelpers` companions.
  `Scripts/protocol-gen-swift.mjs` rewrites upstream `.value as? T` casts to the
  typed `AnyCodable` accessors and fails on any cast it cannot rewrite.
- `GatewayMethodCatalog`: descriptors for the 482 upstream core methods (scope,
  since, advertised, startup-gated, control-plane write), 324 params validators,
  64 events, 21 server capabilities, 17 client ids and the 9 methods removed
  since the previous pin, plus the `GatewayEventName`,
  `GatewayServerCapabilityName`, `GatewayClientID`, `GatewayClientMode` and
  `GatewayClientCapability` enums.
- Public in-process `GatewayServer` method registration API:
  `GatewayMethodRegistrar`, `register(method:descriptor:handler:)`, the typed
  `register(method:params:handler:)`, `unregister(method:)`,
  `addMethodResolver(_:)`, `GatewayMethodRequest`, `GatewayConnectionContext`,
  `GatewayEventEmitter`, `GatewayMethodError`, `handle(_:connection:)`,
  `supportedMethods()` and `advertisedMethods()`. Feature modules register their
  own handlers through `register…GatewayMethods(on:)` functions (channels,
  skills, ClawHub, memory, cron, plugins, MCP OAuth, and the agent runtime's
  `attach(to:)`).
- Server push events: `GatewayServer.events(filter:bufferingNewest:)` streams
  `agent`, protocol-v4 `chat` (`deltaText`, `replace`, `stopReason`, `yielded`,
  `errorDetail`), `session.message`, `session.tool`, `sessions.changed`,
  approval, question, progress-card, task and cron events with a server-global
  `seq`. `LoopbackGatewaySocket` forwards server events per connection, and
  `ChatEventFrame` wraps the v4 `ChatEvent` union.
- Startup gating: `GatewayServer(startupPending:)`, `beginStartup(gating:)`,
  `completeStartup()` and `runStartup(gating:_:)` answer startup-gated methods
  with the retryable `startup-sidecars` `UNAVAILABLE` error until hosted
  subsystems are ready; `GatewayClient` retries it
  (`startupUnavailableRetryLimit`, default 3).
- New in-process methods: `secrets.store.list/set/delete` (backed by
  `GatewaySecretVault` per-entry metadata), `tools.catalog`, `tools.effective`
  and `tools.invoke` (approval-gated invocations return an `approvalId`),
  `sessions.rewind`, `sessions.fork`, `sessions.branches.list`,
  `sessions.branches.switch`, `sessions.search`, `sessions.groups.*`,
  `system-presence` with presence events, `node.list`,
  `node.pair.list/approve/reject/remove`, `node.rename`
  (`GatewayNodePairingStore`) and `mcp.authLogin`.
- `ErrorShape.errorCode`, `typedDetails`, `isStartupUnavailable` and
  `startupRetryAfterMs`; `AnyCodable.isNull`, `int64Value` and
  `init(encoding:)`. The typed `AnyCodable` accessors now live in
  `OpenClawProtocol`, so they are available on Linux.

#### Gateway client and native state

- `GatewayChannelActor` is rebuilt around socket generations (upstream
  `2026.9.6`): late callbacks from a retired socket can no longer tear down or
  leak into its replacement, concurrent `connect()` callers share one attempt,
  and handshake failures back off on the monotonic clock (500 ms doubling to 30
  s).
- Liveness follows the hello-ok tick interval; `reconnectIfStale(now:)` (call it
  when the app becomes active) and `nudgeReconnect()` (call it on network
  changes) force reconnects; WebSocket pings are bounded and resume exactly
  once.
- hello-ok is decoded defensively, so a newer gateway's unknown fields never
  fail the connect. The negotiated protocol, `GatewayHelloPolicy` (tick
  interval, payload and attachment ceilings), server methods, capabilities and
  operator scopes are exposed; requests larger than the advertised `maxPayload`
  fail locally with `GatewayRequestError.payloadTooLarge`.
- `GatewayConnectionProblem` and its mapper turn auth, pairing,
  protocol-mismatch, TLS and transport failures into actionable, localizable
  guidance.
- Optional `expectedProfileId` request binding
  (`request(method:params:timeoutMs:expectedProfileID:)`,
  `GatewayProfileEventBinding`) and sanitized operator proxy headers (for
  example Cloudflare Access service tokens), sent only on `wss://` upgrades and
  re-read on every reconnect.
- `GatewayNodeSession`: route leases (`GatewayNodeSessionRoute`), serialized
  teardown, per-command invoke cancellation, input events and timeouts,
  `computer.act` idempotency receipts, structured invoke result payloads,
  `pairingState()`, `negotiatedProtocolVersion()`, and hello-ok
  `pluginSurfaceUrls` with single-flight `node.pluginSurface.refresh` /
  `plugin.surface.refresh`.
- Opt-in Network.framework transport (`NetworkConnectionWebSocketSession`, OS
  26+) with per-connection TLS pinning and path/viability events; URLSession
  stays the default.
- TLS: a pin mismatch pauses automatic reconnects and exposes a reviewable
  `GatewayTLSPinRotationRequest` (`pendingTLSPinRotationRequest()`,
  `acceptTLSPinRotation(_:)`, `resumeAfterTLSRepair()`); URLSession certificate
  rejections surface as typed `GatewayTLSValidationError`; mutual TLS and
  managed trust anchors through `GatewayClientIdentityProviding` /
  `ManagedGatewayClientIdentity`.
- `CancellationShieldSupport.run(_:)` (OpenClawCore) runs cleanup RPCs for
  cancelled callers without `withTaskCancellationShield`, which would strongly
  link 27-only runtime symbols at the package floors.
- New product `OpenClawNativeState` (Apple): the upstream native state database
  `<stateDir>/state/openclaw.sqlite` (schema v18, canonical STRICT tables) on
  system SQLite, with version-zero bootstrap, validation of Node-owned
  databases, private `0700`/`0600` files with data protection, the state-handles
  coordinator lease, `schemaStatus()` and `schemaDocsURL`.
  `Scripts/check-native-state-parity.mjs` guards the schema version and DDL
  against upstream.
- `DeviceIdentityStore` and `DeviceAuthStore` persist to the native state
  database with one-time claim-import of `identity/device.json` and
  `identity/device-auth.json`, so paired devices keep their `deviceId` and
  tokens. Adds device identity profiles (`GatewayDeviceIdentityProfile`:
  `primary`, `node`, `shareExtension`), gateway-scoped device tokens
  (`gatewayID`), `loadOrCreatePersistedOrThrow(profile:)`,
  `configureStateDirectory(_:)` and async `…InBackground` variants that run on
  `OpenClawNativeStateQueue`.
- State directory opt-ins: an App Group root named by the Info.plist key
  `OpenClawAppGroupIdentifier`, and on macOS
  `OpenClawStateDirectory.cliShared()` to share identity and exec approvals with
  the OpenClaw CLI. The default `~/Library/Application Support/OpenClaw`
  location is unchanged.
- Exec approvals: document models, `ExecApprovalsSQLiteStore` (the
  `exec_approvals_config` row shared with the Node gateway),
  `ExecApprovalsLegacyMigrationRequiredError` and
  `OpenClawSystemRunApprovalPolicySnapshot`.

#### Node commands and Apple helpers

- Node contracts: `computer.act` (input geometry and an
  `OpenClawComputerActHandler` seam), `health.summary` (with an opt-in HealthKit
  provider that uses iOS 27 limited Health access), `camera.ptz.*`,
  `screen.snapshot` (strict params, format sniffing, frame-budgeted encoding),
  `fs.listDir`, `NODE_NOT_READY` / `SYSTEM_RUN_DENIED` codes, a
  `<DOMAIN>_PERMISSION_REQUIRED` helper, battery `levelPercent`, and
  `system.run` `runId`.
- `system.execApprovals.get/set` backed by `ExecApprovalsSQLiteStore`
  (`OpenClawSystemExecApprovalsHandler`), the approval policy snapshot on
  `system.run`, and on macOS `OpenClawSystemRunLaunchGuard`, which re-checks the
  approved executable's real path and SHA-256 right before launch.
- Typed operator RPC client `GatewayOperatorClient` (`tools.invoke`, artifacts,
  environments, tasks, `plugins.sessionAction`, `chat.message.get`,
  `node.pair.remove`, `update.status`, `gateway.identity.get`, `push.test`, exec
  approvals), `GatewayTerminalClient`, `GatewayWorkspaceFilesClient`,
  `GatewaySessionsClient.setPermissionMode(sessionKey:mode:expectedMode:)` and
  `GatewayApprovalBackfill`, all on the `GatewayRequestSending` seam.
- Setup codes accept raw or base64url JSON, `oc-pair://` links and pasted
  messages, with fallback URLs, a TLS fingerprint and an `Int64` expiry. New
  deep links `openclaw://gateway/add`, `openclaw://dashboard`
  (`DashboardRouteMap`) and `openclaw://talk/start`.
- `node.presence.alive` beacons (`NodePresenceAliveBeacon`) and consent-gated
  APNs registration (`GatewayPushRegistrar`, direct or through a host-supplied
  `PushRelayClient`).
- `ChatImageProcessor` and `ShareImageProcessor`; `JPEGTranscoder` adds
  long-edge caps, flattens transparency, strips metadata and converts HEIC to
  JPEG.
- `NotificationCentering` for `system.notify` / `watch.notify` handlers; typed
  models for `skills.status`, `sessions.compact`, `users.prefs` accent and
  `ArtifactBuildInfo`; `tool-display.json` refreshed to the 66 upstream tools
  with alias and MCP-name resolution.
- Opt-in integrations: macOS file-transfer node commands (`file.fetch`,
  `dir.list`, `file.write`; default-deny roots) and an iOS/visionOS 27
  ScreenCaptureKit `screen.record` backend (`ScreenCaptureKitRecorder`).
- `GatewayConnectOptions.defaultNode(caps:commands:permissions:)`,
  `reportingPermissions(_:)` and `applyingGatewayConfig(_:)` (handshake timeout
  from `gateway.handshakeTimeoutMs`); `OpenClawPermissionsSnapshot`
  (non-prompting permission status) and `OpenClawLocalNetworkAccessGate` (defers
  the local-network prompt).
- `OpenClawKit` ships `Localizable.xcstrings` (package `defaultLocalization` is
  `en`).

#### Talk

- `TalkGatewayClient` covers the protocol-v4 Talk surface (`talk.catalog`,
  `talk.config`, `talk.mode`, `talk.session.*`, `talk.client.*`, `talk.voice.*`,
  `talk.speak`, `tts.speak`) with the `TalkMode`, `TalkTransport`, `TalkBrain`,
  `TalkAgentControlMode` and `TalkEventType` vocabulary. It replaces the removed
  `talk.realtime.session`.
- `RealtimeTalkRelaySession` (iOS, macOS, visionOS), ported from upstream: PCM16
  microphone streaming through the gateway relay,
  `RealtimePCMStreamingAudioPlayer` playback, barge-in and output cancellation,
  playback marks, agent tool calls and steering, voice switching
  (`RealtimeTalkVoiceSelection`), a typed route-lost error, the default
  `AVAudioEngineRealtimeTalkAudioCapture`, and a route-bound
  `RealtimeTalkRelayTransport.gatewayNodeSession(_:route:)`.
- `TalkConfigSnapshot` / `TalkRealtimeConfigSnapshot`, speech-locale helpers and
  `TalkVoiceAliases`; `TalkSpeechFallbackChain` speaks through gateway
  `talk.speak` and falls back to the on-device voice; `TalkBufferedAudioPlayer`
  plays container clips with level metering.
- Speech helpers `OpenClawAudioDownmix`, `TalkWakeWordMatcher` (accepts
  trigger-only phrases) and `TalkVoiceWakeRoute`.

#### Watch

- The full upstream iPhone–Watch companion vocabulary: app snapshot, snapshot
  request and command, exec approval prompt/resolve/resolved/expired/snapshot,
  chat completion and semantic app statuses (with legacy decoding).
- Durable Watch chat delivery:
  `OpenClawWatchChatDeliveryCommand`/`Receipt`/`ReceiptAck`, a strict bounded
  codec, and `OpenClawWatchChatDeliveryStore`, a watch-owned SQLite journal in
  its own `watch-chat-delivery.sqlite` that resends unacknowledged messages
  without duplicates.
- `OpenClawWatchMessageCodec` encodes the companion messages as
  WatchConnectivity dictionaries (the SDK does not import WatchConnectivity).
- `OpenClawWatchNodeClient` makes an Apple Watch its own gateway node over
  signed HTTPS long-poll (`/api/nodes/watch/*`) with the fixed `device.info` /
  `device.status` / `system.notify` surface, one-time bootstrap pairing,
  device-token reconnects and a watchOS default factory.
- `WATCH_UNAVAILABLE` node errors and upstream `watch.notify` normalization for
  iPhone relay hosts; standalone Watch Talk is exposed as metadata only
  (`OpenClawWatchTalkSupport`).

#### ChatUI and ChatStore

- The non-view chat core and `OpenClawChatViewModel` are synced with upstream
  `2026.9.6`: transport v2 (about 60 requirements with defaults), new transport
  events, wire models, gateway request builders and payload codec,
  transcript-cache and outbox contracts. Protocol-v4 chat events decode as a
  union on state (`OpenClawChatEventState`), so `deltaText`/`replace` frames
  stream and `status` or unknown states no longer end a run.
- `OpenClawChatGatewayTransport` provides gateway-backed session, question,
  task, command and branch operations from four requirements, and
  `OpenClawGatewaySessionChatTransport` is a ready-made transport over one
  `GatewayNodeSession` whose queued and durable operations capture a route lease
  (`OutboxRouteSafety.strict` by default, `.bestEffort` opt-in).
- The upstream chat shell: `OpenClawChatView`, composer v2 with slash commands,
  a provider-grouped model picker with pinned and recent models,
  thinking/verbose/fast/effort controls, context usage, input history, reply
  preview and attachments; an "Execution permissions" menu that patches only
  `permissionMode`; session management (threads sheet, inspector, groups,
  pin/archive/unread/color, rename, fork/rewind/branches) with offset paging;
  `OpenClawChatSplitView` for macOS, iPadOS, visionOS and iPhone; host-provided
  Talk and dictation controls, AAC voice notes and Listen through gateway
  `tts.speak` with an on-device fallback; `ui.prefs` preferences.
- Native block-structured markdown on swift-markdown (headings, GFM tables, task
  lists, `<details>`, code cards with syntax highlighting and copy), word-paced
  streaming reveal, LaTeX shown as source, Mermaid through a host-supplied
  `OpenClawChatMermaidRenderer`, tool activity rows with inline diffs,
  completed-work folding, working status, progress/question/credential cards,
  subagent and Swarm progress, inline media with a single playback coordinator
  that publishes Now Playing, sandboxed inline canvas widgets, opt-in link
  previews (`OpenClawChatDisplayOptions.linkPreviews`) through an SSRF-guarded
  fetcher, transcript Markdown export, find in conversation and a full-message
  reader.
- New product `OpenClawChatStore` (Apple, GRDB 7.11.1):
  `OpenClawClientDatabases` with a disposable `gateway-cache.sqlite` and a
  never-reset `client-state.sqlite` (forward-only migrations),
  `OpenClawChatSQLiteTranscriptCache` (transcript cache and durable command
  outbox) and `OpenClawWatchMessageJournal`.

#### Providers and catalog

- The provider catalog is generated from the upstream `2026.9.6` extension
  manifests by `Scripts/provider-catalog-gen.mjs` (`--check`): 70 text providers
  with 357 manifest model rows, 28 capability/metadata providers, 32 aliases and
  131 suppressions, with TypeScript-only catalogs and SDK-local entries in
  `Scripts/provider-catalog-overrides.json`.
- New text providers `baseten`, `clawrouter`, `cohere`, `deepinfra`,
  `featherless`, `gmi`, `llama-cpp`, `longcat`, `meta`, `novita`,
  `ollama-cloud`, `qwen-token-plan`, `tencent-tokenplan`, `xiaomi-token-plan`
  and `radius` (metadata only); capability providers `azure-speech`,
  `fish-audio`, `pixverse`, `parallel`, `microsoft`, `pdf`, `readability` and
  `apple-speech`.
- Codable `ModelCatalog` manifest types (status, `replacedBy`, context-window
  options, thinking-level maps that keep explicit nulls, tiered pricing, compat,
  media-input limits), data-driven aliases, model-ref normalization
  (`normalizeModelRef`, `resolveModelRef`, `canonicalizeModelRef`,
  `canonicalizeProviderConfig`), suppressions and successors, catalog thinking
  profiles and `ModelChoice` builders, media-understanding candidates,
  ClawRouter live discovery, an opt-in hosted catalog refresh client and opt-in
  environment API-key lookup.
- Model contract v2 (`ModelGenerationRequest`/`Response`): transcript
  `messages`, `tools`/`toolChoice`, `responseFormat` (JSON schema), `toolCalls`,
  `usage`, `stopReason`, `reasoningText`, typed stream chunks and
  `ModelProvider.capabilities`, all additive with defaults. Every HTTP provider
  maps it: OpenAI Chat Completions and Responses, the ChatGPT/Codex route,
  Azure, Anthropic, Gemini/Vertex, Bedrock and native Ollama.
- `ModelStreamingHTTPClient` streams incrementally on Apple platforms (buffered
  replay on Linux); per-model `api`/`baseUrl` routing (`RoutingModelProvider`,
  `ModelProviderFactory.makeProviders(from:)`); `ReasoningEffortResolver`; fast
  mode `on`/`off`/`auto`; prompt caching (`ModelGenerationPolicy.promptCache`);
  Anthropic adaptive/budget thinking and signature replay; Gemini
  thought-signature replay; `ModelContextBudget` and `ModelCostCalculator`.
- `ThinkLevel` gains `max` and `ultra` (ranks, clamping, `ultra` sent to
  providers as `max`); `ModelAPI` adds `openai-chatgpt-responses`,
  `google-vertex`, `pi-messages` and `azure-openai-responses`; `ModelInputType`
  adds `video`, `audio` and `document`.
- The ChatGPT/Codex OAuth route for provider `openai` (API
  `openai-chatgpt-responses`) with token refresh; upstream provider login flows
  merged into `InteractiveAuthFlowCatalog`.

#### Apple Intelligence (FoundationModels 27, Private Cloud Compute, Vision, Spotlight)

- `FoundationModelsProvider` matches upstream `apple-fm`: canonical provider
  `apple-fm` with model `apple-fm/system`
  (`FoundationModelsProvider.systemModelID`), a facts probe (variant, context
  window, capabilities), the 8,192-token utility-role check and upstream-shaped
  provider config builders. It runs in process; there is no helper binary.
- Contract v2 on `apple-fm`: transcript replay, host-owned tool calling (calls
  are proposed by default, with an opt-in in-process mode), JSON-Schema
  structured output re-validated on the host, real streaming, token-keyed
  cancellation and token usage.
- FoundationModels 27: reasoning levels, tool-calling and sampling modes, image
  input on vision-capable models with the Vision OCR and barcode tools, an
  opt-in `SpotlightSearchTool` (Apple silicon), token counting, prewarm and
  typed error mapping (`FoundationModelsError`).
- SDK-only model `apple-fm/private-cloud-compute` (alias `apple-fm/pcc`) with a
  quota snapshot, the system quota-increase offer and on-device fallback. It
  needs Apple's managed Private Cloud Compute entitlement and is the first model
  route on watchOS 27.
- `OpenClawLanguageModel` lets a FoundationModels `LanguageModelSession` run on
  any OpenClaw provider or `ModelRouter` route (OS 27); OpenClawAgents bridges
  agent tools into FoundationModels sessions
  (`FoundationModelsAgentToolAdapter`, a registry-backed executor,
  `OpenClawAgentProfile`) and
  `EmbeddedAgentRuntime.makeFoundationModelsSession(agentID:…)`.
- The runtime compacts on `apple-fm` context overflow, records provider-executed
  tool calls (`ModelGenerationResponse.executedToolCalls`), switches on Tool
  Search for small-context models and routes the `foundation` /
  `apple-foundation-default` aliases to `apple-fm`.

#### Media ML

- On-device media understanding in `OpenClawMedia`:
  `MediaUnderstandingPreprocessor` and
  `MediaPipeline.applyMediaUnderstanding(_:policy:)` convert media a model
  cannot read, based on its catalog `input`: images to Vision OCR/barcode text,
  videos to MediaIntelligence key-frame/highlight JPEG frames plus a summary
  line, audio to SpeechAnalyzer transcripts. Failures never throw.
- `MediaPipeline.expandVideoAttachments(_:)`, `AppleImageTextExtractor`,
  `AppleSpeechTranscriber` (never downloads speech assets unless asked), and the
  `music_analyze` agent tool over MusicUnderstanding (key, BPM, structure,
  loudness, pace, instrument activity).
- CoreAI `.aimodel` support in `OpenClawModels` (27): `CoreAIModelRuntime`,
  `CoreAILocalModelEngine` (runtime `coreai`, caller-supplied tokenizer) and
  `CoreAIEmbeddingProvider`.

#### Agent runtime

- `EmbeddedAgentRuntime` runs a model-driven agent loop over contract v2: tool
  calling, parallel tool batches, before/after tool-call hooks, approvals, an
  iteration cap (24 by default), optional loop detection and one compaction
  retry on context overflow. Providers that only report legacy capabilities keep
  the single-prompt path.
- Streaming agent events (`AgentEventFrame`: lifecycle, assistant, thinking,
  tool, usage, compaction, approval) through `runEvents(_:)` and `events()`;
  per-session run queue, `start`/`abort`/`wait`, and run timeouts.
- Session transcripts (`AgentMessage` codec, entry tree with an active path,
  compaction and reset boundaries, in-memory and JSONL stores); session controls
  from `2026.9.6` (`permissionMode` read-only/guarded/workspace/full,
  `traceLevel`, fast mode `auto`, tool overrides, archive/pin/unread and display
  metadata); canonical `SessionKey` helpers (opt-in format).
- Core tool catalog (61 upstream tool ids) and `ToolPolicy`; `ApprovalBroker`
  and `ExecApprovalGate` (auto-review verdicts); structured questions
  (`QuestionBroker`, `question.*`, `ask_user`); `ContextEngine` with
  summarization compaction and `sessions.compact`; embedded sub-agents, a task
  ledger, session goals, structured Tool Search and progress cards.
- In-process gateway handlers for
  `sessions.create/send/steer/abort/compact/patch/reset/delete`,
  `chat.history/send/abort`, `agent.wait`, `approval.*`, `question.*`,
  `tasks.*`, `sessions.goal.*` and `progressCard.*`;
  `OpenClawSDK.makeEmbeddedAgentStack(stateDirectory:credentialStore:…)` wires a
  persistent runtime and gateway in one call.
- Typed `HookRegistry` hooks across the loop lifecycle and
  `AgentLoopHooks.bridging(_:)`; request shaping passes thinking level (clamped
  per catalog model), fast mode, run start time and prompt cache; the runtime
  wires MCP tools, the skill catalog with a path-jailed read tool, memory tools,
  automations and media understanding (`installMemory`, `registerMCPTools`,
  `installAutomations`, `apply(AgentRuntimeSettings(document:))`).

#### Skills, MCP, memory and plugins

- Skills: YAML-subset frontmatter and JSON5 metadata like upstream, upstream
  source precedence, eligibility checks, the v6 `<available_skills>` prompt
  catalog, in-process `skills.status`, `skills.bins` and `commands.list`, and a
  ClawHub search/detail client.
- New product `OpenClawMCP` (all platforms): MCP client with Streamable HTTP,
  legacy SSE and (macOS/Linux) stdio transports, `<server>__<tool>` naming, tool
  filters, output-schema enforcement, `MCPClientManager` exposing servers as
  agent tools, and HTTP OAuth (discovery, dynamic registration or client
  metadata documents, PKCE S256, refresh, Keychain storage,
  `ASWebAuthenticationSession` presenter). `OpenClawKit` re-exports it.
- Memory: builtin engine over `MEMORY.md` and `memory/**` (BM25 plus optional
  embeddings, recency decay, MMR), `memory_search` / `memory_get` tools, the
  Memory Recall prompt section and `memory.search`; on Apple 27 a
  CoreSpotlight-backed index and an opt-in `spotlight_search` tool.
- Plugins: plugin API v2 registrations (tools, hooks, gateway methods, MCP
  servers, context engines, memory embeddings, skill roots, services),
  `openclaw.plugin.json` manifests, and `plugins.list`, `plugins.setEnabled` and
  `hooks.status`.
- Hooks: the 42 upstream hook names with typed payloads, priority ordering and
  fail-closed/terminal semantics. Automations: `at`/`every`/`cron`
  (timezone-aware) schedules, the `automations` agent tool and `cron.*` gateway
  methods.

#### Channels

- The channel catalog is generated from the upstream manifests
  (`Scripts/channel-catalog-gen.mjs`, 34 channel ids) with aliases, labels, SF
  Symbols, order, distribution, typed capabilities, format profiles and chunk
  limits. New channel ids: `a2a`, `buzz`, `clickclack`, `raft`, `reef`, `sms`,
  `wecom`, `openclaw-weixin`, `yuanbao` and `openclaw-zaloclawbot`.
- Upstream ingress access policy (`ChannelAccessPolicyEvaluator`) and DM pairing
  (`ChannelPairingStore`: 8-character codes, 1-hour TTL, 3 pending per account,
  `channel-pairing.json`), per-channel fence-aware chunking
  (`ChannelTextChunker`), send receipts and retry classification
  (`ChannelSendError`, Retry-After capped at 60 s), bot-loop protection, ack
  reactions, a capability-driven typing lifecycle, ambient room events and join
  introductions.
- `channels.status`, `channels.start/stop/logout` and
  `channels.pairing.list/approve/dismiss` gateway methods
  (`registerChannelGatewayMethods(on:context:)`) with typed client models,
  `ChannelsGatewayClient` and `OpenClawSDK` wrappers, plus an optional
  `message.action` route.
- New native adapters: SMS over Twilio (signed webhook, MMS), A2A 1.0 (Agent
  Card, JSON-RPC, bearer peer auth), LINE Messaging API, an iOS 26+ carrier
  SMS/MMS/RCS adapter over TelephonyMessagingKit (opt-in; Apple entitlement
  required), and an IMAP inbox watcher that turns authenticated mail into hook
  agent turns. iMessage talks to `imsg rpc --json` on macOS (Linux through an
  SSH wrapper).
- Telegram, Discord, Slack, Signal and Microsoft Teams adapters follow upstream
  `2026.9.6` semantics (receipts, message actions, join events, probes,
  unconfigured status instead of start failures); Google Chat adds 32 KB (UTF-8)
  chunking, the typing placeholder message, bot-sender gating behind
  `allowBots` and join events; WhatsApp Cloud reports an unconfigured status
  when `accessToken` or `phoneNumberId` is missing.

#### Config

- `OpenClawConfigDocument`: a lossless, upstream-shaped (`2026.9.6`) model of
  `openclaw.json` that preserves unknown keys and mistyped values and reports
  decode issues, with `OpenClawJSON5`, `OpenClawConfigMigrator` (deterministic
  upstream doctor migrations by rule id) and `OpenClawConfigDocumentStore`
  (upstream write guards: base-hash conflict, `$include` refusal, future-version
  block, `gateway.auth` removal guard, SDK-only key strip, backup ring, atomic
  `0600` writes, observer events).
- A bridge between `OpenClawConfig` and the document
  (`importConfig(from:issues:)`, `documentProjection(preserving:)`), typed
  `config.get` / `config.patch` helpers, and
  `OpenClawSDK.loadConfigRuntime(fromOpenClawJSON:)`, which returns the runtime
  config, group-chat options and per-channel messaging policy from an upstream
  `openclaw.json`.
- Lenient `OpenClawConfig` decoding (`ConfigDecodeIssueCollector`): an unknown
  enum value decodes to nil or its default and is recorded as an issue instead
  of failing the whole config. Upstream-shaped `channels.*` (SecretRef and
  `${ENV}` secrets, key aliases, `accounts`/`defaultAccount`,
  `channels.defaults`, `modelByChannel`, lossless extension channels via
  `ChannelsConfigDocument`), `mcp`, `skills`, `memory`, `plugins`,
  `models.catalogRefresh` and `routing.sessionKeyFormat` sections.
- Secrets: `store` SecretRef source, `$NAME` shorthand, legacy markers,
  `egressProxy`, exec `pluginIntegration`, `SecretRefResolver`; gateway config
  keys `publicOrigin`, `portals`, `roles`, `terminal`, `identityScopes`,
  `nodes.commands`, `remote.tlsFingerprint`, `sshHostKeyPolicy`, `edgeAuth`,
  `deviceAutoApprove`, reload mode and `handshakeTimeoutMs`; auth profile
  `displayName` and `aws-sdk` mode.
- Cross-platform exec allowlist matching (`argPattern`, cwd-bound allow-always
  grants, realpath trust paths, `env -P/-S` unwrapping) with per-agent
  `SecurityRuntime` allowlists that Apple hosts can persist in the shared
  exec-approvals store (`ExecApprovalsSQLiteAllowlistStore`);
  `OpenClawClock.nowMs()` (`Int64`); `ModelAuthMarkers`.
- A ManagedApp.framework MDM configuration overlay with locked paths, a managed
  SecretRef resolver and a managed mTLS client identity (iOS 18.4+, visionOS
  2.4+, macOS 27+).

#### Apple 27 system integration

- New product `OpenClawAppIntents`: `OpenClawSessionAppEntity` and
  `OpenClawAgentAppEntity` with queries, `AskOpenClawIntent`,
  `AbortOpenClawRunIntent`, `StartOpenClawTalkIntent` and, on OS 27,
  `RunOpenClawTaskIntent` (a cancellable long-running background intent with
  progress), plus `GatewayOpenClawIntentHost`, `EmbeddedOpenClawIntentHost`,
  `OpenClawAppIntents.configure(host:)` and `OpenClawAppIntentsPackage`. Linking
  the product merges the SDK's App Intents metadata into the host app (verified
  with Xcode 27.1 at an iOS 17 deployment target).
- On OS 27, OpenClaw errors adopt `CustomAppIntentErrorConvertible`, session
  entities adopt `OwnershipProvidingEntity`, queries declare execution targets,
  notification and Now Playing content can be linked to session entities
  (`linkOpenClawSession`), and talk sessions are published to relevant entities.
- Experimental, off by default: with the `ExperimentalAppleModelDelegation`
  package trait, `OpenClawModelDelegationIntent` makes OpenClaw a delegated
  model for Siri, Writing Tools and Shortcuts on iOS/macOS/visionOS 27, built on
  the underscored `_ModelDelegationIntent` API.
- StateReporting: an opt-in bridge (`OpenClawSystemState.isEnabled`) for the
  `ai.openclaw.gateway`, `node.invoke`, `agent.run`, `talk` and `config` domains
  with privacy-safe metadata and coalesced volatile updates. The gateway
  channel, node session and talk report their state, config loading through
  `OpenClawSDK.loadConfigRuntime(fromOpenClawJSON:)` reports config health, and
  `OpenClawSystemState.diagnosticSink(reporter:forwardingTo:)` reports agent
  runs.
- Now Playing: `OpenClawNowPlayingPublishing` backed by NowPlaying
  `MediaSession` on OS 27 with an `MPNowPlayingInfoCenter` fallback and an
  extension-safe factory; Talk speech and chat media publish through it.
- `OpenClawRunProgress` (Foundation `ProgressManager` on OS 27 with a legacy
  `Progress` bridge); `OpenClawBackgroundTasks.submit(_:)`, which uses the async
  `BGTaskScheduler.submitTaskRequest(_:)` on iOS/tvOS 27 and returns every
  submission error, and `submitContinuedProcessing(_:)` with a queue fallback.
- TrustInsights coaching-risk friction before device pairing, token rotation and
  exec approvals on iOS 27 (`OpenClawApprovalGate`,
  `TrustInsightsApprovalSignals`); LinkSecurity flags links from untrusted
  sources in ChatUI and confirms before opening them; system data detection and
  Apple Intelligence suggested actions in ChatUI; an Image Playground sheet and
  iOS 27 paste destinations in the composer.
- The upstream Live Activity schema (`OpenClawActivityAttributes`) and
  presentation arbiter, plus per-run `OpenClawAgentRunActivityAttributes` and
  `OpenClawAgentRunActivityReducer` (iOS).

#### Toolchain and platforms

- New products `OpenClawMCP` (all platforms), `OpenClawNativeState`,
  `OpenClawAppIntents` and `OpenClawChatStore` (Apple). `OpenClawChatUI` depends
  on swift-markdown 0.8.0; `OpenClawChatStore` on GRDB 7.11.1 (resolved for
  every consumer, compiled only when linked). New default-off package trait
  `ExperimentalAppleModelDelegation`.
- `Scripts/build-apple-platforms.sh` (every product on all five platforms),
  `Scripts/check-apple-weak-links.sh` (frameworks newer than the floors must be
  weak-linked; now also watches ImagePlayground, TelephonyMessagingKit and
  ManagedApp, fails on strong references to 27-only Swift runtime symbols such
  as `swift_task_cancellationShieldPush`/`Pop`, and can inspect a linked app
  binary with `--binary`), `Scripts/typecheck-apple-sdks.sh` (fast per-SDK
  typecheck of OpenClawKit at the floors, now emitting every module it depends
  on), new `Scripts/validate-apple-matrix.sh` gates (including an iOS 27
  availability gate for `submitTaskRequest(`), and
  `Scripts/check-upstream-drift.sh` (all generator and fixture `--check`
  scripts, with `--allow-missing-upstream`).

### Changed

- Gateway: operator connections negotiate protocol 4 by default (upstream
  parity); node-role connections offer 3...4.
  `GatewayConnectOptions.minimumProtocolVersion` widens the range for pre-v4
  gateways.
- Gateway: in-process dispatch is table-driven. Known upstream methods without a
  handler validate their params and answer `UNAVAILABLE`; removed and unknown
  methods answer `INVALID_REQUEST` (`unknown method: X`); requests are
  authorized by role and scope (`FORBIDDEN` with `MISSING_SCOPE` details).
  `handle(_:)` keeps using an `operator.admin` in-process context.
- Gateway: handlers accept upstream wire shapes (`AgentParams` with an
  idempotency retry cache, `runId`, `agentId`, `model`, `fastMode`, null clears)
  next to the legacy SDK keys; `models.list` rows carry the `ModelChoice` keys.
- Gateway client: connects sign the device proof with the server's
  `connect.challenge` time (v2-compatible payload; v3 is opt-in with
  `GatewayConnectOptions.deviceProofPayload = .v3`). The default operator client
  id is per platform and the default operator scopes add `operator.questions`.
  The connect handshake budget is 30 s (override with `handshakeTimeoutMs`).
- Gateway client: a scanned setup code forces the bootstrap path; bootstrap
  connects request bounded scopes; bootstrap handoff tokens persist only over
  TLS, loopback or a cleartext LAN; a consumed setup code is not replayed on
  reconnect; `AUTH_RATE_LIMITED` waits for `retryAfterMs`; stale device tokens
  are cleared on `AUTH_DEVICE_TOKEN_MISMATCH`.
- Gateway client: `TalkGatewayRequesting` on `GatewayNodeSession` keeps
  millisecond timeouts (a `timeoutMs` of 0 means no client timeout), and chat
  requests with `timeoutMs` 0 leave the deadline to the gateway.
- Native state: device identity and device auth move from
  `<stateDir>/identity/*.json` to `<stateDir>/state/openclaw.sqlite`;
  `GatewayChannelActor` connect throws when the identity cannot be persisted.
- Providers: `google`, `apple-fm` and `kimi` are the canonical ids (`gemini`,
  `foundation`, `kimi-code` and `kimi-coding` stay aliases); `qwen` absorbs
  `modelstudio`; `openai-codex/<model>` and `codex/<model>` resolve to
  `openai/<model>` on the ChatGPT OAuth route with runtime hint `codex`.
- Providers: default models and endpoints follow upstream `2026.9.6` (for
  example `openai` `gpt-6-astra`, `anthropic` `claude-opus-5` with base
  `https://api.anthropic.com`, `google` `gemini-3.1-pro-preview`, `xai`
  `grok-4.7`); Anthropic calls `<base>/v1/messages`, Ollama uses native
  `/api/chat`, the default transport is `ModelStreamingHTTPClient` and the
  default request timeout is 120 s.
- Providers: configs encode `baseUrl` (`baseURL` still decodes) and skip
  SDK-only and default values; `apiKey` and provider headers accept SecretInput;
  an unknown `api` is kept for round-tripping and the factory skips that
  provider.
- Providers: OpenAI Responses fast mode no longer lowers reasoning effort or
  verbosity; the ChatGPT route sends priority service tier when fast mode is on.
  The runtime no longer derives `ModelGenerationPolicy.reasoningEffort` from
  `ThinkLevel`; providers read `thinkingLevel`, clamped to the catalog thinking
  profile.
- Providers: the public OpenAI provider paths no longer use OpenAIKit for
  requests; everything goes through the contract-v2 Responses and Chat
  Completions engines. OpenAIKit stays a package dependency for this release.
- Apple Intelligence: `FoundationModelsProvider.providerID` is `"apple-fm"`;
  responses report model id `system` (or `private-cloud-compute`); availability
  reasons use the upstream copy; watchOS reports
  `systemModelUnsupportedOnPlatform` for the system model; generation failures
  throw `FoundationModelsError` with stable codes; image or binary attachments
  to a model without vision are rejected (the router falls back).
- Agent runtime: the loop is on for providers that declare contract-v2
  capabilities; Tool Search is on by default at 12 or more policy-visible tools;
  `sessions.reset` rotates the transcript id; `resolveOrCreate` assigns a
  session id. `EmbeddedAgentRuntime` no longer connects to
  `ws://127.0.0.1:18789` or sends `agent.run`.
- Channels: DMs default to `dmPolicy: pairing` and groups to `groupPolicy:
  allowlist` with `requireMention` (WebChat is exempt);
  `InboundMessage.accountID` is the channel account key and the sender moved to
  `senderID`; built-in adapter session keys become `<channel>:<peer>`; present
  channel sections without `enabled` decode as enabled; replies are chunked per
  channel; unknown-outcome sends are not retried.
- Channels: Telegram clears its webhook before long polling; Discord ingests
  through the gateway by default (REST polling is `transport: rest-polling`) and
  acknowledgement reactions follow `ackReactionScope`; Slack uses the status API
  instead of `chat.typing`; Teams acquires Bot Framework tokens and rejects
  `serviceUrl` hosts outside the allowlist; Google Chat chunks at 32 KB of UTF-8
  and throws classified `ChannelSendError`; iMessage uses `imsg` when no
  transport is injected.
- Config: `ConfigStore.save` merges onto the on-disk file (unknown top-level
  keys, `gateway.auth`, `gateway.mode`, `meta` and `wizard` are kept) and sorts
  keys; `$NAME` in a SecretInput string is an env SecretRef shorthand; the
  security audit reports typed channel secrets under
  `channels.secrets.plaintext` and ignores non-secret provider markers; SDK
  state directories are created `0700` and state files written `0600`.
- ChatUI: `OpenClawChatView`'s default look follows upstream `2026.9.6`
  (collapsed completed work in the desktop layout, clean chrome,
  `ui.prefs`-driven trace visibility); bubbles render block-structured markdown;
  history sanitation keys on the `⟦openclaw:ctx⟧` provenance marker; the
  thinking picker offers `max`/`ultra` where the catalog allows and hides for
  non-reasoning models; ChatUI views compile on iOS, macOS and visionOS while
  tvOS and watchOS get the non-UI chat core.
- Media: `MediaPipeline` classifies MP4/QuickTime/M4A/M4V, AIFF, CAF and FLAC as
  audio or video.
- Platforms: `InstanceIdentity` reports the real platform and device family on
  watchOS, tvOS, visionOS and iOS-on-Mac; `Scripts/build-visionos-package.sh`
  builds every product.
- CI: the Apple jobs build with Xcode 27.1's own toolchain (no separate Swift 6.2
  setup on macOS); the platform matrix adds tvOS and watchOS and runs the
  floor typecheck, the full build and the weak-link check per platform; new
  jobs run the macOS tests, the upstream drift checks
  (`--allow-missing-upstream`), a build with the
  `ExperimentalAppleModelDelegation` trait and the tvOS example build. The
  Linux job stays on Swift 6.2.
- Examples: the iOS and tvOS apps adopt 2026.3.0:
  `FoundationModelsProvider.systemModelID`, `OpenClawAppIntents` (a launch-time
  `configure(host:)` plus an app `AppIntentsPackage`), opt-in StateReporting with
  the agent-run diagnostics sink, `OpenClawBackgroundTasks` submission, a
  `ChannelPairingStore` with approval UI for the default DM pairing policy, and
  remote gateway chat over `OpenClawGatewaySessionChatTransport`.

### Deprecated

- `ModelAPI.openAICodexResponses` (use `.openAIChatGPTResponses`; legacy
  `openai-codex-responses` and `openai` api ids still decode) and
  `ProviderCapability.memoryEmbedding` (use `.embedding`).
- `ModelCompatConfig.requiresMistralToolIDs` (retired upstream; still decoded,
  never encoded).
- `DeviceIdentityStore.loadOrCreate()` and `loadOrCreate(profile:)`: use
  `loadOrCreatePersistedOrThrow(profile:)` or
  `loadOrCreatePersistedInBackground(profile:)`. They no longer crash on storage
  failure; they log and return an ephemeral identity.
- `OpenClawChatTransport.listModels()` and `listSessions(limit:)`: implement
  `listModels(agentID:)` and `listSessions(limit:search:archived:)`.
- The single-argument-callback `GatewayChannelActor` initializer,
  `GatewayNodeSession.refreshNodeCanvasCapability`,
  `GatewayConnectChallengeSupport.nonce(from:)` / `waitForNonce(...)` and
  `BridgeHelloOk.canvasHostUrl` (use
  `GatewayNodeSession.pluginSurfaceURL("canvas")`).
- BlueBubbles (removed upstream): `BlueBubblesChannelAdapter` and the
  `BlueBubblesChannelConfig` typealias stay for one more release. Migrate with
  `ChannelsConfig.migrateBlueBubblesToIMessage()`.
- Canvas A2UI, `canvas.eval` and `canvas.snapshot` (retired upstream), the
  legacy TCP bridge frames, `ShareToAgentSettings`, `LocalNetworkURLSupport`,
  `OpenClawKitResources.canvasScaffoldURL`, the legacy
  `CameraCapturePipelineSupport` overloads and the `before_agent_start` hook
  alias (use `before_agent_run`).

### Removed

- Generated protocol types removed upstream:
  `SessionsCompaction{List,Get,Branch,Restore}{Params,Result}`,
  `SessionCompactionCheckpoint`, `TalkRealtimeSession{Params,Result}`,
  `NodePairRequestParams`, `NodePairVerifyParams`, the `SessionsPatchParams`
  spawn-lineage fields, `HelloOk.canvashosturl` and `ModelsListParams.models`.
- In-process methods removed upstream: `sessions.compaction.*`,
  `talk.realtime.session`, `node.pair.request`, `node.pair.verify`,
  `sessions.unsubscribe` and `node.canvas.capability.refresh` now answer
  `INVALID_REQUEST`.
- The implicit loopback gateway connection and `agent.run` send in
  `EmbeddedAgentRuntime` (`gatewayClient` is optional).
- The `#if canImport(ElevenLabsKit)` branch of `AudioStreamingProtocols.swift`
  and its `StreamingAudioPlayer` / `PCMStreamingAudioPlayer` typealiases; there
  is no ElevenLabsKit dependency.
- Catalog entries `openai-codex`, `gemini`, `foundation`, `kimi-coding` and
  `modelstudio` (now aliases), the `openai-codex` browser login descriptor
  (resolves to the `openai` ChatGPT login), and the local-only `discord` /
  `whatsapp_login` tool-display entries.

### Fixed

- Every package product builds with Xcode 27 / Swift 6.4 for iOS 17+, tvOS 17+,
  watchOS 10+ (arm64_32 and arm64), visionOS 26+ and macOS 14+; the iOS example
  app builds again with Xcode 27 (isolated-conformance errors in its Live
  Activity code) and both example apps pin the package's dependency versions.
- SDK-owned millisecond timestamps are `Int64`, so they no longer trap on 32-bit
  (arm64_32) Apple Watch: device identity and device auth, session records, auth
  profiles, pairing records, conversation memory, Watch notify params and
  Copilot/Qwen runtime auth.
- `AnyCodable` no longer turns JSON `0`/`1` into booleans, preserves 64-bit
  integers, maps `NSNull` to null and JSON-encodes `Encodable` values instead of
  stringifying them; the generated `AgentsUpdateParams.model` and
  `ChatSendParams.fastmode` compat accessors work with the enum-backed
  `AnyCodable`.
- `GatewayClient` typed requests surface remote gateway errors as
  `GatewayTransportError.remote(ErrorShape)` again, and connects no longer fail
  with `DEVICE_AUTH_SIGNATURE_EXPIRED` on devices with a skewed clock.
- `AsyncTimeout` no longer waits for an operation that ignores cancellation
  (keepalive wedge); Spotlight memory queries and `spotlight_search` are bounded
  by a non-joining timeout (default 3 s) and fall back to the in-memory mirror
  instead of hanging.
- Providers: `OpenAIResponsesModelProvider` and
  `OpenAIModelProvider(configuration:httpClient:)` no longer send plain requests
  through OpenAIKit 3.0.0, which dropped `/v1` and failed every request with
  404; factory-built Anthropic, OpenAI and OpenAI-compatible providers send the
  configured `headers` (for example `anthropic-workspace-id`) and OpenAI
  organization/project; non-streaming generate returns `stopReason` `.length`
  with usage when reasoning exhausts the output limit instead of throwing.
- The WASM skill executor no longer double-closes its stdio pipe descriptors;
  `CameraAuthorization` no longer emits the Swift 6.4
  `withCheckedContinuation(isolation:)` deprecation warning; the visionOS
  interactive-auth presentation anchor no longer uses the deprecated
  `UIWindow()`; `OpenClawChatHaptics` only uses UIKit feedback on iOS.
- Apple helpers: the NULL `ifa_addr` crash, concurrent location requests, camera
  session lifecycle on cancellation, WebView boolean results, UTF-8 Bonjour
  names and the discovery browser session.
- `TalkSystemSpeechSynthesizer` uses per-language watchdog timeouts, and a
  cancelled caller no longer stops the utterance already playing.
- The in-process gateway's first `session.message` sync starts at the run's
  start time, so a run's prompt is no longer skipped; the `canvasHost` doctor
  migration follows upstream.
- The example apps declare their background task identifiers and background
  modes in a merged `Info.plist` (Xcode ignores the
  `INFOPLIST_KEY_BGTaskSchedulerPermittedIdentifiers` build setting they used,
  so every registration was rejected), and submit a request only after its
  launch handler registered, because `BGTaskScheduler` raises an exception for a
  permitted identifier without a handler.

### Fixed and hardened in the release review

An adversarial review of the whole 2026.3.0 diff produced 128 findings; 119
were confirmed by an independent verifier and all of them are fixed, each with
a regression test.

#### Gateway and protocol
- Methods with a dynamic scope (`agent`, `sessions.create`/`patch`/`delete`,
  `node.invoke`, `fs.listDir`, `talk.config`, …) derive their required operator
  scopes from the request like upstream `method-scopes.ts` and fail closed;
  methods registered without a descriptor require `operator.admin`.
- `node.pair.approve` requires `operator.admin` for nodes declaring `system.run`
  or other admin-only commands.
- Event broadcasts are filtered by the receiving connection's role and scopes;
  `sessions.changed` reaches only connections that called `sessions.subscribe`.
- `tools.invoke` approval ids are bound to the exact invocation (tool,
  arguments, session, agent) and are single-use.
- Negative or huge pagination cursors (`tasks.list`, `tasks.history`,
  `approval.history`) and huge client timeouts no longer crash the host; timeouts
  are clamped to the upstream timer bound.
- The built-in `agent.wait` honors `timeoutMs`, reports failed runs as
  `{status: error}` and evicts finished runs; reusing an active idempotency key
  answers `in_flight` instead of starting a second run with the same id.
- Approval events use the upstream `…approval.requested`/`.resolved` wire
  shapes; decoding 2^63 into compat models no longer traps; loopback clients no
  longer reconnect every minute; secret-vault writes to one key are serialized.

#### Gateway client, node commands and Apple helpers
- The opt-in Network.framework transport applies the same TLS pinning policy as
  the URLSession transport (system trust, fail-closed pin storage, typed
  rejections that pause reconnects); a successful handshake clears an earlier
  pin-mismatch pause.
- Request deadlines start when the frame is sent, not before connect; an
  out-of-range `tickIntervalMs` or a non-finite timeout no longer crashes.
- `system.run` pre-launch checks read the approval policy snapshot from
  `systemRunPlan` and fail closed when an approved run has none.
- `file.fetch`/`dir.list`/`file.write` open files once without following
  symlinks and verify identity on the open descriptor, so a swapped path or FIFO
  cannot escape the allowed roots or hang the handler; error codes match
  upstream.
- App Intents runs are matched by run id; Now Playing relevance updates apply in
  order; device-auth token I/O during connect runs off the channel actor.
- New `OpenClawSDK.startGatewayServer(…)` attaches the embedded runtime and gates
  startup by default.

#### Providers and Apple Intelligence
- Provider streams (Chat Completions, Responses, Anthropic, Gemini, Ollama) fail
  when they end before the provider's terminal event instead of reporting a
  truncated turn as complete.
- `ModelRouter.generateStream` falls back to the next profile or provider when a
  stream fails before its first output, and cancellation no longer records
  failures or cooldowns.
- Gemini API keys move from the URL to the `x-goog-api-key` header; transport
  errors and router diagnostics no longer carry URLs or credential-looking
  values (`ProviderErrorRedaction`).
- OpenAI prompt-cache and session-affinity keys are opaque (SHA-256 of the
  session key) instead of the routing session key.
- Anthropic: budget thinking uses the upstream budgets; `AnthropicModelConfig`
  gains `headers` and `workspaceID` (`anthropic-workspace-id`, needed by
  organization-level keys); JSON-schema responses are unwrapped from Markdown
  fences so `response.text` decodes like on providers with native structured
  output (found by the live tests).
- Configs without `auth` use auth-profile credentials on the
  Anthropic-compatible, Gemini, Ollama and xAI routes; OAuth refresh uses an
  Int64 clock (watchOS arm64_32).
- Foundation Models agent sessions run every tool call through
  `FoundationModelsAgentToolGate` (tool policy, schema validation,
  `before_tool_call` hooks, approvals that fail closed); a Private Cloud Compute
  failure after in-process tools ran no longer falls back and replays them;
  framework-executed Vision/Spotlight tools are not offered for forced tool
  choices.
- Invalid CoreAI tensors throw instead of trapping, and concurrent CoreAI
  generations are queued; HEIC/HEIF/AVIF stills are no longer sniffed as video.

#### Agent runtime, skills, MCP and memory
- Exec allow-always grants bind to the exact argv and cwd; chains,
  substitutions, redirections, multi-line commands, shells and wrappers never
  get a durable grant; the approval gate passes the raw command to the
  allowlist, reviewer and approval card.
- Sub-agents and wake runs inherit the parent's permission mode, sandbox mode,
  tool overrides and run policy; hidden tools are refused when called by name;
  per-agent tool policies can only restrict the global policy.
- An abort, timeout or error during a tool batch no longer leaves unpaired tool
  calls, and replay repairs damaged transcripts; JSONL transcripts survive torn
  writes; model-supplied numbers no longer trap.
- `memory_search` no longer crashes on lines longer than the chunk size
  (duplicate chunk ids); Spotlight index writes, deletes and searches time out
  instead of hanging.
- MCP: a `tools/call` is never replayed after it may have reached the server;
  remote JSON-RPC ids that do not fit `Int` no longer crash; the legacy SSE
  connect timeout fires; stdio servers can no longer kill the host with SIGPIPE,
  `close()` escalates even during a blocked write, and loader/interpreter
  injection variables are dropped from server environments.
- Cron: editing jobs no longer cancels the running automation; `every`
  schedules enforce upstream limits; six-field expressions are accepted.
- `PluginRegistry` change listeners broadcast `plugins.changed`.

#### Channels
- HTTP 5xx send failures are unknown outcomes and are never replayed blindly;
  partially delivered multi-part sends are never retried.
- Skill commands require an authorized sender in groups; WhatsApp Cloud
  webhooks verify `X-Hub-Signature-256`; webhook secrets compare in constant
  time; A2A outbound calls refuse redirects; Twilio media fetches are bound to
  the message; bot tokens and credentials are redacted from channel health and
  diagnostics.
- The Discord gateway dispatches off its receive loop, so slow agent turns no
  longer stall heartbeats; A2A tasks pending when the turn ends are failed.
- Chunk limits count UTF-16 code units like the platforms do; remote
  `Retry-After` and size budgets can no longer overflow.

#### Config and security
- The exec allowlist fails closed for backslash-newline continuations,
  `$\⏎(` substitutions, dynamic executables, leading assignments and subscript
  substitutions, and never matches `sudo`, `doas`, `su`, `env` with modifiers or
  busybox shell applets.
- `SecurityRuntime` re-reads the allowlist store before every evaluation and
  changes it transactionally, so revoked rules are not honored or written back;
  the legacy `default` exec-approvals agent folds into `main`.
- Exec secret providers are bounded by their timeouts and output limits and
  kill the whole process group on failure; env/store refs naming an
  unconfigured provider alias are rejected.
- Gateway config import keeps authored values and writes back only what
  changed; legacy `routing.*` keys are migrated instead of deleted; the
  `agents.list` migration pins the first agent's workspace like upstream doctor.

#### ChatUI and ChatStore
- `OpenClawGatewaySessionChatTransport` replays the durable outbox only when
  bound to a gateway (`gatewayStableID`) and refuses reads from a different
  gateway; a route change drops branch reconciliation made against the previous
  gateway.
- Link previews resolve hostnames before each request and redirect and require
  public addresses (NAT64 and IPv4-mapped peers included).
- The GRDB databases observe suspension notifications and coordinate first open
  and migration with `NSFileCoordinator`; the cache is no longer deleted on lock
  contention.
- Agent and `session.tool` events decode millisecond timestamps as Int64, so
  they are no longer dropped on watchOS arm64_32.

### Security

- Local-network policy follows upstream: Tailscale (`*.ts.net`,
  `*.tailscale.net`, `100.64.0.0/10`) and single-label hosts are no longer
  "local", so cleartext `ws://` to them is rejected; IPv6 ULA and link-local
  hosts count as local. `GatewayTransportSecurityPolicy` classifies gateway
  URLs; `LocalNetworkHostPolicy.current = .legacyPermissive` restores the old
  behavior.
- Gateway TLS pinning enforces stored pins, requires system trust before
  first-use pinning, binds challenges to the requested host and port, and moves
  pins to a v3 Keychain store (old pins are migrated). Pin changes require
  explicit review (`GatewayTLSPinRotationRequest`).
- Share-extension relay secrets move from App Group defaults to the Keychain,
  and the App Group is configurable (`OpenClawAppGroupIdentifier`).
- Channels enforce the upstream access defaults (`dmPolicy: pairing`,
  `groupPolicy: allowlist`), bot-loop protection, and signed webhooks (Twilio
  HMAC-SHA1, Slack and LINE signatures with constant-time comparison); A2A peers
  authenticate with bearer tokens and are rate limited.
- File-backed SecretRefs must be regular, single-link files owned by the current
  user with no group/world access; exec SecretRef commands must be absolute,
  non-symlink, owned by the current user, not group/world-writable and inside
  `trustedDirs` when set (the `allowInsecurePath` / `allowSymlinkCommand`
  opt-outs are ignored). Placeholder shared secrets are rejected.
- The security audit honors `security.audit.suppressions`, scans config
  documents for plaintext secrets, checks gateway shared-secret strength and
  reports channel secret findings.
- Native state and SDK state files are private (`0700` directories, `0600`
  files, data protection); ChatUI link previews are off by default and fetch
  only public addresses; LinkSecurity and TrustInsights add confirmation
  friction on OS 27; macOS `system.run` re-checks the approved executable before
  launch.

### Breaking changes

Each item lists the migration. Snippets are in the DocC article "Migrating to
2026.3".

- Protocol v4: operator connections require protocol 4 and are rejected by
  pre-v4 gateways (for example `2026.4.x`). Migration: upgrade the gateway, or
  connect with `GatewayConnectOptions(minimumProtocolVersion: 3, …)` and gate
  v4-only UI on `negotiatedProtocolVersion()`.
- Generated protocol shapes: `ResponseFrame.error` is `ErrorShape?` (was
  `[String: AnyCodable]?`); `HelloOk.canvashosturl` is gone (use
  `pluginsurfaceurls?["canvas"]`); `HelloOk.auth` is non-optional;
  `Snapshot.updateavailable` is the typed `UpdateAvailable`;
  `SessionsSendParams.attachments` is `[[String: AnyCodable]]?`. Migration: read
  `error.code`/`message`/`details` or `errorCode`/`typedDetails`; drop uses of
  the removed types and spawn-lineage fields.
- `GatewayAgentAccepted`, `GatewayAgentWaitParams` and `GatewayAgentWaitResult`
  encode `runId` (decoding still accepts `runID`);
  `GatewayResponseError.details` is flattened like upstream. Migration:
  third-party decoders read `runId`; read flattened `code`, `message`,
  `retryable` and `retryAfterMs` from `details`.
- In-process gateway: removed upstream methods answer `INVALID_REQUEST`, the
  unknown-method and invalid-params messages changed, requests are
  role/scope-checked, and `sessions.patch` rejects `execSecurity`/`execAsk`
  (even `null`). Migration: use `permissionMode` in `sessions.patch`; give each
  `LoopbackGatewaySocket` its own `connectionID` and subscribe with
  `sessions.messages.subscribe` to receive `session.message`/`session.tool`.
- `GatewayChannelActor`'s primary initializer passes the socket generation to
  `pushHandler` and `disconnectHandler`. Migration: adopt `{ push, generation in
  … }` / `{ reason, generation in … }`; the single-argument initializer is
  deprecated and requires `pushHandler`.
- `GatewayDeviceAuthPayload.signedDeviceDictionary(…signedAtMs:)` and
  `buildV3(…signedAtMs:)` take `Int64`; `GatewayConnectAuthDetailCode` and other
  public enums gained cases (`OpenClawCapability`, `OpenClawNodeErrorCode`,
  `OpenClawCameraCommand`, `ChannelID`, `ThinkLevel`, `ModelAPI`,
  `ModelInputType`, `ModelReasoningEffort`, `ModelServiceTier`,
  `ProviderCapability`, `SkillSource`,
  `FoundationModelsRuntimeAvailability.Reason`, `OpenClawChatTransportEvent`,
  config enums). Migration: convert `Int` variables with `Int64(_:)`; add the
  new cases or a `default:` branch to exhaustive switches.
- Millisecond timestamps changed from `Int` to `Int64`:
  `DeviceIdentity.createdAtMs`, `DeviceAuthEntry.updatedAtMs`,
  `SessionRecord.updatedAtMs`, `ResolvedSessionState.updatedAtMs`,
  `GatewaySessionInfo.updatedAtMs`, `ConversationMemoryEntry.createdAtMs`,
  `PairingRecord.approvedAtMs`, auth-profile timestamps and
  `OpenClawWatchNotifyParams.expiresAtMs` (`Int64?`). Migration: integer
  literals still compile; convert `Int` variables with `Int64(_:)`.
- Native state: device identity and tokens are imported once into
  `state/openclaw.sqlite` and the JSON files are deleted; downgrading afterwards
  creates a new identity and requires re-pairing.
  `DeviceIdentityStore.loadOrCreate()` is deprecated. Migration: call
  `loadOrCreatePersistedOrThrow(profile:)` (or the `…InBackground` variant from
  actors); build with the new SDK before shipping to paired devices.
- Channels default to `dmPolicy: pairing` and `groupPolicy: allowlist` with
  `requireMention`, and `AutoReplyEngine.process(_:)` throws
  `AutoReplyIngressRejection` when nothing is sent. Migration: pass a
  file-backed `ChannelPairingStore(stateDirectory:)` and approve codes
  (`channels.pairing.approve` or the store APIs), configure
  `allowFrom`/`dmPolicy`/`groupAllowFrom` per channel, or set
  `channels.compatibility.ingressAccessPolicy = "legacy-allow-all"`; call
  `handle(_:)` or `processIfAllowed(_:)` to observe rejections without an error.
- `InboundMessage.accountID` means the channel account key and the sender moved
  to `senderID`; built-in adapter session keys change from
  `<channel>:<sender>:<peer>` to `<channel>:<peer>`. Migration: set
  `channels.compatibility.legacySessionAccountKeys = true` to keep existing
  session keys and conversation memory.
- Channel adapters: `ChannelAdapter.supportsTypingIndicator` (default `false`)
  must return `true` for adapters that send typing indicators; channel secret
  `String` properties return nil for SecretRef/`${ENV}` values. Migration:
  implement `supportsTypingIndicator`; resolve secrets with
  `ChannelsConfig.resolvingSecrets(using:)` before building adapters.
- Provider identity: `FoundationModelsProvider.providerID` is `"apple-fm"` and
  responses report model `system`; the `openai-codex`, `gemini`, `foundation`,
  `kimi-coding` and `modelstudio` catalog entries are aliases;
  `ProviderCapability.memoryEmbedding` is `.embedding`. Migration: use
  `FoundationModelsProvider.providerID` / `systemModelID` instead of literals
  (or register `FoundationModelsProvider(id: "foundation")`), and migrate stored
  refs with `OpenClawReferenceProviderCatalog.canonicalizeModelRef(_:)`.
- Provider configs encode `baseUrl` and omit defaults; a missing `baseUrl`
  decodes as `""` and is filled from the catalog; Anthropic calls
  `<base>/v1/messages`; Ollama uses `/api/chat`;
  `ModelProviderFactory.makeProvider` throws for an unrecognized `api` and may
  return `RoutingModelProvider`. Migration: re-save configs with the new
  encoder; do not rely on concrete factory return types.
- Custom `ModelProvider`s: the runtime no longer sets
  `ModelGenerationPolicy.reasoningEffort` from `ThinkLevel`. Migration: read
  `policy.thinkingLevel` (see `ReasoningEffortResolver`); declare
  `ModelProviderCapabilities` to opt into transcripts and tools.
- Agent runtime: providers declaring contract-v2 capabilities run the multi-turn
  tool loop, and Tool Search hides non-direct tools behind
  `tool_search`/`tool_describe`/`tool_call` at 12 or more tools. Migration:
  disable with `AgentToolsConfiguration(toolSearch:
  ToolSearchConfiguration(enabled: false))` or cap turns with
  `AgentLoopConfiguration`.
- ChatGPT OAuth: the `openai-codex` login resolves to the `openai` ChatGPT login
  with the loopback callback `http://localhost:1455/auth/callback` (was
  `http://127.0.0.1:1455/oauth-callback`). Migration: update registered redirect
  URIs.
- Config: SecretInput `$NAME` is an env SecretRef; placeholder shared secrets
  fail validation; `ConfigStore.save` merges onto the existing file;
  `OpenClawConfigDocument.Channels` is `ChannelsConfigDocument`; file/exec
  SecretRef hardening fails closed; `AuthProfileConfig` keeps profiles with
  unknown modes. Migration: store literal secrets shaped like `$NAME` through a
  `file` or `store` SecretRef, replace placeholder secrets, `chmod 600` secret
  files, and move exec provider commands into `trustedDirs`.
- Security: tailnet and single-label `ws://` gateways are rejected, TLS
  first-use pinning needs a system-trusted certificate, stored pins are
  enforced, and a pin mismatch stops auto-reconnect until the host accepts the
  rotation. Migration: use `wss://` (Tailscale Serve) or
  `LocalNetworkHostPolicy.current = .legacyPermissive`; show
  `pendingTLSPinRotationRequest()` and call `acceptTLSPinRotation(_:)` after
  user confirmation.
- `ShareGatewayRelaySettings` keeps its token and password in the Keychain and
  follows `OpenClawAppGroupIdentifier` instead of `group.ai.openclaw.shared`.
  Migration: add the Info.plist key to the app and every extension, plus the
  keychain access-group entitlement; an extension-first upgrade needs a
  reconnect from the host app.
- `StreamingPlaybackResult` gains `finished`/`interruptedAt`, and the
  ElevenLabsKit typealiases are gone. Migration: custom
  `PCMStreamingAudioPlaying` players return `finished: false` with
  `interruptedAt` when stopped; wrap ElevenLabsKit players in a small adapter.
- `OpenClawChatTransportEvent` has new cases and `OpenClawChatTransport` v2
  requirements have defaults that throw "not supported". Migration: handle the
  new cases or add `default:`; implement `listModels(agentID:)` and
  `listSessions(limit:search:archived:)`, or adopt
  `OpenClawGatewaySessionChatTransport`.
- `OpenClawIntentGatewayRequesting` is a typealias of `GatewayRequestSending`,
  `GatewayConnectOptions.defaultNode` no longer advertises `canvas.eval`,
  `canvas.snapshot` or `canvas.a2ui.*`, `HookName` raw values follow upstream
  snake_case, `MemoryIndex` scores are normalized BM25, and
  `AgentToolResult.value` is computed. Migration: retune memory thresholds; move
  canvas integrations to the presenter commands.

- Release-review hardening (behavior): exec allowlists never match `sudo`,
  `doas`, `su`, `env` with modifiers or shell carriers, and `<shell> -c …` is
  matched command by command; `SecurityRuntime` re-reads its allowlist store;
  env/store secret refs must name a configured provider alias. Migration: add
  argPattern-bound rules for shells you intentionally allow and configure the
  aliases you reference.
- Release-review hardening (behavior): channel sends treat HTTP 5xx as an
  unknown outcome (no blind retry), `ChannelSendError` gains
  `partiallyDelivered(receipt:failure:)`, and chunk limits count UTF-16 code
  units by default. Migration: handle the new case; pass `.chars` to the chunker
  if you relied on grapheme counting.
- Release-review hardening (behavior): provider streams that end without a
  terminal event now throw; `RuntimeProviderAuthResolver` takes an Int64 clock;
  `ModelProviderFactory.makeProviders(from:)` skips alias keys instead of
  building duplicate providers. Migration: fix non-conformant OpenAI-compatible
  servers that close without `[DONE]`/`finish_reason`; pass Int64 clocks.
- Release-review hardening (behavior): gateway methods registered without a
  descriptor require `operator.admin`; connection-bound event subscribers see
  only events their role and scopes allow; approval events use the upstream
  shapes. Migration: register descriptors with the scopes your methods need and
  call `sessions.subscribe` for `sessions.changed`.

### Tests

- 3,711 macOS tests pass under `swift test` (Swift Testing: 3,147 in
  `OpenClawKitTests`, 544 in `OpenClawLinuxRuntimeTests`, 20 E2E), including ported
  upstream suites for generated protocol models, gateway channel and node
  session, native state (85 upstream tests), Talk relay and voice selection,
  Watch commands and chat delivery, ChatUI core, rendering, shell, store and
  outbox, provider catalog and runtime, Apple FM, media understanding, channels,
  config documents and the agent runtime.
- 533 Linux tests (`OpenClawLinuxRuntimeTests`) pass in the Swift 6.2 Docker
  gate, including smoke suites for protocol sync, channels core and adapters,
  media understanding and the config contract corpus.
- Gated live suites: `LiveProvider*Tests` (OpenAI Responses, OpenAI Chat
  Completions, Anthropic Messages, xAI, agent loops; run with
  `OPENCLAW_LIVE_PROVIDER_TESTS=1`), `AppleFoundationModelsLiveTests`
  (`OPENCLAW_LIVE_APPLE_FM=1`, plus `OPENCLAW_LIVE_APPLE_PCC=1`), media
  (`OPENCLAW_LIVE_APPLE_MEDIA=1`, `OPENCLAW_LIVE_SPEECH=1`) and CoreAI
  (`OPENCLAW_COREAI_MODEL_PATH`). The final live provider pass on the release
  tree ran 67 tests in 6 suites and all passed: OpenAI Responses, OpenAI Chat
  Completions, Anthropic Messages (including signed extended thinking replayed
  before tool use; organization-level keys need `ANTHROPIC_WORKSPACE_ID`), xAI,
  the OpenAI/Anthropic/xAI agent loops with a real tool, and router fallback for
  both `generate` and `generateStream` (63 billed calls on the cheapest models,
  well under $0.05).
- Release gates: `swift build -Xswiftc -warnings-as-errors`,
  `Scripts/lint-swift.sh` (0 violations, Examples included),
  `Scripts/validate-apple-matrix.sh`, `Scripts/build-apple-platforms.sh all`
  (all five platforms, watchOS arm64_32 and arm64),
  `Scripts/check-apple-weak-links.sh all`, `Scripts/typecheck-apple-sdks.sh
  all`, `Scripts/check-upstream-drift.sh`, the Linux Swift 6.2 gate,
  `Scripts/build-docs-site.sh` and the iOS and tvOS example builds.

## 2026.2.5.1 - 2026-04-26

### Fixed

- Fixed visionOS package builds by compiling out AVFoundation photo/movie
  capture helpers whose underlying `AVCapturePhotoOutput`,
  `AVCaptureMovieFileOutput`, and session-preset APIs are unavailable in the
  visionOS SDK. The shared camera command models still compile for visionOS,
  while unsupported native capture wiring remains absent on that platform.

### Tests

- Added `Scripts/build-visionos-package.sh` and a `visionos` leg to the Apple
  platform CI matrix so the `OpenClawKit` SwiftPM scheme is built against
  `generic/platform=visionOS`.

## 2026.2.5 - 2026-04-25

### Added

- OpenClaw `2026.4.25` SDK/control-plane parity pinned to `.codex/openclaw`
  commit `6b0c72bec8`, including regenerated gateway protocol models and
  compatibility shims for existing OpenClawKit gateway payloads.
- Generated protocol coverage for new upstream request/result surfaces:
  message actions, session creation/send/abort, session compaction checkpoints,
  talk realtime/speech requests, command/tool catalog requests, skill
  search/detail requests, and approval control-plane payloads.
- Provider catalog parity for the `2026.4.25` train, including
  `anthropic-vertex`, `amazon-bedrock-mantle`, `arcee`, `chutes`,
  `copilot-proxy`, `deepseek`, `fireworks`, `lmstudio`,
  `microsoft-foundry`, `qwen`, `stepfun`, `stepfun-plan`, and
  `tencent-tokenhub`.
- Capability-aware provider metadata for upstream media, speech, embedding,
  web-search, image-generation, video-generation, and music-generation plugin
  providers that are metadata/config-visible without native Swift runtime
  adapters.
- Channel metadata parity for upstream plugin channels including `feishu`,
  `irc`, `matrix`, `mattermost`, `nextcloud-talk`, `nostr`, `qqbot`,
  `synology-chat`, `tlon`, `twitch`, `zalo`, `zalouser`, and `qa-channel`,
  with native transport availability explicitly marked.

### Changed

- `openai-codex` now defaults to upstream `gpt-5.5` for the pinned parity
  snapshot.
- The in-process gateway server now recognizes and decodes newly known
  control-plane methods, returning explicit unavailable responses for
  metadata-only or unconfigured Swift behavior instead of treating them as
  unknown requests.
- `.codex/` is ignored so the embedded upstream reference checkout remains a
  local-only parity input.

### Tests

- Added snapshot and fixture coverage for new protocol payloads, provider
  capabilities, channel metadata, plugin-channel secret auditing, and known
  gateway-method unavailable/error-code mapping.
- `swift test` remains locally blocked by the machine/toolchain error
  `no such module 'Testing'`; `swift build -Xswiftc -warnings-as-errors`
  passes for the package source.

## 2026.2.4 - 2026-03-14

### Added

- OpenClaw `2026.3.13` protocol and gateway/session snapshot parity, including
  the generated Swift gateway models, richer session metadata, and checked-in
  parity fixtures pinned to upstream commit
  `61cd3a6e446c3d181a0a75861fd85d459c068a3d`.
- Shared Swift package parity surfaces from upstream OpenClaw:
  `OpenClawChatUI`, gateway discovery/channel helpers, device-auth storage,
  push payloads, TLS pinning, talk/browser/camera/location/share helpers, and
  generic password keychain storage.
- Canonical secrets configuration with `SecretRef`, `SecretInput`,
  `SecretProviderConfig`, `SecretsConfig`, env/file/exec providers, and
  backward-compatible plaintext decoding.
- Expanded gateway config parity for `auth`, `remote`, `tailscale`,
  `controlUi`, `http`, and `push` blocks, with secret-aware gateway
  credentials and APNs relay support.
- Auth profile parity for ref-backed credentials, richer snapshots, cooldown and
  last-good metadata, and secure-store migration from legacy inline secrets.
- Provider catalog parity updates including `sglang`, current Codex Spark
  filtering behavior, and the `2026.3.13` provider reference fixture.
- Session/runtime fast-mode parity, including per-model defaults, session
  overrides, runtime forwarding, and provider-specific request shaping.

### Changed

- Direct OpenAI and Codex-backed OpenAI providers now use `OpenAIKit` `3.0.0`
  behind an OpenClawKit-owned adapter layer for configuration, auth, request
  building, and error normalization.
- Direct OpenAI responses requests now use OpenAIKit when the public surface is
  sufficient, with a local advanced adapter path preserved for richer response
  payloads such as multimodal inputs, reasoning, service-tier shaping, and
  Codex transport behavior.
- Direct Anthropic API-key fast mode now maps to Anthropic `service_tier`
  semantics, while OAuth and proxy Anthropic paths skip implicit fast-tier
  injection.
- README and parity manifests now document the `2026.2.4` release baseline,
  canonical secrets/gateway config, OpenAIKit-backed OpenAI behavior, fast
  mode, and `sglang` defaults.

### Tests

- Added regression coverage for imported protocol fields, secrets decoding,
  gateway config parity, auth profile parity, session-store parity, OpenAIKit
  backend mapping, OpenAI/Codex responses behavior, provider filtering, and
  fast-mode request shaping.
- Revalidated `swift build -Xswiftc -warnings-as-errors` and `swift test`
  across the final `2026.2.4` release candidate.

## 2026.2.3 - 2026-03-12

### Added

- Session-control parity for the OpenClaw `2026.3.11` runtime model:
  persisted thinking, reasoning, verbosity, usage, elevation, group
  activation, send policy, exec settings, labels, and model overrides.
- In-process gateway control-plane support for typed agent, session, model,
  skill, secret, and `browser.request` operations, including browser mutation
  guards and local secret-vault bridging.
- Built-in `llm-task` structured-generation support with JSON-first output
  validation, reasoning sanitization, and malformed tool-call repair paths.
- Exec allowlist enforcement shared by `ProcessRunner`, JS/WASM skill
  execution, and gateway/browser-adjacent helpers.
- Shared media fetch/store/handle primitives for local files, URLs, and memory
  blobs, plus BlueBubbles as a first-class channel adapter.
- Checked-in Swift-side control-plane parity fixtures to keep provider, session,
  gateway, `llm-task`, and channel assertions independent from `.cursor/**` at
  runtime.

### Changed

- README, testing docs, and the `2026.3.11` parity manifest now describe the
  shipped `2026.2.3` parity surface, the validated release rules for the train,
  and the checked-in fixture sources used by the test suite.
- Session defaulting now only applies when a session is first created or reset,
  preserving persisted operator overrides on ordinary inbound traffic.
- iMessage routing is no longer simulation-first when a native transport is
  present, and Telegram restart behavior is scoped to polling-network failures
  instead of retrying duplicate-prone outbound sends.

### Tests

- Added regression suites for session controls, gateway request decoding,
  `llm-task`, exec allowlists, media handling, BlueBubbles/iMessage/Telegram
  channel behavior, and checked-in control-plane fixtures.
- Revalidated `swift build -Xswiftc -warnings-as-errors`,
  `Scripts/check-networking-concurrency.sh`, `swift test`, iOS example
  build/test, tvOS example build, and Apple matrix validation for macOS + iOS.

## 2026.2.2 - 2026-03-11

### Added

- Canonical TS-shaped model/auth config surface:
  `OpenClawConfig.auth`, canonical `models.providers`, Bedrock discovery
  settings, auth profiles, and shared provider catalog parity against the pinned
  OpenClaw TS reference.
- Auth profile persistence and routing:
  secure credential indirection through `CredentialStore`, profile cooldown and
  last-good tracking, and router integration for profile-aware fallback.
- Interactive auth descriptors and Apple browser-auth presentation helpers for
  OAuth-capable providers, with device-code metadata for Copilot/Qwen-style
  sign-in flows.
- Provider parity coverage for additional TS-main families and APIs, including
  `openai-codex`, Google Generative AI-style providers, GitHub Copilot, and the
  coding-focused provider aliases in the shared catalog.
- Checked-in provider catalog snapshot coverage via
  `ProviderCatalogReferenceFixture` to keep parity tests independent from
  `.cursor/**` at runtime.

### Changed

- Apple Keychain credentials now default to
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` for device-bound, unlock-only
  storage.
- Apple sample defaults now prefer Foundation Models when the runtime reports
  Apple Intelligence availability, while leaving generic config decoding
  behavior unchanged.
- The incomplete visionOS spatial demo has been deferred from `2026.2.2`; the
  shipped example-app validation gate now covers iOS and tvOS only.
- README, testing docs, and parity notes now describe the Apple hardware model,
  canonical Swift config sources, and the current validation gate.
- Legacy provider-service JSON now decodes into canonical provider configs
  without losing auth mode, API style, or default model information.

### Tests

- Added regression coverage for auth profile persistence, rotation ordering, and
  Keychain accessibility query handling.
- Added provider catalog parity snapshot assertions plus canonical/legacy config
  serialization coverage for `models.providers`.
- Revalidated `swift build -Xswiftc -warnings-as-errors` and `swift test`.

## 2026.2.1 - 2026-03-01

### Added

- Channel adapter parity wave completed:
  - Slack, Google Chat, Signal, iMessage, Microsoft Teams, and production WebChat adapters
  - parity expansion for `WhatsAppCloudChannelAdapter` diagnostics/webhook handling.
- Model service parity completed across remaining OpenClaw provider families:
  - first-class `xai` / Grok support
  - OpenAI-compatible packs: `openrouter`, `groq`, `mistral`, `cerebras`,
    `moonshot`, `litellm`, `together`, `huggingface`, `qianfan`, `nvidia`, `zai`
  - Anthropic-compatible/gateway pack: `minimax`, `minimax-portal`, `synthetic`,
    `xiaomi`, `cloudflare-ai-gateway`, `vercel-ai-gateway`
  - unique protocol pack: `amazon-bedrock`, `github-copilot`, `ollama`,
    `vllm`, `qwen-portal`.
- Generic provider-service model layers:
  - `ProviderServiceOpenAIModelProvider`
  - `ProviderServiceAnthropicModelProvider`
  - `BedrockConverseModelProvider`
  for consistent config/auth handling across provider families.

### Changed

- `OpenClawConfig` channel/model config surfaces now fully cover the parity matrix
  with backward-compatible decode defaults.
- `SecurityAuditReport` now audits newly added channel/provider credentials and
  emits risky-default findings for parity-specific misconfiguration cases.
- iOS sample deployment/state flows now expose all parity providers/channels and
  persist credentials through secure storage with migration-safe settings updates.

### Tests

- Expanded adapter test suites for new channel behavior, mention-only gating, and
  webhook/transport edge handling.
- Expanded model routing tests for all parity providers plus auth/api-style
  validation failures and protocol-specific request expectations.
- Expanded config/security regression suites for provider matrix serialization and
  security-audit parity checks (including local auth-none exemptions and provider
  secret detection).
- Kept full per-commit validation gate green:
  Swift warnings-as-errors build, networking concurrency check, `swift test`,
  iOS build/test scripts, and Apple matrix validation for macOS + iOS.

## 2026.2.0 - 2026-03-01

### Added

- Deterministic replay runtime foundations:
  - `ReplayEvent` / `ReplayEventEnvelope` schema contracts
  - append-only `ReplayStore` with compaction/recovery
  - deterministic `ReplayEngine` query/replay APIs
  - SDK replay facade methods for run/session/time-window filtering
- Secure replay-ledger signing surfaces with integrity-oriented metadata and
  signing hooks for Apple Secure Enclave-backed strategies.
- Instruments-native runtime timeline sink + diagnostics export plumbing for
  signpost/OSLog workflow integration.
- Adaptive routing policy state and scoring model with closed-loop feedback from
  runtime/provider diagnostics.
- WASM skill execution runtime support integrated into the invocation engine.
- Personal-data skills kit with connector metadata, frontmatter parsing, policy
  enforcement, and Apple connector adapter scaffolding.
- Intent graph promoted to first-class SDK/protocol/runtime surface:
  - `IntentGraph` models in `OpenClawProtocol`
  - runtime graph construction/execution APIs
  - SDK facade methods for graph generation and graph-backed runs
- Dynamic iOS App Intents + shortcuts wired to intent-graph-aware bridge flows
  and selectable node-kind entities.
- Live Activities support for long-running runs in the iOS sample, including
  diagnostics-driven progress/status updates.
- Proactive automation layer:
  - persisted rule store (`AutomationRuleStore`)
  - execution runner (`AutomationRunner`)
  - background continuation hooks for scheduled automation ticks
- Multimodal on-device session mode:
  - `MediaAttachment` protocol model
  - runtime attachment normalization/injection
  - channel attachment forwarding
  - iOS chat attachment import/staging UX
- SwiftData + CloudKit-ready memory graph bridge:
  - `ConversationMemoryStoreProtocol`
  - `SwiftDataMemoryGraphStore`
  - legacy conversation-memory migration helper.
- Ask OpenClaw share-extension scaffold and app inbox bridge contract for
  prompt handoff via App Group defaults.
- Apple platform matrix CI validation (`Scripts/validate-apple-matrix.sh`) and
  CI workflow matrix coverage.

### Changed

- `OpenClawConfig.runtime` now includes `memoryGraph` controls for staged
  rollout of SwiftData/CloudKit memory backends.
- iOS sample app startup now consumes share-inbox payloads into the chat
  composer for extension-to-app continuity.
- CI now validates Apple platform declarations and share-extension artifacts in
  addition to existing Swift/Linux/iOS build gates.

### Tests

- Expanded replay/runtime diagnostics tests for deterministic sequence ordering,
  provider fallback metadata, and SDK replay filtering behavior.
- Added skill connector parsing/enforcement tests and permission grant/deny
  invocation coverage.
- Added intent graph SDK facade tests and iOS intent bridge/entity tests.
- Added Live Activity and multimodal iOS/UI/runtime/channel assertions.
- Added proactive automation rule-store/runner tests and background hook tests.
- Added memory-graph migration/config regression tests for SwiftData+CloudKit
  bridge behavior.

## 2026.1.5 - 2026-02-28

### Added

- Runnable iOS example unit/UI test harness (`OpenClawiOSTests`,
  `OpenClawiOSUITests`) plus a dedicated `Scripts/test-ios-example.sh` gate.
- iOS sample Telegram deployment controls (bot token + chat target) wired through
  runtime startup/teardown and secure credential persistence.
- Telegram replay hardening primitives with a persistent
  `TelegramUpdateOffsetStore` and duplicate-update guard logic.
- Additional deterministic sample skills in the iOS example:
  `calculator`, `slugify`, and `json-pretty`.
- Chat skill selection menu in the iOS sample that supports explicit
  slash-command skill routing from user input.
- iOS App Intents/App Shortcuts for deploy/stop/quick-ask actions and a
  background continuation manager using `BGTaskScheduler` with iOS 26
  `BGContinuedProcessingTaskRequest` availability guards.

### Changed

- iOS skills bundling is now deterministic via explicit resource copying and a
  build-time verification script (`Scripts/verify-ios-skills-bundle.sh`) that
  asserts bundled `skills/weather/SKILL.md` presence.
- iOS keyboard ergonomics are improved across chat/deploy/models screens with
  keyboard toolbar dismissal and interactive scroll dismissal behavior.
- iOS app metadata now enables App Intents extraction and background-task
  permitted identifiers for refresh/processing/continued-processing flows.

### Tests

- Added iOS app-state persistence coverage for Telegram settings and legacy
  secret decoding paths.
- Added iOS UI coverage for Telegram deploy fields, keyboard dismissal toolbar +
  interactive scroll behavior, and chat skill-picker visibility.
- Expanded Telegram adapter tests with restart-offset resume and
  duplicate-update dedupe assertions in both unit and E2E suites.
- Expanded skill tests to validate bundled sample-skill discovery and explicit
  invocation behavior for hyphenated skill names.

## 2026.1.4 - 2026-02-23

### Added

- Cross-platform credential storage primitives with `CredentialStore`, including
  `KeychainCredentialStore` on Apple platforms and `FileCredentialStore`
  fallback behavior for non-Keychain environments.
- Streaming runtime execution surface (`EmbeddedAgentRuntime.runStream`) and
  channel streaming integration path for progressive output handling.
- Typing heartbeat lifecycle support in auto-reply orchestration for Discord and
  Telegram long-running reply flows.
- Security audit primitives (`SecurityAuditRunner`, `SecurityAuditReport`) for
  risky defaults, plaintext-secret detection, and filesystem permission checks.
- Per-channel outbound throttling (`ChannelSendThrottlePolicy`) and per-provider
  throttling (`ModelProviderThrottlePolicy`) with delay/drop strategies.

### Changed

- iOS example deploy settings now persist secrets in secure storage with one-time
  legacy plaintext migration and scrubbed JSON persistence.
- iOS example skills are project-owned and sourced from
  `Examples/iOS/OpenClawiOS/skills` instead of repo-root `skills/`.
- Auto-reply runtime flow now supports optional stream-driven response assembly
  and emits stream-chunk diagnostics when enabled.
- `OpenClawSDK` now exposes `runSecurityAudit(...)` and can publish audit
  findings into `RuntimeDiagnosticsPipeline`.

### Tests

- Added credential migration and secure-store selection coverage for keychain +
  fallback semantics.
- Added iOS project-skills discovery regression coverage in `SkillRegistryTests`.
- Added runtime streaming and auto-reply stream-path tests, including chunk/final
  marker assertions.
- Added typing heartbeat cadence/stop-condition tests for both Discord and
  Telegram channels.
- Added security audit coverage for severity classification, hardened-config
  baselines, and diagnostics publication.
- Added channel/model throttling regression coverage for burst delay, drop
  behavior, retry diagnostics, and provider fallback behavior.

## 2026.1.3 - 2026-02-19

### Added

- Model runtime parity contracts for streaming generation, cancellation-aware policies,
  fallback provider chains, and local runtime hints.
- Local model runtime integration upgrades: runtime switching, model lifecycle control,
  state save/restore hooks, token streaming, and cancellation token propagation.
- Skills parity expansion with pluggable executor backends, explicit-only invocation
  policy controls, per-skill/default timeout enforcement, and richer invocation metadata.
- Channel/runtime reliability primitives including health snapshots, retry/backoff
  policy controls, built-in command handling (`/health`, `/status`, `/help`), and
  stronger outbound delivery status tracking.
- Centralized diagnostics and usage pipeline (`RuntimeDiagnosticsPipeline`) with
  app-queryable snapshots for runs, model calls, skill usage, and channel delivery.
- iOS example app expansion into a multi-tab runtime console for Deploy, Chat, Models,
  Skills, Channels, and Diagnostics workflows.

### Changed

- Runtime diagnostics types are now shared in `OpenClawCore` and emitted from both
  `EmbeddedAgentRuntime` and channel auto-reply flows with stable metadata fields.
- `OpenClawSDK` now supports diagnostics pipeline injection for web-channel monitoring
  and one-shot reply flows.
- Gateway reconnect cancellation handling is hardened to avoid lingering reconnect
  loops after disconnect/teardown.

### Tests

- Added dedicated diagnostics pipeline tests for aggregate metrics, sink wiring,
  and SDK-level integration.
- Added channel auto-reply regression coverage for outbound failure diagnostics and
  retry-attempt metadata assertions.
- Added runtime timeout diagnostics regression coverage and gateway reconnect-stop
  E2E assertions after explicit disconnect.

## 2026.1.2.1 - 2026-02-17

### Fixed

- GitHub Actions Swift validation now consistently provisions the Swift 6.2.0
  toolchain required by the package tools version.
- CI Swift setup is hardened against transient upstream signing-key fetch issues
  by using resilient setup options in workflow configuration.
- Linux compatibility is restored for HTTP model/channel providers by adding the
  required conditional `FoundationNetworking` imports.
- Linux test builds are fixed by adding conditional `FoundationNetworking`
  imports in networking-heavy test suites that mock `URLRequest`.
- Cross-platform socket probing in `PortUtils` now uses Linux-safe socket-type
  casting for Swift 6.2 compatibility.

## 2026.1.2.2 - 2026-02-17

### Fixed

- Skill invocation now runs in the SDK runtime layer via
  `SkillInvocationEngine`, instead of app-specific skill interfacing in the
  iOS example.
- Skill invocation matching is now generic for arbitrary workspace skills by
  explicit command (`/skill <name>` and `/<name>`) and natural-language skill
  name references.
- iOS example deployment now syncs project `skills/` into the app sandbox
  workspace so runtime skill discovery works consistently at deploy time.
- Weather sample skill now uses a JavaScript entrypoint
  (`skills/weather/scripts/weather.js`) so invocation behavior stays in-skill
  and iOS-compatible.
- Removed hardcoded sensitive defaults from iOS deploy settings
  (`OpenClawAppState`) for Discord and model-provider credentials.

### Tests

- Added auto-reply coverage for generic arbitrary skill invocation by skill-name
  references.
- Added/updated weather skill invocation coverage through SDK skill execution
  flow in channel auto-reply tests.

## 2026.1.2 - 2026-02-17

### Added

- GitHub Actions CI/CD foundation with `ci.yml`, `security.yml`, and tag-driven
  `release.yml` workflows for build/test/security/release automation.
- Telegram channel adapter with polling lifecycle, mention gating, typing signal,
  outbound delivery, and deterministic transport-mocked tests.
- WhatsApp Cloud API adapter with send endpoint integration, webhook verification
  + event ingestion support, and deterministic transport-mocked tests.
- Model-provider expansion with OpenAI-compatible, Anthropic, and Gemini
  providers plus expanded provider configuration blocks.
- iOS deploy-time provider/model selection and persisted credentials for OpenAI,
  OpenAI-compatible, Anthropic, Gemini, and Foundation provider modes.
- Weather skill example at `skills/weather` using free Open-Meteo APIs and a
  no-dependency Python script entrypoint.
- Multi-agent-lite config and routing with named agent IDs and route maps
  (`channel[:account[:peer]] -> agent`) plus iOS agent routing controls.
- Structured channel diagnostics events for ingress/routing/model-call/egress
  phases to improve runtime observability.

### Changed

- `OpenClawConfig` is now default-decode resilient across top-level, channel,
  model, and agent sections for backward-compatible config evolution.
- Session resolution now updates stored agent binding when route mapping changes,
  enabling lightweight per-route agent assignment.
- Conversation memory prompt formatting now uses explicit trust boundaries and
  escapes unsafe markup tokens before injection into model prompts.
- Skill registry prompt snapshots now surface script entrypoint hints and
  enforce safe entrypoint resolution within each skill directory.

### Tests

- Expanded adapter coverage with Telegram and WhatsApp adapter suites plus
  additional channel registry dispatch E2E tests.
- Expanded model routing coverage for OpenAI-compatible, Anthropic, Gemini, and
  metadata fallback provider behavior.
- Added iOS build-gate-compatible tests for multi-agent route mapping and
  auto-reply mapped-agent session binding.
- Added skill runtime tests for script-file execution, HTTP helper guards, and
  skill entrypoint traversal prevention.
- Added conversation memory hardening tests for escaping and context-boundary
  formatting.

## 2026.1.1.1 - 2026-02-15

### Fixed

- Discord deploy lifecycle now starts a gateway presence client so deployed bots
  report online status and shut down presence cleanly when deployment stops.
- Discord message handling now uses mention-only trigger policy with startup
  backlog cursor initialization to prevent replay spam on deploy.
- Discord mention triggers now acknowledge with an 👀 reaction before reply
  processing begins.
- Adapter conversation turns are now persisted in a file-backed conversation
  memory store and reinjected into subsequent prompts for session-aware context.

### Tests

- Expanded Discord adapter coverage for presence lifecycle startup/teardown,
  backlog skip behavior, mention-only filtering, and reaction acknowledgement.
- Added conversation memory store persistence/context formatting tests and
  auto-reply integration tests for prompt context injection.

## 2026.1.1 - 2026-02-15

### Added

- Model-provider routing module (`OpenClawModels`) with configurable provider
  selection, fallback behavior, and runtime integration through
  `EmbeddedAgentRuntime`.
- Apple Foundation Models provider behind compile/runtime availability guards
  and deterministic fallback tests for unsupported platforms.
- Local-model adapter contracts inspired by on-device lifecycle patterns,
  including load/unload semantics and streaming-friendly generation hooks.
- Workspace skill system (`OpenClawSkills`) with `SKILL.md` discovery,
  frontmatter parsing, precedence-aware merging, and runtime prompt injection.
- JavaScriptCore skill execution sandbox with strict workspace path jail and
  guarded filesystem host APIs for code-executing skills on Apple platforms.
- Bootstrap/personality prompt context loading (`AGENTS.md`, `SOUL.md`,
  `TOOLS.md`, `IDENTITY.md`, `USER.md`, `HEARTBEAT.md`, `BOOTSTRAP.md`,
  `MEMORY.md`) integrated into prompt assembly.
- Live Discord channel adapter with deploy/stop lifecycle controls, inbound
  polling, outbound delivery, auth-safe error handling, and route-aware message
  envelopes.
- iOS example app expanded into Deploy/Chat tabs with `TabView`, local
  transcript persistence, periodic memory summarization jobs, and runtime
  deployment wiring for local + Discord chat flows.

### Changed

- iOS example project now links the local `OpenClawKit` package product and
  enforces warnings-as-errors from project build settings.
- iOS compatibility hardened in core utilities (home-directory resolution and
  process execution fallback behavior).
- iOS validation scripts now rely on target build settings for warnings-as-
  errors to avoid transitive package flag conflicts.

### Documentation

- Added inline `///` API documentation for major public surfaces in
  `OpenClawKit`, `OpenClawAgents`, `OpenClawChannels`, and `OpenClawCore`
  configuration models.

## 2026.1.0 - 2026-02-15

### Added

- Multi-target Swift 6.2 package architecture with strict-concurrency settings and
  library products for protocol, core, gateway, agents, plugins, channels, memory,
  media, and top-level SDK access.
- Cross-platform compatibility shims for crypto, networking, security, process
  execution, and filesystem APIs, including Linux fallbacks.
- Schema-driven gateway protocol generation (`Scripts/protocol-gen-swift.mjs`) and
  generated `OpenClawProtocol` models with `AnyCodable` support.
- Actor-isolated gateway transport with reconnect backoff, request/response tracking,
  TLS fingerprint validation, and tick watchdog handling.
- Config/session persistence stack with cached config loading, session routing helpers,
  session key resolution, and file-backed session store.
- Embedded agent runtime with tool orchestration, lifecycle events, and timeout-aware
  execution semantics.
- Static Swift plugin system with hook dispatch, custom gateway methods, and service
  lifecycle management.
- Channel abstractions and auto-reply engine with in-memory adapter support and
  session-aware reply routing.
- Runtime subsystem primitives for memory indexing/search, media normalization,
  hook registry, cron scheduling, and pairing/approval security state.
- High-level `OpenClawSDK` facade APIs for configuration/session operations, command
  execution, environment checks, and reply flow composition.
- Unit and E2E Swift Testing suites covering protocol models, platform shims,
  gateway transport, runtime subsystems, channels, plugins, and SDK facade behavior.
- Strict networking concurrency validation script:
  `Scripts/check-networking-concurrency.sh`.
- Project documentation set: comprehensive `README.md`, architecture guide,
  testing guide, API surface reference, and MIT `LICENSE`.
