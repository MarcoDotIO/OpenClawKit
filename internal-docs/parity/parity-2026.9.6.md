# 2026.9.6 OpenClaw Parity Manifest

This document locks the parity target for the OpenClawKit `2026.3.0` release against
upstream OpenClaw `v2026.9.6`, and records the Apple 27 framework adoption that ships
with it. Like the `2026.4.25` manifest it is scoped to what makes sense in a Swift
Package SDK for Apple platforms (client, SDK and control-plane contracts, typed models,
gateway interop, node commands, the embedded runtime, provider and channel metadata,
and native adapters where sensible). It is not a mirror of the TypeScript CLI, TUI,
web UI, Node daemon internals or TS plugin runtime.

## Baseline Scope

- **Upstream parity reference:** `.codex/openclaw` at tag `v2026.9.6`, commit
  `eb377ac59e` (`eb377ac59e6c9fd6c7705028034812becf00271b`)
- **Previous pin:** `6b0c72bec8` (`2026.4.25`, OpenClawKit `2026.2.5`)
- **OpenClawKit release target:** `2026.3.0`
- **Toolchain:** Xcode 27.1 / Swift 6.4 with the 27 SDKs on Apple platforms;
  `swift-tools-version` 6.2, and the cross-platform modules build with Swift 6.2 on
  Linux
- **Platform floors (unchanged):** iOS 17, macOS 14, tvOS 17, watchOS 10 (arm64_32:
  32-bit `Int`), visionOS 26. 27-only APIs sit behind `#if compiler(>=6.4)` plus per-OS
  `@available` and are weak-linked.
- **Generators (all support `--check` and `--allow-missing-upstream`):**
  `Scripts/protocol-gen-swift.mjs` (protocol models and method catalog),
  `Scripts/provider-catalog-gen.mjs` (+ `Scripts/provider-catalog-overrides.json`),
  `Scripts/channel-catalog-gen.mjs`
- **Drift guards:** `Scripts/check-native-state-parity.mjs`,
  `Scripts/sync-upstream-gateway-method-fixtures.mjs`,
  `Scripts/sync-upstream-runtime-ext-fixtures.mjs`,
  `Scripts/sync-upstream-tool-catalog-fixture.mjs`, `Scripts/sync-config-fixtures.sh`;
  `Scripts/check-upstream-drift.sh` runs all of them
- **Upstream sessions/transcripts schema baseline hash (informational):**
  `917ba654c57e45fff7e225d90711c6ef395618cf3d1e980ad5138fa3abae6b71`

### Release decisions

- Vendor the upstream `GatewayModels.swift` in full (plus `AgentSummary+Kind`,
  `WakeParamsCompatibility` and an adapted `WizardHelpers`); the generator rewrites
  upstream `.value as? T` casts to the typed accessors of the enum-backed `AnyCodable`.
- Protocol v4: `GATEWAY_PROTOCOL_VERSION` 4, minimum client 4, minimum node 3. Operator
  connects negotiate 4 by default with an opt-in (`minimumProtocolVersion`) for pre-v4
  gateways; node sessions offer 3...4.
- The in-process `GatewayServer` is table-driven from the generated catalog and has a
  public handler-registration API; feature modules register their own methods.
- Provider identity: `apple-fm` is canonical (`apple-fm/system`, alias `foundation`);
  `apple-fm/private-cloud-compute` (alias `apple-fm/pcc`) is SDK-defined;
  `openai-codex` merges into `openai` (ChatGPT OAuth route); `google` resolves to the
  Gemini provider (`gemini` stays an alias). Configs decode `baseURL` and encode
  `baseUrl`.
- `ThinkLevel` gains `max` and `ultra`; `none` normalizes to `off`.
- Model contract v2 and AgentTool v2 are additive with defaults.
- Channels default to upstream `dmPolicy: pairing` (breaking, with opt-outs);
  BlueBubbles is deprecated for one more release; `ChannelID` stays an enum.
- Native state is a new Apple-only product on system SQLite (schema v18, no GRDB);
  device identity and device auth move onto it with a one-time claim-import; the
  default state directory is unchanged and the CLI-shared directory is opt-in.
- ChatUI keeps the iOS 17 / macOS 14 floors; swift-markdown becomes a dependency; the
  GRDB store ships as the separate `OpenClawChatStore` product; no SwiftMath, Mermaid JS,
  mascot art or ElevenLabsKit; tvOS and watchOS get the non-UI chat core only.
