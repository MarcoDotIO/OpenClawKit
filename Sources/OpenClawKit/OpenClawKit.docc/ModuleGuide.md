# Module Guide

The SDK is organized as layered SwiftPM targets so host apps can stay high
level or drop deeper when they need custom behavior.

## Modules

- `OpenClawProtocol` for protocol contracts and generated gateway/session types
- `OpenClawCore` for config, storage, diagnostics, security, and compatibility shims
- `OpenClawGateway` for typed transport and server surfaces
- `OpenClawModels` for providers, routing, auth resolution, and request shaping
- `OpenClawSkills` for skills, executors, and connector permissions
- `OpenClawAgents` for runtime orchestration
- `OpenClawChannels` for adapters and auto-reply flows
- `OpenClawMemory` and `OpenClawMedia` for durable context and attachments
- `OpenClawKit` for the umbrella SDK facade
- `OpenClawChatUI` for optional shared SwiftUI chat integration

## Choosing a Surface

Use ``OpenClawSDK`` when you want the shortest path to a working integration.
Drop into lower-level modules when you need custom provider routing, transport
hosting, skill execution, or UI behavior that sits below the facade.
