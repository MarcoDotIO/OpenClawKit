# OpenClawKit Architecture

This package is organized into layered SwiftPM targets so core concerns remain isolated
while exposing a simple top-level facade. The GitHub Pages documentation site
publishes the same SDK-first view through Swift-DocC; this page is the compact
in-repo companion for contributors and integrators.

The `2026.3.0` release tracks upstream OpenClaw `v2026.9.6` (`eb377ac59e`). The
upstream reference checkout lives at `.codex/openclaw` (git-ignored, read-only);
generator scripts read it and CI verifies the generated files against it when it is
available (`Scripts/check-upstream-drift.sh`).

## Layer Overview

Cross-platform targets (Apple platforms and Linux, Swift 6.2 compatible):

1. `OpenClawProtocol`
   - Transport models (`RequestFrame`, `ResponseFrame`, `EventFrame`, `GatewayFrame`)
   - Protocol v4 constants (`GATEWAY_PROTOCOL_VERSION` 4, minimum client 4, minimum node 3)
   - `GatewayMethodCatalog` (482 method descriptors, params validators, events,
     server capabilities, client ids)
   - Enum-backed, `Sendable` `AnyCodable` with typed accessors (`stringValue`,
     `boolValue`, `intValue`, `int64Value`, `doubleValue`, `arrayValue`,
     `dictionaryValue`); never use `value as? T`
   - Vendored from the pinned upstream checkout by `Scripts/protocol-gen-swift.mjs`:
     `GatewayModels.swift`, `AgentSummary+Kind.swift`, `WakeParamsCompatibility.swift`
     and the generated `GatewayMethodCatalog.swift`. Run
     `OPENCLAW_UPSTREAM_DIR=<checkout> node Scripts/protocol-gen-swift.mjs [--check] [--allow-missing-upstream]`.
     SDK-owned files that are never generated: `AnyCodable.swift`,
     `AnyCodable+Accessors.swift`, `GatewayCompatModels.swift`,
     `GatewayErrorDetails+Support.swift`, `IntentGraphModels.swift`,
     `MultimodalModels.swift` and `WizardHelpers.swift`.

2. `OpenClawCore`
   - Cross-platform shims (crypto/network/security/process/fs)
   - Two config layers: SDK-native `OpenClawConfig` (lenient decoding with
     `ConfigDecodeIssueCollector`) and the lossless upstream-shaped
     `OpenClawConfigDocument` (JSON5, doctor migrations, `OpenClawConfigDocumentStore`
     write guards), bridged by `OpenClawConfig.importConfig(from:issues:)` and
     `documentProjection(preserving:)`
   - Secrets (`SecretInput`, `SecretRef`, hardened file/exec providers), auth profiles
   - Session store, session controls and transcripts (JSONL and in-memory stores)
   - Hooks (42 upstream hook names), cron automations, exec allowlist matching,
     security runtime and audit (`SecurityAuditRunner`)
   - Diagnostics and usage aggregation (`RuntimeDiagnosticsPipeline`)

3. `OpenClawGateway`
   - Actor-safe transport client (`GatewayClient`, `GatewaySocket`)
   - In-process `GatewayServer`: table-driven dispatch over `GatewayMethodCatalog`,
     role/scope authorization, server push events with a server-global `seq`,
     startup gating, presence, node pairing, session groups and the secrets vault

4. `OpenClawModels`
   - Provider catalog generated from upstream manifests
     (`Scripts/provider-catalog-gen.mjs` → `ProviderCatalogData.swift`)
   - Model contract v2 providers (OpenAI Chat Completions and Responses, ChatGPT/Codex
     route, Azure, Anthropic, Gemini/Vertex, Bedrock, Ollama, OpenAI-compatible wrappers)
   - `ModelRouter`, `RoutingModelProvider`, `ModelStreamingHTTPClient`, reasoning
     effort, fast mode, prompt caching
   - `FoundationModelsProvider` (`apple-fm`, FoundationModels 27, Private Cloud
     Compute), `OpenClawLanguageModel`, CoreAI

5. `OpenClawSkills`, `OpenClawMedia`, `OpenClawMemory`, `OpenClawMCP`
   - Skills discovery, eligibility, prompt catalog and JS/WASM execution
   - Media normalization and on-device media understanding (Vision, MediaIntelligence,
     SpeechAnalyzer, MusicUnderstanding adapters behind `#if canImport`)
   - Builtin memory engine and memory tools (CoreSpotlight index on Apple 27)
   - MCP client transports, OAuth and `MCPClientManager`

6. `OpenClawAgents`
   - `EmbeddedAgentRuntime` agent loop over model contract v2 and AgentTool v2
   - Approvals, questions, context engines, sub-agents, task ledger, goals, Tool Search
   - Gateway method registration (`attach(to:options:)`) and streaming agent events

7. `OpenClawPlugins` and `OpenClawChannels`
   - Plugin API v2 (static Swift plugins; no TS plugin runtime)
   - Channel adapters, access policy and pairing, chunking, receipts, `AutoReplyEngine`

Apple-only targets:

8. `OpenClawNativeState`
   - The upstream native state database (`state/openclaw.sqlite`, schema v18) on system
     SQLite: coordinator lease, canonical tables, blocking APIs plus a dedicated serial
     queue (`OpenClawNativeStateQueue`). Native code never migrates the schema.