- Config: `OpenClawConfig` stays the SDK runtime model; a lossless
  `OpenClawConfigDocument` with JSON5 IO and the doctor migrations is added next to it.
- New products: `OpenClawNativeState`, `OpenClawAppIntents`, `OpenClawChatStore`
  (Apple) and `OpenClawMCP` (cross-platform; stdio on macOS and Linux only).
- StateReporting is opt-in (`OpenClawSystemState.isEnabled`) and the SDK owns one
  metadata type per `ai.openclaw.*` domain.
- `_ModelDelegationIntent` ships only behind the default-off
  `ExperimentalAppleModelDelegation` package trait.

## Delivered Parity Surface

### Protocol

- `OpenClawProtocol` vendors upstream `v2026.9.6`: 1,061 types, protocol v4.
- `GatewayMethodCatalog`: 482 core method descriptors (22 not advertised) with scope,
  `since`, advertised, startup-gated and control-plane-write flags; 324 params
  validators; 64 events; 21 server capabilities; 17 client ids; the 9 methods removed
  since `6b0c72bec8`; and the `GatewayEventName`, `GatewayServerCapabilityName`,
  `GatewayClientID`, `GatewayClientMode` and `GatewayClientCapability` enums.
- `AnyCodable` typed accessors live in `OpenClawProtocol` (Linux included); JSON `0`/`1`
  stay numbers, 64-bit integers are preserved, `NSNull` maps to null and `Encodable`
  values become JSON trees. `ChatEventFrame` wraps the v4 `ChatEvent` union.
- SDK-owned files that are never generated: `AnyCodable.swift`,
  `AnyCodable+Accessors.swift`, `GatewayCompatModels.swift`,
  `GatewayErrorDetails+Support.swift`, `IntentGraphModels.swift`,
  `MultimodalModels.swift`, `WizardHelpers.swift`.
- Binary size: the vendored models grow the stripped `OpenClawProtocol` release binary
  from about 1.13 MB to 6.32 MB per architecture on iOS arm64 (about 13.3 MB for watchOS
  arm64 + arm64_32); its release compile time grows from about 12–17 s to 63–72 s.

### Gateway (in-process server)

- Table-driven dispatch with role and scope checks (`FORBIDDEN` / `MISSING_SCOPE`);
  catalog methods without a handler validate params and answer `UNAVAILABLE`; removed
  and unknown methods answer `INVALID_REQUEST`.
- Public registration API (`GatewayMethodRegistrar`, typed
  `register(method:params:handler:)`, `GatewayMethodRequest`,
  `GatewayConnectionContext`, `GatewayEventEmitter`, `GatewayMethodError`) and
  `register…GatewayMethods(on:)` functions for channels, skills, ClawHub, memory, cron,
  plugins and MCP OAuth, plus `EmbeddedAgentRuntime.attach(to:)`.
- Server push events (`events(filter:bufferingNewest:)`) with a server-global `seq`,
  startup gating (`startup-sidecars`), presence, node pairing, session groups, the
  transcript branching RPCs, `tools.catalog` / `tools.effective` / `tools.invoke`,
  `secrets.store.*` and `mcp.authLogin`.
- Upstream wire shapes on the overlapping core methods (`AgentParams` with an
  idempotency retry cache, `runId`, `agentId`, null clears) next to the legacy SDK keys.

### Gateway client, node session and native state

- `GatewayChannelActor` is rebuilt around socket generations (upstream `2026.9.6`):
  shared connect attempts, monotonic backoff, challenge-signed v2 device proof, scoped
  device tokens and bootstrap handoff rules, defensive hello-ok decoding, startup
  retries, tick-based liveness, `maxPayload` enforcement, profile binding, custom
  headers, `GatewayConnectionProblem` and TLS pin rotation review.
- `GatewayNodeSession`: route leases, the invocation registry (cancel, input, timeouts,
  `computer.act` receipts) and single-flight plugin-surface refresh.
- `OpenClawNativeState`: `state/openclaw.sqlite` at schema v18 with the 4 canonical
  tables (`device_identities`, `device_auth_tokens`, `exec_approvals_config`,
  `macos_port_guardian_records`, the last validated only), the state-handles
  coordinator lease and fail-closed schema checks. `DeviceIdentityStore`,
  `DeviceAuthStore` and `GatewayDeviceIdentityProfile` match upstream's public
  signatures; JSON identity files are claim-imported once.

