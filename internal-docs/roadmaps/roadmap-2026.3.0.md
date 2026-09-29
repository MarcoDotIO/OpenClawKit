# Roadmap 2026.3.0

This document records how the `2026.3.0` train brought OpenClawKit to feasible parity
with upstream OpenClaw `v2026.9.6` (`eb377ac59e`) and adopted the Apple 27 frameworks.
The parity scope, validation numbers and scope boundary are in
`internal-docs/parity/parity-2026.9.6.md`; release notes are in `CHANGELOG.md`.

## Goals

1. Feasible parity with OpenClaw `v2026.9.6` for what belongs in a Swift Package SDK:
   client, SDK and control-plane contracts, typed models, gateway interop, node
   commands, the embedded runtime, provider and channel metadata, and native adapters
   where sensible. Not a mirror of the TypeScript CLI, TUI, web UI, Node daemon or TS
   plugin runtime.
2. New features on the iOS, iPadOS, macOS, watchOS, tvOS and visionOS 27 frameworks
   (FoundationModels 27 and Private Cloud Compute, Vision and Spotlight tools,
   StateReporting, NowPlaying, App Intents 27, TrustInsights, LinkSecurity,
   MediaIntelligence, MusicUnderstanding, CoreAI, ScreenCaptureKit on iOS) without
   raising the platform floors.

## Rules for every change

- Xcode 27.1 / Swift 6.4 locally; the cross-platform modules must compile with Swift
  6.2 on Linux (no 6.3/6.4-only syntax outside `#if compiler(>=6.4)`, Apple frameworks
  behind `#if canImport`, FoundationNetworking where `URLSession` is used).
- Floors stay iOS 17, macOS 14, tvOS 17, watchOS 10, visionOS 26. 27-only APIs use
  `#if compiler(>=6.4) && canImport(...)` plus per-OS `@available` (never `anyAppleOS`)
  and must stay weak-linked.
- watchOS arm64_32 has a 32-bit `Int`: SDK-owned millisecond timestamps are `Int64`.
- The enum-backed `Sendable` `AnyCodable` stays; ported upstream `.value as? T` code is
  rewritten to typed accessors.
- Every new public declaration has a `///` doc comment (SwiftLint `missing_docs`).

## Waves

### Wave 0: foundations

- **F1 toolchain and platforms:** every product builds for all five platforms with
  Xcode 27; `Scripts/build-apple-platforms.sh`, `Scripts/check-apple-weak-links.sh`,
  `Scripts/typecheck-apple-sdks.sh` and new `Scripts/validate-apple-matrix.sh` gates.
- **F2 protocol:** re-pin to `v2026.9.6` (1,061 types, protocol v4), the generated
  `GatewayMethodCatalog`, the table-driven `GatewayServer` with its public registration
  API, and the `AnyCodable` fixes.
- **F3 contracts and skeleton:** the new products (`OpenClawMCP`,
  `OpenClawNativeState`, `OpenClawAppIntents`, `OpenClawChatStore`), the
  `ExperimentalAppleModelDelegation` trait, the config split, `ThinkLevel` `max`/`ultra`,
  lenient config decoding, model contract v2 and AgentTool v2.

### Wave 1: feature slices (parallel worktrees)

- **W1** gateway client core (socket generations, connect auth, node session, optional
  Network.framework transport).
- **W2** kit leaf files (security and TLS pinning, node command contracts, operator RPC
  client, presence, push, health, ScreenCaptureKit).
- **W3** Talk (v4 client, realtime relay, Now Playing, AVFAudio 27 paths).
- **W4** native state (SQLite store, identity and auth import, exec approvals).
- **W5** ChatUI core (transport v2, v4 events, view model).
- **W6a** provider catalog generator; **W6b** provider runtime (contract v2 in every
  HTTP provider, streaming, routing, fast mode, prompt caching).
- **W7** Apple Foundation Models (`apple-fm`, FoundationModels 27, PCC, bridges).
- **W8** Apple media ML (media understanding, `music_analyze`, CoreAI).
- **W9a** channels core (catalog, envelopes, config, access policy and pairing,
  `AutoReplyEngine`, receipts, gateway methods).
