# Changelog

## 2026.2.3 - Unreleased

### Added

- `2026.3.11` SDK + control-plane parity train scaffolding and release rules,
  keyed to the pinned OpenClaw reference snapshot.

### Changed

- Documentation now states that `2026.2.3` must land as one green commit per
  implementation step with warnings-as-errors validation and full coverage for
  newly introduced codepaths.

### Tests

- Pending parity-train implementation and validation.

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