### Node commands and Apple helpers

- `computer.act`, `health.summary` (opt-in HealthKit provider), `camera.ptz.*`,
  `screen.snapshot`, `fs.listDir`, `system.execApprovals.get/set`, the `system.run`
  approval snapshot and macOS pre-launch re-check, macOS file transfer (opt-in) and an
  iOS/visionOS 27 ScreenCaptureKit `screen.record` backend.
- Upstream TLS pinning (v3 Keychain store, system trust before first use), the
  tightened local-network policy, setup-code v2 and deep links, presence beacons,
  consent-gated APNs registration, `GatewayOperatorClient` and the terminal and
  workspace-file clients.

### Talk and Watch

- The v4 Talk surface (`TalkGatewayClient`), the gateway-relay realtime session
  (iOS, macOS, visionOS), Talk config snapshots and the gateway-first speech fallback
  chain.
- The full `watch.*` companion vocabulary, durable Watch chat delivery with its own
  SQLite journal, a WatchConnectivity-free message codec and the direct Apple Watch
  node over signed HTTPS long-poll.

### ChatUI and ChatStore

- The non-view chat core (transport v2, v4 chat events, wire models, gateway request
  builders, transcript-cache and outbox contracts), the rendering stack (block
  markdown, tool activity, cards, media, widgets, link previews) and the chat shell
  (composer v2, pickers, session management, split shell, Talk and voice notes).
- `OpenClawGatewaySessionChatTransport` with route-bound outbox replays, and the GRDB
  `OpenClawChatStore` (`gateway-cache.sqlite`, `client-state.sqlite`).

### Providers and catalog

- Generated catalog: 70 text providers with 357 manifest model rows, 28
  capability/metadata providers, 32 aliases and 131 suppressions; TypeScript-only
  catalogs, display names and SDK-local entries live in the overrides file.
- Model contract v2 in every HTTP provider (OpenAI Chat Completions and Responses, the
  ChatGPT/Codex route, Azure, Anthropic, Gemini/Vertex, Bedrock, native Ollama),
  incremental streaming, per-model routing, reasoning effort resolution, fast mode,
  prompt caching and catalog thinking profiles.

### Apple Intelligence and media ML

- `apple-fm` in process on FoundationModels (no helper binary): upstream identity,
  facts and error copy; contract v2 (transcript replay, host-owned tool calls,
  structured output, streaming, cancellation, usage).
- FoundationModels 27: reasoning levels, tool-calling and sampling modes, image input,
  the Vision OCR/barcode tools, an opt-in `SpotlightSearchTool`, token counting and
  prewarm. SDK-only: `apple-fm/private-cloud-compute`, image input,
  `OpenClawLanguageModel` and the agent profile/tool bridges.
- Media understanding (Vision OCR, MediaIntelligence video, SpeechAnalyzer
  transcription), the `music_analyze` tool (MusicUnderstanding) and CoreAI `.aimodel`
  support.

### Agent runtime, skills, MCP, memory and plugins

- A model-driven tool loop with streaming agent events, run control, approvals,
  questions, compaction, sub-agents, the task ledger, goals, Tool Search and progress
  cards; the core tool catalog covers all 61 upstream tool ids (native or
  recognized-only).
- Skills with upstream frontmatter, precedence, eligibility and the v6 prompt catalog;
  the MCP client (Streamable HTTP, SSE, stdio on macOS/Linux, OAuth); the builtin
  memory engine with a CoreSpotlight index on Apple 27; plugin API v2; the 42 upstream
  hook names; cron automations.

### Channels

- Generated catalog of 34 channel ids (new: `a2a`, `buzz`, `clickclack`, `raft`,
  `reef`, `sms`, `wecom`, `openclaw-weixin`, `yuanbao`, `openclaw-zaloclawbot`).
- Upstream ingress access policy and DM pairing, per-channel chunking, receipts and
  retry classification, bot-loop protection, ack reactions, typing lifecycle, join
  introductions and the `channels.*` gateway methods.
- New native adapters: SMS (Twilio), A2A 1.0, LINE, carrier messaging (iOS 26+,
  TelephonyMessagingKit), the IMAP watcher, and iMessage over `imsg rpc --json`.

### Config

