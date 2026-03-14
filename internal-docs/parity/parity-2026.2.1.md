# 2026.2.1 Channel + Model Parity Manifest

This document locks the parity target for the 2026.2.1 release train.
It is intentionally implementation-focused and should be treated as the source
of truth for adapter/provider naming while commits are in flight.

## Baseline Scope

- **Upstream parity reference:** pinned `.cursor/openclaw` snapshot at
  `8cc0c9baf2ffce3da3402c0fb1309cc31a7343e6`
- **Swift implementation source of truth:**
  `Sources/OpenClawCore/OpenClawConfig.swift` and
  `Sources/OpenClawModels/ProviderCatalog.swift`
- **Checked-in parity fixture:**
  `Tests/OpenClawKitTests/ProviderCatalogReferenceFixture.swift`
- **Release target:** full parity for remaining channel adapters and model API
  services requested for 2026.2.1.
- **WhatsApp scope lock:** continue using `WhatsAppCloudChannelAdapter` as the
  canonical WhatsApp implementation and expand parity within that adapter.

## Channel Adapter Parity Matrix

| Channel | Status in Swift SDK | 2026.2.1 Target |
| --- | --- | --- |
| WhatsApp | Implemented as cloud adapter (`WhatsAppCloudChannelAdapter`) | Expand parity behavior and diagnostics |
| Slack | `ChannelID` exists, no concrete adapter | Add `SlackChannelAdapter` |
| Google Chat | No channel ID/config/adapter | Add `googlechat` channel + `GoogleChatChannelAdapter` |
| Signal | `ChannelID` exists, no concrete adapter | Add `SignalChannelAdapter` |
| iMessage | `ChannelID` exists, no concrete adapter | Add `IMessageChannelAdapter` with availability guards |
| Microsoft Teams | No channel ID/config/adapter | Add `msteams` channel + `MicrosoftTeamsChannelAdapter` |
| WebChat | In-memory adapter only | Add production WebChat adapter surface |

Current Swift channel baseline:

- `Sources/OpenClawChannels/DiscordChannelAdapter.swift`
- `Sources/OpenClawChannels/TelegramChannelAdapter.swift`
- `Sources/OpenClawChannels/WhatsAppCloudChannelAdapter.swift`
- `Sources/OpenClawChannels/ChannelAdapter.swift`

## Model API Service Parity Matrix

OpenClaw parity reference surfaces:

- pinned `.cursor/openclaw` snapshot for TS provider/auth behavior
- `Sources/OpenClawCore/OpenClawConfig.swift` for Swift config compatibility
- `Sources/OpenClawModels/ProviderCatalog.swift` for Swift provider registry
- `Tests/OpenClawKitTests/ProviderCatalogReferenceFixture.swift` for the checked-in
  provider snapshot used by tests

### Already first-class in Swift SDK

- `openai`
- `openai-compatible`
- `anthropic`
- `gemini`
- `foundation`
- `local`

### Parity targets to add for 2026.2.1

- **Required first-class:** `xai` / Grok
- **OpenAI-compatible family:** `openrouter`, `groq`, `mistral`, `cerebras`,
  `moonshot`, `litellm`, `together`, `huggingface`, `qianfan`, `nvidia`, `zai`
- **Anthropic-compatible/gateway family:** `minimax`, `minimax-portal`,
  `synthetic`, `xiaomi`, `cloudflare-ai-gateway`, `vercel-ai-gateway`
- **Unique protocol/service family:** `amazon-bedrock`, `github-copilot`,
  `ollama`, `vllm`, `qwen-portal`

## Config/Auth Parity Constraints

- Add backward-compatible config decode defaults for all new channel/provider
  blocks in `Sources/OpenClawCore/OpenClawConfig.swift`.
- Ensure all new credentials are represented in security audit checks in
  `Sources/OpenClawCore/SecurityAuditReport.swift`.
- Keep provider IDs stable and lowercase-hyphenated to align with OpenClaw
  naming and routing expectations.

## Quality Gate Per Commit

1. `swift build -Xswiftc -warnings-as-errors`
2. `Scripts/check-networking-concurrency.sh`
3. `swift test`
4. `./Scripts/build-ios-example.sh`
5. `./Scripts/test-ios-example.sh`
6. `./Scripts/build-tvos-example.sh`
7. `Scripts/validate-apple-matrix.sh --platform macos`
8. `Scripts/validate-apple-matrix.sh --platform ios`
