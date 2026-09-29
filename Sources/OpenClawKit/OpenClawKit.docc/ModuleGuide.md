# Module Guide

The SDK is organized as layered SwiftPM targets so host apps can stay high
level or drop deeper when they need custom behavior.

## Cross-Platform Modules

These build on every Apple platform and on Linux (Swift 6.2):

- `OpenClawProtocol` for the gateway protocol v4 models vendored from upstream
  `v2026.9.6`, the generated method catalog and the typed `AnyCodable` accessors
- `OpenClawCore` for SDK config and the lossless upstream config document, secrets,
  storage, sessions and transcripts, hooks, cron, exec allowlists, diagnostics and
  security audit
- `OpenClawGateway` for the gateway client and the in-process `GatewayServer` with its
  method-registration API, events and startup gating
- `OpenClawModels` for the generated provider catalog, model contract v2 providers,
  routing, auth resolution, Apple Foundation Models and CoreAI
- `OpenClawSkills` for skill discovery, eligibility, the prompt catalog and executors
- `OpenClawAgents` for the embedded agent runtime and its tool-calling loop
- `OpenClawChannels` for channel adapters, access policy and pairing, and auto-reply
- `OpenClawMemory` and `OpenClawMedia` for the memory engine and tools, attachments and
  on-device media understanding
- `OpenClawPlugins` for plugin API v2 registrations and hook dispatch
- `OpenClawMCP` for the Model Context Protocol client (stdio transport on macOS and
  Linux only)

## Apple Platform Modules

- `OpenClawKit` for the umbrella SDK facade and the Apple app helpers (gateway channel
  and node session, device identity, node commands, Talk, Watch, StateReporting). It
  re-exports the cross-platform modules, including `OpenClawMCP`.
- `OpenClawNativeState` for the upstream native state database (`state/openclaw.sqlite`).
  OpenClawKit uses it for device identity and exec approvals; import it only for the
  low-level SQLite API.
- `OpenClawChatUI` for SwiftUI chat. Views compile on iOS, macOS and visionOS; tvOS and
  watchOS get the non-UI chat core (view model, transports, models). Depends on
  swift-markdown.
- `OpenClawChatStore` for the GRDB-backed transcript cache and durable command outbox.
- `OpenClawAppIntents` for App Intents entities, queries and intents backed by an
  embedded runtime or a gateway.

## Choosing a Surface

Use ``OpenClawSDK`` when you want the shortest path to a working integration.
Drop into lower-level modules when you need custom provider routing, transport
hosting, skill execution, or UI behavior that sits below the facade. Linux services
depend on the cross-platform products directly; the Apple-only products are not
declared on Linux.
