# Roadmap 2026.2.1

This document records the 2026.2.1 channel + model-service parity train and
its release discipline (`one step = one commit`).

## Commit Train

1. `c1-parity-manifest` - parity manifest lock for channels/providers
2. `c2-channel-config-foundation` - shared channel config/ID scaffolding
3. `c3-whatsapp-cloud-parity` - WhatsApp Cloud parity behavior + diagnostics
4. `c4-slack-adapter` - Slack adapter + tests
5. `c5-google-chat-adapter` - Google Chat adapter + tests
6. `c6-signal-adapter` - Signal adapter + tests
7. `c7-imessage-adapter` - iMessage adapter with availability guards + tests
8. `c8-ms-teams-adapter` - Microsoft Teams adapter + tests
9. `c9-webchat-adapter` - production WebChat adapter + integration coverage
10. `c10-provider-config-matrix` - provider service config/auth matrix expansion
11. `c11-grok-provider` - xAI/Grok provider + routing tests
12. `c12-openai-pack-a` - OpenRouter/Groq/Mistral/Cerebras services
13. `c13-openai-pack-b` - Moonshot/LiteLLM/Together/Hugging Face/Qianfan/NVIDIA/Z.AI services
14. `c14-anthropic-gateway-pack` - MiniMax/MiniMax Portal/Synthetic/Xiaomi/Cloudflare/Vercel services
15. `c15-unique-provider-pack` - Bedrock/Copilot/Ollama/vLLM/Qwen Portal services
16. `c16-security-audit-updates` - parity secret/risky-default audit coverage
17. `c17-ios-integration` - iOS provider/channel surfaces + persistence wiring
18. `c18-tests-hardening` - expanded unit/E2E/config/security parity coverage
19. `c19-docs-and-release` - docs refresh + release/tag finalization

## Required Validation Gate (Per Commit)

1. `swift build -Xswiftc -warnings-as-errors`
2. `Scripts/check-networking-concurrency.sh`
3. `swift test`
4. `./Scripts/build-ios-example.sh`
5. `./Scripts/test-ios-example.sh`
6. `Scripts/validate-apple-matrix.sh --platform macos`
7. `Scripts/validate-apple-matrix.sh --platform ios`

## Release Output References

- Parity scope lock: `docs/parity-2026.2.1.md`
- Human-facing release notes: `CHANGELOG.md`
- Testing/quality guidance: `docs/testing.md`
- Version tag: `2026.2.1`
