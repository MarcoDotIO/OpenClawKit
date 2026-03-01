# 2026.2.1 Channel + Model Parity Manifest

This document locks the parity target for the 2026.2.1 release train.
It is intentionally implementation-focused and should be treated as the source
of truth for adapter/provider naming while commits are in flight.

## Baseline Scope

- **Canonical reference:** `.cursor/openclaw`
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

OpenClaw provider reference surfaces:

- `.cursor/openclaw/docs/concepts/model-providers.md`
- `.cursor/openclaw/src/agents/models-config.providers.ts`
- `.cursor/openclaw/src/commands/onboard-types.ts`

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
6. `Scripts/validate-apple-matrix.sh --platform macos`
7. `Scripts/validate-apple-matrix.sh --platform ios`