- `OpenClawConfigDocument` (lossless `2026.9.6` model), `OpenClawJSON5`,
  `OpenClawConfigMigrator` (deterministic doctor migrations by rule id) and
  `OpenClawConfigDocumentStore` (upstream write guards), with a bridge to
  `OpenClawConfig`, typed `config.get` / `config.patch` helpers and lenient
  `OpenClawConfig` decoding.

### Apple 27 system integration

- `OpenClawAppIntents` (entities, queries, Ask/Abort/Start Live Voice and the OS 27
  long-running Run Task intent; metadata merged into host apps with Xcode 27.1),
  opt-in StateReporting, Now Playing `MediaSession`, `ProgressManager` run progress,
  async background-task submission, TrustInsights approval friction, LinkSecurity,
  data detection and suggested actions in ChatUI, the Image Playground sheet,
  ManagedApp MDM configuration, and the experimental model-delegation intent behind its
  trait.

## Validation Status

State of release branch `release/2026.3.0` after the release-review fixes:

- Passed: `swift build -Xswiftc -warnings-as-errors` (macOS)
- Passed: `swift test` on macOS: 3,711 tests (3,147 `OpenClawKitTests`, 544
  `OpenClawLinuxRuntimeTests`, 20 E2E)
- Passed: Linux Swift 6.2 gate in Docker (`swift:6.2`): strict build, networking
  concurrency gate and 533 `OpenClawLinuxRuntimeTests`
- Passed: `Scripts/lint-swift.sh` with 0 violations (Sources, Tests, Examples,
  `Package.swift`)
- Passed: all five Apple platforms build every product (`OpenClawKit-Package`;
  watchOS arm64_32 and arm64)
- Passed: `Scripts/check-apple-weak-links.sh all` at the deployment floors, with no
  strong references to 27-only runtime symbols:
  - iOS: weak FoundationModels, TelephonyMessagingKit, ImagePlayground, ManagedApp,
    CoreAI, StateReporting, NowPlaying, MediaIntelligence, MusicUnderstanding,
    SuggestedActions, TrustInsights, LinkSecurity
  - macOS: weak FoundationModels, ImagePlayground, ManagedApp, CoreAI, StateReporting,
    NowPlaying, MediaIntelligence, MusicUnderstanding, SuggestedActions, LinkSecurity
  - tvOS: weak CoreAI, StateReporting, NowPlaying, MediaIntelligence,
    MusicUnderstanding, LinkSecurity
  - watchOS (arm64_32 and arm64): weak FoundationModels, CoreAI, StateReporting,
    NowPlaying, MusicUnderstanding, LinkSecurity
  - visionOS: weak CoreAI, StateReporting, NowPlaying, MediaIntelligence,
    MusicUnderstanding, SuggestedActions, LinkSecurity (FoundationModels and the other
    floor frameworks exist at the visionOS 26 floor)
- Passed: `Scripts/typecheck-apple-sdks.sh all`, `Scripts/validate-apple-matrix.sh`,
  `Scripts/check-upstream-drift.sh` (8 checks against `eb377ac59e`),
  `Scripts/build-docs-site.sh`, `Scripts/build-ios-example.sh` and
  `Scripts/build-tvos-example.sh`
- Live provider suite (`OPENCLAW_LIVE_PROVIDER_TESTS=1 swift test --filter
  LiveProvider`), final pass on the release tree: 67 tests in 6 suites, all passed.
  - OpenAI Responses (15), OpenAI Chat Completions (12), Anthropic Messages (10, with
    a workspace-scoped key; signed extended thinking replayed before tool use), xAI
    (10, catalog Responses route and direct Chat Completions), agent loops with a
    calculator tool on OpenAI, Anthropic and xAI, and router fallback for both
    `generate` and `generateStream`.
  - 63 billed calls on `gpt-6-luna`, `claude-haiku-4-5` and
    `grok-4.20-0309-non-reasoning` (about 12k input / 1.5k output tokens), well under
    $0.05. Organization-level Anthropic keys need `ANTHROPIC_WORKSPACE_ID`
    (`anthropic-workspace-id`).
  - The live runs found and fixed four SDK bugs: OpenAIKit dropping `/v1` (every
    plain request failed with 404), factory-built providers dropping configured
    headers, non-streaming generate throwing when reasoning exhausted the output
    limit, and Anthropic prompted JSON arriving inside a Markdown fence.
