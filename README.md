<p align="center">
  <img src="Resources/logo-banner.jpg" alt="OpenClawKit logo banner, also hi random stranger :)" width="900" />
</p>

# OpenClawKit

[![CI](https://github.com/MarcoDotIO/OpenClawKit/actions/workflows/ci.yml/badge.svg)](https://github.com/MarcoDotIO/OpenClawKit/actions/workflows/ci.yml)
[![Documentation](https://github.com/MarcoDotIO/OpenClawKit/actions/workflows/docs.yml/badge.svg)](https://github.com/MarcoDotIO/OpenClawKit/actions/workflows/docs.yml)
[![Security](https://github.com/MarcoDotIO/OpenClawKit/actions/workflows/security.yml/badge.svg)](https://github.com/MarcoDotIO/OpenClawKit/actions/workflows/security.yml)
[![Release](https://github.com/MarcoDotIO/OpenClawKit/actions/workflows/release.yml/badge.svg)](https://github.com/MarcoDotIO/OpenClawKit/actions/workflows/release.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

OpenClawKit is a Swift-native SDK for building OpenClaw-style agents, channels, and app integrations on Apple platforms, with cross-platform runtime modules that also build for Linux services.

The repository currently ships:

- layered SwiftPM products for protocol, core runtime, gateway, agents, plugins, channels, memory, media, models, skills and MCP
- an Apple-facing `OpenClawKit` facade for app and gateway-node integrations, plus Apple-only products for native state, App Intents, SwiftUI chat and an offline chat store
- an in-process gateway with a public method-registration API, and a gateway client that speaks OpenClaw protocol v4
- provider routing across OpenAI (Platform and ChatGPT/Codex OAuth), OpenAI-compatible, Anthropic, Google Gemini/Vertex, xAI, Bedrock, Ollama, local runtimes and Apple Foundation Models (on-device and Private Cloud Compute)
- channel adapters with upstream access policy and DM pairing, secret-aware lossless config, session transcripts, diagnostics, replay and security audit tooling
- a published Swift-DocC site plus CI, SwiftLint, and release automation

Current baseline:

- latest release: `2026.3.0`
- upstream parity target: OpenClaw `v2026.9.6` at `.codex/openclaw` commit `eb377ac59e`
- gateway protocol: v4 (operator clients negotiate 4; node sessions accept 3...4)
- toolchain: Xcode 27.1 / Swift 6.4 for Apple platforms; the cross-platform modules stay compatible with Swift 6.2 on Linux (`swift-tools-version` 6.2)
- public docs site: [marcodotio.github.io/OpenClawKit](https://marcodotio.github.io/OpenClawKit/)

## Documentation

- Swift-DocC site: [OpenClawKit Documentation](https://marcodotio.github.io/OpenClawKit/)
- Migration guide for this release: the "Migrating to 2026.3" DocC article
- Architecture notes: [docs/architecture.md](docs/architecture.md)
- High-level SDK API index: [docs/api-surface.md](docs/api-surface.md)
- Testing and validation guide: [docs/testing.md](docs/testing.md)
- Release notes: [CHANGELOG.md](CHANGELOG.md)

## Installation

Add the package with Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/MarcoDotIO/OpenClawKit.git", from: "2026.3.0")
]
```

For Apple apps, most integrations should depend on `OpenClawKit` and add the Apple-only products they use:

```swift
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "OpenClawKit", package: "OpenClawKit"),
            // Optional:
            .product(name: "OpenClawChatUI", package: "OpenClawKit"),
            .product(name: "OpenClawChatStore", package: "OpenClawKit"),
            .product(name: "OpenClawAppIntents", package: "OpenClawKit"),
            .product(name: "OpenClawNativeState", package: "OpenClawKit"),
        ]
    )
]
```

For Linux services or lower-level integrations, depend on the specific runtime products you need instead of the Apple-only facade.

The experimental App Intents model-delegation surface (built on the underscored AppIntents 27 `_ModelDelegationIntent` API) is behind a package trait that is off by default. Passing `traits:` replaces the default traits, so keep `.defaults`:

```swift
.package(
    url: "https://github.com/MarcoDotIO/OpenClawKit.git",
    from: "2026.3.0",
    traits: [.defaults, "ExperimentalAppleModelDelegation"]
)
```

## Quick Start

```swift
import OpenClawKit

let sdk = OpenClawSDK.shared
let diagnostics = sdk.makeDiagnosticsPipeline(eventLimit: 500)

let reply = try await sdk.getReplyFromConfig(
    config: OpenClawConfig(),
    sessionStoreURL: URL(fileURLWithPath: "./state/sessions.json"),
    inbound: InboundMessage(
        channel: .webchat,
        peerID: "user-1",
        text: "Plan a concise project update."
    ),
    diagnosticsPipeline: diagnostics
)

print(reply.text)
print(await diagnostics.usageSnapshot().runsCompleted)
```

For a persistent embedded agent (session and transcript stores, the tool-calling agent loop, sub-agents, goals, tasks and an in-process gateway with every runtime method registered), use `OpenClawSDK.makeEmbeddedAgentStack(stateDirectory:credentialStore:)`. To talk to a remote OpenClaw gateway, connect a `GatewayNodeSession` (or `GatewayChannelActor`) and put `OpenClawChatView` on top of `OpenClawGatewaySessionChatTransport`.

## Package Products

### Cross-platform runtime modules (Apple platforms and Linux)

- `OpenClawProtocol`: gateway protocol v4 models vendored from upstream `2026.9.6`, the generated method catalog, typed `AnyCodable` accessors, protocol constants
- `OpenClawCore`: SDK config and the lossless upstream config document (JSON5, doctor migrations, write guards), secrets, auth storage, sessions and transcripts, hooks, cron, exec allowlists, diagnostics, replay, security audit
- `OpenClawGateway`: gateway client with reconnect lifecycle, and the in-process `GatewayServer` with its public method-registration API, events and startup gating
- `OpenClawAgents`: embedded agent runtime with the tool-calling loop, approvals, questions, context engines, sub-agents, task ledger and core tool catalog
- `OpenClawPlugins`: plugin API v2, manifests, hook dispatch and service lifecycle
- `OpenClawChannels`: channel adapters, access policy and DM pairing, chunking, receipts, auto-reply routing
- `OpenClawMemory`: builtin memory engine (BM25, embeddings, MMR), memory tools and, on Apple 27, a CoreSpotlight index
- `OpenClawMedia`: attachment normalization, limits and on-device media understanding
- `OpenClawModels`: generated provider catalog, model contract v2 providers, routing, auth resolution, Apple Foundation Models and CoreAI
- `OpenClawSkills`: skill discovery, eligibility, prompt catalog and JS/WASM execution
- `OpenClawMCP`: Model Context Protocol client (Streamable HTTP, legacy SSE, stdio on macOS/Linux, OAuth) exposed as agent tools

### Apple platform modules

- `OpenClawKit`: high-level SDK facade plus Apple app helpers (gateway channel and node session, TLS pinning, device identity and auth, node commands, Talk, Watch, StateReporting, Now Playing, background tasks, Live Activities). Re-exports the runtime modules above, including `OpenClawMCP`.
- `OpenClawNativeState`: the upstream native state database (`state/openclaw.sqlite`, schema v18) on system SQLite. Import it explicitly; `OpenClawKit` uses it for device identity and exec approvals.
- `OpenClawChatUI`: SwiftUI chat (views on iOS, macOS and visionOS; the non-UI chat core on every Apple platform). Depends on `OpenClawKit` and swift-markdown.
- `OpenClawChatStore`: GRDB-backed offline transcript cache and durable command outbox for ChatUI. GRDB is resolved for every consumer but only compiled when this product is linked.
- `OpenClawAppIntents`: App Intents entities, queries and intents (Ask, Abort, Start Live Voice and, on OS 27, a long-running Run Task intent) backed by an embedded runtime or a gateway.

## Platform Support

| Platform | Minimum | Notes |
| --- | --- | --- |
| iOS / iPadOS | 17 | All products. iOS 26/27 features are availability-gated and weak-linked. |
| macOS | 14 | All products; MCP stdio transport and the macOS-only node commands. |
| visionOS | 26 | All products, including ChatUI views. |
| tvOS | 17 | ChatUI ships the non-UI chat core only (view model, transports, models). FoundationModels is unavailable; the `apple-fm` provider reports `frameworkUnavailable`. |
| watchOS | 10 | ChatUI non-UI core only; no camera or Bonjour resolution. `apple-fm/private-cloud-compute` is the only Foundation Models route (watchOS 27). `Int` is 32-bit on arm64_32, so SDK timestamps are `Int64`. |
| Linux | Swift 6.2 | The cross-platform runtime modules. Apple-only products are not declared. |

- Swift tools: `6.2`. Build with Xcode 27.1 (Swift 6.4) on Apple platforms; Xcode's own toolchain is required to use the 27 SDKs.
- Apple 27 APIs (FoundationModels 27, Private Cloud Compute, StateReporting, NowPlaying, App Intents 27, TrustInsights, LinkSecurity, BackgroundTasks async submission, MediaIntelligence, MusicUnderstanding, CoreAI, ScreenCaptureKit on iOS) sit behind `#if compiler(>=6.4)` and per-OS `@available`, so apps with the floors above launch on older systems. `Scripts/check-apple-weak-links.sh` enforces this.

## Highlights in 2026.3.0

- OpenClaw `v2026.9.6` parity: protocol v4 models and method catalog, the upstream gateway client (socket generations, challenge-signed device proof, scoped device tokens, defensive hello-ok), native SQLite state with one-time identity import, and the in-process gateway's registration API, events and startup gating.
- Agent runtime: a model-driven tool-calling loop on model contract v2, streaming agent events, approvals, questions, compaction, sub-agents, tasks, goals and Tool Search; MCP, skills catalog, memory and automations wired in.
- Providers: a catalog generated from upstream manifests (70 text providers, 357 models), `ThinkLevel` `max`/`ultra`, incremental streaming, fast mode, prompt caching and the ChatGPT/Codex OAuth route on `openai`.
- Apple Intelligence: `apple-fm` on FoundationModels 27 with host-owned tool calls, structured output and streaming; Private Cloud Compute (`apple-fm/private-cloud-compute`); Vision and Spotlight tools; `OpenClawLanguageModel` to run FoundationModels sessions on any provider; on-device media understanding and CoreAI.
- Apple 27 system integration: App Intents product, opt-in StateReporting, Now Playing, TrustInsights approval friction, LinkSecurity, async background-task submission, `ProgressManager` run progress and Live Activity schemas.
- Channels: upstream access policy with DM pairing (default `dmPolicy: pairing`), per-channel chunking and receipts, new SMS (Twilio), A2A, LINE, carrier messaging and IMAP adapters.
- ChatUI: the upstream chat shell and rendering stack (markdown blocks, tool activity, cards, media, widgets) and the GRDB-backed `OpenClawChatStore`.

See [CHANGELOG.md](CHANGELOG.md) for the complete list, including breaking changes and migration notes.

## Examples

The repo includes example apps in [Examples/iOS](Examples/iOS) and [Examples/tvOS](Examples/tvOS). Both build with Xcode 27 and show:

- an embedded runtime with channel adapters behind the default DM pairing policy (approve senders in the Channels tab)
- the SDK App Intents (`OpenClawAppIntents.configure(host:)` and an app `AppIntentsPackage`)
- opt-in StateReporting (`OpenClawSystemState.isEnabled`) with the agent-run diagnostics sink
- background tasks submitted through `OpenClawBackgroundTasks` (async on OS 27)
- remote gateway chat over `OpenClawGatewaySessionChatTransport` (`OpenClawChatView` on iOS, a custom transcript on tvOS)

CI builds both apps; they are also the best reference for diagnostics surfaces and local skill packaging.

## Local Validation

For code or docs changes, this is the recommended local gate:

```bash
swift build -Xswiftc -warnings-as-errors
Scripts/lint-swift.sh
Scripts/check-networking-concurrency.sh
swift test
Scripts/build-docs-site.sh
```

For Apple platform changes, add:

```bash
Scripts/validate-apple-matrix.sh
Scripts/typecheck-apple-sdks.sh all
Scripts/build-apple-platforms.sh all
Scripts/check-apple-weak-links.sh all
Scripts/build-ios-example.sh
Scripts/build-tvos-example.sh
```

If you are touching a cross-platform module, run the Swift 6.2 Linux gate in Docker (the named volume keeps the Linux `.build` separate from the macOS one):

```bash
docker run --rm -v "$PWD:/workspace" -v openclawkit-linux-build:/workspace/.build \
  -w /workspace swift:6.2 bash -c \
  'Scripts/build-linux-runtime.sh && Scripts/check-networking-concurrency.sh && Scripts/test-linux-runtime.sh'
```

After a parity refresh, check generated sources and fixtures against the pinned upstream checkout:

```bash
OPENCLAW_UPSTREAM_DIR=.codex/openclaw Scripts/check-upstream-drift.sh
```

Live provider tests are opt-in and never run in CI. They read keys from the environment (for example a local, git-ignored `.env`):

```bash
set -a; . ./.env; set +a
OPENCLAW_LIVE_PROVIDER_TESTS=1 swift test --filter LiveProvider
```

See [docs/testing.md](docs/testing.md) for the full matrix, costs and the Anthropic workspace note.

## Contributing

Keep public-facing conceptual documentation in the DocC catalog under `Sources/OpenClawKit/OpenClawKit.docc`, and keep the markdown files in `docs/` focused on stable SDK usage notes rather than release-history tracking.

If you are changing protocol models, provider or channel catalogs, regenerate them from the pinned upstream snapshot with the generator scripts instead of hand-maintaining divergent copies. Every new public declaration needs a `///` doc comment (SwiftLint `missing_docs`). Put 27-only APIs behind `#if compiler(>=6.4) && canImport(...)` plus per-OS `@available` (never `anyAppleOS`), and do not use `withTaskCancellationShield` while the floors are below 27.

## License

OpenClawKit is released under the [MIT License](LICENSE).
