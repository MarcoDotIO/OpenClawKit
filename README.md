<p align="center">
  <img src="Resources/logo-banner.jpg" alt="OpenClawKit logo banner" width="900" />
</p>

# OpenClawKit

[![CI](https://github.com/MarcoDotIO/OpenClawKit/actions/workflows/ci.yml/badge.svg)](https://github.com/MarcoDotIO/OpenClawKit/actions/workflows/ci.yml)
[![Documentation](https://github.com/MarcoDotIO/OpenClawKit/actions/workflows/docs.yml/badge.svg)](https://github.com/MarcoDotIO/OpenClawKit/actions/workflows/docs.yml)
[![Security](https://github.com/MarcoDotIO/OpenClawKit/actions/workflows/security.yml/badge.svg)](https://github.com/MarcoDotIO/OpenClawKit/actions/workflows/security.yml)
[![Release](https://github.com/MarcoDotIO/OpenClawKit/actions/workflows/release.yml/badge.svg)](https://github.com/MarcoDotIO/OpenClawKit/actions/workflows/release.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

OpenClawKit is a Swift-native agent SDK for Apple platforms and Linux services.
It provides a complete runtime surface: protocol contracts, model routing, channels,
skills, memory, observability, security, iOS app integrations, and release-grade tooling.

Public SDK documentation is published as a Swift-DocC site on GitHub Pages, with
stable companion notes in `docs/`.

## 2026.2.4 Highlights

### OpenClaw 2026.3.13 Parity

- The generated gateway/session Swift snapshot is now pinned to the OpenClaw
  `2026.3.13` upstream release commit
  `61cd3a6e446c3d181a0a75861fd85d459c068a3d`.
- Shared Apple-facing Swift surfaces from upstream are now bundled here,
  including gateway discovery/channel helpers, device-auth storage, TLS pinning,
  push payloads, and the additive `OpenClawChatUI` product.
- The provider catalog matches the current parity baseline, including `sglang`,
  current Codex Spark handling, and richer session/runtime metadata such as
  `fastMode` and `spawnedWorkspaceDir`.

### Secrets, Gateway, and Auth Parity

- Canonical `OpenClawConfig.secrets` now supports env, file, and exec-backed
  secret providers through `SecretRef`, `SecretInput`, and `SecretsConfig`.
- `GatewayConfig` now carries upstream-style auth, remote, control UI, HTTP,
  Tailscale, and push/APNs relay settings with secret-aware credentials.
- Auth profiles can persist ref-backed credentials and richer cooldown/last-good
  metadata while still decoding older plaintext config safely.

### OpenAIKit + Fast Mode

- Direct OpenAI and Codex-backed OpenAI paths now run through `OpenAIKit`
  `3.0.0` via an internal OpenClawKit adapter layer.
- The shared fast-mode toggle is wired through canonical config, session state,
  and runtime policy resolution.
- Fast mode applies OpenAI/Codex low-latency shaping where supported, and maps
  direct Anthropic API-key requests onto Anthropic `service_tier` semantics.

## 2026.2.2 Highlights

### TS Model/Auth Parity

- Canonical TS-shaped config now lives in `OpenClawConfig.auth` and
  `OpenClawConfig.models.providers`, with backward-compatible decoding for the
  older provider-service shape.
- Auth profiles now support API key, token, and OAuth credential storage with
  secure secret indirection through `CredentialStore`.
- Interactive auth metadata now exposes browser-OAuth and device-code flows for
  providers such as `openai-codex`, `github-copilot`, and `qwen-portal`, with
  Apple browser login handled through `ASWebAuthenticationSession`.
- Shared provider catalog parity now covers the current OpenClaw TS reference,
  including `openai-codex`, Google parity aliases, Copilot, Bedrock, and the
  additional coding-focused provider families.

### Apple Hardware Hardening

- Keychain-backed credentials now default to
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` for device-bound, unlock-only
  storage on Apple platforms.
- Sample app defaults now prefer Foundation Models when the host device is
  eligible and the runtime reports Apple Intelligence availability.
- Apple hardware guidance now documents Keychain, Secure Enclave-backed replay
  signing, Foundation Models, Metal-backed local inference, and Apple connector
  adapters.

## 2026.2.1 Highlights

### Channel + Model-Service Parity

- Channel adapter parity against OpenClaw references:
  Slack, Google Chat, Signal, iMessage (with availability guards), Microsoft Teams,
  production WebChat, and hardened WhatsApp Cloud behavior/diagnostics.
- Provider service parity for xAI/Grok and the remaining provider packs:
  OpenRouter, Groq, Mistral, Cerebras, Moonshot, LiteLLM, Together, Hugging Face,
  Qianfan, NVIDIA, Z.AI, MiniMax, MiniMax Portal, Synthetic, Xiaomi,
  Cloudflare AI Gateway, Vercel AI Gateway, Amazon Bedrock, GitHub Copilot,
  Ollama, vLLM, and Qwen Portal.
- Unified provider matrix through `ProviderServiceConfig` with explicit API style
  and auth mode controls (`apiKey`, bearer/OAuth token, `awsSDK`, `none`).

### Security + Validation Hardening

- Security audit coverage expanded for new channel/provider secrets and risky defaults,
  including mention-only gates, verification/shared-secret checks, insecure service
  URL checks, and provider auth/region diagnostics.
- iOS sample deploy surfaces now expose parity provider/channel configuration with
  migration-safe secure secret persistence.
- Full release gate is enforced across Swift build/test, networking concurrency,
  iOS build/test, and Apple matrix validation.

## Table of Contents

- [Installation](#installation)
- [Quick Start](#quick-start)
- [Runtime Features](#runtime-features)
- [Secrets, Fast Mode, and Provider Parity](#secrets-fast-mode-and-provider-parity)
- [Apple Hardware](#apple-hardware)
- [Skills and Connectors](#skills-and-connectors)
- [Replay, Routing, and Intent Graphs](#replay-routing-and-intent-graphs)
- [Apple Platform Integrations](#apple-platform-integrations)
- [Modules](#modules)
- [Testing and CI](#testing-and-ci)
- [Documentation](#documentation)
- [Contributing](#contributing)
- [License](#license)

## Installation

Add OpenClawKit with Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/MarcoDotIO/OpenClawKit.git", branch: "main")
]
```

Then link the product:

```swift
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "OpenClawKit", package: "OpenClawKit")
        ]
    )
]
```

### Toolchain and Platform Baseline

- Swift tools: `6.2`
- iOS `17+`
- macOS `14+`
- tvOS `17+`
- visionOS `26+`
- watchOS `10+`
- Linux supported for package/runtime flows with compatibility shims

The Swift package still declares visionOS compatibility, but `2026.2.2` does
not ship a visionOS example app.

## Quick Start

```swift
import OpenClawKit

let sdk = OpenClawSDK.shared
let diagnostics = sdk.makeDiagnosticsPipeline(eventLimit: 500)

let outbound = try await sdk.getReplyFromConfig(
    config: OpenClawConfig(),
    sessionStoreURL: URL(fileURLWithPath: "./state/sessions.json"),
    inbound: InboundMessage(
        channel: .webchat,
        peerID: "user-1",
        text: "Plan a concise project update."
    ),
    diagnosticsPipeline: diagnostics
)

print(outbound.text)
print(await diagnostics.usageSnapshot().runsCompleted)
```

## Runtime Features

- Actor-isolated embedded runtime orchestration (`EmbeddedAgentRuntime`)
- In-process gateway control plane with typed agent, session, model, skill,
  secret, and `browser.request` handlers
- Multi-provider model routing with fallback and adaptive optimization across
  OpenAIKit-backed direct OpenAI/Codex, OpenAI-compatible, Anthropic-compatible,
  Gemini, xAI, Bedrock, and local runtimes
- Provider-aware auth profile routing with OAuth refresh/token exchange support
  for TS parity providers such as GitHub Copilot and Qwen Portal
- Built-in `llm-task` structured-generation tool for JSON-first agent workflows
- Secret-aware config and gateway auth surfaces using `SecretRef`,
  `SecretInput`, and `CredentialStore`
- Built-in `llm-task` structured-generation tool for JSON-first agent workflows
- Channel adapters (Discord, Telegram, WhatsApp Cloud, Slack, Google Chat, Signal,
  BlueBubbles, iMessage, Microsoft Teams, and production WebChat)
- Skill discovery/invocation (`SKILL.md`, JS/WASM executors with embedded WasmKit fallback)
- Exec allowlist enforcement shared by process, skill, and gateway browser helpers
- Shared media pipeline for URL/file/blob attachment fetch, storage, and provider-ready handles
- Prompt bootstrap context loading (`AGENTS.md`, identity/personality files)
- Persistent session routing and conversation memory
- Streaming output support and typing heartbeat semantics
- Diagnostics pipeline with usage snapshots and recent-event timelines
- Shared gateway/device helpers in `OpenClawKit` plus optional SwiftUI chat
  surfaces in `OpenClawChatUI`

## Secrets, Fast Mode, and Provider Parity

The canonical parity surface lives in `OpenClawConfig.secrets`,
`OpenClawConfig.gateway`, and `OpenClawConfig.models.providers`.

```json
{
  "secrets": {
    "providers": {
      "default": {
        "source": "env",
        "allowlist": ["OPENAI_API_KEY", "OPENCLAW_GATEWAY_TOKEN"]
      },
      "mounted-json": {
        "source": "file",
        "path": "/run/secrets/providers.json"
      }
    },
    "defaults": {
      "env": "default",
      "file": "mounted-json"
    }
  },
  "gateway": {
    "auth": {
      "mode": "token",
      "token": "${OPENCLAW_GATEWAY_TOKEN}"
    },
    "remote": {
      "enabled": true,
      "url": "https://gateway.example.com",
      "token": {
        "source": "file",
        "provider": "mounted-json",
        "id": "/gateway/token"
      }
    },
    "push": {
      "apns": {
        "relay": {
          "baseUrl": "https://push.example.com",
          "timeoutMs": 15000
        }
      }
    }
  },
  "models": {
    "providers": {
      "openai": {
        "enabled": true,
        "baseURL": "https://api.openai.com/v1",
        "auth": "api-key",
        "api": "openai-responses",
        "models": [
          {
            "id": "gpt-5.4",
            "api": "openai-responses",
            "fastMode": true
          }
        ]
      },
      "sglang": {
        "enabled": true,
        "baseURL": "http://127.0.0.1:30000/v1",
        "auth": "api-key",
        "api": "openai-completions",
        "models": [
          {
            "id": "Qwen/Qwen3-8B",
            "api": "openai-completions"
          }
        ]
      }
    }
  }
}
```

Notes:

- Secret-bearing fields accept either plaintext strings or structured refs.
  Environment templates such as `"${OPENAI_API_KEY}"` decode into `SecretRef`
  automatically.
- Direct `openai/*` and `openai-codex/*` requests use the OpenAIKit-backed path.
  `openai-compatible/*` remains on the custom HTTP transport so proxy/runtime
  compatibility stays unchanged.
- Fast mode resolves in the same direction as upstream OpenClaw:
  request override, session override, per-model config default, then provider
  behavior fallback.
- For direct OpenAI public API traffic, fast mode adds low reasoning effort,
  low text verbosity, and `service_tier=priority` when that surface supports it.
- For direct Anthropic API-key traffic, fast mode maps onto
  `service_tier=auto`, while explicit `fastMode: false` maps to
  `service_tier=standard_only`. OAuth and proxy Anthropic paths skip that
  default injection.
- Built-in model filtering suppresses the stale direct
  `openai/gpt-5.3-codex-spark` row while preserving Codex Spark on the
  `openai-codex/*` auth path.

## Apple Hardware

- Keychain-backed credentials default to device-bound, unlock-only
  accessibility, and replay signing surfaces are designed to work with Secure
  Enclave-backed key material through `ReplayLedgerSigner`.
- Browser-based OAuth can use the system Apple auth surface via
  `AppleWebAuthenticationSessionPresenter`, which wraps
  `ASWebAuthenticationSession` for host apps that need interactive provider
  sign-in.
- Foundation Models are the preferred on-device preset in the Apple sample apps
  when Apple Intelligence is available; `FoundationModelsProvider` handles
  runtime eligibility checks and surfaces concrete unavailability reasons.
- Local inference keeps Apple acceleration explicit through
  `LocalModelConfig.useMetal`, so host apps can bias toward Metal-backed runtimes
  when they are available.
- Connector adapters cover Apple-native surfaces such as EventKit and Photos in
  `AppleConnectorAdapters`, alongside the broader skill permission model.

## Skills and Connectors

- Workspace skills: `skills/<name>/SKILL.md`
- Explicit invocation:
  - `/skill weather {"location":"San Diego"}`
  - `/<skill-name> {"arg":"value"}`
- Natural-language skill reference matching in auto-reply flow
- Connector permission metadata and enforcement:
  - connector types (contacts, eventkit, reminders, photos, speech, camera, etc.)
  - scope checks and consent requirements
  - deny-by-default policy until grants are present

## Replay, Routing, and Intent Graphs

### Replay APIs

- `OpenClawSDK.makeReplayStore(...)`
- `OpenClawSDK.makeReplayEngine(store:)`
- `OpenClawSDK.replayEvents(forRunID:...)`
- `OpenClawSDK.replayEvents(forSessionKey:...)`
- `OpenClawSDK.replayEvents(in:...)`

### Intent Graph APIs

- `OpenClawSDK.makeIntentGraph(for:runtime:diagnosticsPipeline:)`
- `OpenClawSDK.runIntentGraph(_:runtime:timeoutMs:diagnosticsPipeline:)`
- Graph contracts in `OpenClawProtocol` (`IntentGraph`, nodes/edges/kinds)

### Adaptive Router Feedback

- Runtime diagnostics feed adaptive policy state
- Objective-driven optimization (`balanced`, `latency`, `cost`, `quality`)
- Provider scoring updates from observed latency/error behavior

## Apple Platform Integrations

### iOS Sample App (`Examples/iOS/OpenClawiOS`)

- Deploy/chat/models/skills/channels/diagnostics flows
- Provider/channel parity selection surfaces with secure credential persistence
- Project-owned UI remains the example shell, while shared gateway/device
  helpers now live in `OpenClawKit` and reusable chat surfaces ship separately
  in `OpenClawChatUI`
- Skills tab includes a one-tap WASM smoke test (`wasm-hello`) for simulator validation
- Intent-graph aware App Intents + shortcuts
- Live Activities status surfaces for run lifecycle
- Proactive background automation hooks
- Multimodal chat attachment staging/import flow
- Share inbox bridge (`SharePromptInbox`) for extension handoff

WASM smoke-test flow:

1. Build and run `Examples/iOS/OpenClawiOS` on iOS Simulator.
2. Open the **Skills** tab.
3. Tap **Run WASM Smoke Test** in the **WASM Showcase** section.
4. Confirm success status and output preview (backed by `skills/wasm-hello/module/hello.wasm`).

### Ask OpenClaw Share Extension

Scaffold files live in:

- `Examples/iOS/OpenClawiOS/OpenClawShareExtension/AskOpenClawShareViewController.swift`
- `Examples/iOS/OpenClawiOS/OpenClawShareExtension/Info.plist`
- `Examples/iOS/OpenClawiOS/OpenClawShareExtension/README.md`

The extension writes shared prompts into the app-group inbox:

- suite: `group.io.marcodotio.OpenClawKit`
- key: `openclaw.share.prompt.inbox`

## Modules

- `OpenClawProtocol` - protocol contracts and schema models
- `OpenClawCore` - config/session/security/replay/diagnostics foundations
- `OpenClawGateway` - gateway transport/socket runtime
- `OpenClawModels` - providers, routing, adaptive policy
- `OpenClawSkills` - skill metadata/registry/execution/connectors
- `OpenClawAgents` - runtime orchestration and automation runner
- `OpenClawPlugins` - plugin hooks/services
- `OpenClawChannels` - adapters + auto-reply engine
- `OpenClawMemory` - conversation store + memory graph bridge
- `OpenClawMedia` - attachment normalization/classification
- `OpenClawKit` - top-level SDK facade
- `OpenClawChatUI` - optional shared SwiftUI chat surfaces

## Testing and CI

Recommended local gate:

```bash
swift build -Xswiftc -warnings-as-errors
Scripts/check-networking-concurrency.sh
swift test
./Scripts/build-ios-example.sh
./Scripts/test-ios-example.sh
./Scripts/build-tvos-example.sh
```

Apple matrix static validation:

```bash
Scripts/validate-apple-matrix.sh --platform macos
Scripts/validate-apple-matrix.sh --platform ios
```

CI workflows:

- `ci.yml` - Swift validation, linting, iOS build, and Apple platform matrix checks
- `docs.yml` - Swift-DocC build validation and GitHub Pages deployment
- `security.yml` - secret/security scanning
- `release.yml` - changelog-gated tagged releases

## Documentation

- GitHub Pages DocC site: `https://marcodotio.github.io/OpenClawKit/`
- [Architecture](docs/architecture.md)
- [API Surface](docs/api-surface.md)
- [Testing Guide](docs/testing.md)
- [Changelog](CHANGELOG.md)

Protocol generation:

```bash
node Scripts/protocol-gen-swift.mjs
```

This syncs `OpenClawProtocol/GatewayModels.swift` from the pinned upstream
OpenClaw 2026.3.13 generated Swift snapshot at
`61cd3a6e446c3d181a0a75861fd85d459c068a3d`.

## Contributing

Issues and PRs are welcome.

- Bugs / requests: <https://github.com/MarcoDotIO/OpenClawKit/issues>
- PRs: <https://github.com/MarcoDotIO/OpenClawKit/pulls>

Please include tests for runtime/networking changes and run the full local gate before opening a PR.

## Acknowledgements

OpenClawKit is aligned with the broader OpenClaw ecosystem and design principles:

- <https://github.com/openclaw/openclaw>

## License

OpenClawKit is released under MIT. See [LICENSE](LICENSE).
