# 2026.2.4 OpenClaw 2026.3.13 Parity Manifest

This document locks the parity target for the `2026.2.4` OpenClawKit release.
It is intentionally implementation-focused and should be treated as the source
of truth for the Swift SDK surfaces shipped in this release.

## Baseline Scope

- **Upstream parity reference:** pinned `.cursor/openclaw` snapshot at
  `61cd3a6e446c3d181a0a75861fd85d459c068a3d`
- **Primary upstream release notes:** `.cursor/openclaw/CHANGELOG.md`
  sections `2026.3.12` and `2026.3.13`
- **Official docs references:**
  - <https://docs.openclaw.ai/gateway/secrets>
  - <https://docs.openclaw.ai/providers/openai>
- **Swift package source of truth:**
  - `Sources/OpenClawCore/OpenClawConfig.swift`
  - `Sources/OpenClawCore/GatewayConfig.swift`
  - `Sources/OpenClawCore/SecretsConfig.swift`
  - `Sources/OpenClawCore/ModelProviderConfigTypes.swift`
  - `Sources/OpenClawModels/ProviderCatalog.swift`
- **Checked-in parity fixtures:**
  - `Sources/OpenClawProtocol/GatewayModels.swift`
  - `Tests/OpenClawKitTests/ProviderCatalogReferenceFixture.swift`
- **Dependency pin introduced for this train:** `OpenAIKit` exact `3.0.0`

## Delivered Parity Surface

### Protocol and Session Snapshot

- Generated gateway/session protocol models now track the upstream
  `2026.3.13` snapshot instead of the earlier reduced local schema.
- Swift session persistence and patch handling now include parity fields such as
  `fastMode`, `spawnedWorkspaceDir`, and richer route/provenance metadata.

### Shared Swift Package Surface

- `OpenClawKit` now includes the upstream shared Apple-facing helper families:
  device auth/store payloads, gateway discovery, gateway channel helpers,
  push payloads, TLS pinning, talk/browser/camera/location/share helpers, and
  generic password keychain storage.
- `OpenClawChatUI` ships as an additive library product for host apps that want
  a reusable SwiftUI chat layer without adopting the example-app UI wholesale.

### Secrets, Gateway, and Auth Parity

- `OpenClawConfig.secrets` supports env, file, and exec providers through
  `SecretRef`, `SecretInput`, `SecretProviderConfig`, and `SecretsConfig`.
- Secret-bearing gateway and model fields accept either plaintext strings or
  structured references.
- `GatewayConfig` includes parity blocks for:
  - `auth`
  - `remote`
  - `tailscale`
  - `controlUi`
  - `http`
  - `push`
- Auth profile storage now keeps ref-backed credentials, richer metadata,
  cooldown state, and last-good selection data while preserving secure-store
  migration for legacy plaintext values.

### OpenAI, Codex, and Fast Mode Parity

- Direct OpenAI and Codex-backed OpenAI paths now run through an
  OpenClawKit-owned adapter on top of `OpenAIKit`.
- `openai-compatible` continues to use the custom transport so proxy and
  compatibility-provider behavior remains stable.
- Fast mode is now a canonical config and session/runtime surface:
  - per-model default via `models.providers.<provider>.models[].fastMode`
  - session override via the stored session record
  - runtime override via `ModelGenerationPolicy.fastMode`
- OpenAI/Codex fast mode behavior:
  - low reasoning effort by default
  - low text verbosity by default
  - `service_tier=priority` for direct public `openai/*` traffic when supported
- Anthropic fast mode behavior:
  - direct API-key `anthropic/*` requests map `fastMode: true` to
    `service_tier=auto`
  - direct API-key `anthropic/*` requests map `fastMode: false` to
    `service_tier=standard_only`
  - OAuth and proxy Anthropic paths do not inject Anthropic fast-mode defaults

### Provider Catalog Parity

- The built-in provider catalog matches the `2026.3.13` parity target for the
  shared Swift SDK, including `sglang`.
- `sglang` ships with the default local OpenAI-compatible endpoint:
  - provider ID: `sglang`
  - base URL: `http://127.0.0.1:30000/v1`
  - default model: `Qwen/Qwen3-8B`
- Codex Spark handling matches current upstream behavior:
  - suppress stale direct `openai/gpt-5.3-codex-spark`
  - preserve Codex Spark on the `openai-codex/*` path

## Canonical Config Notes

### Secrets

- `"${OPENAI_API_KEY}"` is decoded as an env `SecretRef`.
- File refs use `id: "value"` for single-value files or JSON pointers such as
  `"/providers/openai/apiKey"` for JSON files.
- Exec refs use stable IDs resolved by a configured exec secret provider.

### Models

- Canonical provider configuration lives under `models.providers`.
- Legacy provider-service decoding remains available for backward compatibility,
  but new parity work should target `ModelProviderConfig` and
  `ModelDefinitionConfig`.

### Gateway

- Canonical gateway auth lives under `gateway.auth`, not only the legacy
  `gateway.authMode` string.
- Remote gateway credentials should use `gateway.remote.token` or
  `gateway.remote.password` with `SecretInput` rather than plaintext fields.
- Push/APNs relay settings live under `gateway.push.apns.relay`.

## Example App Notes

- The iOS and tvOS examples continue to use project-owned UI shells and runtime
  state containers.
- Shared SDK-facing helpers are now expected to come from `OpenClawKit`, while
  reusable chat UI can come from `OpenClawChatUI`.
- The examples remain the smoke-test host for app-facing package integration,
  not the canonical source of shared SDK types.

## Release Gate

Every commit in this release train is expected to pass:

1. `swift build -Xswiftc -warnings-as-errors`
2. `swift test`
3. existing platform/example validation scripts when the touched surface
   requires them
