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

- layered SwiftPM products for protocol, core runtime, gateway, agents, plugins, channels, memory, media, models, and skills
- an Apple-facing `OpenClawKit` facade for app integrations and an optional `OpenClawChatUI` SwiftUI surface
- provider routing across direct OpenAI/Codex, OpenAI-compatible, Anthropic-compatible, Gemini, xAI, Bedrock, and local runtimes
- channel adapters, secret-aware config, session storage, diagnostics, replay, and security audit tooling
- a published Swift-DocC site plus CI, SwiftLint, and release automation

Current baseline:

- latest tagged release: `2026.2.5`
- current development parity target: upstream `2026.4.25` at `.codex/openclaw` commit `6b0c72bec8`
- direct OpenAI and Codex-backed OpenAI paths run through `OpenAIKit 3.0.0`
- public docs site: [marcodotio.github.io/OpenClawKit](https://marcodotio.github.io/OpenClawKit/)

## Documentation

- Swift-DocC site: [OpenClawKit Documentation](https://marcodotio.github.io/OpenClawKit/)
- Architecture notes: [docs/architecture.md](docs/architecture.md)
- High-level SDK API index: [docs/api-surface.md](docs/api-surface.md)
- Testing and validation guide: [docs/testing.md](docs/testing.md)

## Installation

Add the package with Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/MarcoDotIO/OpenClawKit.git", from: "2026.2.5")
]
```

For Apple apps, most integrations should depend on `OpenClawKit`:

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

For Linux services or lower-level integrations, depend on the specific runtime products you need instead of the Apple-only facade.

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

## Package Products

### Cross-platform runtime modules

- `OpenClawProtocol`: transport models, generated gateway/session schema, protocol constants
- `OpenClawCore`: config, secrets, auth storage, diagnostics, replay, security, platform shims
- `OpenClawGateway`: transport client, reconnect lifecycle, typed gateway flows
- `OpenClawAgents`: embedded runtime orchestration, tools, streaming execution
- `OpenClawPlugins`: plugin hooks and service lifecycle integration
- `OpenClawChannels`: channel adapters and auto-reply routing
- `OpenClawMemory`: conversation memory and indexing primitives
- `OpenClawMedia`: attachment normalization, limits, and media handling
- `OpenClawModels`: provider routing, auth resolution, OpenAIKit-backed OpenAI integrations
- `OpenClawSkills`: skill discovery and JS/WASM execution

### Apple platform modules

- `OpenClawKit`: high-level SDK facade plus Apple app helpers such as gateway discovery, TLS pinning, device auth, and command surfaces
- `OpenClawChatUI`: optional SwiftUI chat components built on top of `OpenClawKit`

## Platform Support

- Swift tools: `6.2`
- iOS: `17+`
- macOS: `14+`
- tvOS: `17+`
- visionOS: `26+`
- watchOS: `10+`
- Linux: supported for the cross-platform runtime products

## Examples

The repo includes example apps in [Examples/iOS](Examples/iOS) and [Examples/tvOS](Examples/tvOS). These are used in CI and are the best reference for end-to-end app integration, diagnostics surfaces, and local skill packaging.

## Local Validation

For code or docs changes, this is the recommended local gate:

```bash
swift build -Xswiftc -warnings-as-errors
Scripts/lint-swift.sh
Scripts/check-networking-concurrency.sh
swift test
Scripts/build-docs-site.sh
```

If you are touching Linux runtime behavior, run the Docker-backed Linux scripts from [docs/testing.md](docs/testing.md) before pushing.

## Contributing

Keep public-facing conceptual documentation in the DocC catalog under `Sources/OpenClawKit/OpenClawKit.docc`, and keep the markdown files in `docs/` focused on stable SDK usage notes rather than release-history tracking.

If you are changing protocol models, sync them from the pinned upstream snapshot instead of hand-maintaining divergent copies.

## License

OpenClawKit is released under the [MIT License](LICENSE).