- Apple Foundation Models live tests (7) passed on the development Mac (AFM 3 Core
  Advanced, 8,192-token context, vision supported). Private Cloud Compute generation was not verified end to end:
  unsigned test processes lack the managed entitlement (`ModelManagerError` 1046), which
  is mapped and falls back to on-device.

## Scope Boundary

### Skipped (with reasons)

Protocol and gateway:

- **TypeBox schema pipeline and TS generators.** The committed Swift artifact is
  produced by upstream CI (`protocol:gen:swift --check`), so vendoring it gives the same
  bits. The Kotlin generator, the Codex app-server sync and the registry guards are
  upstream-monorepo concerns; only the event-coverage idea is borrowed
  (`GatewayEventName`).
- **In-process handlers for daemon, worker and control-UI families** (`environments.*`,
  `worker.*`, `desktop.*`, `computer.*`, `terminal.*`, `worktrees.*`, `controlUi.*`,
  `themes.*`, `board.*`, `canvas.document.*`, `claws.*`, `update.*`,
  `gateway.restart/suspend.*`, `doctor.*`, `mcp.app.*`, `migrations.*`, `audit.*`,
  plugin install/catalog, skill proposals/curator/library/upload, …). Their typed models
  ship so clients can call a real gateway; in process they answer `UNAVAILABLE`.
- **Multi-user session sharing** (owners, members, public share, observers). An
  in-process gateway has one user; the sharing RPCs answer `UNAVAILABLE`.
- **OpenClaw as an MCP server and MCP Apps UI resources.** A long-running listener is
  hard to justify on iOS and MCP Apps render inside the Control UI sandbox; the typed
  `mcp.app.*` models remain.

Native state:

- **The TypeScript state-DB runtime** (Kysely access, worker brokers, forward
  migrations v5–v18, Doctor imports, integrity quarantine). Native clients never upgrade
  the database.
- **The per-agent `openclaw-agent.sqlite`** (sessions, transcripts, FTS). The schema
  churns and has canonical-validation triggers; the data is reachable through gateway
  methods.
- **Moving TLS pins and credentials from the Keychain into SQLite.** Upstream still
  keeps them in the Keychain.
- **A native importer for legacy `exec-approvals.json`.** It would race
  `openclaw doctor --fix`; access fails with `ExecApprovalsLegacyMigrationRequiredError`
  while that migration is pending.

Providers:

- **`claude-cli`, `codex` and `copilot` agent runtimes.** They are CLI subprocess
  runtimes; only the `codex/*` and `openai-codex/*` ref migration is kept.
- **The `apple-fm` helper binary and JSON IPC.** The SDK calls FoundationModels in
  process.
- **`localService` supervision and managed llama.cpp installs.** The field is decoded
  and round-tripped; llama.cpp is supported as an existing OpenAI-compatible server.
- **Non-provider contracts** (decision, worker, code-mode, migration and tool-result
  middleware providers).

Runtime:

- **Claws, boards and Workboard widgets, fleet and CLI flows, ACP harnesses, Task
  Flow / Lobster / Swarm collectors.** Gateway-host or TS plugin runtimes; typed models
  are kept where clients need them, and the embedded `sessions_spawn` rejects
  `runtime: "acp"`.
- **Active Memory, memory-wiki vaults and dreaming.** Gateway-owned pipelines that add
  latency and cost; the embedded runtime implements the builtin memory tools.
- **Skill Workshop, library and curator.** Gateway-hosted, review-gated systems; typed
  client models remain.

Channels:

- **Non-channel plugins and non-portable transports:** meeting bots (Google Meet, Teams,
  Zoom), voice-call, FaceTime (private APIs), webhooks, session-share, visitor-access,
  admin-http-rpc, logbook, mxc. Also skipped: the Signal managed daemon, Discord voice,
  WhatsApp Web/Baileys linking (the Swift adapter stays on the Cloud API), Zalo personal,
  Buzz/Nostr/Raft native transports, the SQLite ingress queue and the progress-draft
  compositor.

ChatUI and Apple app shells:

- **Web, Tauri and Android chat surfaces and upstream app shells** (Quick Chat window,
  app navigation chrome, onboarding, mascot art). The SDK ships the reusable views.
