# 2026.4.25 OpenClaw Parity Manifest

This document locks the SDK/control-plane parity target for the OpenClawKit
`2026.2.5` release against the upstream `2026.4.25` train. It is intentionally
scoped to Swift SDK contracts, provider/channel metadata, and in-process
gateway interoperability, not a TypeScript CLI/TUI/web/mobile app mirror.

## Baseline Scope

- **Upstream parity reference:** pinned `.codex/openclaw` snapshot at
  `6b0c72bec8`
- **Upstream package train:** `2026.4.25`
- **OpenClawKit release target:** `2026.2.5`
- **Swift protocol generator:** `Scripts/protocol-gen-swift.mjs`
- **Generated protocol fixture:** `Sources/OpenClawProtocol/GatewayModels.swift`
- **Local gateway compatibility shim:**
  `Sources/OpenClawProtocol/GatewayCompatModels.swift`
- **Provider catalog:** `Sources/OpenClawModels/ProviderCatalog.swift`
- **Channel metadata:** `Sources/OpenClawChannels/ChannelAdapter.swift`
- **Security/config surface:** `Sources/OpenClawCore/OpenClawConfig.swift` and
  `Sources/OpenClawCore/SecurityAuditReport.swift`

## Delivered Parity Surface

### Protocol

- `GatewayModels.swift` is refreshed from the pinned `.codex/openclaw` Swift
  snapshot.
- New or changed protocol surfaces represented in Swift include:
  - `MessageActionParams`
  - session creation, send, abort, and message subscription params
  - session compaction list/get/branch/restore params and result types
  - talk realtime session and speech params/results
  - command, tool catalog, and effective-tool listing types
  - skill status, bin, search, and detail types
  - `ExecApprovalGetParams`
  - plugin approval request/resolve params
  - `ErrorCode.approvalNotFound`
- OpenClawKit-owned helper payloads remain in `GatewayCompatModels.swift` so
  the local gateway server/client contract stays source-compatible while the
  generated upstream file can be refreshed cleanly.

### Gateway

- The in-process `GatewayServer` decodes newly known upstream control-plane
  methods before returning an unavailable response for intentionally unimplemented
  Swift behavior.
- Unknown method names still map to `INVALID_REQUEST`.
- Invalid params for known methods map to `INVALID_REQUEST` before the
  unavailable stub is reached.

### Providers

- Provider catalog reference commit is now `6b0c72bec8`.
- `openai-codex` default model is updated to `gpt-5.5`.
- Added SDK-relevant text/model providers:
  - `anthropic-vertex`
  - `amazon-bedrock-mantle`
  - `arcee`
  - `chutes`
  - `copilot-proxy`
  - `deepseek`
  - `fireworks`
  - `lmstudio`
  - `microsoft-foundry`
  - `qwen`
  - `stepfun`
  - `stepfun-plan`
  - `tencent-tokenhub` with `tencent` as an alias
- Added `ProviderCapability` and `ProviderPluginMetadataEntry` so non-text
  provider plugins can be represented as metadata without becoming Swift
  `ModelProvider` runtimes.
- Metadata-only provider plugins now cover web search, speech, realtime
  transcription, memory embeddings, media understanding, image generation, video
  generation, and music generation.

### Channels

- Added channel IDs and metadata for upstream plugin channels:
  `feishu`, `irc`, `matrix`, `mattermost`, `nextcloud-talk`, `nostr`, `qqbot`,
  `synology-chat`, `tlon`, `twitch`, `zalo`, `zalouser`, and `qa-channel`.
- Metadata marks existing native Swift adapters as available and plugin-only
  channels as unavailable for native transport.
- `ChannelsConfig.pluginChannels` provides a generic metadata/config-visible
  location for plugin-only channel settings and secret references.
- `SecurityAuditRunner` now scans plugin-channel secret maps for plaintext
  secret values.

## Validation Status

- Passed: `swift build -Xswiftc -warnings-as-errors`
- Blocked locally: `swift test`
  - Failure: `no such module 'Testing'`
  - Location: test-target compilation before test execution
  - Required completion path: validate through the CI Swift 6.2 toolchain or fix
    the local Swift Testing toolchain before treating this train as complete.

## Scope Boundary

This train represents and interoperates with OpenClaw SDK/control-plane
contracts. It does not reimplement the full TypeScript plugin runtime, app UI,
web/mobile clients, or every upstream transport in Swift.
