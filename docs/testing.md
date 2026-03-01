# Testing Guide

OpenClawKit uses Swift Testing (`import Testing`) for both unit and E2E coverage.

## Run All Tests

```bash
swift test
```

## Test Structure

- `Tests/OpenClawKitTests`
  - unit-level tests for protocol, core shims, runtime primitives, diagnostics, facade helpers
- `Tests/OpenClawKitE2ETests`
  - end-to-end tests across transport/runtime/channels/plugin flow and reconnect lifecycle

## Networking Concurrency Gate

Run this before committing networking changes:

```bash
Scripts/check-networking-concurrency.sh
```

This enforces strict concurrency diagnostics for networking-related targets.

## API Key Dependent E2E Workflows

Some integration-style E2E workflows may require provider keys:

- `OPENAI_API_KEY`
- `GEMINI_API_KEY`
- `ANTHROPIC_API_KEY`
- `XAI_API_KEY`

Set these in local `.env` (ignored by git) when running live provider-backed scenarios.
Never commit `.env`.

## Recommended Local Validation Sequence

1. `swift build -Xswiftc -warnings-as-errors`
2. `Scripts/check-networking-concurrency.sh`
3. `swift test`
4. `./Scripts/build-ios-example.sh`
5. `./Scripts/test-ios-example.sh`
6. `Scripts/validate-apple-matrix.sh --platform macos`
7. `Scripts/validate-apple-matrix.sh --platform ios`

## 2026.2.1 Parity Coverage Highlights

- Channel adapter reliability:
  dedicated suites for Slack, Google Chat, Signal, iMessage, Microsoft Teams,
  WebChat, and parity-expanded WhatsApp Cloud handling.
- Provider parity reliability:
  routing/unit tests for xAI/Grok, OpenAI-compatible packs, Anthropic-compatible
  gateway packs, and unique protocol providers (Bedrock/Copilot/Ollama/vLLM/Qwen).
- Config matrix reliability:
  serialization/defaulting coverage for expanded provider-service auth/API-style
  fields and channel config surfaces.
- Security reliability:
  regression coverage for parity secret detection and risky-default findings,
  including local-runtime auth-none exemptions and AWS-region checks.
- CI platform coverage:
  full per-commit gate remains required, including Apple matrix validation in
  `Scripts/validate-apple-matrix.sh` for macOS and iOS declarations.