- **W10** config (`OpenClawConfigDocument`, JSON5, migrations, store, ManagedApp).
- **W11a** agent loop (runtime loop, events, transcripts, approvals, questions, context
  engine, sub-agents, tasks, goals, Tool Search, progress cards).
- **W12** runtime extensions (skills, MCP, memory, plugins, hooks, cron).
- **W13** Apple system integration (App Intents product, StateReporting, run progress,
  background tasks, TrustInsights, Live Activity schemas, permissions).

### Wave 2: second-order slices and integration

- **W5b** ChatUI rendering, **W5c** ChatUI shell, **W5d** ChatStore and the gateway
  chat transport.
- **W9b** channel adapters (SMS, A2A, iMessage over `imsg`, LINE, carrier messaging,
  IMAP, refreshed adapters).
- **W11b** runtime gateway (wire shapes, events, startup gating, presence, node pairing,
  tools and branching RPCs, `mcp.authLogin`).
- **W16** Watch (companion contracts, chat delivery journal, direct Watch node).
- **W17** live provider end-to-end suites (found and fixed three provider bugs).
- **I1**, **I2a**, **I2b** integration: wave-1 cross-owner requests for the OpenClawKit
  facade and App Intents, the runtime modules, and OpenClawCore.
- Post-merge fix: Spotlight queries bounded by a non-joining timeout.

### Wave 3: release

- **W14** docs, CI and examples: CHANGELOG, README, docs, DocC articles and the
  migration guide, the parity manifest and this roadmap, CI on Xcode 27.1 with tvOS and
  watchOS in the matrix plus drift, trait and example jobs, script fixes
  (`typecheck-apple-sdks.sh` module emission, weak-link symbol check, the
  `submitTaskRequest(` gate) and the example apps.
- A parallel code-review and fix phase on `Sources/**`.

## Decisions

The release decisions (protocol v4 negotiation, the table-driven gateway, provider
identity, `ThinkLevel`, additive contracts, the channel pairing default, native state,
ChatUI scope, the dual config model, new products, opt-in StateReporting and the
experimental model-delegation trait) are listed in the parity manifest under "Release
decisions".

## Validation gate

1. `swift build -Xswiftc -warnings-as-errors`
2. `swift test` (3,711 tests on macOS at release)
3. `Scripts/lint-swift.sh` (0 violations, Examples included)
4. `Scripts/validate-apple-matrix.sh`
5. `Scripts/typecheck-apple-sdks.sh all`
6. `Scripts/build-apple-platforms.sh all`
7. `Scripts/check-apple-weak-links.sh all`
8. The Linux Swift 6.2 gate (533 tests at release)
9. `Scripts/check-upstream-drift.sh`
10. `Scripts/build-docs-site.sh`
11. `Scripts/build-ios-example.sh`, `Scripts/test-ios-example.sh`,
    `Scripts/build-tvos-example.sh`

## Deferred to a later train

- ElevenLabsKit talk trait (needs Swift tools 6.3 and macOS 15).
- SQLite session-store backend and Linux SQLite for native state.
- Code Mode (JavaScriptCore) and the decision-model contract.
- SwiftMath typesetting and a bundled Mermaid renderer.
- `plugins.changed` events, ClawHub install, the memory daily-note hook, compaction
  mode `safeguard`, SwiftData transcripts, IndexedEntityQuery.
- `ModelRouter.generateStream` fallback before the first chunk, Bedrock SigV4 signing
  and streaming, more upstream thinking policies.
- Removing BlueBubbles, the deprecated canvas A2UI/eval/snapshot commands, the legacy
  bridge frames and the OpenAIKit dependency.
- Anthropic live coverage once a workspace id is available.

## Release Output References

- Parity scope lock: `internal-docs/parity/parity-2026.9.6.md`
- Human-facing release notes: `CHANGELOG.md`
- Migration guide: the DocC article "Migrating to 2026.3"
- Testing guidance: `docs/testing.md`
- Version tag: `2026.3.0`
