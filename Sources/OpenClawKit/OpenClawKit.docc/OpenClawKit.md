# ``OpenClawKit``

Build agentic Swift apps, services, and channel integrations with a single SDK
that spans configuration, model routing, gateway transport, skills, memory, and
optional shared chat UI.

## Overview

`OpenClawKit` packages the full OpenClaw runtime surface into SwiftPM targets
that can be used together or independently. Most host apps start with
``OpenClawSDK`` and then drop to lower-level modules only when they need custom
runtime, transport, or UI behavior.

The public docs site is organized around the high-level SDK flow first:

- install the package
- create or load an ``OpenClawConfig``
- choose how sessions are persisted with ``SessionStore``
- route messages through ``OpenClawSDK`` or a lower-level runtime surface
- observe runs with ``RuntimeDiagnosticsPipeline``

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:ConfigurationAndSecrets>
- <doc:ChannelsAndSessions>
- <doc:ProviderRoutingAndFastMode>
- <doc:TestingAndValidation>
- <doc:ModuleGuide>

### Core Symbols

- ``OpenClawSDK``
- ``OpenClawConfig``
- ``SessionStore``
- ``CredentialStore``
- ``RuntimeDiagnosticsPipeline``

### Optional UI

- ``OpenClawChatViewModel``
- ``OpenClawChatTransport``
