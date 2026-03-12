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
6. `./Scripts/build-tvos-example.sh`
7. `Scripts/validate-apple-matrix.sh --platform macos`
8. `Scripts/validate-apple-matrix.sh --platform ios`

## 2026.2.3 Parity Train Rules

The `2026.2.3` release is the SDK + control-plane parity train for the pinned
OpenClaw `2026.3.11` snapshot in [docs/parity-2026.3.11.md](./parity-2026.3.11.md).

For this train:

1. each implementation step must land as exactly one commit
2. `swift build -Xswiftc -warnings-as-errors` must pass before the commit is created
3. all previously passing tests must still pass
4. tests added for the step must pass and fully cover the code introduced by the step

Do not defer warning cleanup, test fixes, or coverage gaps to later commits.

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

## 2026.2.2 Coverage Highlights

- Config/auth compatibility:
  regression coverage for canonical `auth` and `models.providers` encoding,
  legacy provider-service decoding, and auth profile cooldown ordering.
- Provider catalog parity:
  snapshot-backed assertions for provider IDs, auth modes, base URLs, APIs, and
  default model IDs against the pinned OpenClaw TS reference commit.
- Apple hardware hardening:
  credential-store coverage for device-bound Keychain accessibility and Apple
  sample defaults that prefer Foundation Models only when runtime availability
  allows it.
- Example-app release scope:
  the `2026.2.2` validation gate covers the iOS and tvOS demos only; the
  visionOS demo is deferred from this release train.
