# ``OpenClawKit``

Build agentic Swift apps, services, and channel integrations with a single SDK
that spans configuration, model routing, gateway transport, skills, memory, and
optional shared chat UI.

## Overview

`OpenClawKit` packages the OpenClaw runtime surface into SwiftPM targets that can be
used together or independently. Release `2026.3.0` tracks upstream OpenClaw `v2026.9.6`
(gateway protocol v4) and adopts the Apple 27 frameworks behind availability gates, so
apps keep their iOS 17 / macOS 14 / tvOS 17 / watchOS 10 / visionOS 26 floors.

Most host apps start with ``OpenClawSDK`` and then drop to lower-level modules only when
they need custom runtime, transport, or UI behavior. The docs are organized around the
high-level SDK flow first:

- install the package and pick products
- create or load an ``OpenClawConfig`` (or an upstream `openclaw.json`)
- choose how sessions are persisted with ``SessionStore``
- run an embedded agent or connect to a gateway
- observe runs with ``RuntimeDiagnosticsPipeline`` and, on OS 27, StateReporting

Upgrading from 2026.2.x? Start with <doc:MigratingTo2026_3>.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:MigratingTo2026_3>
- <doc:ModuleGuide>
- <doc:ConfigurationAndSecrets>

### Gateway and State

- <doc:GatewayAndProtocol>
- <doc:NativeStateAndDeviceIdentity>

### Agents and Models

- <doc:ProviderRoutingAndFastMode>
- <doc:AppleIntelligence>
- <doc:MCPSkillsAndMemory>
- <doc:ChannelsAndSessions>

### Apple Platforms

- <doc:AppIntentsAndSystemIntegration>
- <doc:ChatUIAndChatStore>
- <doc:TalkAndWatch>

### Validation

- <doc:TestingAndValidation>

### Core Symbols

- ``OpenClawSDK``
- ``OpenClawConfig``
- ``SessionStore``
- ``CredentialStore``
- ``RuntimeDiagnosticsPipeline``

### Gateway Client

- ``GatewayChannelActor``
- ``GatewayNodeSession``
- ``GatewayConnectOptions``
- ``DeviceIdentityStore``

### System Integration

- ``OpenClawSystemState``
- ``OpenClawBackgroundTasks``
- ``OpenClawNowPlaying``