9. `OpenClawKit`
   - Facade API (`OpenClawSDK`) exposing primary integration points
   - Re-exports the cross-platform modules (including `OpenClawMCP`); import
     `OpenClawNativeState` explicitly
   - Gateway channel and node session, device identity/auth on native state, TLS
     pinning, node commands, Talk, Watch, StateReporting, Now Playing, background
     tasks, Live Activity schemas and permission helpers

10. `OpenClawChatUI`, `OpenClawChatStore`, `OpenClawAppIntents`
    - SwiftUI chat (views on iOS/macOS/visionOS; the non-UI core under
      `Sources/OpenClawChatUI/Core` on every Apple platform) with
      `OpenClawGatewaySessionChatTransport`
    - GRDB-backed transcript cache and durable outbox
    - App Intents entities, queries and intents with pluggable intent hosts

## Gateway Method Registration

The in-process server owns dispatch; feature modules own their handlers. A module
exposes a `register…GatewayMethods(on registrar: some GatewayMethodRegistrar)`
function and the host calls it after creating the server:

```swift
let server = GatewayServer(/* stores, vault, handlers */)
await registerChannelGatewayMethods(on: server, context: channelContext)
await registerMemoryGatewayMethods(on: server, configuration: memoryConfiguration)
await runtime.attach(to: server)

await server.register(method: "example.echo") { request in
    guard let text = request.stringParam("text") else {
        throw GatewayMethodError.invalidRequest("text is required")
    }
    return AnyCodable(["text": AnyCodable(text)])
}
```

Handlers receive a `GatewayMethodRequest` (params, connection context with role and
scopes, an event emitter) and throw `GatewayMethodError` for wire error codes. Methods
in the upstream catalog without a registered handler validate their params and answer
`UNAVAILABLE`; removed and unknown methods answer `INVALID_REQUEST`. Methods listed in
`GatewayServer.sdkExtensionMethods` (`agent.run`, `skills.invoke`, `secrets.*`,
`browser.request`, …) are OpenClawKit extensions, not upstream core methods.

## Concurrency Model

- Mutable runtime state is actor-isolated; public model types are `Sendable`.
- Cross-task callbacks are `@Sendable`.
- Blocking SQLite work (native state, ChatStore) runs off the Swift concurrency pool
  (`…InBackground` APIs, `OpenClawNativeStateQueue`).
- Timeouts are non-joining races (`AsyncTimeout`, `SpotlightTimeoutRace`) so an
  operation that ignores cancellation cannot wedge its caller.
- `withTaskCancellationShield` is not used while the deployment floors are below 27:
  the Swift 6.4 compiler strongly links `swift_task_cancellationShieldPush`/`Pop`
  even behind `#available`. `CancellationShieldSupport.run(_:)` is the replacement.
- Networking safety is validated by `Scripts/check-networking-concurrency.sh`.

## Platform Guards

- 27-only APIs: `#if compiler(>=6.4) && canImport(Framework)` plus platform exclusions
  and per-OS `@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)`
  (never `anyAppleOS`), so the framework is weak-linked.
- FoundationModels exists on tvOS/watchOS with the 27 SDKs but its declarations are
  unavailable on tvOS, and `SystemLanguageModel` is unavailable on watchOS: guard with
  `canImport(FoundationModels) && !os(tvOS)` (and `!os(watchOS)` for the system model).
- watchOS arm64_32 has a 32-bit `Int`: SDK-owned millisecond timestamps are `Int64`.
  Generated protocol models keep upstream's `Int` (documented limitation); read such
  values through `AnyCodable.int64Value`.
- `Scripts/validate-apple-matrix.sh` enforces the static rules and
  `Scripts/check-apple-weak-links.sh` verifies the linked result.

## Observability Flow

`AutoReplyEngine` and `EmbeddedAgentRuntime` emit `RuntimeDiagnosticEvent` payloads
into an injected `RuntimeDiagnosticSink`. Host apps can plug a
`RuntimeDiagnosticsPipeline` sink to:

- retain recent event timelines (`recentEvents(limit:)`)
- inspect aggregate usage (`usageSnapshot()`)
- power app-level diagnostics surfaces (for example, the expanded iOS sample tabs)

`OpenClawSystemState.diagnosticSink(forwardingTo:)` maps agent-run events onto Apple
StateReporting (OS 27, opt-in with `OpenClawSystemState.isEnabled`) and forwards them to
the next sink. The gateway channel, node session, talk and config store report their
own domains. `EmbeddedAgentRuntime.runEvents(_:)` streams structured `AgentEventFrame`s
for UI.

`OpenClawSDK.runSecurityAudit(...)` can also publish structured `security` subsystem
events (`audit.completed`, `audit.finding`) into the same pipeline.

## Feature Implementation Guidance

When adding new features:

- add protocol surface in `OpenClawProtocol` first (if needed); regenerate vendored
  files with the generator instead of editing them
- add core/runtime capability in the appropriate module target
- register gateway methods from the owning module through the registration API
- wire facade entry points in `OpenClawSDK` (as `extension OpenClawSDK` files) only
  after lower layers are tested
- add unit + E2E coverage with Swift Testing, and Linux coverage for cross-platform code
- prefer user-facing conceptual docs in the DocC catalog, and keep this file
  focused on stable architecture notes
