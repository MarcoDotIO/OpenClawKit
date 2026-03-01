<p align="center">
  <img src="Resources/logo-banner.jpg" alt="OpenClawKit logo banner" width="900" />
</p>

# OpenClawKit

[![CI](https://github.com/MarcoDotIO/OpenClawKit/actions/workflows/ci.yml/badge.svg)](https://github.com/MarcoDotIO/OpenClawKit/actions/workflows/ci.yml)
[![Security](https://github.com/MarcoDotIO/OpenClawKit/actions/workflows/security.yml/badge.svg)](https://github.com/MarcoDotIO/OpenClawKit/actions/workflows/security.yml)
[![Release](https://github.com/MarcoDotIO/OpenClawKit/actions/workflows/release.yml/badge.svg)](https://github.com/MarcoDotIO/OpenClawKit/actions/workflows/release.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

OpenClawKit is a Swift-native agent SDK for Apple platforms and Linux services.
It provides a complete runtime surface: protocol contracts, model routing, channels,
skills, memory, observability, security, iOS app integrations, and release-grade tooling.

## 2026.2.0 Highlights

### Core Breakthroughs

- **Deterministic Replay Runtime (Flight Recorder)**  
  Stable replay schemas (`ReplayEvent`, `ReplayEventEnvelope`), append-only replay stores,
  deterministic replay engine queries, and SDK replay APIs.
- **Self-Optimizing Router (Latency/Cost/Quality Autopilot)**  
  Adaptive routing state and feedback loops powered by runtime diagnostics and provider telemetry.
- **WASM Skill Runtime (Portable + Safer Skills)**  
  Runtime WASM skill execution support integrated into skill invocation flow.

### Apple-First Features

- Secure Enclave-signed replay ledger hooks with integrity verification support.
- Instruments-native timeline sink (`OSLog`/signpost-friendly diagnostics export).
- Intent graph as a first-class protocol/runtime/SDK surface.
- App Intents + App Shortcuts updated to intent-graph aware flows.
- Live Activities support for long-running runs in the iOS sample.
- Proactive automation layer with persisted rules + background tick hooks.
- Personal-data skills kit with permissioned connector policy gates.
- Multimodal on-device session mode (attachments in protocol/runtime/channel/iOS chat).
- SwiftData + CloudKit-ready memory graph store with legacy migration bridge.
- Ask OpenClaw Share Extension scaffold + app inbox bridge.
- CI Apple matrix validation for platform declarations and iOS build coverage.

## Table of Contents

- [Installation](#installation)
- [Quick Start](#quick-start)
- [Runtime Features](#runtime-features)
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
- watchOS `10+`
- Linux supported for package/runtime flows with compatibility shims

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
- Multi-provider model routing with fallback and adaptive optimization
- Channel adapters (Discord, Telegram, WhatsApp Cloud, webchat)
- Skill discovery/invocation (`SKILL.md`, JS/WASM executors)
- Prompt bootstrap context loading (`AGENTS.md`, identity/personality files)
- Persistent session routing and conversation memory
- Streaming output support and typing heartbeat semantics
- Diagnostics pipeline with usage snapshots and recent-event timelines

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
- Intent-graph aware App Intents + shortcuts
- Live Activities status surfaces for run lifecycle
- Proactive background automation hooks
- Multimodal chat attachment staging/import flow
- Share inbox bridge (`SharePromptInbox`) for extension handoff

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

## Testing and CI

Recommended local gate:

```bash
swift build -Xswiftc -warnings-as-errors
Scripts/check-networking-concurrency.sh
swift test
./Scripts/build-ios-example.sh
./Scripts/test-ios-example.sh
```

Apple matrix static validation:

```bash
Scripts/validate-apple-matrix.sh --platform macos
Scripts/validate-apple-matrix.sh --platform ios
```

CI workflows:

- `ci.yml` - Swift validation, iOS build, and Apple platform matrix checks
- `security.yml` - secret/security scanning
- `release.yml` - changelog-gated tagged releases

## Documentation

- [Architecture](docs/architecture.md)
- [API Surface](docs/api-surface.md)
- [Testing Guide](docs/testing.md)
- [Changelog](CHANGELOG.md)

Protocol generation:

```bash
node Scripts/protocol-gen-swift.mjs
```

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