- **`DeviceSettingsContract`** (the first-party app's dashboard-to-settings bridge).
- **ElevenLabsKit in ChatUI.** No upstream ChatUI file imports it; the package needs
  Swift tools 6.3 and macOS 15.

Config:

- **TypeScript runtime sections** are passed through losslessly without Swift behavior:
  `browser.*`, `acp.*`, `agents.*.sandbox.*`, `models.providers.*.localService`,
  `hooks.gmail`, `skills.install`, `security.installPolicy.exec`,
  `plugins.load.paths`, `wizard.*`, `env.shellEnv`, `gateway.terminal`,
  `gateway.cliAgents`, `gateway.portals`, the Control UI serving keys, `tools.github`,
  and `$include` resolution beyond detection.

Upstream changelog items out of scope:

- Gateway service management (launchd, doctor, update, Docker), Control UI / WebChat /
  TUI / PWA features, TS plugin SDK internals and breaking changes, Android-only node
  features, TS channel transport internals, Node runtime floors and SQLite schema 21
  host operations, desktop companions and the Rust gateway libraries.

Apple 27 frameworks:

- **ComputeGraph** (GPU simulation), **MediaIntelligence face grouping** (biometric
  identity clustering), **`SystemLanguageModel.Adapter`** (obsoleted in 27),
  **`ImageCreator`** (deprecated in favor of user-driven Image Playground UI).
- **ML-DSA / X-Wing device-auth signatures.** The gateway accepts only Ed25519 device
  identities and the connect payload has no algorithm field.
- **AppManagedFeatures, ServicesAccountLinking, WiFiInfrastructure, AVSystemRouting,
  MediaDevice, AudioAccessoryKit, StickerFoundation**, and MediaIntents audio search,
  NowPlaying remote sessions, workout audio contexts, empty overlays and delivered
  verification codes: no agent or SDK use case.

### Deferred

- **ElevenLabsKit talk trait.** ElevenLabsKit 0.1.3 needs Swift tools 6.3 and macOS 15,
  which conflict with the tools 6.2 / macOS 14 floors; the `StreamingAudioPlaying` seams
  stay.
- **SQLite session-store backend.** `SessionStore` stays JSON; there is no upstream
  interop need. Transcripts use the SDK-owned JSONL layout, which is not
  interchangeable with the CLI's SQLite transcripts.
- **Linux SQLite for `OpenClawNativeState`.** The product is Apple-only this release.
- **Code Mode (JavaScriptCore).** Experimental and not a hardened sandbox upstream.
- **Decision-model contract.** Landed on upstream `main` after `2026.9.5`; not confirmed
  in the `v2026.9.6` target.
- **Equatable generated protocol models.** The generated models stay as upstream emits
  them.
- **macOS port guardian.** App-specific; its table is validated but has no SDK API.
- **Post-quantum wrapping of the device private key at rest.** Conflicts with the
  shared `private_key_pem` contract.
- **SwiftMath (`ChatMath` trait) and a bundled Mermaid renderer.** LaTeX renders as
  source and Mermaid needs a host renderer.
- **`plugins.changed` events, ClawHub install/download, the memory daily-note hook,
  compaction mode `safeguard`, SwiftData transcripts, IndexedEntityQuery, Vision
  `RecognizeDocumentsRequest`, `SCClipBufferingOutput` clip mode, and the Rust WebRTC
  standalone Watch Talk stack.**
- **Full upstream TS plugin runtime.**

### Known limitations carried into 2026.3.0

- Generated protocol models keep upstream's `Int` for millisecond fields (173 fields),
  which overflows on arm64_32 watchOS above `Int32.max`; SDK-owned timestamps are
  `Int64` and `AnyCodable.int64Value` reads raw payloads safely.
- The 47 generated union enums and 66 strict decoders throw on unknown discriminators;
  the gateway channel decodes hello-ok defensively.
- `ModelRouter.generateStream` does not fall back when a stream fails before its first
  chunk.
- Bedrock requests are not SigV4-signed and Bedrock streaming yields one final chunk.
- Only the generic, OpenAI unified and Claude thinking policies are ported; other
  providers use the catalog-driven generic profile.
- `CancellationShieldSupport` uses an unstructured task instead of
  `withTaskCancellationShield` (strongly linked 27-only runtime symbols).
- Private Cloud Compute generation, `SpotlightSearchTool`, ScreenCaptureKit recording,
  carrier messaging, the `imsg` transport, the IMAP TLS transport and the direct Watch
  node are verified by builds, fakes and weak-link checks, not end to end.
- Linking OpenClawKit links HealthKit on iOS, watchOS, macOS and visionOS.
- The GatewayTLSPinning test fixture certificates expire on 2027-09-16.
